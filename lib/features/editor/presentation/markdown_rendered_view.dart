import 'dart:async' show Timer;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, ValueListenable, ValueNotifier;
import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerCancelEvent,
        PointerDownEvent,
        PointerEvent,
        PointerHoverEvent,
        PointerRemovedEvent,
        PointerUpEvent,
        kSecondaryButton,
        kTertiaryButton,
        kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart'
    show cupertinoTextSelectionControls, cupertinoDesktopTextSelectionControls;
import 'package:flutter_md/flutter_md.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/markdown_math.dart';
import '../../../core/utils/haptics_helper.dart';
import '../../../core/utils/link_safety.dart';
import '../../../core/utils/selection_auto_scroller.dart';
import '../../settings/providers/settings_provider.dart';
import 'package:flutter_math_fork/flutter_math.dart' show ParseException;
import 'package:flutter_math_fork/tex.dart'
    show SyntaxTree, TexParser, TexParserSettings;
import 'code_block_with_copy.dart';
import 'display_math_block.dart';

/// Vista di sola lettura di una nota, renderizzata SEMPRE in Markdown
/// formattato: non esiste più una modalità "testo grezzo" separata.
///
/// Il rendering usa `flutter_md` (vedi pubspec.yaml): la nota resta divisa in
/// blocchi dentro una `ListView.builder` virtualizzata (un blocco Markdown
/// per item, vedi `_buildItem`) per continuare a beneficiare della
/// virtualizzazione su note molto lunghe, ma a differenza del vecchio motore
/// (`flutter_markdown_plus`) la selezione di testo non richiede più alcun
/// trucco di realizzazione forzata: `MarkdownSelectionController` ancora la
/// selezione al modello dati immutabile (`Markdown`/`MD$...`) invece che ai
/// `RenderObject` a schermo, quindi resta corretta — "Seleziona tutto"
/// incluso — anche per blocchi mai costruiti o già scomparsi dalla
/// `cacheExtent` di default.
///
/// Unica eccezione alla virtualizzazione: i (al massimo 2) blocchi che
/// contengono gli estremi della selezione restano montati finché la
/// selezione esiste, altrimenti le maniglie non tornerebbero dopo aver
/// scrollato lontano (vedi `_KeepAliveWhileSelectionEdge`).
class MarkdownRenderedView extends ConsumerStatefulWidget {
  final String title;
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
  final ScrollController _scrollController = ScrollController();
  final FocusNode _selectionFocusNode = FocusNode(debugLabel: 'markdown-selection');

  // Il gruppo coordina la selezione "anchored al modello" del corpo
  // (`MarkdownSelectionController`, sotto) con la selezione nativa e
  // indipendente del titolo (un semplice `SelectableText`, vedi
  // `_buildTitleWidget`): flutter_md non ha un punto di estensione per
  // includere un widget arbitrario non-Markdown nella stessa selezione
  // ancorata, quindi il titolo resta un `SelectableText` a parte. Il gruppo
  // garantisce almeno che avviare una selezione nel titolo cancelli quella
  // nel corpo (vedi `onSelectionChanged` di `_buildTitleWidget`); il
  // percorso inverso (selezionare nel corpo mentre il titolo ha già una
  // selezione attiva) non è coperto da un punto di estensione equivalente
  // lato `SelectableText` e resta una piccola imperfezione nota — prima
  // della migrazione titolo e corpo condividevano un'unica `SelectableRegion`
  // nativa, quindi un'unica selezione continua tra i due non è più possibile.
  final MarkdownSelectionGroup _selectionGroup = MarkdownSelectionGroup();
  late final MarkdownSelectionController _selectionController =
      MarkdownSelectionController(group: _selectionGroup);

  // --- Problema 2: tocco a vuoto non annulla più la selezione -------------
  // L'API pubblica di `MarkdownSelectionScope`/`MarkdownSelectionScopeState`
  // (v0.2.0) non espone un parametro tipo `clearOnTapOutside`/`dismissOnTap`
  // (verificato su README/changelog del pacchetto): lo stato pubblico offre
  // solo `copySelection` / `selectAll` / `clearSelection` / `showToolbar` /
  // `contextMenuButtonItems` / `contextMenuAnchors`. Serve quindi gestirlo a
  // mano, con un `GlobalKey` sullo stato dello scope per poter chiamare
  // `clearSelection()` da fuori.
  final GlobalKey<MarkdownSelectionScopeState> _selectionScopeKey =
      GlobalKey<MarkdownSelectionScopeState>();
  MarkdownSelection? _activeSelection;

  // --- Auto-scroll durante il trascinamento della selezione ----------------
  // `MarkdownSelectionScope` (flutter_md 0.2.0) non ha alcun auto-scroll:
  // trascinando una selezione verso il bordo la `ListView` restava ferma
  // (esiste solo una PR upstream non ancora rilasciata, DoctorinaAI/md#30).
  // Lo fa quindi questo componente, usando solo API pubbliche: osserva i
  // puntatori, e mentre un dito/mouse trascina una selezione nella fascia di
  // bordo fa scorrere `_scrollController` in modo continuo, anche a dito
  // fermo (vedi la doc di `SelectionAutoScroller`).
  late final SelectionAutoScroller _autoScroller;
  MarkdownSelection? _lastObservedSelection;

  // Id dei blocchi da tenere vivi: `(base, extent)` PUBBLICATI, oppure
  // `(null, null)` se non c'è una selezione vera (assente o collassata:
  // senza range non ci sono maniglie). Lo ascoltano SOLO i blocchi montati
  // (vedi `_KeepAliveWhileSelectionEdge`), che si tengono vivi finché sono un
  // estremo. I record hanno uguaglianza per valore: il notifier avvisa solo
  // se cambia davvero un estremo.
  //
  // Durante un gesto NON coincide con gli estremi reali della selezione
  // (`_latestEdgeIds`): la pubblicazione è parziale, vedi `_syncEdgeIds`.
  final ValueNotifier<(String?, String?)> _selectionEdgeIds =
      ValueNotifier<(String?, String?)>((null, null));

