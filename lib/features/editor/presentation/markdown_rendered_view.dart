import 'dart:async' show Timer;
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderBox, RenderObject, RenderParagraph;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/haptics_helper.dart';
import '../../settings/providers/settings_provider.dart';
import '../domain/models/markdown_selection_range.dart';
import '../models/markdown_ast_nodes.dart';
import '../services/markdown_ast_parser.dart';
import 'providers/markdown_selection_provider.dart';
import 'widgets/blocks/markdown_block_style.dart';
import 'widgets/blocks/markdown_block_widget.dart';

/// Blocco individuato dalla risoluzione puntatore → offset documento, con
/// la `RenderBox` del suo wrapper.
///
/// Dichiarato a livello di file: un `typedef` non può essere annidato
/// dentro una classe (errore di compilazione), quindi vive qui pur
/// essendo un dettaglio privato di `_MarkdownRenderedViewState`.
typedef _BlockHit = ({MarkdownBlockNode node, RenderBox box});

/// Vista di sola lettura di una nota, renderizzata SEMPRE in Markdown
/// formattato: non esiste una modalità "testo grezzo" separata.
///
/// MOTORE DI VIRTUALIZZAZIONE (Fase 2, invariato): il testo sorgente viene
/// parsato UNA SOLA VOLTA in un albero [MarkdownBlockNode] (vedi
/// `MarkdownAstParser`) quando [content] cambia; durante lo scroll l'albero
/// non viene mai ricalcolato — solo i blocchi di primo livello effettivamente
/// vicini alla viewport corrente vengono istanziati come widget, tramite
/// `ListView.builder`. Il titolo della nota occupa sempre l'indice 0 dello
/// scroll, così da scorrere in perfetta sincronia coi blocchi del documento.
///
/// ## SELEZIONE (nuovo sistema, offset AST + Riverpod)
///
/// Questa vista NON contiene alcun pezzo del motore di selezione nativo di
/// Flutter: niente `SelectableRegion`, `SelectionArea`, `SelectionContainer`
/// né `SelectionRegistrar`. Il suo ruolo è esclusivamente quello di
/// **orchestratore**:
///
/// 1. esporre la superficie (scroll virtuale + titolo) renderizzata dai
///    [MarkdownBlockWidget], che si autosottoscrivono a
///    [markdownSelectionProvider] e si evidenziano da soli;
/// 2. tradurre i gesti del puntatore in offset del documento (vedi
///    [_resolveDocumentOffset]) e pilotare il ciclo
///    `startSelection` → `updateSelection` → `endSelection` del notifier;
/// 3. azionare l'auto-scroll durante il trascinamento vicino ai bordi;
/// 4. installare le scorciatoie desktop (Ctrl/Cmd+A, Ctrl/Cmd+C) tramite
///    [MarkdownSelectionShortcuts], che invoca a sua volta il notifier: la
///    copia resta "non distruttiva" perché passa sempre dal testo sorgente
///    integrale (`documentSource`).
///
/// ## CONTRATTO DI PRESTAZIONI
///
/// La vista **non fa alcun `ref.watch` dello stato di selezione**: durante il
/// drag il provider cambia stato a ogni pointer-move, e la `ListView` non
/// deve rebuildingarsi di conseguenza. I rebuild mirati avvengono nei singoli
/// blocchi (vedi la memoizzazione in `MarkdownBlockWidget`). Qui dentro lo
/// stato di selezione viene solo *letto* (`ref.read`) al momento del
/// tap-to-clear; il notifier è ottenuto via `ref.read(...notifier)`, che non
/// sottoscrive nulla.
///
/// ## POLITICA DEI DISPOSITIVI (risoluzione del conflitto drag/selezione
/// vs drag/scroll)
///
/// - **Mouse**: il drag con pulsante primario seleziona (paradigma desktop).
///   Lo scroll col mouse resta quello da rotellina; il trascinamento con il
///   mouse NON scrolla la lista perché [_NoGlowScrollBehavior] espone un
///   `dragDevices` che esclude esplicitamente il mouse — il gesto resta così
///   interamente dedicato alla selezione, senza competizioni nell'arena.
/// - **Touch / tablet / stilo**:
///   1. Lo swipe/drag rapido scrolla la `ListView` in modo fluido e nativo;
///   2. Il Long-Press (~300ms a dito fermo) attiva la modalità di selezione
///      con vibrazione aptica, commuta temporaneamente la fisica su
///      [NeverScrollableScrollPhysics] e consente di trascinare il dito per
///      selezionare il testo con auto-scroll automatico ai bordi;
///   3. Il tap singolo azzera la selezione attiva (come per il mouse).
/// - **Tap (qualsiasi dispositivo)**: se esiste una selezione attiva
///   (`isValid && !isCollapsed`), invoca `clearSelection()`.
class MarkdownRenderedView extends ConsumerStatefulWidget {
  /// Titolo della nota, renderizzato in testa allo scroll. NON fa parte del
  /// sorgente Markdown ([content]): un drag che parte dall'area del titolo
  /// viene risolto per clamp sull'offset `0`, così "Seleziona tutto"/copia
  /// restituiscono sempre e solo il documento Markdown, mai il titolo
  /// mescolato al corpo (stessa semantica della versione a selezione nativa).
  final String title;

