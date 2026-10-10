import 'package:flutter/foundation.dart'
    show
        ErrorDescription,
        FlutterError,
        FlutterErrorDetails,
        TargetPlatform,
        defaultTargetPlatform;
import 'package:flutter/gestures.dart'
    show
        GestureDisposition,
        HitTestResult,
        LongPressEndDetails,
        LongPressGestureRecognizer,
        LongPressStartDetails,
        PointerDeviceKind,
        PointerDownEvent,
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
class MarkdownRenderedView extends ConsumerStatefulWidget {
  final String title;
  final String content;

  const MarkdownRenderedView({
    super.key,
    required this.title,
    required this.content,
  });

  /// SOLO PER I TEST: quante volte il long-press "di richiamo" ha eseguito
  /// `_recallSelectionUi` (vedi `_MarkdownRenderedViewState`). Serve a
  /// distinguere in modo deterministico "il richiamo è scattato" da "ha
  /// agito il pacchetto" nei casi in cui l'effetto visibile coinciderebbe
  /// (long-press fuori dalla selezione, tap, mouse...). Nessun codice di
  /// produzione lo legge.
  static int debugSelectionRecallCount = 0;

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
  static const double _tapTouchSlop = kTouchSlop; // ~18px
  static const Duration _tapMaxDuration = Duration(milliseconds: 500); // ~kLongPressTimeout
  final Map<int, _PendingTap> _pendingTapPointers = <int, _PendingTap>{};

  // --- Step A: long-press DENTRO la selezione = "richiamo" di maniglie e menù
  // Il perché della scelta (un recognizer che vince l'arena prima di quello
  // del pacchetto) e i dettagli del gesto sono nel doc comment di
  // [_SelectionRecallRecognizer]; qui solo lo stato necessario.
  //
  // Tolleranza (px) attorno ai rettangoli della selezione entro cui un
  // long-press touch conta come "sulla selezione": `globalSelectionRects()`
  // restituisce i box delle righe, quindi senza margine l'interlinea, i 16px
  // fra un blocco e l'altro e un dito che sfiora il bordo del testo
  // cadrebbero "fuori". Con 10px per lato i 16px fra blocchi sono coperti.
  static const double _recallTouchTolerance = 10.0;

  // true SOLO mentre [_rebuildSelectionOverlay] riassegna la selezione: un
  // ripristino programmatico non è un gesto dell'utente, quindi non deve né
  // segnalare un cambio all'auto-scroller (vedi
  // [_onSelectionControllerChanged]) né toccare il riarmo aptico (vedi
  // `onSelectionChanged` in [_buildFormattedView]).
  bool _rebuildingSelectionOverlay = false;

