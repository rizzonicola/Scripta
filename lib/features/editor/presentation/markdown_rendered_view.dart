import 'package:flutter/foundation.dart'
    show
        ErrorDescription,
        FlutterError,
        FlutterErrorDetails,
        Listenable,
        TargetPlatform,
        ValueNotifier,
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
import 'selection_handle_visibility.dart';

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
/// DUE COMPORTAMENTI DELLA SELEZIONE TOUCH CHE IL PACCHETTO NON OFFRE
/// (nessun hook in 0.2.0: li realizza questa vista con sole API pubbliche):
///  * RICHIAMO: un long-press DENTRO una selezione esistente la lascia
///    invariata e riporta maniglie e menù Copia / Seleziona tutto, se erano
///    scomparsi (vedi `_SelectionRecallRecognizer` e `_recallSelectionUi`);
///  * INSEGUIMENTO: il menù segue la nota mentre scorre e si aggancia al bordo
///    superiore/inferiore finché la selezione non finisce (vedi
///    `_buildSelectionToolbar`).
/// Entrambi sono stati scritti e ragionati senza poter eseguire Flutter: la
/// CI e la prova su dispositivo sono l'unico banco di prova, e i limiti noti
/// sono elencati nei doc comment di `_buildSelectionToolbar` e
/// `_recallTouchTolerance`.
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

  // --- Richiamo: long-press DENTRO la selezione = maniglie e menù ----------
  // Il perché della scelta (un recognizer che vince l'arena prima di quello
  // del pacchetto) e i dettagli del gesto sono nel doc comment di
  // [_SelectionRecallRecognizer]; qui solo lo stato necessario.
  //
  // Tolleranza (px) attorno ai rettangoli della selezione entro cui un
  // long-press touch conta come "sulla selezione": `globalSelectionRects()`
  // restituisce i box delle righe, quindi senza margine l'interlinea e un dito
  // che sfiora il bordo del testo cadrebbero "fuori".
  //
  // LIMITE NOTO. Tra due paragrafi `flutter_md` inserisce un blocco VUOTO (una
  // nota di 5 paragrafi produce 9 `MarkdownWidget`, passo di 32 px con altezza
  // di 16: osservato in CI), quindi fra i box di testo di due paragrafi
  // consecutivi ci sono 16 + 16 + 16 = 48 px. Con 10 px per lato ne restano
  // scoperti circa 28: un long-press in quella fascia, anche se la selezione
  // ricopre entrambi i paragrafi, conta come "fuori" e agisce il pacchetto
  // (nuova selezione per parola). Allargare la tolleranza o unire i rettangoli
  // dei blocchi selezionati è una scelta di design non fatta: i rettangoli dei
  // blocchi vuoti non sono stati ispezionati.
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

  // --- Inseguimento: il menù Copia / Seleziona tutto segue la selezione ----
  // Il PERCHÉ (contenuto che si aggiorna da solo, coordinate di CONTENUTO,
  // flip deciso una volta sola) è nel doc comment di
  // [_buildSelectionToolbar]; qui solo lo stato.
  //
  // Ultima geometria nota della selezione in COORDINATE DI CONTENUTO
  // (y_contenuto = y_globale - viewport.top + offset): non dipende dallo scroll
  // e resta valida anche quando i blocchi della selezione vengono smontati
  // (osservato in CI: con gli estremi smontati `contextMenuAnchors` perde la
  // direzione e `selectionHandleEndpoints()` non è affidabile). È l'«ultimo
  // lato noto». `null` = mai misurata per la selezione corrente.
  _TrackedExtent? _trackedExtent;

  // Il menù sta SOTTO la selezione (true) o SOPRA (false)? Si decide una sola
  // volta, quando il menù compare o la selezione cambia (vedi
  // [_wantsBelowPlacement]), e poi resta stabile durante lo scroll: ricalcolarlo
  // a ogni frame farebbe saltare il menù da un lato all'altro della selezione.
  bool _trackBelow = false;

  // true se il menù attualmente costruito è ancorato alla SELEZIONE (e quindi
  // va inseguito); false per il menù posizionale (tasto destro,
  // `showToolbar(Offset)`), che resta fermo come prima.
  bool _toolbarTracked = false;

  // Coalescenza dei ricalcoli «dalla geometria viva» (vedi
  // [_scheduleToolbarRefresh]) e richiesta di ridecidere il lato.
  bool _toolbarRefreshScheduled = false;
  bool _trackRedecidePending = false;
  bool _trackReplacePending = false;

  // Ultima dimensione dello schermo vista dal builder del menù: se cambia
  // (rotazione, finestra ridimensionata) il viewport si è spostato senza che
  // ci sia stato uno scroll.
  Size? _trackScreenSize;

  // Contatore che fa ricostruire il menù quando il ricalcolo dalla geometria
  // viva cambia le coordinate di contenuto (lo scroll lo ricostruisce già da
  // sé, via `_scrollController`).
  final ValueNotifier<int> _toolbarTrackRevision = ValueNotifier<int>(0);

  // Un'unica istanza: il `ListenableBuilder` si iscrive una volta sola.
  late final Listenable _toolbarTrackListenable = Listenable.merge(
    <Listenable>[_scrollController, _toolbarTrackRevision],
  );

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
    // Il controller notifica per qualunque motivo (selezione che
    // cambia, ma anche documenti/superfici che si registrano): se il menù
    // segue la selezione, la sua geometria va rimisurata a frame finito. Va
    // fatto PRIMA del confronto qui sotto, che esce se il valore della
    // selezione è identico.
    if (_toolbarTrackingActive) _scheduleToolbarRefresh();
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
    _toolbarTrackRevision.dispose();
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
    // Coordinate e modo del menù si riferivano ai blocchi di prima.
    _trackedExtent = null;
    _trackBelow = false;
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
      // schermo (vedi [_afterSelectAll]). Il menù ancorato alla selezione
      // SEGUE la nota mentre scorre e si aggancia ai bordi del viewport (Step
      // B, vedi [_buildSelectionToolbar]); quello aperto con il tasto destro
      // resta fermo, con le ancore riportate dentro il viewport (vedi
      // [_clampAnchorsToViewport]).
      contextMenuBuilder: (context, state) => _buildSelectionToolbar(state),
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
                  // Un blocco che si costruisce può portare nuovi rettangoli
                  // della selezione (vedi [_onBlockBuilt]).
                  _onBlockBuilt();
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
          _afterSelectAll(state);
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
  //
  // Con il menù che insegue la selezione c'è un passo in più: "Seleziona
  // tutto" SOSTITUISCE la selezione (di solito con una che parte e finisce
  // FUORI dai blocchi montati), quindi la geometria e il lato (sopra/sotto) del
  // menù vanno rimisurati e ridecisi; lo fa [_scheduleToolbarRefresh]. Che il
  // menù finisca agganciato al bordo giusto (la selezione "parte sopra") non
  // richiede altro codice: è il caso generale di [_trackedToolbarAnchors].
  void _afterSelectAll(MarkdownSelectionScopeState state) {
    _scheduleToolbarRefresh(redecide: true);
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

  // Sporgenza massima della toolbar rispetto alle ancore, usata SOLO dal modo
  // `following` di [_clampAnchorsToViewport]. `_toolbarExtent` non
  // basta lì: serve che la toolbar resti nel viewport e che Flutter non
  // ribalti sopra/sotto in prossimità del bordo (il ribaltamento sposterebbe il
  // menù di decine di px di colpo, cioè uno scatto). Conosco due varianti
  // della toolbar Material (a memoria, NON verificate sull'SDK locale):
  //  * semplice: sopra occupa [P - 44, P], sotto [S, S + 44]; ci sta sopra se
  //    `P >= padding.top + 8 + 44`;
  //  * con distanze dal contenuto: sopra [P - 52, P - 8], sotto [S + 20,
  //    S + 64]; ci sta sopra se `P >= padding.top + 68`.
  // 76 e 72 reggono entrambe, con qualche px di scorta sulla soglia di ribalta-
  // mento della seconda (68): con `P >= viewport.top + 76` la toolbar sta
  // sempre sopra (se il viewport non parte sopra la barra di stato), e con
  // `S <= viewport.bottom - 72` sotto non esce dal viewport. Il prezzo è
  // qualche px in più dal bordo quando il menù è agganciato (almeno
  // `_toolbarEdgeMargin`, in pratica 24-32 px). Se in CI `_scanForJumps` segna
  // uno SCATTO vicino all'aggancio, la toolbar del SDK locale non coincide con
  // nessuna delle due varianti: rivedere queste due costanti.
  static const double _toolbarReachAbove = 76.0;
  static const double _toolbarReachBelow = 72.0;

  // Le ancore di default di `flutter_md` sono calcolate sulla geometria dei
  // soli blocchi MONTATI (top/bottom del bounding box della selezione), che
  // con "Seleziona tutto" o con una selezione scrollata via possono cadere
  // ben fuori dalla viewport (blocchi nella `cacheExtent`, o fallback sui
  // bordi dell'intero scope): la toolbar verrebbe posizionata fuori schermo
  // e risulterebbe "scomparsa". Qui le ancore che escono dalla viewport
  // vengono riportate sul bordo visibile più vicino (toolbar agganciata al
  // bordo superiore/inferiore).
  //
  // DUE MODI, con la stessa
  // convenzione di posizionamento (ancora primaria = toolbar SOPRA, secondaria
  // = toolbar SOTTO, stesso margine `_toolbarEdgeMargin` dai bordi):
  //  * `following: false` (predefinito) — il comportamento di sempre. Lo usano
  //    il menù posizionale (tasto destro, `showToolbar(Offset)`: resta com'è) e
  //    il ripiego quando non si conosce ancora la geometria della selezione.
  //    Si toccano solo le ancore che escono dal viewport; quelle già dentro non
  //    vengono toccate, così il flip sopra/sotto per selezioni vicine al bordo
  //    resta quello nativo.
  //  * `following: true` — [anchors] sono le ancore NATURALI della selezione
  //    (primaria = bordo superiore, secondaria = bordo inferiore, in coordinate
  //    globali, anche molto fuori dal viewport: arrivano dalle coordinate di
  //    contenuto, vedi [_trackedToolbarAnchors]). Il risultato mette SEMPRE la
  //    toolbar interamente dentro il viewport, con almeno `_toolbarEdgeMargin`
  //    dal bordo: [below] false = sopra la selezione (ancora primaria
  //    limitata a `top + _toolbarReachAbove` .. `bottom - margine`); [below]
  //    true = sotto la selezione (ancora secondaria limitata a `top + margine`
  //    .. `bottom - _toolbarReachBelow`). Le due sporgenze sono più larghe di
  //    `_toolbarExtent` perché qui, vicino al bordo, un ribaltamento
  //    sopra/sotto di Flutter sarebbe uno scatto (vedi i loro commenti).
  //
  // FLIP SOPRA/SOTTO: SCHERMO, NON VIEWPORT (fissato da un test di contratto in
  // selection_contract_test.dart). Flutter sceglie
  // se disegnare la toolbar sopra l'ancora primaria o sotto la secondaria in
  // base allo spazio fino al bordo alto dello SCHERMO, non del viewport della
  // lista. Il modo `following` non lo subisce, ed è questo il motivo della sua
  // forma:
  //  * sopra: la secondaria è `primaria - _toolbarReachBelow`, cioè il punto
  //    in cui finirebbe la toolbar sotto di essa se Flutter ribaltasse da solo
  //    (viewport che parte sopra la barra di stato...): nella variante «con
  //    distanze» il rettangolo sopra e quello sotto coincidono esattamente;
  //  * sotto: la primaria è 0 (bordo alto dello schermo), cioè «sopra non c'è
  //    spazio»: è il modo pubblico di far scegliere il ramo inferiore, quale
  //    che sia la posizione del viewport sullo schermo.
  TextSelectionToolbarAnchors _clampAnchorsToViewport(
    TextSelectionToolbarAnchors anchors, {
    bool following = false,
    bool below = false,
  }) {
    final viewport = _viewportGlobalRect();
    if (viewport == null ||
        viewport.height < 2 * (_toolbarExtent + _toolbarEdgeMargin)) {
      return anchors;
    }

    double clampX(double x) =>
        x.clamp(viewport.left, viewport.right).toDouble();

    if (following) {
      final x = clampX(anchors.primaryAnchor.dx);
      if (below) {
        final naturalBottom =
            (anchors.secondaryAnchor ?? anchors.primaryAnchor).dy;
        return TextSelectionToolbarAnchors(
          primaryAnchor: Offset(x, 0.0),
          secondaryAnchor: Offset(
            x,
            naturalBottom
                .clamp(
                  viewport.top + _toolbarEdgeMargin,
                  viewport.bottom - _toolbarReachBelow,
                )
                .toDouble(),
          ),
        );
      }
      final abovePrimary = anchors.primaryAnchor.dy
          .clamp(
            viewport.top + _toolbarReachAbove,
            viewport.bottom - _toolbarEdgeMargin,
          )
          .toDouble();
      return TextSelectionToolbarAnchors(
        primaryAnchor: Offset(x, abovePrimary),
        secondaryAnchor: Offset(x, abovePrimary - _toolbarReachBelow),
      );
    }

    // Modo storico. Limiti delle ancore dentro il viewport: primaria (toolbar
    // SOPRA il punto) da `top + extent + margine` a `bottom - margine`;
    // secondaria (toolbar SOTTO il punto) da `top + margine` a `bottom -
    // extent - margine`. `_toolbarExtent` (48) è un po' più alto della toolbar
    // Material (44): il margine effettivo dal bordo è quindi >=
    // `_toolbarEdgeMargin`.
    final minAbove = viewport.top + _toolbarExtent + _toolbarEdgeMargin;
    final maxAbove = viewport.bottom - _toolbarEdgeMargin;
    final minBelow = viewport.top + _toolbarEdgeMargin;
    final maxBelow = viewport.bottom - _toolbarExtent - _toolbarEdgeMargin;

    // Ancora primaria: la toolbar viene disegnata SOPRA questo punto.
    Offset clampPrimary(Offset p) {
      if (p.dy < viewport.top) {
        return Offset(clampX(p.dx), minAbove);
      }
      if (p.dy > viewport.bottom) {
        return Offset(clampX(p.dx), maxAbove);
      }
      return p;
    }

    // Ancora secondaria: la toolbar viene disegnata SOTTO questo punto (solo
    // se sopra non c'è spazio).
    Offset clampSecondary(Offset p) {
      if (p.dy > viewport.bottom) {
        return Offset(clampX(p.dx), maxBelow);
      }
      if (p.dy < viewport.top) {
        return Offset(clampX(p.dx), minBelow);
      }
      return p;
    }

    final secondary = anchors.secondaryAnchor;
    return TextSelectionToolbarAnchors(
      primaryAnchor: clampPrimary(anchors.primaryAnchor),
      secondaryAnchor: secondary == null ? null : clampSecondary(secondary),
    );
  }

  // ---------------------------------------------------------------------------
  // Inseguimento: il menù Copia / Seleziona tutto segue la nota
  // ---------------------------------------------------------------------------

  /// Costruisce il menù contestuale della selezione.
  ///
  /// IL PROBLEMA. `flutter_md` mostra il menù con un `OverlayEntry` e richiama
  /// questo builder solo a `showToolbar()` (e alle ricostruzioni dell'entry),
  /// NON a ogni frame di scroll (dedotto dall'API pubblica, non dal sorgente
  /// privato del pacchetto): le ancore calcolate lì restavano ferme mentre la
  /// nota scorreva. Il `ContextMenuController` del
  /// pacchetto è privato (l'app non può chiedere una ricostruzione) e
  /// richiamare `showToolbar()` a ogni frame ricreerebbe l'`OverlayEntry`:
  /// da qui il divieto di `showToolbar()` per frame.
  ///
  /// LA SOLUZIONE. Per il menù ancorato alla selezione il widget restituito si
  /// aggiorna da solo: un `ListenableBuilder` ascolta `_scrollController` (e
  /// la «revisione» del tracking) e ricalcola le ancore nello STESSO frame
  /// dello scroll, senza `setState` sull'intera vista.
  ///
  /// COORDINATE DI CONTENUTO (niente frame di ritardo). La geometria viva
  /// (`globalSelectionRects()`, `contextMenuAnchors`) è quella dell'ULTIMO
  /// layout: `ScrollPosition` notifica prima del layout, quindi leggerla a
  /// ogni scroll darebbe un menù in ritardo di un frame. Si misura invece una
  /// volta, la si converte in coordinate di CONTENUTO
  /// (`y_contenuto = y_globale - viewport.top + offset`, che non dipendono
  /// dallo scroll) e a ogni scroll basta l'aritmetica
  /// `y_globale = y_contenuto - offset + viewport.top` con l'`offset` ATTUALE,
  /// lo stesso che la `ListView` userà per il layout di questo frame. La
  /// geometria viva si rilegge (a frame finito, [_scheduleToolbarRefresh])
  /// solo quando può essere cambiata: selezione diversa, blocchi che si
  /// montano, schermo ridimensionato. Le coordinate di contenuto restano
  /// valide anche quando i blocchi della selezione vengono smontati (è
  /// l'«ultimo lato noto»: con estremi smontati `contextMenuAnchors` perde la
  /// direzione e `selectionHandleEndpoints()` non è affidabile: osservato in
  /// CI).
  ///
  /// MENÙ NON ANCORATO ALLA SELEZIONE. Dopo `showToolbar(Offset)` (tasto
  /// destro) `contextMenuAnchors` ha solo l'ancora primaria (dal dartdoc
  /// pubblicato del pacchetto; il test 6 di selection_toolbar_tracking_test.dart
  /// ne verifica l'effetto: menù fermo); senza selezione non c'è niente da
  /// seguire. In entrambi i casi si
  /// restituisce la toolbar di sempre: ferma, con le ancore riportate nel
  /// viewport.
  ///
  /// LIMITI NOTI E NON VERIFICATI (nessuno è coperto da test):
  ///  * Overflow: a ogni notifica di scroll i pulsanti vengono ricreati e
  ///    `_TextSelectionToolbarOverflowable` chiude il menù «⋮» se i figli
  ///    cambiano. Con due voci l'overflow non esiste; se se ne aggiungessero,
  ///    andrebbero passati i figli già costruiti
  ///    (`AdaptiveTextSelectionToolbar.getAdaptiveButtons`) invece di
  ///    `buttonItems`.
  ///  * Pulsanti stantii: l'elenco è calcolato quando il menù compare; se la
  ///    selezione cambia a menù aperto (Seleziona tutto) non si aggiorna.
  ///  * Testo che cambia a menù aperto: le coordinate memorizzate sarebbero
  ///    stantie; `_updateBlocks` le azzera. Lo stesso vale se cambia solo la
  ///    larghezza del pannello (tablet a due pannelli con divisore mobile) o
  ///    la dimensione del carattere: la rimisura parte da blocchi che si
  ///    costruiscono, da notifiche del controller e da cambi di dimensione
  ///    dello SCHERMO, non da un cambio di larghezza del solo viewport.
  ///  * Scroll fulmineo: se in un frame si supera la `cacheExtent` (250 px) la
  ///    rimisura arriva uno-due frame dopo; nel frattempo vale la memoria.
  ///  * Cupertino e desktop: le costanti `_toolbarReach*` sono tarate sulla
  ///    toolbar Material; la toolbar desktop usa la sola ancora primaria.
  ///  * Tabelle a scroll orizzontale: il centro orizzontale del menù è
  ///    misurato una volta; scorrere la tabella non lo aggiorna.
  Widget _buildSelectionToolbar(MarkdownSelectionScopeState state) {
    final buttonItems = <ContextMenuButtonItem>[
      for (final item in state.contextMenuButtonItems)
        _wrapMenuItem(item, state),
    ];
    final anchors = state.contextMenuAnchors;
    final selection = _selectionController.selection;

    if (selection == null ||
        selection.isCollapsed ||
        anchors.secondaryAnchor == null) {
      _toolbarTracked = false;
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: _clampAnchorsToViewport(anchors),
        buttonItems: buttonItems,
      );
    }

    _armToolbarTracking(selection);
    return ListenableBuilder(
      listenable: _toolbarTrackListenable,
      builder: (context, _) {
        if (!mounted) return const SizedBox.shrink();
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: _trackedToolbarAnchors(context, anchors),
          buttonItems: buttonItems,
        );
      },
    );
  }

  /// Inizio di una «sessione» di inseguimento: il menù è appena comparso (o è
  /// stato ricostruito dal pacchetto). Memorizza la geometria della selezione
  /// in coordinate di contenuto e decide una volta sola il lato del menù.
  ///
  /// Se non ci sono rettangoli montati (selezione interamente fuori dalla
  /// `cacheExtent`) si tiene l'ultima geometria nota PER QUESTA selezione;
  /// se non ce n'è, [_trackedExtent] resta `null` e il menù ripiega sulle
  /// ancore statiche del pacchetto finché il ricalcolo a frame
  /// finito non trova qualcosa da misurare.
  void _armToolbarTracking(MarkdownSelection selection) {
    _toolbarTracked = true;
    final offset = _scrollOffset();
    final viewport = offset == null ? null : _viewportGlobalRect();
    final measured = _measureSelectionExtent();
    final remembered = _trackedExtent;
    final extent = measured ??
        (remembered != null && remembered.selection == selection
            ? remembered
            : null);
    _trackedExtent = extent;
    _trackBelow = extent != null &&
        offset != null &&
        viewport != null &&
        _wantsBelowPlacement(extent, viewport, offset);

    _scheduleToolbarRefresh();
  }

  /// Il menù va SOTTO la selezione (true) o SOPRA (false)? Si chiama solo
  /// quando il menù compare, la selezione cambia o il lato va ridecìso
  /// (richiamo): durante lo scroll il lato resta quello, perché ricalcolarlo a
  /// ogni frame farebbe saltare il menù da un lato all'altro della selezione
  /// (e l'utente chiede «senza scatti»).
  ///
  /// Sotto SOLO se la selezione parte dentro il viewport ma sopra non c'è
  /// spazio per la toolbar (`top` entro `_toolbarReachAbove` dal bordo alto) e
  /// sotto sì (`bottom` non oltre `_toolbarReachBelow` dal bordo basso): è il
  /// flip nativo («sotto il bordo inferiore se sopra non c'è spazio»), deciso
  /// però rispetto al VIEWPORT e non allo schermo. Una selezione che parte
  /// SOPRA il viewport non rientra qui: per lei vale l'aggancio al bordo
  /// superiore, con il menù sopra (a coprirne le prime righe).
  ///
  /// Le toolbar desktop usano la sola ancora primaria (il menù si apre SULL'ancora,
  /// non sopra/sotto): lì il lato inferiore non ha senso e si resta sopra.
  bool _wantsBelowPlacement(
    _TrackedExtent extent,
    Rect viewport,
    double offset,
  ) {
    if (!_toolbarUsesBothAnchors) return false;
    final top = extent.top - offset + viewport.top;
    final bottom = extent.bottom - offset + viewport.top;
    final minAbove = viewport.top + _toolbarReachAbove;
    final maxBelow = viewport.bottom - _toolbarReachBelow;
    return top >= viewport.top && top < minAbove && bottom <= maxBelow;
  }

  // Le toolbar touch (Material Android, Cupertino) usano ancora primaria e
  // secondaria; quelle desktop solo la primaria.
  bool get _toolbarUsesBothAnchors {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return true;
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return false;
    }
  }

  /// Ancore del menù per il frame corrente. Gira a ogni notifica dello scroll
  /// (dentro il `ListenableBuilder`): niente geometria viva, niente
  /// `showToolbar()`, solo aritmetica sulle coordinate di contenuto.
  ///
  /// Le ancore NATURALI sono il bordo superiore (primaria) e inferiore
  /// (secondaria) della selezione in coordinate globali, anche molto fuori dal
  /// viewport (selezione scrollata via, blocchi smontati); poi
  /// [_clampAnchorsToViewport] in modo `following` le riporta nel viewport:
  /// il menù si ferma sul bordo superiore se la selezione sta sopra o parte
  /// sopra, sul bordo inferiore se sta sotto, sempre interamente visibile.
  /// Il lato sopra/sotto lo decide il solo [_trackBelow].
  ///
  /// `MediaQuery.sizeOf` fa ricostruire il menù anche a rotazione o
  /// ridimensionamento della finestra, quando il viewport cambia senza scroll;
  /// il viewport nuovo si legge a layout finito, quindi si pianifica la
  /// rimisura (con sostituzione delle coordinate: il testo può essere
  /// andato a capo diversamente).
  TextSelectionToolbarAnchors _trackedToolbarAnchors(
    BuildContext context,
    TextSelectionToolbarAnchors staticAnchors,
  ) {
    final screen = MediaQuery.sizeOf(context);
    final previousScreen = _trackScreenSize;
    _trackScreenSize = screen;
    if (previousScreen != null && previousScreen != screen) {
      _scheduleToolbarRefresh(redecide: true, replace: true);
    }

    final extent = _trackedExtent;
    final offset = _scrollOffset();
    final viewport = offset == null ? null : _viewportGlobalRect();
    if (extent == null || offset == null || viewport == null) {
      // Geometria della selezione non nota (mai misurata e nessun
      // rettangolo montato): ancore statiche del pacchetto, cioè il
      // comportamento senza inseguimento, finché non c'è da misurare.
      return _clampAnchorsToViewport(staticAnchors);
    }

    final top = extent.top - offset + viewport.top;
    final bottom = extent.bottom - offset + viewport.top;
    return _clampAnchorsToViewport(
      TextSelectionToolbarAnchors(
        primaryAnchor: Offset(extent.centerX, top),
        secondaryAnchor: Offset(extent.centerX, bottom),
      ),
      following: true,
      below: _trackBelow,
    );
  }

  // Offset di scroll attuale (`pixels`), o `null` se la lista non è montata.
  // Non usa `ScrollController.offset`, che in debug asserisce di avere ESATTA-
  // MENTE una posizione: durante lo smontaggio della lista possono essere 0 o 2.
  double? _scrollOffset() {
    if (!_scrollController.hasClients) return null;
    final positions = _scrollController.positions;
    if (positions.length != 1) return null;
    return positions.first.pixels;
  }

  /// Misura la selezione corrente dalla geometria VIVA, in coordinate di
  /// contenuto: bounding box dei rettangoli montati (`globalSelectionRects()`).
  /// `null` se non c'è selezione, se la lista non è montata o se nessun
  /// rettangolo è montato. Va chiamata a layout finito (builder del menù a
  /// scroll fermo, oppure post-frame): a metà frame la geometria è quella
  /// del frame prima.
  _TrackedExtent? _measureSelectionExtent() {
    final selection = _selectionController.selection;
    if (selection == null || selection.isCollapsed) return null;
    final offset = _scrollOffset();
    final viewport = offset == null ? null : _viewportGlobalRect();
    if (offset == null || viewport == null) return null;

    Rect? box;
    for (final rect in _selectionController.globalSelectionRects()) {
      box = box == null ? rect : box.expandToInclude(rect);
    }
    if (box == null) return null;
    return _TrackedExtent(
      selection: selection,
      top: box.top - viewport.top + offset,
      bottom: box.bottom - viewport.top + offset,
      centerX: box.center.dx,
    );
  }

  // Il menù è quello inseguito (non il posizionale) ed è visibile ora.
  bool get _toolbarTrackingActive {
    if (!_toolbarTracked || !mounted) return false;
    final state = _selectionScopeKey.currentState;
    return state != null && state.mounted && state.toolbarIsVisible;
  }

  // Un blocco che si (ri)costruisce può portare nuovi rettangoli della
  // selezione (blocchi rimontati): se il menù è inseguito, si rimisura a
  // frame finito. Costo a menù chiuso: un `bool`.
  void _onBlockBuilt() {
    if (_toolbarTrackingActive) _scheduleToolbarRefresh();
  }

  /// Pianifica la rimisura dalla geometria viva, a frame finito, e la ripete
  /// una volta al frame dopo: se il registro del pacchetto assegna i rettangoli
  /// ai blocchi appena montati con un callback post-frame proprio, la prima
  /// passata può vederlo ancora vuoto (osservato in CI: il registro si è
  /// assestato più tardi del previsto). Le richieste che arrivano mentre una
  /// rimisura è già in coda si fondono con quella.
  ///
  /// [redecide]: ridecidi il lato sopra/sotto («posizione naturale»: richiamo,
  /// Seleziona tutto, schermo). [replace]: sostituisci le coordinate invece di
  /// unirle alle note (schermo: il testo può essere andato a capo altrove).
  void _scheduleToolbarRefresh({
    bool redecide = false,
    bool replace = false,
  }) {
    if (redecide) _trackRedecidePending = true;
    if (replace) _trackReplacePending = true;
    if (_toolbarRefreshScheduled) return;
    _toolbarRefreshScheduled = true;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      // La seconda passata va registrata PRIMA della prima: se questa
      // lanciasse, la coalescenza non resterebbe bloccata per sempre.
      binding.addPostFrameCallback((_) {
        _toolbarRefreshScheduled = false;
        if (mounted) _refreshToolbarTracking();
      });
      binding.ensureVisualUpdate();
      if (mounted) _refreshToolbarTracking();
    });
    // `addPostFrameCallback` da solo non pianifica un frame.
    binding.ensureVisualUpdate();
  }

  /// Rimisura la selezione dalla geometria viva (a frame finito) e, se è
  /// cambiato qualcosa, fa ricostruire il menù.
  ///
  /// A selezione invariata le note si UNISCONO (min dei top, max dei bottom):
  /// una misura dopo che alcuni blocchi sono stati smontati vede solo una
  /// parte della selezione e non deve far dimenticare l'estremo noto prima.
  /// Se la selezione cambia (o si chiede [_trackReplacePending]) si parte da
  /// zero, e il lato sopra/sotto si decide di nuovo.
  void _refreshToolbarTracking() {
    final redecide = _trackRedecidePending;
    final replace = _trackReplacePending;
    _trackRedecidePending = false;
    _trackReplacePending = false;
    if (!mounted || !_toolbarTrackingActive) return;

    final measured = _measureSelectionExtent();
    // Nessun rettangolo montato: si tiene l'ultima geometria nota.
    if (measured == null) return;

    final previous = _trackedExtent;
    final next = (previous != null &&
            previous.selection == measured.selection &&
            !replace)
        ? previous.unionWith(measured)
        : measured;
    final decideAgain =
        redecide || previous == null || previous.selection != next.selection;
    if (previous != null && !decideAgain && next.sameGeometryAs(previous)) {
      return;
    }

    final offset = _scrollOffset();
    final viewport = offset == null ? null : _viewportGlobalRect();
    _trackedExtent = next;
    if (decideAgain && offset != null && viewport != null) {
      _trackBelow = _wantsBelowPlacement(next, viewport, offset);
    }
    _toolbarTrackRevision.value++;
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
  // Richiamo di maniglie e menù con un long-press DENTRO la selezione.
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
      // In cima al tocco c'è un'altra cosa: di solito una maniglia, la toolbar
      // o il magnifier. NON VERIFICATO su dispositivo: l'hit-test non guarda
      // se una maniglia è dipinta, quindi una maniglia invisibile con l'area
      // di tocco sopra la selezione potrebbe far rifiutare il richiamo.
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

  /// È l'unico posto in cui la UI della selezione viene riportata in vista
  /// dopo un long-press sulla selezione: qui si innesta anche il ri-armo
  /// dell'inseguimento del menù (ultimo passo), senza toccare il
  /// riconoscimento del gesto.
  ///
  /// È IDEMPOTENTE: ogni passo agisce solo se manca qualcosa, quindi se
  /// maniglie e menù sono già visibili non cambia nulla (nessun
  /// lampeggio, nessun toggle). Non modifica mai la selezione (valore
  /// identico prima e dopo), non vibra e non arma l'auto-scroll.
  ///  1. focus: tastiera fisica e azioni del pacchetto lo richiedono;
  ///  2. maniglie (solo piattaforme touch con almeno un estremo montato): si
  ///     ricostruisce l'overlay con [_rebuildSelectionOverlay] se NON TUTTE le
  ///     maniglie esistenti sono DIPINTE ([_selectionHandlesNeedRebuild]:
  ///     controlla la visibilità, non l'esistenza del widget);
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

    if (_selectionHandlesNeedRebuild) {
      _rebuildSelectionOverlay();
    }

    // Dopo `_rebuildSelectionOverlay` la toolbar può essere sparita (il
    // pacchetto la nasconde quando la selezione passa per `null`): si
    // controlla per ultima.
    if (!state.toolbarIsVisible) state.showToolbar();

    // «Ri-arma» l'inseguimento del menù. Se era già visibile NON lo si
    // ricrea (niente `showToolbar()`: resterebbe lo stesso widget), ma si
    // rimisura la geometria e si ridecide il lato sopra/sotto: così il
    // richiamo lo riporta in posizione naturale anche se era rimasto agganciato
    // a un bordo. Se invece è stato appena ri-mostrato, il suo builder ha già
    // iniziato una nuova sessione e questa rimisura è solo una conferma.
    _scheduleToolbarRefresh(redecide: true);
  }

  // Le maniglie esistono solo sulle piattaforme touch (su desktop il
  // pacchetto non le mostra, come `SelectableText`) e solo se almeno uno dei
  // due estremi della selezione è montato (`selectionHandleEndpoints()` è
  // null altrimenti): fuori da questi casi non c'è nulla da ripristinare.
  //
  // CASO «ENTRAMBI gli estremi smontati» (selezione molto lunga: in vista c'è
  // solo il suo centro). Le maniglie non hanno un punto
  // a cui agganciarsi (il loro leader è il render object dell'estremo), quindi
  // il comportamento MENO INVASIVO è non toccarle: niente `clear()` né
  // riassegnazione, che farebbe solo lampeggiare il menù senza alcun
  // beneficio. Il richiamo mostra comunque il menù. Quando un estremo
  // rientra in vista un nuovo long-press sulla selezione ricostruisce le
  // maniglie se non risultano dipinte. NOTA: in CI, con
  // «Seleziona tutto» e scroll a metà di una nota di 80 paragrafi,
  // `selectionHandleEndpoints()` risultava comunque NON null; lo stato (b)
  // non si è riusciti a produrlo e non è stato osservato su dispositivo.
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

  // Serve ricostruire l'overlay per far riapparire le maniglie? Sì se se ne
  // aspettano ([_selectionHandlesExpected]) E non ce n'è nessuna oppure NON
  // TUTTE quelle esistenti sono DIPINTE.
  //
  // PERCHÉ VISIBILITÀ E NON ESISTENZA. Una versione precedente cercava il
  // widget `_SelectionHandleOverlay` nell'overlay radice e, se c'era,
  // rispondeva «le maniglie ci sono»: sul dispositivo non riapparivano. Quel
  // widget resta montato
  // anche quando non si vede (follower scollegato perché l'estremo è
  // smontato, opacità zero: vedi [SelectionHandleStatus]): nello stato del
  // sintomo la risposta era «ci sono» e non si ricostruiva nulla. Ora si
  // misura se sono DIPINTE ([inspectSelectionHandles]).
  //
  // POLITICA DI RICOSTRUZIONE: tre candidate.
  //  [A] ricostruire solo se NESSUNA maniglia è visibile. Sbaglia nello stato
  //      «parziale»: un estremo non è mai uscito dal rendering (maniglia
  //      dipinta), l'altro è uscito ed è rientrato e la sua maniglia non è
  //      stata ricollegata (`flutter_md` 0.2.0 non ha «proxy» per le maniglie
  //      di un estremo smontato: li introduce la PR #27 del repository
  //      upstream, successiva alla 0.2.0 e letta solo come indizio).
  //      L'utente vedrebbe UNA maniglia e il richiamo non farebbe nulla.
  //  [B] ricostruire sempre quando gli estremi sono montati. Copre ogni caso
  //      ma lampeggia anche quando va tutto bene (maniglie dipinte, menù
  //      visibile) e rompe l'idempotenza voluta dal richiamo (test 1: stessi
  //      `Element`, nessun lampeggio).
  //  [B'] SCELTA: come [B] ma SOLO se almeno una maniglia esistente non è
  //      dipinta. Stessa copertura di [B] nello stato parziale, nessun
  //      lampeggio nello stato sano. Il prezzo è un lampeggio quando un
  //      estremo è legittimamente smontato (la sua maniglia non può essere
  //      dipinta): accettato perché avviene solo su richiamo esplicito.
  //
  // Evidenza: il sorgente privato di `flutter_md` NON è stato letto, quindi
  // «nello stato parziale una sola maniglia manca» è un'inferenza, non un
  // fatto osservato; [B'] è la scelta che non ne dipende.
  bool get _selectionHandlesNeedRebuild {
    if (!_selectionHandlesExpected) return false;
    final handles = inspectSelectionHandles(context);
    return handles.isEmpty || handles.any((handle) => !handle.isPainted);
  }

  // ESPEDIENTE per riportare le maniglie: il pacchetto (0.2.0) non ha un API
  // pubblico per ri-mostrarle, ma ricostruisce overlay e maniglie quando la
  // selezione cambia. Si riassegna quindi la stessa selezione passando per
  // `null`: `selection = x` è un no-op se `x` è già il valore corrente
  // (confronto per valore), per cui senza il passaggio da `null` non
  // succederebbe nulla. È sincrono e dentro lo stesso gestore di eventi:
  // nessun frame intermedio con la selezione sparita. Va chiamato SOLO se
  // non tutte le maniglie sono dipinte (vedi [_selectionHandlesNeedRebuild]):
  // ricostruirle mentre sono visibili le farebbe riapparire con la
  // dissolvenza di Flutter, cioè un lampeggio. Il flag
  // [_rebuildingSelectionOverlay] impedisce che questo ripristino sia
  // scambiato per un gesto (auto-scroll, riarmo aptico).
  //
  // NON VERIFICATO: che il pacchetto ricolleghi davvero le maniglie a questo
  // passaggio da `null` (il test 7 di selection_recall_test.dart lo asserisce,
  // ma solo la prova su dispositivo dice se vale anche con i blocchi veri).
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