  // Estremi REALI `(base, extent)` dell'ultima selezione osservata, sempre
  // aggiornati (`(null, null)` se non c'è una selezione vera).
  (String?, String?) _latestEdgeIds = (null, null);

  // Puntatori attualmente premuti, in QUALSIASI punto dello schermo (le
  // maniglie vivono in un `OverlayEntry`, fuori da ogni `Listener` di questa
  // vista): pointer -> device. Serve solo a sapere se è in corso un gesto
  // (vedi `_syncEdgeIds`); lo mantiene `_trackPressedPointers`.
  final Map<int, int> _pressedPointers = <int, int>{};

  // Nel gesto in corso l'ancora è già stata pubblicata una volta (vedi
  // `_syncEdgeIds`): da qui al rilascio lo stato pubblicato non cambia più.
  bool _anchorPublishedInGesture = false;

  // Rilevamento del "tap a vuoto" fatto a mano su eventi puntatore grezzi
  // (`Listener`), non con un `GestureDetector`/`TapGestureRecognizer`.
  // Motivo: un `TapGestureRecognizer` partecipa alla gesture arena, e se da
  // qualche parte nell'albero (verosimilmente dentro `MarkdownSelectionScope`,
  // per il doppio-tap-seleziona-parola) esiste anche un
  // `DoubleTapGestureRecognizer` sulla stessa arena, QUALSIASI tap recognizer
  // — incluso questo — deve attendere la finestra di disambiguazione
  // doppio-tap (~300ms) prima di potersi dichiarare vincitore: è il ritardo
  // percepito segnalato. Un `Listener` riceve gli eventi subito, fuori
  // dall'arena, quindi non ha questo ritardo — a costo di dover replicare a
  // mano la logica minima di "è stato un tap breve, non un drag né un
  // long-press" (soglia di spostamento + soglia di durata), usando le stesse
  // costanti che userebbe Flutter internamente.
  //
  // La soglia di DURATA è un `Timer` (vedi `_PendingTap`), NON un confronto
  // fra due `DateTime.now()`: il `Timer` segue l'orologio della `Zone`
  // corrente, quindi nei test (`FakeAsync`, dove `tester.pump(Duration)` fa
  // avanzare solo l'orologio finto) un long-press simulato scade davvero
  // dopo `_tapMaxDuration`, esattamente come su un dispositivo. Con
  // `DateTime.now()` (orologio di sistema, non toccato da `FakeAsync`) un
  // long-press di test sembrava durare ~0 ms, veniva scambiato per un tap
  // breve e `_handleBackgroundPointerUp` annullava subito la selezione appena
  // creata dal long-press.
  //
  // Invariante: `_pendingTapPointers` contiene SOLO puntatori ancora
  // candidati a essere un tap breve (premuti da meno di `_tapMaxDuration` e
  // mai spostati oltre `_tapTouchSlop`). Tutto ciò che li squalifica (scadenza
  // del timer, movimento, cancel, up) li toglie dalla mappa e annulla il
  // loro timer; `dispose()` annulla quelli ancora in corsa. Così non resta
  // mai un `Timer` vivo oltre la vita del widget.
  static const double _tapTouchSlop = kTouchSlop; // ~18px
  static const Duration _tapMaxDuration = Duration(milliseconds: 500); // ~kLongPressTimeout
  final Map<int, _PendingTap> _pendingTapPointers = <int, _PendingTap>{};

