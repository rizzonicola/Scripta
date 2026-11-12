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
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:flutter/cupertino.dart'
    show cupertinoTextSelectionControls, cupertinoDesktopTextSelectionControls;
import 'package:flutter_md/flutter_md.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/markdown_math.dart';
import '../../../core/utils/perf_marks.dart';
import '../../../core/utils/haptics_helper.dart';
import '../../../core/utils/link_safety.dart';
import '../../../core/utils/selection_auto_scroller.dart';
import '../../settings/providers/settings_provider.dart';
import '../providers/note_search_provider.dart';
import 'package:flutter_math_fork/flutter_math.dart' show ParseException;
import 'package:flutter_math_fork/tex.dart'
    show SyntaxTree, TexParser, TexParserSettings;
import 'code_block_with_copy.dart';
import 'display_math_block.dart';
import 'reading_colors.dart';
import 'reading_empty_state.dart';
import 'reading_layout.dart';
import 'reading_meta_footer.dart';
import 'reading_outline_sheet.dart';
import 'reading_scroll_memory.dart';
import 'reading_search.dart';
import 'selection_handle_visibility.dart';

/// Sotto questa larghezza il pannello di lettura è considerato stretto:
/// i pulsanti flottanti (indice e torna-in-cima) coprirebbero ~24 px della
/// colonna di testo (44 px di cerchio a `right: 8`, contro i 28 px di padding
/// della colonna). Sui telefoni e sugli schermi stretti li togliamo entrambi:
/// per tornare in cima basta scorrere, senza occupare spazio sopra il testo.
const double _kOverlayButtonsMinWidth = 700;

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

  /// Identificativo stabile della nota, usato per ricordare la posizione di
  /// lettura tra un cambio nota e l'altro (in memoria). Opzionale: i test e
  /// gli usi isolati della vista non hanno una nota.
  final String? noteId;

  /// Metadati opzionali mostrati nel footer. Se assenti (test, anteprime)
  /// il footer è semplicemente omesso.
  final DateTime? updatedAt;
  final int? wordCount;
  final int? readingTimeMinutes;

  /// Invocato dallo stato vuoto per passare alla modifica. Se assente, lo
  /// stato vuoto resta puramente informativo.
  final VoidCallback? onEdit;

  /// Se `false`, il pulsante flottante dell'indice non viene mostrato.
  /// Usato dal focus mode, dove la barra deve restare completamente libera.
  /// Anche con `true`, il pulsante compare solo se il pannello di lettura è
  /// abbastanza largo: sotto [_kOutlineOverlayMinWidth] l'indice flottante
  /// coprirebbe la colonna di testo e viene omesso (vedi
  /// `_buildFormattedView`).
  final bool showOutline;

  const MarkdownRenderedView({
    super.key,
    required this.title,
    required this.content,
    this.noteId,
    this.updatedAt,
    this.wordCount,
    this.readingTimeMinutes,
    this.onEdit,
    this.showOutline = true,
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
  final FocusNode _selectionFocusNode = FocusNode(
    debugLabel: 'markdown-selection',
  );

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
  static const Duration _tapMaxDuration = Duration(
    milliseconds: 500,
  ); // ~kLongPressTimeout
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
  late final Listenable _toolbarTrackListenable = Listenable.merge(<Listenable>[
    _scrollController,
    _toolbarTrackRevision,
  ]);

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

  // Indice (titoli) e chiavi di aggancio per lo scroll a un blocco. Le chiavi
  // vengono create pigramente quando il blocco è costruito: per i blocchi
  // mai montati lo scroll usa una stima proporzionale (vedi
  // [_scrollToItem]).
  List<ReadingOutlineEntry> _outline = const [];
  final Map<int, GlobalKey> _itemKeys = <int, GlobalKey>{};

  // Ricerca resa: firma dell'ultimo calcolo (query + indice + lista items) e
  // risultati. La firma evita di ricalcolare/riscrivere la selezione a ogni
  // rebuild che non c'entra con la ricerca.
  Object? _searchSignature;
  List<ReadingSearchHit> _searchHits = const [];
  MarkdownSelection? _searchSelection;
  int _searchRevision = 0;
  int _publishedSearchTotal = 0;

  (ThemeData, String, double, double, TextScaler)? _cachedThemeKey;
  late MarkdownThemeData _markdownTheme;
  late TextStyle _titleTextStyle;
  late TextStyle _mathTextStyle;
  late Color _codeSurfaceColor;
  late Color _mathSurfaceColor;

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
    _restoreReadingPosition();
  }

  void _restoreReadingPosition() {
    final noteId = widget.noteId;
    if (noteId == null) return;
    final offset = ReadingScrollMemory.offsetFor(noteId);
    if (offset == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(
        offset.clamp(0.0, _scrollController.position.maxScrollExtent),
      );
    });
  }

  void _saveReadingPosition() {
    final noteId = widget.noteId;
    if (noteId == null || !_scrollController.hasClients) return;
    ReadingScrollMemory.save(noteId, _scrollController.offset);
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
    if (oldWidget.noteId != widget.noteId) {
      _saveReadingPosition();
      _restoreReadingPosition();
    }
    if (oldWidget.content != widget.content) {
      _updateBlocks(widget.content);
    }
  }

  @override
  void dispose() {
    _saveReadingPosition();
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
    PerfMarks.timeSync('reading.parse', () {
      final items = <_ViewItem>[];
      final documents = <MarkdownDocumentRef>[];
      final outline = <ReadingOutlineEntry>[];

      // 1) Le formule a blocco `$$...$$` vengono estratte prima del parsing
      //    (fuori da code fence/blocchi indentati); 2) ogni tratto Markdown è
      //    parsato con `inlineMath: true` (`$...$` -> Unicode), dopo una
      //    normalizzazione dei costrutti LaTeX comuni non coperti dal
      //    pacchetto (`\text{..}`, `\frac{..}{..}` semplici, ...).
      // `flutter_md` espone già i blocchi tramite il proprio modello
      // (`Markdown.fromString(...).blocks`): niente splitter manuale a righe.
      //
      // I blocchi `MD$Spacer` non producono testo (vedi
      // `markdownBlockRenderedText`) e aggiungevano solo un secondo margine
      // tra i paragrafi: si scartano e la spaziatura resta quella del padding
      // per blocco.
      for (final chunk in splitNoteChunks(content)) {
        switch (chunk) {
          case MarkdownChunk(:final source):
            if (source.trim().isEmpty) continue;
            final blocks = Markdown.fromString(
              normalizeInlineMath(source),
              inlineMath: true,
            ).blocks;
            for (final block in blocks) {
              if (block is MD$Spacer) continue;
              final id = 'block-${documents.length}';
              final model = Markdown(
                markdown: markdownBlockRenderedText(block),
                blocks: [block],
              );
              final itemIndex = items.length;
              items.add(_BlockItem(block, id, model));
              documents.add(
                MarkdownDocumentRef(
                  id: id,
                  model: model,
                  order: documents.length,
                ),
              );
              if (block is MD$Heading && block.text.trim().isNotEmpty) {
                outline.add(
                  ReadingOutlineEntry(
                    title: block.text.trim(),
                    level: block.level,
                    itemIndex: itemIndex,
                  ),
                );
              }
            }
          case DisplayMathChunk(:final tex):
            items.add(_MathItem(tex));
        }
      }

      _items = items;
      _outline = outline;
      _searchSignature = null;
      // Coordinate e modo del menù si riferivano ai blocchi di prima.
      _trackedExtent = null;
      _trackBelow = false;
      _selectionController.setDocuments(documents);
    });
  }

  void _ensureTheme(
    ThemeData theme,
    String fontFamily,
    double fontSize,
    double lineHeight,
    TextScaler textScaler,
  ) {
    final key = (theme, fontFamily, fontSize, lineHeight, textScaler);
    if (_cachedThemeKey == key) return;
    _cachedThemeKey = key;

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

    // Sfondo condiviso da citazioni, blocchi di codice e tabelle: derivato
    // dallo schema del tema attivo, così ogni palette mantiene il proprio
    // carattere invece di usare tinte fisse.
    final surfaceColor = ReadingColors.surface(theme.colorScheme);
    // Sfondo del testo monospace (inline e a blocco condividono lo stesso
    // campo in questa versione del pacchetto): poco più marcato del surface.
    final monospaceBackgroundColor = ReadingColors.monospaceBackground(
      theme.colorScheme,
    );

    _codeSurfaceColor = surfaceColor;
    _mathSurfaceColor = surfaceColor;
    _mathTextStyle = TextStyle(
      fontSize: fontSize * 1.15,
      color: theme.colorScheme.onSurface,
    );

    _markdownTheme = MarkdownThemeData.mergeTheme(
      theme,
      textScaler: textScaler,
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
    final textScaler = MediaQuery.textScalerOf(context);
    final searchQuery = ref.watch(
      noteSearchProvider.select((s) => s.isActive ? s.query.trim() : ''),
    );
    final requestedMatch = ref.watch(
      noteSearchProvider.select((s) => s.currentMatchIndex),
    );

    _ensureTheme(theme, fontFamily, fontSize, lineHeight, textScaler);
    _syncReadingSearch(searchQuery, requestedMatch);

    return _buildFormattedView(theme);
  }

  Widget _buildFormattedView(ThemeData theme) {
    final items = _items;
    final hasTitle = widget.title.trim().isNotEmpty;
    final hasEmptyState = items.isEmpty;
    final hasFooter =
        widget.updatedAt != null &&
        widget.wordCount != null &&
        widget.readingTimeMinutes != null;
    final itemCount =
        (hasTitle ? 1 : 0) +
        (hasEmptyState ? 1 : items.length) +
        (hasFooter ? 1 : 0);
    final selectionColor = _searchHits.isNotEmpty
        ? ReadingColors.searchHighlight(theme.colorScheme)
        : theme.colorScheme.primary.withValues(alpha: 0.35);

    final scrollable = MarkdownTheme(
      data: _markdownTheme,
      child: ScrollConfiguration(
        behavior: _NoGlowScrollBehavior(),
        child: Scrollbar(
          controller: _scrollController,
          child: ListView.builder(
            key: const ValueKey('markdown-formatted-listview'),
            controller: _scrollController,
            padding: ReadingLayout.readingPadding,
            itemCount: itemCount,
            itemBuilder: (context, index) {
              // Un blocco che si costruisce può portare nuovi
              // rettangoli della selezione (vedi [_onBlockBuilt]).
              _onBlockBuilt();
              if (hasTitle && index == 0) {
                return _buildTitleWidget(theme, selectionColor);
              }
              var cursor = hasTitle ? 1 : 0;
              if (hasEmptyState) {
                if (index == cursor) return _buildEmptyItem();
                cursor++;
              } else {
                if (index < cursor + items.length) {
                  final itemIndex = index - cursor;
                  return _buildItem(itemIndex, items[itemIndex]);
                }
                cursor += items.length;
              }
              if (hasFooter && index == cursor) {
                return _buildFooterItem();
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    // Una nota vuota non ha testo da selezionare: si evita del tutto lo
    // strato di selezione. Oltre a non servire, i suoi recognizer di
    // doppio-tap tengono aperta l'arena dei gesti ~300 ms, ritardando il
    // pulsante principale dello stato vuoto ("Modifica nota").
    final content = Focus(
      onKeyEvent: _handleReadingKeyEvent,
      child: hasEmptyState
          ? scrollable
          : MarkdownSelectionScope(
              key: _selectionScopeKey,
              controller: _selectionController,
              focusNode: _selectionFocusNode,
              selectionColor: selectionColor,
              selectionControls: _platformSelectionControls,
              onSelectionChanged: (selection) {
                _activeSelection = selection;
                // Durante un ripristino programmatico la selezione passa per
                // `null` per un istante: segnalarlo pianificherebbe il riarmo
                // aptico (vedi `HapticsHelper.reportSelectionState`). Il
                // valore finale è identico a quello di partenza, quindi non
                // c'è nulla da riferire.
                if (_rebuildingSelectionOverlay) return;
                HapticsHelper.reportSelectionState(
                  isCollapsed: selection == null || selection.isCollapsed,
                );
              },
              // Dopo "Copia" (o "Taglia", se mai presente) la selezione deve
              // terminare, come nel comportamento nativo di copia/incolla —
              // il menu di default del pacchetto copia ma lascia la selezione
              // attiva. Ricostruiamo la stessa toolbar di default
              // (`state.contextMenuButtonItems`, pattern documentato nel
              // README di flutter_md) avvolgendo solo i pulsanti
              // "copia"/"taglia": eseguono prima l'azione originale (deve
              // ancora leggere la selezione attiva) e poi chiudono la
              // selezione. "Seleziona tutto" lascia la selezione com'è, ma
              // deve garantire che la toolbar resti visibile anche se la
              // selezione di partenza era fuori schermo (vedi
              // [_afterSelectAll]). Il menù ancorato alla selezione SEGUE la
              // nota mentre scorre e si aggancia ai bordi del viewport (Step
              // B, vedi [_buildSelectionToolbar]); quello aperto con il tasto
              // destro resta fermo, con le ancore riportate dentro il
              // viewport (vedi [_clampAnchorsToViewport]).
              contextMenuBuilder: (context, state) =>
                  _buildSelectionToolbar(state),
              // Il `RawGestureDetector` è un FIGLIO dello scope (quindi più
              // profondo del suo `RawGestureDetector` interno): riceve il
              // `PointerDown` prima e i suoi recognizer entrano per primi
              // nell'arena. Contiene un solo recognizer, che si iscrive
              // all'arena soltanto per un tocco touch dentro una selezione
              // esistente (vedi [_SelectionRecallRecognizer]); in ogni altro
              // caso è inerte e il comportamento resta quello di prima.
              child: RawGestureDetector(
                behavior: HitTestBehavior.translucent,
                gestures: _recallGestures,
                // Il recognizer non deve aggiungere azioni di accessibilità:
                // serve solo a decidere chi vince l'arena dei gesti.
                excludeFromSemantics: true,
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _handleBackgroundPointerDown,
                  onPointerMove: _handleBackgroundPointerMove,
                  onPointerUp: _handleBackgroundPointerUp,
                  onPointerCancel: _handleBackgroundPointerCancel,
                  child: scrollable,
                ),
              ),
            ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // Gli overlay sono chrome sopra il testo: sugli schermi stretti li
        // togliamo del tutto invece di rimpicciolirli. Vale anche per il
        // torna-in-cima, che altrimenti coprirebbe la colonna di lettura.
        final showOverlayButtons =
            constraints.maxWidth >= _kOverlayButtonsMinWidth;
        final showOutlineButton =
            widget.showOutline &&
            _outline.length >= 2 &&
            showOverlayButtons;
        return Stack(
          children: [
            Positioned.fill(child: content),
            if (showOutlineButton)
              Positioned(
                top: 8,
                right: 8,
                child: _ReadingOverlayButton(
                  icon: Icons.toc_rounded,
                  tooltip: AppLocalizations.of(context).readingOutline,
                  onPressed: _showOutline,
                ),
              ),
            if (showOverlayButtons)
              Positioned(
                bottom: 16,
                right: 16,
                child: _buildBackToTopButton(),
              ),
          ],
        );
      },
    );
  }

  Widget _buildEmptyItem() {
    return ReadingLayout.centered(
      ReadingEmptyState(onEdit: widget.onEdit),
      key: const ValueKey('rendered-empty-state'),
    );
  }

  Widget _buildFooterItem() {
    return ReadingLayout.centered(
      ReadingMetaFooter(
        wordCount: widget.wordCount!,
        readingTimeMinutes: widget.readingTimeMinutes!,
        updatedAt: widget.updatedAt!,
      ),
      key: const ValueKey('rendered-meta-footer'),
    );
  }

  Widget _buildBackToTopButton() {
    return ListenableBuilder(
      listenable: _scrollController,
      builder: (context, _) {
        final visible =
            _scrollController.hasClients && _scrollController.offset > 480;
        // Quando non serve non si costruisce affatto: niente pulsante
        // invisibile nell'albero (niente hit target fantasma e un solo
        // IconButton nella vista finché l'utente non scorre davvero).
        if (!visible) return const SizedBox.shrink();
        return _ReadingOverlayButton(
          icon: Icons.vertical_align_top_rounded,
          tooltip: AppLocalizations.of(context).readingBackToTop,
          onPressed: () => _scrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          ),
        );
      },
    );
  }

  /// Gestisce PageUp/PageDown, Home/End e Spazio quando il focus è sulla
  /// vista di lettura (dopo un tocco/una selezione). Non intercetta i tasti
  /// quando il focus è altrove: barra di ricerca e pulsanti restano
  /// indipendenti.
  KeyEventResult _handleReadingKeyEvent(FocusNode node, KeyEvent event) {
    if (!_selectionFocusNode.hasFocus) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      _scrollByPage(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _scrollByPage(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _scrollByPage(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  double _viewportPageExtent() {
    if (!_scrollController.hasClients) return 0;
    return _scrollController.position.viewportDimension;
  }

  void _scrollByPage(double direction) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target =
        (_scrollController.offset + direction * _viewportPageExtent() * 0.85)
            .clamp(0.0, position.maxScrollExtent);
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  void _showOutline() {
    if (_outline.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => ReadingOutlineSheet(
        entries: _outline,
        onSelected: (entry) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _scrollToItem(entry.itemIndex);
          });
        },
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Ricerca nella vista di lettura
  // ---------------------------------------------------------------------

  /// Calcola le occorrenze sul testo RESO (query/indice/lista cambiati) e
  /// programma l'applicazione della selezione a frame finito. La firma evita
  /// di rifare il lavoro a ogni rebuild estraneo alla ricerca.
  void _syncReadingSearch(String query, int requestedIndex) {
    final signature = (query, requestedIndex, _items);
    if (signature == _searchSignature) return;
    _searchSignature = signature;
    final revision = ++_searchRevision;

    if (query.isEmpty) {
      _searchHits = const [];
      _publishSearchTotal(0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || revision != _searchRevision) return;
        _clearSearchSelectionIfOurs();
      });
      return;
    }

    final blocks = <ReadingSearchBlock>[];
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (item is _BlockItem) {
        blocks.add(
          ReadingSearchBlock(
            itemIndex: i,
            documentId: item.documentId,
            text: markdownBlockRenderedText(item.block),
          ),
        );
      }
    }
    final hits = findReadingSearchHits(blocks, query);
    _searchHits = hits;
    _publishSearchTotal(hits.length);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _searchRevision) return;
      if (hits.isEmpty) {
        _clearSearchSelectionIfOurs();
        return;
      }
      final index = requestedIndex < 0 ? 0 : requestedIndex % hits.length;
      _applySearchHit(hits[index]);
    });
  }

  void _publishSearchTotal(int total) {
    if (_publishedSearchTotal == total) return;
    _publishedSearchTotal = total;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(renderedNoteSearchTotalProvider.notifier).set(total);
    });
  }

  void _applySearchHit(ReadingSearchHit hit) {
    final selection = MarkdownSelection(
      base: MarkdownPosition(
        documentId: hit.documentId,
        blockIndex: 0,
        offset: hit.range.start,
      ),
      extent: MarkdownPosition(
        documentId: hit.documentId,
        blockIndex: 0,
        offset: hit.range.end,
      ),
    );
    _rebuildingSelectionOverlay = true;
    try {
      _selectionController.selection = selection;
    } finally {
      _rebuildingSelectionOverlay = false;
    }
    _searchSelection = selection;
    _activeSelection = selection;
    final state = _selectionScopeKey.currentState;
    if (state != null && state.toolbarIsVisible) state.hideToolbar();
    _scrollToItem(hit.itemIndex);
  }

  void _clearSearchSelectionIfOurs() {
    final applied = _searchSelection;
    if (applied == null) return;
    _searchSelection = null;
    if (_selectionController.selection != applied) return;
    _rebuildingSelectionOverlay = true;
    try {
      _selectionController.clear();
    } finally {
      _rebuildingSelectionOverlay = false;
    }
    final state = _selectionScopeKey.currentState;
    if (state != null && state.toolbarIsVisible) state.hideToolbar();
  }

  /// Porta a schermo il blocco [itemIndex]. Se il blocco è montato usa la
  /// geometria reale (`Scrollable.ensureVisible`); altrimenti salta a una
  /// stima proporzionale e riprova un frame dopo, quando la
  /// virtualizzazione lo ha costruito.
  void _scrollToItem(int itemIndex, {int retries = 1}) {
    final context = _itemKeys[itemIndex]?.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        alignment: 0.2,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    if (!_scrollController.hasClients || _items.isEmpty) return;
    final position = _scrollController.position;
    final estimate = position.maxScrollExtent * (itemIndex / _items.length);
    _scrollController.animateTo(
      estimate.clamp(0.0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
    if (retries > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToItem(itemIndex, retries: retries - 1);
      });
    }
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

  // Le ancore di flutter_md sono calcolate sui soli blocchi montati e possono
  // cadere fuori dal viewport (selezione scrollata via, "Seleziona tutto"):
  // qui le ancore vengono riportate sul bordo visibile più vicino.
  //
  // `following: false` conserva il comportamento precedente e tocca solo le
  // ancore esterne. Con `following: true` le ancore naturali (fornite in
  // coordinate globali) tengono sempre la toolbar dentro il viewport, con
  // `_toolbarEdgeMargin` dal bordo. Flutter decide il flip sopra/sotto in base
  // allo schermo, non al viewport: la forma delle ancore evita quel salto.
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
  /// flutter_md richiama questo builder solo quando il menù appare, non a ogni
  /// frame di scroll: le ancore resterebbero ferme. Il widget restituito si
  /// aggiorna quindi con un `ListenableBuilder` sullo scroll e ricalcola le
  /// ancore nello stesso frame, senza ricreare l'`OverlayEntry`. La geometria
  /// viene misurata una volta e convertita in coordinate di contenuto, così a
  /// ogni scroll basta l'aritmetica. Per i menù non ancorati alla selezione
  /// (tasto destro) resta la toolbar classica, ferma nel viewport.
  ///
  /// Limiti noti: i pulsanti vengono ricreati a ogni scroll; una selezione o
  /// un testo che cambiano a menù aperto lasciano le ancore memorizzate; uno
  /// scroll oltre la `cacheExtent` rimisura con uno-due frame di ritardo.
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
    final extent =
        measured ??
        (remembered != null && remembered.selection == selection
            ? remembered
            : null);
    _trackedExtent = extent;
    _trackBelow =
        extent != null &&
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
  void _scheduleToolbarRefresh({bool redecide = false, bool replace = false}) {
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
    final next =
        (previous != null &&
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
    _pendingTapPointers[event.pointer] = _PendingTap(
      event.position,
      DateTime.now(),
    );
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
    return _selectionController.globalSelectionRects().any(
      (rect) => rect.inflate(_recallTouchTolerance).contains(position),
    );
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

  // Serve ricostruire l'overlay? Sì se le maniglie sono attese
  // ([_selectionHandlesExpected]) e nessuna è dipinta (o non lo sono tutte).
  //
  // Si controlla che siano DIPINTE, non che esistano: il widget resta
  // montato anche da invisibile (follower scollegato, opacità zero; vedi
  // [SelectionHandleStatus]). Ricostruire sempre lampeggerebbe anche quando
  // va tutto bene, quindi si ricostruisce solo se almeno una maniglia
  // esistente non è dipinta. Il costo è un lampeggio quando un estremo è
  // legittimamente smontato, ma avviene solo su richiamo esplicito.
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
    return ReadingLayout.centered(
      Column(
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
      key: const ValueKey('rendered-block-title'),
    );
  }

  // I BlockPainter di flutter_md non hanno hook di gesture: il drag di
  // selezione è orchestrato da MarkdownSelectionScope. Per le tabelle non si
  // tocca quindi il rendering interno; si avvolge il singolo blocco in uno
  // `SingleChildScrollView` orizzontale, che lascia intatti scroll verticale,
  // selezione touch e larghezza naturale della tabella.
  //
  // LIMITE NOTO: le checkbox delle task list sono disegnate dal painter e
  // `MD$ListItem.checked` è immutabile; flutter_md 0.2.0 non espone un hook
  // per il tocco su una singola checkbox. Restano quindi di sola lettura:
  // per spuntarle si passa a Modifica (dove sono testo normale).
  Widget _buildItem(int index, _ViewItem item) {
    final Widget content;
    final String semanticsLabel;
    switch (item) {
      case _MathItem(:final tex, :final ast, :final parseError):
        semanticsLabel = tex;
        content = DisplayMathBlock(
          tex: tex,
          textStyle: _mathTextStyle,
          ast: ast,
          parseError: parseError,
          surfaceColor: _mathSurfaceColor,
        );
      case _BlockItem(:final block, :final documentId, :final model):
        semanticsLabel = markdownBlockRenderedText(block);
        final markdownWidget = MarkdownWidget(
          markdown: model,
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

    final anchorKey = _itemKeys.putIfAbsent(index, GlobalKey.new);
    return ReadingLayout.centered(
      KeyedSubtree(
        key: anchorKey,
        child: Padding(
          padding: ReadingLayout.blockBottomPadding,
          child: Semantics(
            container: true,
            label: semanticsLabel,
            child: content,
          ),
        ),
      ),
      key: ValueKey('rendered-block-$index'),
    );
  }
}

class _NoGlowScrollBehavior extends ScrollBehavior {
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

/// Piccolo pulsante circolare sovrapposto alla vista di lettura (indice e
/// torna in cima). Ha un'area di tocco di 44×44 e un tooltip localizzato.
class _ReadingOverlayButton extends StatelessWidget {
  const _ReadingOverlayButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        // Un filo di rilievo, non un FAB: la lettura è carta, non una
        // dashboard. Il fondo è semitrasparente così il pulsante si appoggia
        // alla pagina invece di ritagliarci sopra un cerchio pieno; il bordo
        // sottile mantiene il contorno leggibile anche nei temi scuri/OLED,
        // dove l'ombra quasi non si vede.
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: 0.18),
        shape: CircleBorder(
          side: BorderSide(
            color: scheme.outline.withValues(alpha: 0.55),
            width: 1,
          ),
        ),
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.76),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          onPressed: onPressed,
          icon: Icon(icon, size: 20),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 44, height: 44),
          visualDensity: VisualDensity.compact,
          color: scheme.onSurface.withValues(alpha: 0.8),
        ),
      ),
    );
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
/// Si usa un recognizer invece di annullare a posteriori il gesto del
/// pacchetto: così la parola sotto il dito non viene mai selezionata e non
/// partono focus, vibrazione, chiusura del menù o magnifier. Usa solo API
/// pubbliche e assume (verificato da `selection_recall_test.dart`) che il
/// long-press di flutter_md sia un recognizer dell'arena con scadenza ≥ 480 ms.
///
/// Fuori da una selezione, o con mouse/trackpad/penna, il recognizer non entra
/// nell'arena. Dentro una selezione si rifiuta al rilascio, quindi non ritarda
/// tap o double-tap; con più puntatori il ricontrollo alla scadenza rifiuta il
/// gesto.
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
  const _BlockItem(this.block, this.documentId, this.model);
  final MD$Block block;
  final String documentId;
  final Markdown model;
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