/// Geometria della selezione in COORDINATE DI CONTENUTO
/// (`y_contenuto = y_globale - viewport.top + offset`), misurata a frame
/// finito dalla geometria viva e poi usata, a ogni scroll, per ricavare per
/// sola aritmetica dove deve stare il menù. Non dipende dallo scroll:
/// resta valida anche quando i blocchi della selezione sono smontati.
///
/// [centerX] è invece globale: lo scroll è verticale e il centro orizzontale
/// della selezione non cambia con esso.
@immutable
class _TrackedExtent {
  const _TrackedExtent({
    required this.selection,
    required this.top,
    required this.bottom,
    required this.centerX,
  });

  /// La selezione a cui si riferisce la misura: se cambia, la memoria non vale.
  final MarkdownSelection selection;
  final double top;
  final double bottom;
  final double centerX;

  /// Stessa geometria entro mezzo pixel (rumore di virgola mobile).
  bool sameGeometryAs(_TrackedExtent other) =>
      (top - other.top).abs() < 0.5 &&
      (bottom - other.bottom).abs() < 0.5 &&
      (centerX - other.centerX).abs() < 0.5;

  /// Unisce due misure della STESSA selezione: gli estremi noti non vengono
  /// dimenticati se una misura successiva vede solo i blocchi ancora montati.
  /// Il centro orizzontale resta quello della prima misura, per non far
  /// muovere il menù di lato durante lo scroll.
  _TrackedExtent unionWith(_TrackedExtent other) => _TrackedExtent(
        selection: other.selection,
        top: top < other.top ? top : other.top,
        bottom: bottom > other.bottom ? bottom : other.bottom,
        centerX: centerX,
      );
}