  /// Testo Markdown integrale della nota: unica fonte di verità per AST,
  /// risoluzione puntatore→offset, `selectAll` e copia non distruttiva.
  final String content;

  const MarkdownRenderedView({
    super.key,
    required this.title,
    required this.content,
  });

  @override
  ConsumerState<MarkdownRenderedView> createState() =>
      _MarkdownRenderedViewState();
}

class _MarkdownRenderedViewState extends ConsumerState<MarkdownRenderedView>
    with SingleTickerProviderStateMixin {
  /// Controller dello scroll virtuale: è l'unico attuatore dell'auto-scroll
  /// durante il trascinamento della selezione (vedi [_handleAutoScrollTick]).
  final ScrollController _scrollController = ScrollController();

  /// FocusNode della superficie: passato a [MarkdownSelectionShortcuts] così
  /// le scorciatoie desktop (Ctrl/Cmd+A, Ctrl/Cmd+C) sono vive appena l'utente
  /// tocca la vista (vedi [_handlePointerDown]). Ownership e dispose restano
  /// di questo State: il wrapper dispone solo i nodi che crea internamente.
  final FocusNode _surfaceFocusNode =
      FocusNode(debugLabel: 'markdown-rendered-view-surface');

  /// Key della superficie di scroll (il [Listener] più esterno): fornisce la
  /// `RenderBox` della viewport usata per calcolare le soglie di bordo
  /// dell'auto-scroll in coordinate globali.
  final GlobalKey _scrollSurfaceKey =
      GlobalKey(debugLabel: 'markdown-scroll-surface');

  /// Registry dei blocchi di primo livello renderizzati: nodo → `GlobalKey`
  /// del wrapper del blocco. È la base della **risoluzione Livello 1**
  /// (quale blocco si trova sotto il puntatore): ogni `GlobalKey` dà accesso
  /// alla `RenderBox` del blocco, la cui banda verticale (incluso il padding
  /// di 16px che separa i blocchi) rende le bande stesse contigue e quindi la
  /// copertura dello scroll completa.
  ///
  /// Le chiavi dei blocchi virtualizzati via (contesto nullo) vengono potate
  /// pigramente in [_resolveDocumentOffset]; la mappa viene azzerata quando
  /// il contenuto viene riparsato. Le chiavi raddoppiano il ruolo di identità
  /// degli elementi della `ListView`: blocchi identici tra rebuild di solo
  /// stile riutilizzano lo stesso elemento.
  final Map<MarkdownBlockNode, GlobalKey> _blockKeys =
      <MarkdownBlockNode, GlobalKey>{};

  /// Ticker dell'auto-scroll: attivo solo mentre un drag di selezione è in
  /// corso; a ogni frame applica il delta di scroll e ri-proietta l'estremo
  /// mobile della selezione (vedi [_handleAutoScrollTick]).
  late final Ticker _autoScrollTicker;

  // Parser dell'AST: stateless e privo di side-effect (vedi
  // `MarkdownAstParser`), può essere condiviso in modo sicuro per tutta la
  // vita di questo State senza mai toccare DAO/database/sync.
  static const MarkdownAstParser _astParser = MarkdownAstParser();

  /// Margine di pre-materializzazione oltre la viewport, in px logici.
  ///
  /// NOTA: con il nuovo sistema di selezione a offset NON serve più forzare
  /// la realizzazione dell'intero documento per "Seleziona tutto" (era
  /// necessario per `SelectableRegion.selectAll`): la selezione è logica, e
  /// ogni blocco che entra nella viewport/缓存 extent si autosottoscrive al
  /// provider evidenziandosi correttamente. Rimane quindi un solo valore,
  /// quello di riposo.
  static const double _kIdleCacheExtent = 800.0;

  /// Soglia di movimento (px logici) oltre la quale un pointer-down passa da
  /// "tap candidato" a "drag di selezione". Allineata a `kTouchSlop` (18),
  /// replicata localmente per non dipendere da export non garantiti.
  static const double _kSelectionDragSlop = 18.0;

  /// Durata della pressione prolungata (long-press) su touch / tablet / stilo
  /// per attivare la modalità di selezione del testo (~300ms).
  static const Duration _kLongPressTimeout = Duration(milliseconds: 300);

  /// Banda di bordo (superiore/inferiore) della viewport che attiva
  /// l'auto-scroll durante il trascinamento, in px logici (~48dp).
  static const double _kAutoScrollEdgeThreshold = 48.0;

  /// Velocità massima di auto-scroll, in px logici al secondo, raggiunta in
  /// modo proporzionale all'avvicinamento del puntatore al bordo.
  static const double _kAutoScrollMaxVelocity = 900.0;

  /// Tetto sul delta-tempo per singolo tick: isola l'auto-scroll da salti
  /// enormi (GC/lag) che produrrebbero scatti di centinaia di pixel.
  static const double _kMaxFrameDeltaSeconds = 0.1;

  // Cache dell'AST: ricalcolato SOLO quando il testo sorgente è realmente
  // cambiato (confronto per identità/valore stringa in build), mai durante lo
  // scroll — è questo, insieme alla virtualizzazione della ListView sotto, a
  // garantire 60+ FPS anche su documenti > 50.000 parole.
  List<MarkdownBlockNode>? _cachedBlocks;
  String? _cachedContent;

  (ThemeData, String, double, double)? _cachedStyleKey;
  late MarkdownBlockStyle _blockStyle;
  late TextStyle _titleTextStyle;

  // ---------------------------------------------------------------------
  // Stato del gesto (macchina a stati locale, complementare e sincrona con
  // `isSelecting` del provider).
  // ---------------------------------------------------------------------

  /// Timer per l'attivazione della selezione tramite Long-Press su dispositivi
  /// touch / tablet / stilo.
  Timer? _longPressTimer;

  /// Id del puntatore tracciato (il primo che tocca la superficie); i
  /// puntatori successivi (multi-touch) vengono ignorati finché non termina.
  int? _trackedPointer;

  /// Posizione globale del pointer-down: è l'ANCORA della selezione quando
  /// il movimento supera [_kSelectionDragSlop].
  Offset? _pointerDownPosition;

  /// Ultima posizione globale nota del puntatore: usata dal ticker
  /// dell'auto-scroll per ri-proiettare la selezione mentre il contenuto
  /// scorre sotto un puntatore fermo.
  Offset _lastPointerPosition = Offset.zero;

  /// `true` da quando il drag ha superato lo slop (e quindi
  /// `startSelection` è stato invocato) fino al pointer-up. È il mirror
  /// locale di `MarkdownSelectionRange.isSelecting` durante il nostro gesto:
  /// tenerlo qui evita di leggere il provider a ogni tick.
  bool _selectionDragActive = false;

  /// `true` solo per drag che possono selezionare (mouse, pulsante
  /// primario). Per touch/stilo il drag è proprietà dello scroll nativo.
  bool _pointerCanDragSelect = false;

  /// Lettura del tempo dell'ultimo tick dell'auto-scroll (per il delta-t).
  Duration _lastAutoScrollElapsed = Duration.zero;

  /// Accesso one-shot al notifier della selezione: `ref.read` sul provider
  /// `.notifier` NON sottoscrive rebuild (l'istanza è stabile per tutta la
  /// vita del provider) — requisito di performance della vista.
  MarkdownSelectionNotifier get _selectionNotifier =>
      ref.read(markdownSelectionProvider.notifier);

  @override
  void initState() {
    super.initState();
    _autoScrollTicker = createTicker(_handleAutoScrollTick);
  }

  @override
  void dispose() {
    _cancelLongPressTimer();
    // Il ticker va fermato PRIMA del dispose (un Ticker attivo non può
    // essere disposto) — gestisce anche lo smontaggio a drag in corso.
    _stopAutoScrollTicker();
    _autoScrollTicker.dispose();
    _scrollController.dispose();
    _surfaceFocusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // Unico `watch` della vista: i soli parametri che influenzano lo stile.
    // Lo stato di selezione NON viene mai osservato qui (contratto di
    // performance): durante il drag la ListView non si rebuildinga.
    final (String fontFamily, double fontSize, double lineHeight) = ref.watch(
      settingsProvider.select((s) => (s.fontFamily, s.fontSize, s.lineHeight)),
    );

    _ensureParsedContent();
    _ensureStyles(theme, fontFamily, fontSize, lineHeight);

    final List<MarkdownBlockNode> blocks = _cachedBlocks!;
    final bool hasTitle = widget.title.trim().isNotEmpty;
    final int itemCount =
        (hasTitle ? 1 : 0) + (blocks.isEmpty ? 1 : blocks.length);

    // Superficie: scorciatoie desktop → Listener dei gesti → scroll virtuale.
    // `documentSource` restituisce il Markdown integrale CORRENTE al momento
    // della combinazione (closure su `widget`, quindi sempre aggiornata): è
    // ciò che rende la copia non distruttiva (testo sorgente, non renderizzato).
    return MarkdownSelectionShortcuts(
      documentSource: () => widget.content,
      focusNode: _surfaceFocusNode,
      child: Listener(
        key: _scrollSurfaceKey,
        // `opaque`: il Listener deve ricevere i pointer-event anche sulle
        // aree vuote della lista (sotto l'ultimo blocco, padding) per poter
        // gestire tap-clear e drag di selezione ovunque. Non consuma nulla:
        // link/bottoni eventualmente presenti nei blocchi continuano a
        // ricevere i propri gesti.
        behavior: HitTestBehavior.opaque,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        onPointerCancel: _handlePointerCancel,
        child: ScrollConfiguration(
          behavior: const _NoGlowScrollBehavior(),
          // `ListView.builder` opera unicamente sui nodi di primo livello
          // dell'AST: solo i blocchi effettivamente vicini alla viewport
          // corrente (più il margine dato da `cacheExtent`) vengono
          // istanziati nel widget tree. Il titolo occupa sempre l'indice 0,
          // così da scorrere in sincronia con i blocchi sottostanti.
          child: ListView.builder(
            key: const ValueKey('markdown-formatted-listview'),
            controller: _scrollController,
            physics: _selectionDragActive
                ? const NeverScrollableScrollPhysics()
                : null,
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
            cacheExtent: _kIdleCacheExtent,
            itemCount: itemCount,
            itemBuilder: (BuildContext context, int index) {
              if (hasTitle && index == 0) {
                return _buildTitleWidget(theme);
              }
              final int blockIndex = hasTitle ? index - 1 : index;
              if (blocks.isEmpty) {
                return _buildEmptyPlaceholder(theme);
              }
              return _buildTopLevelBlock(blocks[blockIndex]);
            },
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // CACHE: CONTENUTO E STILE
  // ---------------------------------------------------------------------

  /// Ri-parsing dell'AST SOLO se il testo sorgente è realmente cambiato:
  /// questo è ciò che rende il costo del parsing indipendente dal numero di
  /// frame di scroll/rebuild — non dal numero di caratteri del documento, che
  /// viene pagato una volta sola per modifica. Quando il contenuto cambia,
  /// vengono anche azzerate le chiavi di hit-test: i nuovi nodi otterranno
  /// `GlobalKey` fresche al prossimo pass dell'`itemBuilder`.
  void _ensureParsedContent() {
    if (_cachedContent == widget.content) return;
    _cachedContent = widget.content;
    _cachedBlocks = _astParser.parse(widget.content);
    _blockKeys.clear();
  }

  void _ensureStyles(
    ThemeData theme,
    String fontFamily,
    double fontSize,
    double lineHeight,
  ) {
    final key = (theme, fontFamily, fontSize, lineHeight);
    if (_cachedStyleKey == key) return;
    _cachedStyleKey = key;

    final isDark = theme.brightness == Brightness.dark;
    final primaryColor = theme.colorScheme.primary;

    final baseTextStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize,
      height: lineHeight,
      color: theme.colorScheme.onSurface,
    );

    final inlineCodeStyle = GoogleFonts.jetBrainsMono(
      fontSize: fontSize * 0.9,
      height: 1.4,
      color: theme.colorScheme.primary,
    );

    _titleTextStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize * 2.2,
      fontWeight: FontWeight.w800,
      color: theme.colorScheme.onSurface,
      height: 1.25,
    );

    final styleSheet = MarkdownStyleSheet(
      p: baseTextStyle,
      h1: AppTheme.getTextStyleForFont(
        fontFamily,
        fontSize: fontSize * 2.0,
        fontWeight: FontWeight.w800,
        color: theme.colorScheme.onSurface,
        height: 1.3,
      ),
      h2: AppTheme.getTextStyleForFont(
        fontFamily,
        fontSize: fontSize * 1.6,
        fontWeight: FontWeight.w700,
        color: theme.colorScheme.onSurface,
        height: 1.3,
      ),
      h3: AppTheme.getTextStyleForFont(
        fontFamily,
        fontSize: fontSize * 1.3,
        fontWeight: FontWeight.w600,
        color: theme.colorScheme.onSurface,
        height: 1.3,
      ),
      blockquote: baseTextStyle.copyWith(
        fontStyle: FontStyle.italic,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
      ),
      blockquoteDecoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(
            color: theme.colorScheme.primary,
            width: 4,
          ),
        ),
      ),
      blockquotePadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      code: inlineCodeStyle,
      codeblockDecoration: const BoxDecoration(),
      codeblockPadding: EdgeInsets.zero,
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.4),
            width: 1.5,
          ),
        ),
      ),
      tableBorder: TableBorder.all(
        color: theme.colorScheme.outline.withValues(alpha: 0.4),
        width: 1,
        borderRadius: BorderRadius.circular(4),
      ),
      tableHead: AppTheme.getTextStyleForFont(
        fontFamily,
        fontSize: fontSize * 0.95,
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.onSurface,
      ),
      tableBody: baseTextStyle.copyWith(
        fontSize: fontSize * 0.95,
      ),
      tableHeadAlign: TextAlign.center,
      tableCellsPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      listBullet: baseTextStyle.copyWith(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
      checkbox: TextStyle(
        color: theme.colorScheme.primary,
      ),
      a: TextStyle(
        color: theme.colorScheme.primary,
        decoration: TextDecoration.underline,
        fontWeight: FontWeight.w500,
      ),
    );

    _blockStyle = MarkdownBlockStyle(
      styleSheet: styleSheet,
      inlineCodeStyle: inlineCodeStyle,
      titleTextStyle: _titleTextStyle,
      fontFamily: fontFamily,
      fontSize: fontSize,
      isDark: isDark,
      primaryColor: primaryColor,
      onSurfaceColor: theme.colorScheme.onSurface,
      outlineColor: theme.colorScheme.outline,
    );
  }

  // ---------------------------------------------------------------------
  // BUILDER DEGLI ITEM
  // ---------------------------------------------------------------------

  Widget _buildTitleWidget(ThemeData theme) {
    return Align(
      key: const ValueKey('rendered-block-title'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Il titolo NON fa parte del sorgente Markdown e non compare nel
            // registry dei blocchi: nessun wrapper di selezione è più
            // necessario — l'esclusione è garantita a monte dalla mancanza
            // di offset sorgente. Un drag che parte da qui viene risolto,
            // per clamp, sull'offset 0 del documento.
            Text(
              widget.title,
              style: _titleTextStyle,
            ),
            const SizedBox(height: 16),
            Divider(
              color: theme.colorScheme.outline.withValues(alpha: 0.3),
              thickness: 1,
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyPlaceholder(ThemeData theme) {
    return Align(
      key: const ValueKey('rendered-block-empty'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Text(
          'Nessun contenuto',
          style: _blockStyle.styleSheet.p?.copyWith(
            fontStyle: FontStyle.italic,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }

  /// Costruisce il wrapper (allineamento + larghezza massima + spaziatura
  /// verticale) di UN SINGOLO blocco di primo livello, delegando il contenuto
  /// vero e proprio al dispatcher [MarkdownBlockWidget] — che si
  /// autosottoscrive al provider di selezione e non necessita di parametri
  /// aggiuntivi da questa vista.
  ///
  /// La `GlobalKey` assegnata al wrapper ha un DUPICE ruolo:
  /// 1. identità dell'elemento nella `ListView` — stabile per lo stesso nodo
  ///    tra rebuild di solo stile (tema/font/impostazioni), exactly come la
  ///    vecchia `ValueKey` derivata dagli offset;
  /// 2. àncora di hit-testing per la risoluzione puntatore→offset (Livello 1
  ///    in [_resolveDocumentOffset]): dalla key si risale alla `RenderBox`
  ///    del blocco, la cui banda verticale INCLUDE il padding inferiore di
  ///    16px, rendendo le bande dei blocchi contigue sulla superficie.
  Widget _buildTopLevelBlock(MarkdownBlockNode node) {
    final GlobalKey blockKey = _blockKeys.putIfAbsent(
      node,
      () => GlobalKey(debugLabel: 'markdown-block-${node.startOffset}'),
    );
    return Align(
      key: blockKey,
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: MarkdownBlockWidget(node: node, style: _blockStyle),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // GESTI: TAP-CLEAR + CICLO DRAG (start → update → end) + LONG-PRESS
  // ---------------------------------------------------------------------

  void _startLongPressTimer() {
    _cancelLongPressTimer();
    _longPressTimer = Timer(_kLongPressTimeout, _handleLongPressTimeout);
  }

  void _cancelLongPressTimer() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  void _handleLongPressTimeout() {
    _longPressTimer = null;
    if (!mounted || _pointerDownPosition == null || _trackedPointer == null) {
      return;
    }

    // Modalità selezione attivata via Long-Press:
    // 1. Vibrazione aptica di inizio selezione
    HapticsHelper.reportSelectionState(isCollapsed: false);

    // 2. Attivazione stato di selezione e proiezione posizione iniziale
    _selectionDragActive = true;
    _selectionNotifier.startSelection(
      _resolveDocumentOffset(_pointerDownPosition!),
    );
    _startAutoScrollTicker();

    // 3. Blocca temporaneamente la fisica dello scroll della ListView
    //    per evitare trascinamento concorrente della pagina durante la selezione.
    setState(() {});
  }

  void _handlePointerDown(PointerDownEvent event) {
    // Porta il focus sulla superficie: le scorciatoie (Ctrl/Cmd+A, Ctrl/Cmd+C)
    // diventano attive dal primo tocco. Se il focus è già qui (o su un
    // discendente, es. un link), non viene spostato.
    if (!_surfaceFocusNode.hasFocus) {
      _surfaceFocusNode.requestFocus();
    }

    // Puntatori successivi (secondo dito, click extra): ignorati.
    if (_trackedPointer != null) return;

    final bool isPrimaryMouse = event.kind == PointerDeviceKind.mouse &&
        (event.buttons & kPrimaryButton) != 0;

    // Click destro/centro del mouse: nessun gesto di selezione (restano
    // disponibili per menu contestuali futuri). Touch e stilo continuano a
    // essere tracciati per il tap-to-clear e per il long-press.
    if (event.kind == PointerDeviceKind.mouse && !isPrimaryMouse) return;

    _trackedPointer = event.pointer;
    _pointerDownPosition = event.position;
    _lastPointerPosition = event.position;
    _selectionDragActive = false;
    _pointerCanDragSelect = isPrimaryMouse;

    // Touch / tablet / stilo: avvia il timer di ~300ms per il Long-Press.
    // Se il dito resta fermo, scatta la selezione; se si muove oltre lo slop
    // prima dei 300ms (in _handlePointerMove), il timer viene cancellato
    // preservando lo scorrimento fluido nativo della ListView.
    final bool isTouchOrStylus = event.kind == PointerDeviceKind.touch ||
        event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;

    if (isTouchOrStylus) {
      _startLongPressTimer();
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_trackedPointer != event.pointer) return;
    _lastPointerPosition = event.position;

    // Touch / stilo: se il puntatore si muove oltre lo slop prima dei 300ms,
    // l'utente intende scrollare: cancelliamo il timer lasciando che la
    // ListView gestisca lo scorrimento nativo senza entrare in selezione.
    if (_longPressTimer != null) {
      final double distance =
          (event.position - _pointerDownPosition!).distance;
      if (distance >= _kSelectionDragSlop) {
        _cancelLongPressTimer();
      }
    }

    // Se la selezione non è attiva e il puntatore non è abilitato al drag immediato
    // (es. touch senza long-press scattato), non procediamo con la selezione.
    if (!_selectionDragActive && !_pointerCanDragSelect) return;

    if (!_selectionDragActive) {
      // Caso mouse: superamento dello slop per avviare la selezione immediata.
      final double distance =
          (event.position - _pointerDownPosition!).distance;
      if (distance < _kSelectionDragSlop) return; // ancora un "tap candidato"

      _selectionDragActive = true;
      _selectionNotifier.startSelection(
        _resolveDocumentOffset(_pointerDownPosition!),
      );
      HapticsHelper.reportSelectionState(isCollapsed: false);
      _startAutoScrollTicker();
    }

    // Aggiornamento continuo della selezione mentre il puntatore si muove.
    _selectionNotifier.updateSelection(_resolveDocumentOffset(event.position));
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_trackedPointer != event.pointer) return;
    _lastPointerPosition = event.position;
    _cancelLongPressTimer();
    _stopAutoScrollTicker();

    if (_selectionDragActive) {
      // Congelamento dell'estremo mobile sull'ultima posizione reale.
      _selectionDragActive = false;
      _selectionNotifier.updateSelection(
        _resolveDocumentOffset(event.position),
      );
      _selectionNotifier.endSelection();
      // Ripristina la fisica di scroll nativo
      setState(() {});
    } else {
      // Movimento rimasto sotto lo slop e timer non scattato: è un tap singolo.
      _maybeClearSelectionOnTap();
    }

    _trackedPointer = null;
    _pointerDownPosition = null;
    _pointerCanDragSelect = false;
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_trackedPointer != event.pointer) return;
    _cancelLongPressTimer();
    _stopAutoScrollTicker();

    if (_selectionDragActive) {
      // Gesto interrotto (focus perso, gesto competitor): la selezione viene
      // congelata così com'è — resta disponibile il tap-to-clear.
      _selectionDragActive = false;
      _selectionNotifier.endSelection();
      // Ripristina la fisica di scroll nativo
      setState(() {});
    }

    _trackedPointer = null;
    _pointerDownPosition = null;
    _pointerCanDragSelect = false;
  }

  /// Tap singolo: azzera la selezione SOLO se è davvero attiva, cioè se lo
  /// stato è valido e non degenere (`isValid && !isCollapsed`). La sentinella
  /// `noSelection` (`collapsed(-1)`) e un eventuale caret valido non
  /// triggerano nulla.
  void _maybeClearSelectionOnTap() {
    final MarkdownSelectionRange selection =
        ref.read(markdownSelectionProvider);
    if (selection.isValid && !selection.isCollapsed) {
      _selectionNotifier.clearSelection();
      HapticsHelper.reportSelectionState(isCollapsed: true);
    }
  }

  // ---------------------------------------------------------------------
  // AUTO-SCROLL DURANTE IL TRASCINAMENTO
  // ---------------------------------------------------------------------

  void _startAutoScrollTicker() {
    _lastAutoScrollElapsed = Duration.zero;
    if (!_autoScrollTicker.isActive) {
      _autoScrollTicker.start();
    }
  }

  void _stopAutoScrollTicker() {
    if (_autoScrollTicker.isActive) {
      _autoScrollTicker.stop();
    }
  }

  /// Un frame di auto-scroll: viene eseguito solo durante il drag di
  /// selezione ([_selectionDragActive], il mirror locale di `isSelecting`).
  ///
  /// Se il puntatore è entro [_kAutoScrollEdgeThreshold] dal bordo
  /// superiore/inferiore della viewport, scivola in avanti di
  /// `velocità · dt`, con velocità proporzionale alla vicinanza al bordo
  /// (rampa lineare fino a [_kAutoScrollMaxVelocity]) tramite
  /// [_scrollController]. Il target viene clampato agli estremi di scroll:
  /// ai margini del documento l'auto-scroll si ferma da solo.
  ///
  /// Dopo il `jumpTo` la geometria è aggiornata solo al frame successivo: la
  /// ri-proiezione dell'estremo mobile della selezione avviene quindi in
  /// `addPostFrameCallback`, con la layout fresca — il contenuto è scorso
  /// sotto un puntatore fermo, quindi l'offset documento è cambiato.
  void _handleAutoScrollTick(Duration elapsed) {
    if (!_selectionDragActive || _trackedPointer == null) return;

    final Duration delta = elapsed - _lastAutoScrollElapsed;
    _lastAutoScrollElapsed = elapsed;
    final double deltaTime = math.min(
      delta.inMicroseconds / Duration.microsecondsPerSecond,
      _kMaxFrameDeltaSeconds,
    );
    if (deltaTime <= 0.0) return;

    final BuildContext? surfaceContext = _scrollSurfaceKey.currentContext;
    final RenderObject? surfaceObject = surfaceContext?.findRenderObject();
    if (surfaceObject is! RenderBox || !surfaceObject.attached) return;

    final Offset localPosition =
        surfaceObject.globalToLocal(_lastPointerPosition);
    final double viewportHeight = surfaceObject.size.height;

    double velocity = 0.0;
    if (localPosition.dy < _kAutoScrollEdgeThreshold) {
      // Banda superiore: scroll verso l'alto (delta negativo). Se il puntatore
      // esce completamente dalla viewport, la prossimità satura a 1.
      final double proximity = _clamp01(
        (_kAutoScrollEdgeThreshold - localPosition.dy) /
            _kAutoScrollEdgeThreshold,
      );
      velocity = -_kAutoScrollMaxVelocity * proximity;
    } else if (localPosition.dy >
        viewportHeight - _kAutoScrollEdgeThreshold) {
      // Banda inferiore: scroll verso il basso.
      final double proximity = _clamp01(
        (localPosition.dy - (viewportHeight - _kAutoScrollEdgeThreshold)) /
            _kAutoScrollEdgeThreshold,
      );
      velocity = _kAutoScrollMaxVelocity * proximity;
    }

    if (velocity == 0.0 || !_scrollController.hasClients) return;

    final ScrollPosition position = _scrollController.position;
    final double clampedPixels = math.max(
      position.minScrollExtent,
      math.min(
        position.maxScrollExtent,
        position.pixels + velocity * deltaTime,
      ),
    );
    if (clampedPixels == position.pixels) return; // già al bordo documento

    position.jumpTo(clampedPixels);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_selectionDragActive) return;
      _selectionNotifier
          .updateSelection(_resolveDocumentOffset(_lastPointerPosition));
    });
  }

  // ---------------------------------------------------------------------
  // RISOLUZIONE PUNTATORE → OFFSET DOCUMENTO
  // ---------------------------------------------------------------------

  /// Converte una posizione globale del puntatore in un offset assoluto sul
  /// documento Markdown sorgente (lo stesso spazio di
  /// [MarkdownNode.startOffset]/[MarkdownNode.endOffset] e di
  /// [markdownSelectionProvider]).
  ///
  /// Pipeline a due livelli:
  ///
  /// - **Livello 1 — blocco**: si individuano i blocchi di primo livello
  ///   attualmente materializzati (via [_blockKeys]) e si trova quello la cui
  ///   banda verticale contiene il puntatore. Le bande sono contigue (il
  ///   padding inter-blocco è dentro il wrapper), quindi la copertura è
  ///   completa; nelle gutter laterali (padding orizzontale della lista) vale
  ///   comunque la banda in y.
  /// - **Livello 2 — geometria del testo**: dentro il blocco si cercano i
  ///   `RenderParagraph` del sottoalbero e si usa `getPositionForOffset` per
  ///   ricavare l'offset relativo al testo renderizzato; il tutto viene
  ///   proiettato proporzionalmente sul range sorgente del blocco
  ///   `[node.startOffset, node.endOffset]`. In assenza di geometria interna
  ///   (thematic break, formule, gap di padding) si applica il **fallback
  ///   lineare** sull'altezza del blocco.
  ///
  /// Fuori dal contenuto (titolo, padding estremi, documento vuoto) il
  /// risultato è clampato a `0` o alla lunghezza del documento in base alla
  /// posizione verticale.
  int _resolveDocumentOffset(Offset globalPosition) {
    final int documentLength = _cachedContent?.length ?? 0;

    // Potatura pigra: le chiavi dei blocchi virtualizzati via (elemento
    // smontato) non servono più né alla hit-test né all'identità — l'itemBuilder
    // ne creerà di fresche se il blocco rientra in viewport.
    _blockKeys.removeWhere(
      (MarkdownBlockNode node, GlobalKey key) => key.currentContext == null,
    );

    _BlockHit? containedHit; // banda in y + contenimento anche in x
    _BlockHit? bandHit; // sola banda in y (gutter laterali)
    bool hasLiveBlocks = false;
    double topmostBandTop = 0.0;
    double bottomBandBottom = 0.0;

    for (final MapEntry<MarkdownBlockNode, GlobalKey> entry
        in _blockKeys.entries) {
      final BuildContext? elementContext = entry.value.currentContext;
      if (elementContext == null) continue;
      final RenderObject? renderObject = elementContext.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) continue;

      final double bandTop = renderObject.localToGlobal(Offset.zero).dy;
      final double bandBottom = bandTop + renderObject.size.height;
      if (!hasLiveBlocks) {
        hasLiveBlocks = true;
        topmostBandTop = bandTop;
        bottomBandBottom = bandBottom;
      } else {
        if (bandTop < topmostBandTop) topmostBandTop = bandTop;
        if (bandBottom > bottomBandBottom) bottomBandBottom = bandBottom;
      }

      if (globalPosition.dy < bandTop || globalPosition.dy > bandBottom) {
        continue;
      }

      final Offset local = renderObject.globalToLocal(globalPosition);
      final bool containsX =
          local.dx >= 0.0 && local.dx <= renderObject.size.width;
      if (containsX) {
        containedHit = (node: entry.key, box: renderObject);
      } else {
        bandHit ??= (node: entry.key, box: renderObject);
      }
    }

    final _BlockHit? hit = containedHit ?? bandHit;
    if (hit != null) {
      final int? viaTextGeometry =
          _resolveOffsetViaTextGeometry(hit, globalPosition);
      if (viaTextGeometry != null) return viaTextGeometry;
      return _resolveOffsetByBlockHeight(hit, globalPosition);
    }

    if (!hasLiveBlocks) return 0; // documento vuoto / nulla materializzato
    if (globalPosition.dy < topmostBandTop) return 0; // titolo / padding alto
    if (globalPosition.dy > bottomBandBottom) {
      return documentLength; // padding basso / oltre l'ultimo blocco
    }
    // Teoricamente irraggiungibile (bande contigue): nearest-boundary clamp.
    return (globalPosition.dy - topmostBandTop) <=
            (bottomBandBottom - globalPosition.dy)
        ? 0
        : documentLength;
  }

  /// Livello 2, via geometria del testo: raccoglie in ordine di disegno tutti
  /// i [RenderParagraph] del sottoalbero del blocco (paragrafo singolo, item
  /// di lista, celle di tabella, righe di codice, ...), individua quello che
  /// contiene il puntatore e combina
  /// `(caratteri prima) + offset nel paragrafo` sul totale dei caratteri
  /// renderizzati del blocco. La frazione risultante viene proiettata sul
  /// range sorgente `[node.startOffset, node.endOffset]`: per blocchi il cui
  /// testo renderizzato coincide col sorgente la mappa è pressoché identità,
  /// per gli altri (heading senza cancelletti, code senza fence, marcatori di
  /// lista) resta una proiezione proporzionale stabile e monotona.
  ///
  /// Ritorna `null` quando non esiste geometria testuale utile (nessun
  /// paragrafo, testo vuoto, puntatore tra due run di testo): il chiamante
  /// applica allora il fallback lineare.
  int? _resolveOffsetViaTextGeometry(
      _BlockHit hit, Offset globalPosition) {
    final List<(RenderParagraph, int)> paragraphs = <(RenderParagraph, int)>[];
    _collectTextParagraphs(hit.box, paragraphs);
    if (paragraphs.isEmpty) return null;

    int totalCharacters = 0;
    for (final (_, int length) in paragraphs) {
      totalCharacters += length;
    }
    if (totalCharacters == 0) return null;

    int charactersBefore = 0;
    for (final (RenderParagraph paragraph, int length) in paragraphs) {
      final Offset local = paragraph.globalToLocal(globalPosition);
      if (!_containsPointInclusively(paragraph, local)) {
        charactersBefore += length;
        continue;
      }
      final TextPosition textPosition = paragraph.getPositionForOffset(local);
      final int relative =
          math.max(0, math.min(length, textPosition.offset));
      return _projectToSourceRange(
        hit.node,
        (charactersBefore + relative) / totalCharacters,
      );
    }
    return null;
  }

  /// Fallback lineare: proietta la posizione verticale del puntatore
  /// sull'altezza totale del blocco e poi sul range sorgente del nodo.
  /// Usato per blocchi senza geometria testuale interrogabile.
  int _resolveOffsetByBlockHeight(_BlockHit hit, Offset globalPosition) {
    final Offset local = hit.box.globalToLocal(globalPosition);
    final double height = hit.box.size.height;
    if (height <= 0.0) return hit.node.startOffset;
    return _projectToSourceRange(hit.node, local.dy / height);
  }

  /// Proiezione di una frazione `0..1` sull'intervallo sorgente del nodo.
  int _projectToSourceRange(MarkdownBlockNode node, double fraction) {
    final double clamped = _clamp01(fraction);
    return node.startOffset + (clamped * node.length).round();
  }

  /// Visita ricorsiva del sottoalbero di render del blocco, raccogliendo i
  /// [RenderParagraph] in ordine di disegno (≈ ordine di lettura) insieme
  /// alla lunghezza del loro testo plain (calcolata una sola volta).
  void _collectTextParagraphs(
    RenderObject renderObject,
    List<(RenderParagraph, int)> out,
  ) {
    if (renderObject is RenderParagraph) {
      out.add((renderObject, renderObject.text.toPlainText().length));
      return;
    }
    renderObject.visitChildren((RenderObject child) {
      _collectTextParagraphs(child, out);
    });
  }

  bool _containsPointInclusively(RenderBox box, Offset local) {
    return local.dx >= 0.0 &&
        local.dy >= 0.0 &&
        local.dx <= box.size.width &&
        local.dy <= box.size.height;
  }

  double _clamp01(double value) {
    if (value < 0.0) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
  }
}

/// Comportamento di scroll della superficie:
///
/// - nessun indicatore di overscroll (glow/edge) — coerente col look
///   precedente;
/// - `dragDevices` ESPLICITO e senza mouse: il drag col mouse non scrolla
///   mai la lista, quindi resta interamente dedicato alla selezione (non
///   compete con nessun riconoscitore nell'arena dei gesti). Touch e stilo
///   mantengono lo scroll nativo; la rotellina/trackpad scrollano come prima
///   (non passano da `dragDevices`).
class _NoGlowScrollBehavior extends ScrollBehavior {
  const _NoGlowScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
      BuildContext context, Widget child, ScrollableDetails details) {
    return child;
  }

  @override
  Set<PointerDeviceKind> get dragDevices => const <PointerDeviceKind>{
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.unknown,
      };
}