  // Un'unica istanza della mappa, riusata a ogni build: il recognizer viene
  // creato una sola volta dal `RawGestureDetector` e la sua inizializzazione
  // (callback) rieseguita a ogni aggiornamento del widget.
  late final Map<Type, GestureRecognizerFactory> _recallGestures =
      <Type, GestureRecognizerFactory>{
    _SelectionRecallRecognizer:
        GestureRecognizerFactoryWithHandlers<_SelectionRecallRecognizer>(
      () => _SelectionRecallRecognizer(
        shouldClaim: _claimsRecallAt,
        stillClaimable: _stillClaimsRecallAt,
      ),
      (instance) {
        instance
          ..onLongPressStart = _handleRecallLongPressStart
          ..onLongPressEnd = _handleRecallLongPressEnd;
      },
    ),
  };

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
    // Un ripristino programmatico (vedi [_rebuildSelectionOverlay]) cambia il
    // valore ma non è un trascinamento di selezione: si aggiorna
    // `_lastObservedSelection` (così i veri cambi successivi vengono
    // confrontati col valore giusto) ma non si arma l'auto-scroller.
    if (_rebuildingSelectionOverlay) return;
    if (selection != null) _autoScroller.notifySelectionChanged();
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
    _selectionController.removeListener(_onSelectionControllerChanged);
    _autoScroller.dispose();
    _scrollController.dispose();
    _selectionFocusNode.dispose();
    _selectionController.dispose();
    _pendingTapPointers.clear();
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
        // Durante un ripristino programmatico la selezione passa per `null`
        // per un istante: segnalarlo pianificherebbe il riarmo aptico
        // (vedi `HapticsHelper.reportSelectionState`). Il valore finale è
        // identico a quello di partenza, quindi non c'è nulla da riferire.
        if (_rebuildingSelectionOverlay) return;
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
      // Il `RawGestureDetector` è un FIGLIO dello scope (quindi più profondo
      // del suo `RawGestureDetector` interno): riceve il `PointerDown` prima
      // e i suoi recognizer entrano per primi nell'arena. Contiene un solo
      // recognizer, che si iscrive all'arena soltanto per un tocco touch
      // dentro una selezione esistente (vedi [_SelectionRecallRecognizer]);
      // in ogni altro caso è inerte e il comportamento resta quello di prima.
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: _recallGestures,
        // Il recognizer non deve aggiungere azioni di accessibilità: serve
        // solo a decidere chi vince l'arena dei gesti.
        excludeFromSemantics: true,
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
    // Desktop (mouse/trackpad/penna): il tasto DESTRO (o centrale) apre il
    // menu contestuale (Copia / Seleziona tutto) e NON deve mai contare come
    // "tocco a vuoto": prima veniva trattato come un normale tap breve e
    // `_handleBackgroundPointerUp` annullava la selezione appena prima/dopo
    // l'apertura del menu. Il tasto va letto qui, sul `PointerDown`: sul
    // `PointerUp` `event.buttons` vale già 0. Su touch `buttons` è sempre
    // `kPrimaryButton`, quindi il comportamento mobile resta identico.
    if ((event.buttons & (kSecondaryButton | kTertiaryButton)) != 0) {
      _pendingTapPointers.remove(event.pointer);
      return;
    }
    _pendingTapPointers[event.pointer] = _PendingTap(event.position, DateTime.now());
  }

  void _handleBackgroundPointerMove(PointerMoveEvent event) {
    _pendingTapPointers[event.pointer]?.registerPosition(event.position);
  }

  void _handleBackgroundPointerCancel(PointerCancelEvent event) {
    _pendingTapPointers.remove(event.pointer);
  }

  void _handleBackgroundPointerUp(PointerUpEvent event) {
    final pending = _pendingTapPointers.remove(event.pointer);
    if (pending == null) return;

    // Non un tap: si è spostato oltre la soglia (drag/scroll/table-scroll) o
    // è stato tenuto premuto oltre la soglia di long-press (avvio selezione
    // touch). In entrambi i casi non deve annullare nulla.
    if (pending.maxDistanceFromOrigin > _tapTouchSlop) return;
    if (DateTime.now().difference(pending.downTime) > _tapMaxDuration) return;

    final selection = _activeSelection;
    if (selection == null || selection.isCollapsed) return;
    _selectionScopeKey.currentState?.clearSelection();
  }

  // ---------------------------------------------------------------------------
  // Step A: richiamo di maniglie e menù con un long-press DENTRO la selezione.
  // ---------------------------------------------------------------------------

  // Un tocco touch appena iniziato in `position` (globale), col puntatore
  // `pointer`, è un candidato al richiamo? Sì se TUTTE queste condizioni
  // valgono:
  //  1. nessun altro puntatore è premuto (multi-touch: no). `_pendingTapPointers`
  //     contiene tutti i puntatori primari giù; si esclude quello in esame
  //     perché, a seconda dell'ordine di consegna dell'evento, potrebbe
  //     esserci già o no;
  //  2. esiste una selezione non collassata;
  //  3. il punto cade in uno dei `globalSelectionRects()` gonfiati di
  //     [_recallTouchTolerance]. I rettangoli sono vuoti se la selezione è
  //     collassata o tutta fuori schermo: in quel caso il long-press è per
  //     forza "fuori" e agisce il pacchetto, come prima.
  bool _isRecallCandidate(Offset position, int pointer) {
    if (!mounted) return false;
    if (_pendingTapPointers.keys.any((other) => other != pointer)) return false;
    final selection = _selectionController.selection;
    if (selection == null || selection.isCollapsed) return false;
    return _selectionController
        .globalSelectionRects()
        .any((rect) => rect.inflate(_recallTouchTolerance).contains(position));
  }

  // Il layer più alto colpito dal tocco appartiene a QUESTA vista? Le maniglie
  // (e la toolbar, il magnifier) vivono nell'overlay radice, sopra il
  // contenuto: se il tocco le colpisce — compresa l'area di tocco allargata
  // di una maniglia, che è trasparente agli hit-test e può sovrapporsi ai
  // rettangoli della selezione — il long-press NON parte "dal testo" e non
  // deve attivare il richiamo (un trascinamento di maniglia resta com'è).
  // L'hit-test visita dal più profondo/alto al più basso, quindi il primo
  // `RenderObject` del percorso dice cosa sta in cima: se non è dentro il
  // sottoalbero di questa vista, sopra c'è qualcos'altro.
  //
  // Senza informazioni (nessun `RenderObject` nel percorso, vista non ancora
  // con un render object) la risposta è "sì": il controllo serve solo a
  // ESCLUDERE i tocchi su un layer sovrastante, e un'esclusione sbagliata
  // disattiverebbe del tutto il richiamo, mentre un'esclusione mancata nel
  // caso raro costa al più un richiamo in più.
  bool _isTopHitInsideThisView(PointerDownEvent event) {
    final root = context.findRenderObject();
    if (root == null) return true;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is! RenderObject) continue;
      for (RenderObject? node = target; node != null; node = node.parent) {
        if (identical(node, root)) return true;
      }
      return false;
    }
    return true;
  }

  // Il richiamo è un'AGGIUNTA: se il controllo di candidatura dovesse mai
  // lanciare (geometria in uno stato inatteso...) non deve compromettere i
  // gesti già esistenti. L'errore viene segnalato (visibile in debug e nei
  // test) ma il recognizer rinuncia e il long-press passa al pacchetto.
  bool _failSafe(bool Function() check) {
    try {
      return check();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'scripta',
          context: ErrorDescription(
            'while deciding whether a long press recalls the selection UI',
          ),
        ),
      );
      return false;
    }
  }

  bool _claimsRecallAt(PointerDownEvent event) => _failSafe(
        () =>
            _isRecallCandidate(event.position, event.pointer) &&
            _isTopHitInsideThisView(event),
      );

  // Ricontrollo alla scadenza del long-press (la selezione o un secondo dito
  // possono essere comparsi nei 480 ms di attesa).
  bool _stillClaimsRecallAt(Offset position, int pointer) =>
      _failSafe(() => _isRecallCandidate(position, pointer));

  // Il long-press di richiamo è stato RICONOSCIUTO (il dito è fermo da
  // 480 ms). Da questo momento quel puntatore non può più essere un tap: va
  // tolto da `_pendingTapPointers`, altrimenti [_handleBackgroundPointerUp]
  // lo giudicherebbe un tap breve (la sua soglia è 500 ms, la nostra 480:
  // un rilascio fra le due annullerebbe la selezione) — e nei test con
  // orologio finto, dove `DateTime.now()` non avanza, ogni rilascio
  // sembrerebbe un tap. Dopo il richiamo il tocco non fa altro: un
  // trascinamento successivo non estende né sposta la selezione.
  void _handleRecallLongPressStart(LongPressStartDetails details) {
    _pendingTapPointers.removeWhere(
      (_, tap) =>
          (tap.origin - details.globalPosition).distance <= _tapTouchSlop,
    );
  }

  // Il richiamo vero e proprio avviene a FINE gesto (dito sollevato), come
  // per il long-press normale del pacchetto, che mostra il menù al rilascio.
  void _handleRecallLongPressEnd(LongPressEndDetails details) {
    _recallSelectionUi();
  }

  /// PUNTO DI AGGANCIO dello step B (menù che segue la nota e si aggancia ai
  /// bordi): è l'unico posto in cui la UI della selezione viene riportata in
  /// vista dopo un long-press sulla selezione. Lo step B vi si può innestare
  /// (ricalcolo delle ancore, aggancio al bordo, ri-armo dell'inseguimento)
  /// senza toccare il riconoscimento del gesto.
  ///
  /// È IDEMPOTENTE: ogni passo agisce solo se manca qualcosa, quindi se
  /// maniglie e menù sono già visibili non cambia nulla (nessun
  /// lampeggio, nessun toggle). Non modifica mai la selezione (valore
  /// identico prima e dopo), non vibra e non arma l'auto-scroll.
  ///  1. focus: tastiera fisica e azioni del pacchetto lo richiedono;
  ///  2. maniglie (solo piattaforme touch): se non ci sono, si ricostruisce
  ///     l'overlay con [_rebuildSelectionOverlay];
  ///  3. menù: `showToolbar()` solo se `toolbarIsVisible` è false. La
  ///     posizione "naturale" vicino alla selezione arriva dal
  ///     `contextMenuBuilder` (`_clampAnchorsToViewport`), come per ogni
  ///     altro punto in cui il menù compare.
  void _recallSelectionUi() {
    if (!mounted) return;
    final state = _selectionScopeKey.currentState;
    if (state == null || !state.mounted) return;
    final selection = _selectionController.selection;
    if (selection == null || selection.isCollapsed) return;

    MarkdownRenderedView.debugSelectionRecallCount++;

    if (!_selectionFocusNode.hasFocus) _selectionFocusNode.requestFocus();

    if (_selectionHandlesExpected && !_areSelectionHandlesShown()) {
      _rebuildSelectionOverlay();
    }

    // Dopo `_rebuildSelectionOverlay` la toolbar può essere sparita (il
    // pacchetto la nasconde quando la selezione passa per `null`): si
    // controlla per ultima.
    if (!state.toolbarIsVisible) state.showToolbar();
  }

  // Le maniglie esistono solo sulle piattaforme touch (su desktop il
  // pacchetto non le mostra, come `SelectableText`) e solo se almeno uno dei
  // due estremi della selezione è montato (`selectionHandleEndpoints()` è
  // null altrimenti): fuori da questi casi non c'è nulla da ripristinare.
  bool get _selectionHandlesExpected {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return _selectionController.selectionHandleEndpoints() != null;
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return false;
    }
  }

  // Il pacchetto non espone se le maniglie sono visibili, e non possiamo
  // chiederlo a un suo membro privato. Le maniglie sono però costruite dal
  // `SelectionOverlay` di Flutter nell'overlay radice (`_SelectionHandleOverlay`,
  // un `StatefulWidget` privato del framework): se nessuno è presente non ci
  // sono maniglie. Il confronto è per NOME del tipo, quindi fragile per
  // costruzione: se Flutter lo rinominasse la risposta sarebbe sempre "no" e
  // l'espediente [_rebuildSelectionOverlay] girerebbe a ogni richiamo (le
  // maniglie lampeggerebbero, nient'altro si romperebbe). I build di release
  // non usano `--obfuscate`, quindi il nome è leggibile anche lì.
  bool _areSelectionHandlesShown() {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return false;
    var found = false;
    void visit(Element element) {
      if (found) return;
      // (Non chiamarlo `widget`: nasconderebbe `State.widget`.)
      final candidate = element.widget;
      if (candidate is StatefulWidget &&
          candidate.runtimeType.toString() == '_SelectionHandleOverlay') {
        found = true;
        return;
      }
      element.visitChildren(visit);
    }

    (overlay.context as Element).visitChildren(visit);
    return found;
  }

  // ESPEDIENTE per riportare le maniglie: il pacchetto (0.2.0) non ha un API
  // pubblico per ri-mostrarle, ma ricostruisce overlay e maniglie quando la
  // selezione cambia. Si riassegna quindi la stessa selezione passando per
  // `null`: `selection = x` è un no-op se `x` è già il valore corrente
  // (confronto per valore), per cui senza il passaggio da `null` non
  // succederebbe nulla. È sincrono e dentro lo stesso gestore di eventi:
  // nessun frame intermedio con la selezione sparita. Va chiamato SOLO se le
  // maniglie mancano (vedi [_recallSelectionUi]): ricostruirle mentre sono
  // visibili le farebbe riapparire con la dissolvenza di Flutter, cioè un
  // lampeggio. Il flag [_rebuildingSelectionOverlay] impedisce che questo
  // ripristino sia scambiato per un gesto (auto-scroll, riarmo aptico).
  void _rebuildSelectionOverlay() {
    final saved = _selectionController.selection;
    if (saved == null || saved.isCollapsed) return;
    _rebuildingSelectionOverlay = true;
    try {
      _selectionController.clear();
      _selectionController.selection = saved;
    } finally {
      _rebuildingSelectionOverlay = false;
    }
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
          child: content,
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

/// Stato di un puntatore ancora "in corsa" fra `PointerDown` e `PointerUp`,
/// usato da `_MarkdownRenderedViewState` per riconoscere a mano un tap breve
/// senza passare dalla gesture arena (vedi commento su `_pendingTapPointers`).
class _PendingTap {
  _PendingTap(this.origin, this.downTime);

  final Offset origin;
  final DateTime downTime;
  double maxDistanceFromOrigin = 0;

  void registerPosition(Offset position) {
    final distance = (position - origin).distance;
    if (distance > maxDistanceFromOrigin) {
      maxDistanceFromOrigin = distance;
    }
  }
}

/// Scadenza del long-press di richiamo: 20 ms PRIMA di `kLongPressTimeout`
/// (500 ms), che è la scadenza di default del long-press di Flutter e quindi,
/// verosimilmente, anche di quello di `MarkdownSelectionScope`. Nell'arena dei
/// gesti vince chi dichiara per primo: con una scadenza strettamente più
/// corta il nostro recognizer batte quello del pacchetto SENZA dipendere
/// dall'ordine con cui i due si registrano a parità di scadenza. Il tocco
/// lungo è comunque indistinguibile (20 ms) e, una volta riconosciuto, non può
/// essere scambiato per un tap (vedi `_handleRecallLongPressStart`).
const Duration _recallLongPressDuration = Duration(milliseconds: 480);

/// Riconoscitore del long-press "di richiamo": scatta solo se un dito (touch)
/// si appoggia DENTRO una selezione già esistente e vi resta fermo; allora
/// `_MarkdownRenderedViewState._recallSelectionUi` riporta maniglie e menù
/// SENZA toccare la selezione.
///
/// PERCHÉ UN RECOGNIZER (approccio a) E NON UN RIPRISTINO A POSTERIORI (b)
/// ----------------------------------------------------------------------
/// `flutter_md` 0.2.0 non permette di vietare l'avvio di un gesto di
/// selezione (nessun hook, tipo `canStartSelectionAt`, che esiste solo su
/// master) e `enabled: false` rimonterebbe l'albero sopra la `ListView`.
/// Quindi o si lascia agire il pacchetto e si annulla il suo effetto (b), o
/// gli si impedisce di agire (a). Si è scelto (a) perché, se il nostro
/// recognizer vince l'arena, il gestore del long-press del pacchetto NON
/// parte affatto:
///  * la parola sotto il dito non viene mai selezionata, nemmeno per un
///    frame (con (b) esisterebbe per l'intervallo fra la notifica del
///    controller e il ripristino, e vedrebbero il cambio tutti i listener);
///  * non partono i suoi effetti collaterali — focus, vibrazione, nascondere
///    il menù, magnifier — che (b) non potrebbe annullare né evitare;
///  * non serve "congelare" la selezione per la durata del gesto né
///    sincronizzarsi con l'ordine dei listener del controller o con lo stato
///    interno (ancora di trascinamento, granularità) del pacchetto.
/// Usa solo API pubbliche: `LongPressGestureRecognizer` di Flutter e
/// `MarkdownSelectionController.globalSelectionRects()`. L'unico
/// accoppiamento col pacchetto è un'assunzione verificabile dal test
/// `selection_recall_test.dart`: che il suo long-press sia un recognizer
/// dell'arena (lo dice il README: "long-press-then-drag", "uno swipe fa
/// ancora scorrere la lista") con scadenza ≥ 480 ms. Se così non fosse
/// vincerebbe il pacchetto e il comportamento resterebbe quello di prima:
/// nessuna regressione, solo il richiamo che non scatta.
///
/// NIENTE RITARDI SU TAP E DOUBLE-TAP
/// ----------------------------------
/// (Il commento su `_pendingTapPointers` racconta come un
/// `TapGestureRecognizer` aveva già causato ~300 ms di ritardo percepito.)
///  * Fuori da una selezione, e con mouse/trackpad/penna, [isPointerAllowed]
///    è `false`: il recognizer non entra proprio nell'arena.
///  * Dentro una selezione resta in arena solo fino al rilascio: il
///    `LongPressGestureRecognizer` si rifiuta da solo al `PointerUp` se la
///    scadenza non è passata, e le route dei recognizer girano PRIMA dello
///    sweep dell'arena, quindi non trattiene mai la vittoria di un tap né di
///    un double-tap. Non fa mai `hold` dell'arena e si rifiuta anche se il
///    dito supera `kTouchSlop`, quindi lo scroll resta quello di prima.
///  * Il tap a vuoto dell'app non passa dall'arena (usa un `Listener`):
///    invariato.
///
/// MULTI-TOUCH
/// -----------
/// Con più di un puntatore giù il tocco non viene reclamato (vedi
/// `_isRecallCandidate`); se il secondo dito arriva durante l'attesa, il
/// ricontrollo alla scadenza ([didExceedDeadline]) rifiuta il gesto.
class _SelectionRecallRecognizer extends LongPressGestureRecognizer {
  _SelectionRecallRecognizer({
    required this.shouldClaim,
    required this.stillClaimable,
  }) : super(
          duration: _recallLongPressDuration,
          supportedDevices: const <PointerDeviceKind>{PointerDeviceKind.touch},
        );

  /// Decide, al `PointerDown`, se il tocco va reclamato.
  final bool Function(PointerDownEvent event) shouldClaim;

  /// Ricontrollo alla scadenza del long-press, sulla posizione iniziale.
  final bool Function(Offset position, int pointer) stillClaimable;

  Offset? _downPosition;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      super.isPointerAllowed(event) && shouldClaim(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _downPosition = event.position;
    super.addAllowedPointer(event);
  }

  @override
  void didExceedDeadline() {
    final position = _downPosition;
    final pointer = primaryPointer;
    if (position == null ||
        pointer == null ||
        !stillClaimable(position, pointer)) {
      resolve(GestureDisposition.rejected);
      return;
    }
    super.didExceedDeadline();
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