  TextSelectionControls get _platformSelectionControls {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return cupertinoTextSelectionControls;
      case TargetPlatform.macOS:
        return cupertinoDesktopTextSelectionControls;
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return materialTextSelectionControls;
    }
  }

  // Elementi della lista: blocchi Markdown (uno per item, con il proprio
  // `documentId` per la selezione) e formule a blocco `$$...$$`, che
  // `flutter_md` non gestisce e sono quindi widget a sé (vedi
  // `markdown_math.dart`). Le formule non sono registrate nella selezione
  // ancorata al modello: restano fuori dal testo selezionato/copiato.
  List<_ViewItem> _items = const [];

  (ThemeData, String, double, double)? _cachedThemeKey;
  late MarkdownThemeData _markdownTheme;
  late TextStyle _titleTextStyle;
  late TextStyle _mathTextStyle;
  late Color _codeSurfaceColor;

  @override
  void initState() {
    super.initState();
    _autoScroller = SelectionAutoScroller(
      vsync: this,
      scrollController: _scrollController,
      viewportRect: _viewportGlobalRect,
      onScrollingChanged: (scrolling) =>
          HapticsHelper.selectionAutoScrollActive = scrolling,
    );
    // Route GLOBALE (come quella dell'auto-scroller, indipendente da essa):
    // vede anche i puntatori che non passano per il `Listener` di questa
    // vista, come quello che trascina una maniglia.
    GestureBinding.instance.pointerRouter.addGlobalRoute(_trackPressedPointers);
    _selectionController.addListener(_onSelectionControllerChanged);
    _updateBlocks(widget.content);
  }

  // Il controller notifica anche per motivi diversi dalla selezione (es.
  // `setDocuments`): si segnala all'auto-scroller solo un VERO cambio di
  // valore della selezione (`MarkdownSelection` ha uguaglianza per valore),
  // altrimenti un normale scroll a dito potrebbe essere scambiato per un
  // trascinamento di selezione.
  void _onSelectionControllerChanged() {
    final selection = _selectionController.selection;
    if (selection == _lastObservedSelection) return;
    _lastObservedSelection = selection;
    _latestEdgeIds = _edgeIdsOf(selection);
    _syncEdgeIds();
    if (selection != null) _autoScroller.notifySelectionChanged();
  }

  /// Pubblica gli estremi da tenere vivi (`_selectionEdgeIds`).
  ///
  /// A RIPOSO (nessun puntatore premuto) si pubblicano subito gli estremi
  /// reali. Durante un GESTO no: lì la selezione cambia a ogni evento
  /// puntatore e, con i blocchi spaziatori fra un paragrafo e l'altro, ogni
  /// attraversamento di uno "spazio vuoto" cambia il blocco dell'estremo.
  /// Se il keep-alive lo seguisse in tempo reale, ogni cambio farebbe
  /// scattare in sincrono, dentro la `notifyListeners()` del controller e
  /// PRIMA dei listener del pacchetto, un rilascio + un nuovo keep-alive su
  /// due blocchi: una mutazione strutturale della lista (`markNeedsLayout`
  /// dello sliver, garbage collection, attach/detach dei `RenderObject` che
  /// il controller usa come superfici) a ogni evento del drag. In 0.9.8 lo
  /// stesso evento era un semplice repaint. Durante il gesto quindi:
  ///
  /// - l'ANCORA (`base`, l'estremo fisso) si pubblica subito, ma al massimo
  ///   UNA volta per gesto: in un trascinamento di maniglia non cambia mai
  ///   (nessun churn); nasce o cambia una sola volta se il gesto crea una
  ///   nuova selezione (long-press + trascinamento senza staccare il dito:
  ///   l'auto-scroll può portarla lontano prima del rilascio). Se cambiasse
  ///   a ogni evento (maniglie scavalcate l'una sull'altra) vale comunque
  ///   solo il primo cambio: il resto aspetta il rilascio;
  /// - l'estremo MOBILE (`extent`) resta quello già pubblicato: segue il dito,
  ///   quindi è sempre in viewport e non serve tenerlo vivo finché il dito è
  ///   giù. Si pubblica al rilascio (`_flushEdgeIds`).
  void _syncEdgeIds() {
    final latest = _latestEdgeIds;
    if (_pressedPointers.isEmpty) {
      _selectionEdgeIds.value = latest;
      return;
    }
    final published = _selectionEdgeIds.value;
    if (!_anchorPublishedInGesture && latest.$1 != published.$1) {
      _anchorPublishedInGesture = true;
      _selectionEdgeIds.value = (latest.$1, published.$2);
    }
  }

  /// Pubblica gli estremi reali (fine del gesto).
  void _flushEdgeIds() {
    _anchorPublishedInGesture = false;
    _selectionEdgeIds.value = _latestEdgeIds;
  }

  /// Route globale: tiene aggiornato `_pressedPointers` e, quando l'ultimo
  /// puntatore viene rilasciato, pubblica gli estremi reali.
  ///
  /// Ordine di consegna (`PointerRouter.route`): prima le route dei
  /// recognizer del puntatore (quindi la fine del drag di una maniglia, nel
  /// pacchetto), poi quelle globali: qui la selezione è già "assestata".
  void _trackPressedPointers(PointerEvent event) {
    if (event is PointerDownEvent) {
      if (_pressedPointers.isEmpty) _anchorPublishedInGesture = false;
      _pressedPointers[event.pointer] = event.device;
      return;
    }
    final bool released;
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      released = _pressedPointers.remove(event.pointer) != null;
    } else if (event is PointerHoverEvent || event is PointerRemovedEvent) {
      // Rete di sicurezza (stessa dell'auto-scroller): un hover o una
      // rimozione dello stesso device significa che non è più premuto, anche
      // se il suo `PointerUp` non è mai arrivato (mouse rilasciato fuori
      // dalla finestra). Senza, il gesto resterebbe "aperto" per sempre.
      final before = _pressedPointers.length;
      _pressedPointers.removeWhere((_, device) => device == event.device);
      released = _pressedPointers.length != before;
    } else {
      return;
    }
    if (released && _pressedPointers.isEmpty) _flushEdgeIds();
  }

  // Id dei blocchi con base ed extent. `documentId` è un `Object` opaco per
  // il pacchetto, ma qui è sempre la stringa 'block-N' di `_updateBlocks`.
  static (String?, String?) _edgeIdsOf(MarkdownSelection? selection) {
    if (selection == null || selection.isCollapsed) return (null, null);
    final base = selection.base.documentId;
    final extent = selection.extent.documentId;
    return (base is String ? base : null, extent is String ? extent : null);
  }

  @override
  void didUpdateWidget(covariant MarkdownRenderedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      _updateBlocks(widget.content);
    }
  }

  @override
  void dispose() {
    // Prima di tutto i timer: nessun callback deve poter girare dopo lo
    // smontaggio (in un test sarebbe "A Timer is still pending even after
    // the widget tree was disposed").
    _cancelAllPendingTaps();
    GestureBinding.instance.pointerRouter
        .removeGlobalRoute(_trackPressedPointers);
    _pressedPointers.clear();
    // Il timer di riarmo dell'aptica è statico (vive in `HapticsHelper`) e
    // l'ultimo `onSelectionChanged` può averlo appena avviato (selezione
    // appena annullata): va annullato qui, altrimenti sopravvive al widget.
    HapticsHelper.resetSelectionState();
    _selectionController.removeListener(_onSelectionControllerChanged);
    _selectionEdgeIds.dispose();
    _autoScroller.dispose();
    _scrollController.dispose();
    _selectionFocusNode.dispose();
    _selectionController.dispose();
    super.dispose();
  }

  // Ricalcola i blocchi e li registra sul controller di selezione. Chiamato
  // da `initState`/`didUpdateWidget` (mai da dentro `build`) perché
  // `setDocuments` notifica il controller, e farlo mentre QUESTO widget è a
  // sua volta nel mezzo del proprio `build` rischierebbe di richiedere un
  // nuovo rebuild di un discendente (`MarkdownSelectionScope`) già costruito
  // in questo stesso frame.
  void _updateBlocks(String content) {
    final effectiveContent = content.isEmpty ? '*Nessun contenuto*' : content;
    final items = <_ViewItem>[];
    final documents = <MarkdownDocumentRef>[];

    // 1) Le formule a blocco `$$...$$` vengono estratte prima del parsing
    //    (fuori da code fence/blocchi indentati); 2) ogni tratto Markdown è
    //    parsato con `inlineMath: true` (`$...$` -> Unicode), dopo una
    //    normalizzazione dei costrutti LaTeX comuni non coperti dal
    //    pacchetto (`\text{..}`, `\frac{..}{..}` semplici, ...).
    // `flutter_md` espone già i blocchi tramite il proprio modello
    // (`Markdown.fromString(...).blocks`): niente splitter manuale a righe.
    for (final chunk in splitNoteChunks(effectiveContent)) {
      switch (chunk) {
        case MarkdownChunk(:final source):
          if (source.trim().isEmpty) continue;
          final blocks = Markdown.fromString(
            normalizeInlineMath(source),
            inlineMath: true,
          ).blocks;
          for (final block in blocks) {
            final id = 'block-${documents.length}';
            items.add(_BlockItem(block, id));
            documents.add(
              MarkdownDocumentRef(
                id: id,
                model: Markdown(
                  markdown: markdownBlockRenderedText(block),
                  blocks: [block],
                ),
                order: documents.length,
              ),
            );
          }
        case DisplayMathChunk(:final tex):
          items.add(_MathItem(tex));
      }
    }

    _items = items;
    _selectionController.setDocuments(documents);
  }

  void _ensureTheme(
    ThemeData theme,
    String fontFamily,
    double fontSize,
    double lineHeight,
  ) {
    final key = (theme, fontFamily, fontSize, lineHeight);
    if (_cachedThemeKey == key) return;
    _cachedThemeKey = key;

    final isDark = theme.brightness == Brightness.dark;

    final baseTextStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize,
      height: lineHeight,
      color: theme.colorScheme.onSurface,
    );

    _titleTextStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize * 2.2,
      fontWeight: FontWeight.w800,
      color: theme.colorScheme.onSurface,
      height: 1.25,
    );

    TextStyle headingStyle(double scale, FontWeight weight, {Color? color}) {
      return AppTheme.getTextStyleForFont(
        fontFamily,
        fontSize: fontSize * scale,
        fontWeight: weight,
        color: color ?? theme.colorScheme.onSurface,
        height: 1.3,
      );
    }

    // Sfondo condiviso da citazioni, blocchi di codice e tabelle
    // (`MarkdownThemeData.surfaceColor` copre tutti e tre, non c'è un hook
    // separato per ciascuno come nel vecchio `MarkdownStyleSheet`): stessa
    // tinta usata prima per lo sfondo dei blocchi di codice, che resta
    // l'elemento visivamente più caratterizzato.
    final surfaceColor =
        isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5);
    // Sfondo del testo monospace (inline e a blocco condividono lo stesso
    // campo in questa versione del pacchetto): tinta leggermente più chiara,
    // vicina a quella usata prima solo per il code inline.
    final monospaceBackgroundColor =
        isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEFEFEF);

    _codeSurfaceColor = surfaceColor;
    _mathTextStyle = TextStyle(
      fontSize: fontSize * 1.15,
      color: theme.colorScheme.onSurface,
    );

    _markdownTheme = MarkdownThemeData.mergeTheme(
      theme,
      textStyle: baseTextStyle,
      h1Style: headingStyle(2.0, FontWeight.w800),
      h2Style: headingStyle(1.6, FontWeight.w700),
      h3Style: headingStyle(1.3, FontWeight.w600),
      // h4-h6 non erano personalizzati nel vecchio MarkdownStyleSheet (si
      // affidava agli stili di default del pacchetto): questa scala
      // discendente è una scelta autonoma presa per questa migrazione, per
      // avere comunque una gerarchia coerente coi livelli superiori.
      h4Style: headingStyle(1.15, FontWeight.w600),
      h5Style: headingStyle(1.05, FontWeight.w600),
      h6Style: headingStyle(
        1.0,
        FontWeight.w600,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
      ),
      quoteStyle: baseTextStyle.copyWith(
        fontStyle: FontStyle.italic,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
      ),
      linkColor: theme.colorScheme.primary,
      linkStyle: const TextStyle(
        decoration: TextDecoration.underline,
        fontWeight: FontWeight.w500,
      ),
      surfaceColor: surfaceColor,
      monospaceBackgroundColor: monospaceBackgroundColor,
      dividerColor: theme.colorScheme.outline.withValues(alpha: 0.4),
      onLinkTap: (title, url) async {
        // Solo http, https e mailto (vedi safeExternalUri): qualunque altro
        // schema (file:, intent:, javascript:, content:, ...) viene ignorato.
        final uri = safeExternalUri(url);
        if (uri == null) return;
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {
          // Nessuna app in grado di gestire il link: nessuna azione.
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (fontFamily, fontSize, lineHeight) = ref.watch(
      settingsProvider.select((s) => (s.fontFamily, s.fontSize, s.lineHeight)),
    );

    _ensureTheme(theme, fontFamily, fontSize, lineHeight);

    return _buildFormattedView(theme);
  }

  Widget _buildFormattedView(ThemeData theme) {
    final items = _items;
    final hasTitle = widget.title.trim().isNotEmpty;
    final itemCount = (hasTitle ? 1 : 0) + items.length;
    final selectionColor = theme.colorScheme.primary.withValues(alpha: 0.35);

    return MarkdownSelectionScope(
      key: _selectionScopeKey,
      controller: _selectionController,
      focusNode: _selectionFocusNode,
      selectionColor: selectionColor,
      selectionControls: _platformSelectionControls,
      onSelectionChanged: (selection) {
        _activeSelection = selection;
        HapticsHelper.reportSelectionState(
          isCollapsed: selection == null || selection.isCollapsed,
        );
      },
      // Dopo "Copia" (o "Taglia", se mai presente) la selezione deve
      // terminare, come nel comportamento nativo di copia/incolla — il menu
      // di default del pacchetto copia ma lascia la selezione attiva.
      // Ricostruiamo la stessa toolbar di default (`state.contextMenuButtonItems`,
      // pattern documentato nel README di flutter_md) avvolgendo solo i
      // pulsanti "copia"/"taglia": eseguono prima l'azione originale (deve
      // ancora leggere la selezione attiva) e poi chiudono la selezione.
      // "Seleziona tutto" lascia la selezione com'è, ma deve garantire che la
      // toolbar resti visibile anche se la selezione di partenza era fuori
      // schermo (vedi [_keepToolbarVisibleAfterSelectAll]). Le ancore sono
      // inoltre sempre riportate dentro il viewport (vedi
      // [_clampAnchorsToViewport]).
      contextMenuBuilder: (context, state) =>
          AdaptiveTextSelectionToolbar.buttonItems(
        anchors: _clampAnchorsToViewport(state.contextMenuAnchors),
        buttonItems: [
          for (final item in state.contextMenuButtonItems)
            _wrapMenuItem(item, state),
        ],
      ),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handleBackgroundPointerDown,
        onPointerMove: _handleBackgroundPointerMove,
        onPointerUp: _handleBackgroundPointerUp,
        onPointerCancel: _handleBackgroundPointerCancel,
        child: MarkdownTheme(
          data: _markdownTheme,
          child: ScrollConfiguration(
            behavior: _NoGlowScrollBehavior(),
            child: ListView.builder(
              key: const ValueKey('markdown-formatted-listview'),
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
              itemCount: itemCount,
              itemBuilder: (context, index) {
                if (hasTitle && index == 0) {
                  return _buildTitleWidget(theme, selectionColor);
                }
                final itemIndex = hasTitle ? index - 1 : index;
                return _buildItem(itemIndex, items[itemIndex]);
              },
            ),
          ),
        ),
      ),
    );
  }

  ContextMenuButtonItem _wrapMenuItem(
    ContextMenuButtonItem item,
    MarkdownSelectionScopeState state,
  ) {
    final originalOnPressed = item.onPressed;
    if (originalOnPressed == null) return item;

    if (item.type == ContextMenuButtonType.copy ||
        item.type == ContextMenuButtonType.cut) {
      return ContextMenuButtonItem(
        type: item.type,
        label: item.label,
        onPressed: () {
          originalOnPressed();
          state.clearSelection();
        },
      );
    }

    if (item.type == ContextMenuButtonType.selectAll) {
      return ContextMenuButtonItem(
        type: item.type,
        label: item.label,
        onPressed: () {
          originalOnPressed();
          _keepToolbarVisibleAfterSelectAll(state);
        },
      );
    }

    return item;
  }

  // BUG ("Seleziona tutto" con selezione di partenza fuori schermo): la
  // selezione di `flutter_md` è ancorata al modello, non ai `RenderObject`,
  // quindi sopravvive anche quando il blocco che la contiene esce dalla
  // `cacheExtent` della `ListView` e viene smontato. Se in quello stato si
  // preme "Seleziona tutto", la toolbar sparisce e non torna più finché
  // non si ri-seleziona a mano; con la selezione di partenza visibile il
  // problema non c'è. (Il sorgente privato del pacchetto non è stato
  // ispezionato: la causa esatta lato pacchetto è un'ipotesi, il rimedio
  // sotto è volutamente difensivo e usa solo API pubbliche.)
  //
  // Rimedio: subito dopo "Seleziona tutto", per qualche frame (il tempo di
  // far assestare layout/registry del pacchetto), se la selezione è ancora
  // attiva ma la toolbar non è visibile, la ri-mostriamo con l'API pubblica
  // `showToolbar()` (che ricalcola le ancore dalla geometria corrente).
  // Si ferma da sola se nel frattempo la selezione viene annullata.
  void _keepToolbarVisibleAfterSelectAll(MarkdownSelectionScopeState state) {
    void check(int retriesLeft) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !state.mounted) return;
        final selection = _activeSelection;
        if (selection == null || selection.isCollapsed) return;
        if (!state.toolbarIsVisible) state.showToolbar();
        if (retriesLeft > 0) check(retriesLeft - 1);
      });
      // `addPostFrameCallback` da solo non pianifica un frame.
      WidgetsBinding.instance.ensureVisualUpdate();
    }

    check(2);
  }

  // Rettangolo globale della viewport di scroll (l'area in cui il contenuto
  // è realmente visibile), o `null` se non ancora disponibile.
  Rect? _viewportGlobalRect() {
    if (!_scrollController.hasClients) return null;
    final box = _scrollController.position.context.storageContext
        .findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  static const double _toolbarExtent = 48.0;
  static const double _toolbarEdgeMargin = 8.0;

  // Le ancore di default di `flutter_md` sono calcolate sulla geometria dei
  // soli blocchi MONTATI (top/bottom del bounding box della selezione), che
  // con "Seleziona tutto" o con una selezione scrollata via possono cadere
  // ben fuori dalla viewport (blocchi nella `cacheExtent`, o fallback sui
  // bordi dell'intero scope): la toolbar verrebbe posizionata fuori schermo
  // e risulterebbe "scomparsa". Qui le ancore che escono dalla viewport
  // vengono riportate sul bordo visibile più vicino (toolbar agganciata al
  // bordo superiore/inferiore); quelle già dentro non vengono toccate, così
  // il flip sopra/sotto della toolbar per selezioni vicine al bordo resta
  // quello nativo.
  TextSelectionToolbarAnchors _clampAnchorsToViewport(
    TextSelectionToolbarAnchors anchors,
  ) {
    final viewport = _viewportGlobalRect();
    if (viewport == null ||
        viewport.height < 2 * (_toolbarExtent + _toolbarEdgeMargin)) {
      return anchors;
    }

    double clampX(double x) =>
        x.clamp(viewport.left, viewport.right).toDouble();

    // Ancora primaria: la toolbar viene disegnata SOPRA questo punto.
    Offset clampPrimary(Offset p) {
      if (p.dy < viewport.top) {
        return Offset(
          clampX(p.dx),
          viewport.top + _toolbarExtent + _toolbarEdgeMargin,
        );
      }
      if (p.dy > viewport.bottom) {
        return Offset(clampX(p.dx), viewport.bottom - _toolbarEdgeMargin);
      }
      return p;
    }

    // Ancora secondaria: la toolbar viene disegnata SOTTO questo punto (solo
    // se sopra non c'è spazio).
    Offset clampSecondary(Offset p) {
      if (p.dy > viewport.bottom) {
        return Offset(
          clampX(p.dx),
          viewport.bottom - _toolbarExtent - _toolbarEdgeMargin,
        );
      }
      if (p.dy < viewport.top) {
        return Offset(clampX(p.dx), viewport.top + _toolbarEdgeMargin);
      }
      return p;
    }

    final secondary = anchors.secondaryAnchor;
    return TextSelectionToolbarAnchors(
      primaryAnchor: clampPrimary(anchors.primaryAnchor),
      secondaryAnchor: secondary == null ? null : clampSecondary(secondary),
    );
  }

  void _handleBackgroundPointerDown(PointerDownEvent event) {
    final pointer = event.pointer;
    // Un id di puntatore non viene riusato, ma un eventuale residuo non deve
    // mai lasciare un timer orfano.
    _forgetPendingTap(pointer);

    // Desktop (mouse/trackpad/penna): il tasto DESTRO (o centrale) apre il
    // menu contestuale (Copia / Seleziona tutto) e NON deve mai contare come
    // "tocco a vuoto": prima veniva trattato come un normale tap breve e
    // `_handleBackgroundPointerUp` annullava la selezione appena prima/dopo
    // l'apertura del menu. Il tasto va letto qui, sul `PointerDown`: sul
    // `PointerUp` `event.buttons` vale già 0. Su touch `buttons` è sempre
    // `kPrimaryButton`, quindi il comportamento mobile resta identico.
    if ((event.buttons & (kSecondaryButton | kTertiaryButton)) != 0) return;

    _pendingTapPointers[pointer] = _PendingTap(
      origin: event.position,
      maxDuration: _tapMaxDuration,
      // Tenuto premuto oltre la soglia di long-press (avvio selezione
      // touch, o pressione lunga con il mouse): non è più un tap.
      onExpired: () => _forgetPendingTap(pointer),
    );
  }

  void _handleBackgroundPointerMove(PointerMoveEvent event) {
    final pending = _pendingTapPointers[event.pointer];
    if (pending == null) return;
    // Spostato oltre la soglia (drag/scroll/table-scroll): non è un tap.
    if ((event.position - pending.origin).distance > _tapTouchSlop) {
      _forgetPendingTap(event.pointer);
    }
  }

  void _handleBackgroundPointerCancel(PointerCancelEvent event) {
    _forgetPendingTap(event.pointer);
  }

  void _handleBackgroundPointerUp(PointerUpEvent event) {
    // Se il puntatore non è più nella mappa NON è un tap breve (scaduto,
    // spostato oltre la soglia, tasto destro/centrale): non deve annullare
    // nulla.
    final pending = _pendingTapPointers.remove(event.pointer);
    if (pending == null) return;
    pending.cancel();

    final selection = _activeSelection;
    if (selection == null || selection.isCollapsed) return;
    _selectionScopeKey.currentState?.clearSelection();
  }

  // Toglie il puntatore dai candidati-tap e ne annulla il timer.
  void _forgetPendingTap(int pointer) {
    _pendingTapPointers.remove(pointer)?.cancel();
  }

  void _cancelAllPendingTaps() {
    for (final pending in _pendingTapPointers.values) {
      pending.cancel();
    }
    _pendingTapPointers.clear();
  }

  Widget _buildTitleWidget(ThemeData theme, Color selectionColor) {
    return Align(
      key: const ValueKey('rendered-block-title'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(
              widget.title,
              style: _titleTextStyle,
              selectionColor: selectionColor,
              onSelectionChanged: (selection, cause) {
                if (!selection.isCollapsed) {
                  _selectionGroup.clearExternal();
                }
              },
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

  // Problema 1: nessun hook di gesture nel `BlockPainter`. Il log di build
  // ha rivelato l'interfaccia reale di `BlockPainter`/`SelectableBlockPainter`
  // (flutter_md 0.2.0):
  //   abstract final Size size;
  //   Size layout(double width);
  //   void paint(Canvas canvas, Size size, double offset);
  //   void handleTapDown(PointerDownEvent event);
  //   void handleTapUp(PointerUpEvent event);
  //   String get renderedText;
  //   int offsetForLocalPosition(Offset local);
  //   List<Rect> boxesForRange(int start, int end);
  //   TextRange wordBoundaryForLocal(Offset local);
  //   bool isLinkAtLocal(Offset local);
  // Nessun metodo di pan/drag: un `BlockPainter` riceve solo tap, non
  // possiede un proprio gesture arena per un drag orizzontale. Il drag di
  // selezione multi-blocco è quindi orchestrato da un livello sopra (la
  // `MarkdownWidget`/`MarkdownSelectionScope`), non dal singolo painter —
  // motivo per cui il mio precedente `_HorizontalScrollTablePainter`
  // (custom drag consumato dentro il painter) non poteva funzionare: quel
  // punto di estensione non esiste in questa API.
  //
  // Soluzione corretta con l'API reale: non toccare affatto il rendering
  // interno di flutter_md per le tabelle (lasciamo che disegni/selezioni la
  // tabella esattamente come per ogni altro blocco), e diamo invece più
  // spazio orizzontale con un vero `Scrollable` a livello di widget
  // (`SingleChildScrollView(scrollDirection: Axis.horizontal)`) attorno al
  // `MarkdownWidget` di quel singolo blocco. Questo non richiede alcun
  // codice custom per isolare i gesti: la disambiguazione nativa di Flutter
  // fra `Scrollable` con assi ortogonali fa già esattamente quello che
  // serve — un drag verticale che parte sopra la tabella risale comunque
  // alla `ListView` esterna, un drag orizzontale resta isolato qui, e un
  // long-press-poi-drag per la selezione touch (gestito da
  // `MarkdownSelectionScope`, non da uno `Scrollable`) non è in
  // competizione con un semplice `HorizontalDragGestureRecognizer`. Dando
  // al figlio un vincolo di larghezza non limitato (`maxWidth: infinity`,
  // che `SingleChildScrollView` fornisce di default sull'asse di scroll),
  // la tabella può calcolare la sua larghezza naturale (somma colonne)
  // esattamente come richiesto, invece di essere forzata/troncata nella
  // larghezza del blocco padre.
  Widget _buildItem(int index, _ViewItem item) {
    final Widget content;
    switch (item) {
      case _MathItem(:final tex, :final ast, :final parseError):
        content = DisplayMathBlock(
          tex: tex,
          textStyle: _mathTextStyle,
          ast: ast,
          parseError: parseError,
        );
      case _BlockItem(:final block, :final documentId):
        final markdownWidget = MarkdownWidget(
          markdown: Markdown(
            markdown: markdownBlockRenderedText(block),
            blocks: [block],
          ),
          documentId: documentId,
        );
        if (block is MD$Table) {
          content = SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: markdownWidget,
          );
        } else if (block is MD$Code) {
          // Barra con pulsante "Copia" in alto a destra, FUORI dal blocco
          // disegnato da flutter_md: non copre il codice e non entra nella
          // selezione (vedi `CodeBlockWithCopy`).
          content = CodeBlockWithCopy(
            code: block.text,
            language: block.language,
            surfaceColor: _codeSurfaceColor,
            child: SizedBox(width: double.infinity, child: markdownWidget),
          );
        } else {
          content = SizedBox(width: double.infinity, child: markdownWidget);
        }
    }

    return Align(
      key: ValueKey('rendered-block-$index'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          // Solo i blocchi Markdown: le formule non hanno `documentId` e non
          // contengono mai un estremo della selezione. Il wrapper non
          // aggiunge alcun RenderObject (vedi la sua doc per il perché).
          child: item is _BlockItem
              ? _KeepAliveWhileSelectionEdge(
                  documentId: item.documentId,
                  edgeIds: _selectionEdgeIds,
                  child: content,
                )
              : content,
        ),
      ),
    );
  }
}

class _NoGlowScrollBehavior extends ScrollBehavior {
  @override
  Widget buildOverscrollIndicator(
      BuildContext context, Widget child, ScrollableDetails details) {
    return child;
  }
}

/// Puntatore ancora "in corsa" fra `PointerDown` e `PointerUp` e ancora
/// candidato a essere un tap breve, usato da `_MarkdownRenderedViewState` per
/// riconoscere a mano un tap senza passare dalla gesture arena (vedi commento
/// su `_pendingTapPointers`).
///
/// La durata massima è un `Timer` creato alla costruzione: quando scade
/// chiama [onExpired] (il proprietario toglie il puntatore dai candidati).
/// Chi rimuove un `_PendingTap` dalla mappa DEVE chiamare [cancel], altrimenti
/// il timer resta vivo fino alla scadenza.
class _PendingTap {
  _PendingTap({
    required this.origin,
    required Duration maxDuration,
    required void Function() onExpired,
  }) : _expiryTimer = Timer(maxDuration, onExpired);

  /// Posizione globale del `PointerDown`.
  final Offset origin;

  final Timer _expiryTimer;

  /// Annulla il timer di scadenza (idempotente).
  void cancel() => _expiryTimer.cancel();
}

/// Tiene vivo — cioè NON smontato dalla virtualizzazione della
/// `ListView.builder` — il blocco che contiene un estremo della selezione
/// attiva, e solo finché lo è: al massimo 2 blocchi, mai tutti.
///
/// PERCHÉ ESISTE (bug "le maniglie non tornano")
/// ---------------------------------------------
/// In `flutter_md` 0.2.0 le maniglie sono gli `OverlayEntry` di un
/// `SelectionOverlay` che seguono dei `LayerLink`; il `LeaderLayer` di
/// ciascun link lo disegna il `RenderObject` del blocco che contiene
/// l'estremo (`MarkdownSelectionSurface.setSelectionHandleLayers`, vedi
/// CHANGELOG 0.2.0) e, senza leader, il framework non disegna la maniglia
/// (`showWhenUnlinked: false` nel `SelectionOverlay` di Flutter). Quando il
/// blocco esce dalla `cacheExtent` il suo `RenderObject` viene distrutto: la
/// selezione sopravvive (è ancorata al modello) e l'evidenziazione torna al
/// ritorno (comportamento osservato), ma i `LayerLink` non vengono ridati al
/// nuovo `RenderObject`: `MarkdownSelectionController.attachSurface` e
/// `detachSurface` aggiornano solo una mappa, senza `notifyListeners()`, e
/// nei metodi pubblici dello scope (`initState`, `didChangeDependencies`,
/// `build`, `dispose`) non c'è alcun ascoltatore di scroll: lo scope non ha
/// quindi motivo di ricalcolare le maniglie finché la selezione non cambia.
/// Non esiste un'API pubblica per ri-mostrarle (`showToolbar` gestisce solo
/// la toolbar).
///
/// (Verificato sul sorgente pubblicato su pub.dev, solo membri pubblici: i
/// due metodi del controller, `selectionHandleEndpoints`, `showToolbar`,
/// `initState`/`didChangeDependencies`/`build`/`dispose` dello scope. NON
/// verificato: i metodi PRIVATI dello scope (`_onControllerChanged` e
/// simili), non consultabili da lì; il passaggio "nessun ricalcolo dopo il
/// rimontaggio" è dedotto dal sintomo osservato.)
///
/// RIMEDIO
/// -------
/// Tenendo montato il blocco di ogni estremo, il suo `RenderObject` non
/// viene mai ricreato: conserva i `LayerLink` e, quando torna dentro la
/// viewport, ridisegna il leader da solo. Fuori viewport lo sliver non
/// disegna i figli tenuti vivi (nessun leader, quindi nessuna maniglia fuori
/// posto). Per tutti gli altri blocchi `cacheExtent` e virtualizzazione
/// restano quelle di default. Il meccanismo è quello standard
/// (`AutomaticKeepAliveClientMixin`): la `ListView.builder` avvolge già ogni
/// item in un `AutomaticKeepAlive`, qui non si cambia nessun parametro.
///
/// QUANDO CAMBIA IL KEEP-ALIVE (regressione 0.9.9: sfarfallio nel drag)
/// ---------------------------------------------------------------------
/// NON a ogni cambio di estremo. Nella prima versione di questo wrapper gli
/// estremi pubblicati seguivano la selezione in tempo reale: durante il
/// trascinamento di una maniglia l'estremo mobile cambia blocco a quasi ogni
/// evento puntatore (con i blocchi spaziatori fra un paragrafo e l'altro, a
/// ogni attraversamento di uno "spazio vuoto"), e ogni cambio muta la
/// struttura della lista dentro la `notifyListeners()` del controller (rilascio
/// = `markNeedsLayout` dello sliver + garbage collection; vedi sopra). Ora lo
/// stato cambia solo a riposo e a fine gesto; durante il gesto si pubblica al
/// massimo un cambio di ancora. Vedi `_MarkdownRenderedViewState._syncEdgeIds`.
class _KeepAliveWhileSelectionEdge extends StatefulWidget {
  // Niente `super.key`: la classe è privata e nessun punto di chiamata passa
  // una `key` (l'item della lista è già identificato dall'`Align` con
  // `ValueKey`), quindi il parametro sarebbe sempre inutilizzato e farebbe
  // scattare `unused_element_parameter` in `flutter analyze`.
  const _KeepAliveWhileSelectionEdge({
    required this.documentId,
    required this.edgeIds,
    required this.child,
  });

  final String documentId;
  final ValueListenable<(String?, String?)> edgeIds;
  final Widget child;

  @override
  State<_KeepAliveWhileSelectionEdge> createState() =>
      _KeepAliveWhileSelectionEdgeState();
}

class _KeepAliveWhileSelectionEdgeState
    extends State<_KeepAliveWhileSelectionEdge>
    with AutomaticKeepAliveClientMixin<_KeepAliveWhileSelectionEdge> {
  // `late` con inizializzatore: il mixin legge `wantKeepAlive` già dentro
  // `super.initState()`, dove `widget` è disponibile.
  late bool _isEdge = _computeIsEdge();

  @override
  bool get wantKeepAlive => _isEdge;

  bool _computeIsEdge() {
    final (base, extent) = widget.edgeIds.value;
    return base == widget.documentId || extent == widget.documentId;
  }

  // Si ricalcola solo la risposta a "devo restare vivo?": nessun `setState`
  // (non cambia nulla di visibile) e `updateKeepAlive` solo se cambia. È
  // sicuro anche se il controller notifica in fase di build/layout:
  // `AutomaticKeepAlive` gestisce notifiche e rilasci in qualunque fase.
  void _syncKeepAlive() {
    final isEdge = _computeIsEdge();
    if (isEdge == _isEdge) return;
    _isEdge = isEdge;
    updateKeepAlive();
  }

  @override
  void initState() {
    super.initState();
    widget.edgeIds.addListener(_syncKeepAlive);
  }

  @override
  void didUpdateWidget(covariant _KeepAliveWhileSelectionEdge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.edgeIds != widget.edgeIds) {
      oldWidget.edgeIds.removeListener(_syncKeepAlive);
      widget.edgeIds.addListener(_syncKeepAlive);
    }
    // Lo stesso slot della lista può essere riusato per un altro blocco.
    _syncKeepAlive();
  }

  @override
  void dispose() {
    widget.edgeIds.removeListener(_syncKeepAlive);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // richiesto da AutomaticKeepAliveClientMixin
    return widget.child;
  }
}

/// Elemento della lista di lettura: un blocco Markdown o una formula a blocco.
sealed class _ViewItem {
  const _ViewItem();
}

final class _BlockItem extends _ViewItem {
  const _BlockItem(this.block, this.documentId);
  final MD$Block block;
  final String documentId;
}

final class _MathItem extends _ViewItem {
  _MathItem(this.tex);

  final String tex;
  bool _parsed = false;
  SyntaxTree? _ast;
  ParseException? _parseError;

  void _ensureParsed() {
    if (_parsed) return;
    _parsed = true;
    try {
      _ast = SyntaxTree(
        greenRoot: TexParser(tex, const TexParserSettings()).parse(),
      );
    } on ParseException catch (e) {
      _parseError = e;
    } on Object catch (e) {
      _parseError = ParseException('Errore sintassi TeX: $e');
    }
  }

  SyntaxTree? get ast {
    _ensureParsed();
    return _ast;
  }

  ParseException? get parseError {
    _ensureParsed();
    return _parseError;
  }
}
