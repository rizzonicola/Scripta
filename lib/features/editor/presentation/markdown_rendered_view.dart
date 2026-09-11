import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/haptics_helper.dart';
import '../../../core/utils/syntax_highlighter.dart';
import '../../settings/providers/settings_provider.dart';

// Import esplicito da `rendering.dart`: `SelectedContent` è il tipo restituito
// da `SelectionArea.onSelectionChanged` (usato più sotto per la "Seamless
// Text Selection"). È tecnicamente raggiungibile anche solo tramite
// `material.dart` in molte versioni del framework, ma affidarsi a
// un'esportazione transitiva è fragile: basta un refactor interno di
// Flutter (o una versione del framework che riorganizzi gli export) perché
// la pipeline CI/CD (Linux/Android build) smetta di compilare con un
// "undefined name SelectedContent". Importarlo esplicitamente da dove è
// realmente definito rende la dipendenza esplicita e stabile.
import 'package:flutter/rendering.dart' show SelectedContent;

/// Vista di sola lettura di una nota Markdown.
///
/// OTTIMIZZAZIONE PERFORMANCE (note di grandi dimensioni):
/// `flutter_markdown_plus` riparsa `data` in un AST e ricostruisce l'intero
/// albero di widget ogni volta che `build()` viene invocato — non fa alcun
/// caching proprio. Nell'albero originale, `build()` veniva rieseguito ad
/// ogni piccolo rebuild "collaterale" del genitore (toggle del focus mode,
/// cambio di un'impostazione non correlata al rendering come la lingua o
/// l'intensità haptic, animazioni), anche quando titolo/contenuto della nota
/// non erano affatto cambiati: su una nota lunga, questo produceva un
/// parsing + relayout Markdown completo più volte al secondo → il
/// lag/freeze osservato.
///
/// La correzione, senza introdurre lazy loading o paginazione del testo:
///  1. Si osservano da Riverpod SOLO i campi di `AppSettings` che influenzano
///     realmente il rendering (font/size/line-height), tramite `.select`,
///     invece dell'intero oggetto impostazioni.
///  2. Il sottoalbero renderizzato (titolo + `MarkdownBody`) viene
///     memorizzato in `State` e ricostruito SOLO quando uno degli input che
///     lo determinano (contenuto, titolo, font, tema) è realmente cambiato
///     rispetto all'ultima build. Se `build()` viene rieseguito per un
///     motivo estraneo, si restituisce la STESSA istanza di widget già
///     costruita in precedenza: Flutter la riconosce (`identical`) e salta
///     interamente rebuild/relayout/repaint di quel sottoalbero, senza
///     bisogno di spezzettare o ritardare il rendering del testo.
///  3. Il sottoalbero è avvolto in un `RepaintBoundary`, così viene isolato
///     sul proprio layer grafico: qualunque repaint circostante (cursore,
///     hover, animazioni della toolbar, ecc.) non forza mai un repaint dei
///     pixel già renderizzati della nota.
///  4. Il contenuto è renderizzato con `ListView.builder`, un blocco per
///     elemento (vedi `_splitMarkdownIntoBlocks`), invece di un unico
///     `MarkdownBody` dentro una `Column`/`SingleChildScrollView` non
///     virtualizzata: su note molto lunghe, quest'ultima è la causa reale
///     del lag durante lo SCROLL (Flutter deve comunque layoutare/dipingere
///     anche i blocchi fuori schermo). Le liste "tight" (senza righe vuote
///     tra un elemento e l'altro — il caso più pesante in pratica: una
///     singola lista lunga centinaia di righe) vengono spezzate un elemento
///     alla volta, non solo sulle righe vuote, altrimenti resterebbero un
///     unico blocco gigante e la virtualizzazione non avrebbe alcun
///     effetto. Il testo resta parsato per intero, in un solo passaggio,
///     prima di essere suddiviso: non è lazy loading né paginazione del
///     contenuto, solo virtualizzazione del rendering di blocchi già pronti.
///
/// Il ripristino "a caldo" resta corretto: quando l'utente passa in modalità
/// modifica e poi torna in visualizzazione, `NoteEditorPane` smonta questo
/// widget (vedi `AnimatedSwitcher`/`KeyedSubtree` in note_editor_pane.dart),
/// quindi lo `State` — e con esso la cache — viene ricreato da zero e il
/// testo più recente viene renderizzato correttamente; da quel momento in
/// poi la cache torna a garantire fluidità sui rebuild superflui successivi.
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

/// ============================================================================
/// SEAMLESS TEXT SELECTION — note di approccio
/// ============================================================================
///
/// PROBLEMA: `flutter_markdown_plus` in modalità `selectable: true` avvolge
/// OGNI elemento (paragrafo, voce di lista, cella di tabella...) nel proprio
/// `SelectableRegion`/`Text` indipendente. Trascinare una selezione che
/// attraversa più elementi (il caso normale: selezionare due righe) obbliga
/// Flutter a fondere selezioni provenienti da widget "fratelli" scollegati:
/// è la causa nota di offset che saltano, caratteri duplicati/mancanti e, su
/// note lunghe, del lag descritto nell'obiettivo. Per questo la vista
/// corrente passa già `selectable: false` a `MarkdownBody` e delega la
/// selezione a UN SOLO `SelectionArea` esterno (vedi più sotto).
///
/// SOLUZIONE ("seamless"): un `SelectionArea` rileva come "selezionabile"
/// qualunque `Text`/`RichText` presente nel suo sottoalbero al momento in cui
/// esegue l'hit-test — non è legato all'istanza di widget che si trovava
/// sotto il dito quando la selezione è partita. Possiamo quindi, blocco per
/// blocco, SOSTITUIRE al volo il contenuto (da `MarkdownBody` formattato a un
/// singolo `Text` con il markdown grezzo) SENZA smontare o ricreare il
/// `SelectionArea` stesso: il drag in corso continua a funzionare, ma ora
/// opera su un unico `RenderParagraph` piatto per quel blocco → corrispondenza
/// 1:1 esatta tra offset del tocco e carattere selezionato, zero fusione tra
/// widget fratelli.
///
/// TRIGGER (quando un blocco passa a "raw"): non intercettiamo i gesture
/// grezzi in competizione con i recognizer di `SelectionArea` (rischierebbe
/// di rubargli l'arena e rompere la selezione nativa). Usiamo invece il
/// canale che Flutter già espone per questo: `SelectionArea.onSelectionChanged`
/// riporta il contenuto testuale non appena una parola viene selezionata
/// (tap-and-hold o doppio tap, sia touch che desktop) — è il segnale stesso
/// di "gesture di selezione iniziata" richiesto dalla spec, semplicemente
/// osservato dal livello giusto invece che da un `Listener`/`GestureDetector`
/// grezzo che dovrebbe poi reimplementare la logica di long-press/doppio tap
/// già presente (e testata) dentro `SelectionArea`. Il testo selezionato
/// viene confrontato (via cache) con il testo "reso" di ciascun blocco per
/// capire quale blocco coinvolge, e SOLO quello passa a raw.
///
/// USCITA dalla modalità raw: `onSelectionChanged(null)` (tap altrove /
/// deselezione) oppure pressione di "Copia" nel menu contestuale (intercettata
/// tramite `contextMenuBuilder`) riportano il blocco a Markdown formattato.
///
/// SCROLL: sostituire un blocco raw/formattato ne cambia l'altezza (il
/// markdown grezzo contiene caratteri di sintassi in più/meno rispetto al
/// testo reso). Per non perdere il punto a cui l'utente sta guardando NON
/// stimiamo l'offset con un calcolo approssimativo (es. "N px per riga"):
/// misuriamo la posizione VERTICALE REALE del blocco (via `GlobalKey` +
/// `RenderBox.localToGlobal`) subito prima e subito dopo lo swap, e
/// compensiamo lo `ScrollController` esattamente della differenza misurata.
/// È un aggiustamento basato su geometria già disposta (layout reale), non su
/// un'euristica sui pixel per riga — l'ancoraggio segue quindi il blocco
/// (e con esso il testo/offset di carattere che l'utente stava toccando),
/// non una quantità di scroll indovinata a priori.
///
/// PRESTAZIONI: la costosa suddivisione in blocchi + costruzione dello
/// stylesheet resta cache-ata esattamente come prima (invariata da
/// contenuto/font/tema). In aggiunta, ogni blocco FORMATTATO viene
/// costruito una sola volta come istanza di widget e riusato `identical`
/// finché il suo stato raw/formattato non cambia: attivare la selezione
/// grezza su un blocco NON invalida né ricostruisce gli altri blocchi della
/// nota (niente reparse Markdown "di massa" durante il drag di selezione).
class _MarkdownRenderedViewState extends ConsumerState<MarkdownRenderedView> {
  // --- Cache degli "ingredienti" costosi (invariata nello spirito rispetto
  // alla versione precedente): ricalcolati SOLO quando cambia davvero
  // contenuto/titolo/font/tema, mai per un cambio di selezione. ---
  List<String>? _cachedBlocks;
  List<bool>? _cachedBlockIsListItem;
  List<Widget>? _cachedFormattedItems;
  Widget? _cachedTitleWidget;
  bool _cachedHasTitle = false;
  TextStyle? _cachedRawTextStyle;
  String? _cachedTitle;
  String? _cachedContent;
  String? _cachedFontFamily;
  double? _cachedFontSize;
  double? _cachedLineHeight;
  ColorScheme? _cachedColorScheme;
  Brightness? _cachedBrightness;

  // --- Stato di selezione "seamless" (vedi doc di classe sopra). ---
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _blockKeys = {};
  final Map<int, Widget> _cachedRawItems = {};
  final Map<String, String> _renderedPlainTextCache = {};
  Set<int> _rawBlockIndices = const {};

  @override
  void dispose() {
    // Rilascia esplicitamente i riferimenti pesanti (testo della nota e
    // sottoalbero renderizzato) non appena la vista viene smontata, così non
    // restano agganciati più a lungo del necessario in attesa della GC.
    _cachedFormattedItems = null;
    _cachedTitleWidget = null;
    _cachedContent = null;
    _blockKeys.clear();
    _cachedRawItems.clear();
    _renderedPlainTextCache.clear();
    _scrollController.dispose();
    super.dispose();
  }

  /// Testo "reso" approssimato di un blocco: il testo visibile dopo che il
  /// markdown è stato interpretato (es. `**bold**` → `bold`, `# Titolo` →
  /// `Titolo`), usato SOLO per capire quale blocco corrisponde al testo che
  /// `SelectionArea.onSelectionChanged` riporta come selezionato. Calcolato
  /// una sola volta per blocco (cache tenuta in vita quanto il blocco
  /// stesso) e mai ricalcolato durante un drag di selezione, che può
  /// invocare questo confronto molte volte al secondo.
  String _renderedPlainTextFor(String block) {
    return _renderedPlainTextCache.putIfAbsent(block, () {
      try {
        final document = md.Document(extensionSet: md.ExtensionSet.gitHubWeb);
        final nodes = document.parseLines(block.split('\n'));
        final buffer = StringBuffer();
        for (final node in nodes) {
          buffer.writeln(node.textContent);
        }
        return buffer.toString();
      } catch (_) {
        // Fallback prudente: se il parsing del singolo blocco fallisse per
        // un caso limite, usiamo il testo grezzo stesso come approssimazione
        // — nel peggiore dei casi il matching sarà un po' meno preciso, ma
        // non blocca mai la funzionalità né fa fallire la build.
        return block;
      }
    });
  }

  /// Determina quali blocchi (indici in `_cachedBlocks`) sono coinvolti dal
  /// testo attualmente selezionato, confrontandolo con il testo reso di
  /// ciascun blocco. Una selezione può attraversare più blocchi: per questo
  /// si confronta sia il testo intero sia riga per riga.
  Set<int> _activeBlocksFor(String selectedPlainText) {
    final normalizedSelected = selectedPlainText.trim();
    final blocks = _cachedBlocks;
    if (normalizedSelected.isEmpty || blocks == null) return const {};

    final segments = normalizedSelected
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);

    final active = <int>{};
    for (var i = 0; i < blocks.length; i++) {
      final normalizedBlock = _renderedPlainTextFor(blocks[i]).trim();
      if (normalizedBlock.isEmpty) continue;
      final wholeMatch = normalizedBlock.contains(normalizedSelected) ||
          normalizedSelected.contains(normalizedBlock);
      final segmentMatch =
          !wholeMatch && segments.any(normalizedBlock.contains);
      if (wholeMatch || segmentMatch) active.add(i);
    }
    return active;
  }

  bool _sameIndexSet(Set<int> a, Set<int> b) {
    if (a.length != b.length) return false;
    for (final value in a) {
      if (!b.contains(value)) return false;
    }
    return true;
  }

  /// Callback di `SelectionArea.onSelectionChanged`: unico punto da cui la
  /// "gesture di selezione" viene osservata (vedi doc di classe). Aggiorna
  /// anche l'aptica tramite lo stesso canale già usato dall'editor
  /// (`HapticsHelper.reportSelectionState`), così un tap-and-hold in
  /// sola-lettura si comporta in modo coerente con quello nel campo di
  /// modifica, invece di introdurre una logica aptica parallela.
  void _handleSelectionChanged(SelectedContent? content) {
    final hasSelection =
        content != null && content.plainText.trim().isNotEmpty;
    HapticsHelper.reportSelectionState(isCollapsed: !hasSelection);

    if (!hasSelection) {
      if (_rawBlockIndices.isNotEmpty) {
        setState(() => _rawBlockIndices = const {});
      }
      return;
    }

    final nextActive = _activeBlocksFor(content.plainText);
    if (nextActive.isEmpty || _sameIndexSet(_rawBlockIndices, nextActive)) {
      return;
    }

    // Ancora lo scroll sul primo blocco coinvolto: è quello su cui il dito
    // (o il cursore) si trova con maggiore probabilità in questo istante.
    _swapPreservingScrollAnchor(
      anchorBlockIndex: nextActive.first,
      applyChange: () => setState(() => _rawBlockIndices = nextActive),
    );
  }

  /// Riporta tutti i blocchi a Markdown formattato. Usata sia quando la
  /// selezione si azzera (gestito già in `_handleSelectionChanged`), sia
  /// esplicitamente dopo "Copia" dal menu contestuale (vedi
  /// `_buildContextMenu`), perché su alcune piattaforme la selezione visibile
  /// può restare attiva dopo la copia invece di azzerarsi da sola.
  void _revertAllRawBlocks() {
    if (_rawBlockIndices.isEmpty) return;
    setState(() => _rawBlockIndices = const {});
  }

  /// Misura la posizione verticale REALE (non stimata) del blocco indicato
  /// prima di applicare `applyChange`, e la rimisura a frame concluso,
  /// compensando lo `ScrollController` della differenza esatta così che il
  /// punto guardato dall'utente non "salti" quando il blocco cambia altezza
  /// passando da formattato a grezzo (o viceversa).
  void _swapPreservingScrollAnchor({
    required int anchorBlockIndex,
    required VoidCallback applyChange,
  }) {
    double? beforeTop;
    final beforeBox = _blockKeys[anchorBlockIndex]
        ?.currentContext
        ?.findRenderObject();
    if (beforeBox is RenderBox && beforeBox.attached) {
      beforeTop = beforeBox.localToGlobal(Offset.zero).dy;
    }

    applyChange();

    if (beforeTop == null) return;
    final anchor = beforeTop;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final afterBox = _blockKeys[anchorBlockIndex]
          ?.currentContext
          ?.findRenderObject();
      if (afterBox is! RenderBox || !afterBox.attached) return;

      final afterTop = afterBox.localToGlobal(Offset.zero).dy;
      final delta = afterTop - anchor;
      if (delta.abs() < 0.5) return;

      final position = _scrollController.position;
      final target = (_scrollController.offset + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      _scrollController.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // `.select` sui SOLI campi che influenzano il rendering del testo: un
    // cambio di lingua, tema (scuro/chiaro è già gestito da Theme.of sotto),
    // colore d'accento dell'app o intensità haptic NON invalida la cache e
    // NON forza un nuovo parsing del Markdown.
    final (fontFamily, fontSize, lineHeight) = ref.watch(
      settingsProvider.select((s) => (s.fontFamily, s.fontSize, s.lineHeight)),
    );

    final ingredientsStale = _cachedFormattedItems == null ||
        _cachedTitle != widget.title ||
        _cachedContent != widget.content ||
        _cachedFontFamily != fontFamily ||
        _cachedFontSize != fontSize ||
        _cachedLineHeight != lineHeight ||
        _cachedColorScheme != theme.colorScheme ||
        _cachedBrightness != theme.brightness;

    if (ingredientsStale) {
      _rebuildIngredients(
        context: context,
        theme: theme,
        fontFamily: fontFamily,
        fontSize: fontSize,
        lineHeight: lineHeight,
      );
    }

    return _buildListSubtree();
  }

  /// Ricalcola tutto ciò che dipende da contenuto/titolo/font/tema: lo
  /// splitting in blocchi, lo stylesheet e — punto chiave per le
  /// prestazioni — le ISTANZE di widget formattate di ciascun blocco,
  /// costruite una volta sola e poi riusate `identical` da `buildItem` finché
  /// quel blocco resta in modalità formattata (vedi doc di classe).
  ///
  /// Contenuto/titolo cambiati significa quasi sempre "nota diversa" (o nota
  /// modificata altrove): lo stato di selezione grezza precedente non ha più
  /// senso e viene azzerato, così come le cache che indicizzano i blocchi
  /// per posizione.
  void _rebuildIngredients({
    required BuildContext context,
    required ThemeData theme,
    required String fontFamily,
    required double fontSize,
    required double lineHeight,
  }) {
    final title = widget.title;
    final content = widget.content;
    final isDark = theme.brightness == Brightness.dark;

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

    // Markdown stylesheet tailored to Scripta aesthetics
    final markdownStyleSheet = MarkdownStyleSheet(
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
      code: inlineCodeStyle.copyWith(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.w500,
      ),
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
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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

    // Suddivisione in blocchi di primo livello: il testo è già interamente
    // in memoria e viene attraversato una sola volta qui (nessun
    // caricamento incrementale, nessuna paginazione) — serve solo a dare a
    // ListView.builder unità discrete da costruire/disegnare una alla
    // volta, invece dell'intero documento in un'unica Column non
    // virtualizzata (il vero collo di bottiglia per lo scroll su note
    // molto lunghe: senza virtualizzazione, Flutter deve layoutare e
    // dipingere anche i blocchi fuori schermo).
    //
    // IMPORTANTE: le liste puntate/numerate "tight" (senza righe vuote tra
    // un elemento e l'altro — il caso più comune e più pesante: una singola
    // lista lunga centinaia di righe) NON vengono spezzate dalle sole righe
    // vuote. Per questo ogni elemento di primo livello di una lista diventa
    // comunque un blocco a sé (vedi `_splitMarkdownIntoBlocks`), altrimenti
    // l'intera lista resterebbe un unico, enorme blocco e la
    // virtualizzazione non avrebbe alcun effetto.
    final effectiveContent = content.isEmpty ? '*Nessun contenuto*' : content;
    List<String> blocks;
    try {
      blocks = _splitMarkdownIntoBlocks(effectiveContent);
    } catch (_) {
      // Non lasciamo mai che un caso limite nello splitter (es. un
      // paste malformato) faccia fallire la build dell'intera vista: nel
      // peggiore dei casi questa nota perde la virtualizzazione per questa
      // build (torna a un unico blocco, come prima dell'ottimizzazione),
      // ma il contenuto resta sempre visibile e non "sparisce" mai.
      blocks = [effectiveContent];
    }
    final blockIsListItem =
        blocks.map(_isTopLevelListMarkerBlock).toList(growable: false);
    final hasTitle = title.trim().isNotEmpty;

    // Spaziatura tra un blocco e il successivo: tra due elementi della
    // STESSA lista usiamo un gap minimo (come tra due righe consecutive di
    // una lista tight renderizzata in un unico blocco); altrove usiamo lo
    // spacing "ufficiale" dello stylesheet tra blocchi di tipo diverso
    // (paragrafi, heading, code block...). Calcolato una sola volta qui e
    // tenuto in cache: serve identico sia quando il blocco è formattato sia
    // quando passa temporaneamente a raw.
    double gapAfterBlock(int blockIndex) {
      if (blockIndex >= blocks.length - 1) return 0;
      if (blockIsListItem[blockIndex] && blockIsListItem[blockIndex + 1]) {
        return 2.0;
      }
      return markdownStyleSheet.blockSpacing ?? 16.0;
    }

    // NB: un `Center` da solo NON basta — se il blocco (es. un singolo
    // elemento di lista breve) è più stretto della viewport, si
    // restringerebbe al contenuto e verrebbe centrato invece di allargarsi
    // fino a `maxWidth`, con l'effetto di indentazione "casuale" osservato
    // (elementi brevi spostati verso il centro, quelli lunghi no). Lo
    // `SizedBox(width: double.infinity)` forza il figlio a occupare sempre
    // tutta la larghezza disponibile fino a `maxWidth`, replicando lo
    // stretch che prima veniva dato dalla `Column` con
    // `crossAxisAlignment: CrossAxisAlignment.stretch`.
    Widget wrapCentered(Widget child) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: SizedBox(width: double.infinity, child: child),
          ),
        );

    // Testo grezzo: stesso font di base e stessa altezza riga del testo
    // reso (per minimizzare — non azzerare, è impossibile dato che il
    // markdown grezzo ha più/meno caratteri — la differenza di altezza tra
    // le due modalità), ma monospaziato e leggermente attenuato: comunica
    // visivamente "stai selezionando la sorgente", coerente con l'estetica
    // già usata per i code block.
    final rawTextStyle = GoogleFonts.jetBrainsMono(
      fontSize: fontSize * 0.95,
      height: lineHeight,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.87),
    );

    // Istanze formattate: costruite una sola volta per blocco. `buildItem`
    // (in `_buildListSubtree`) le restituirà `identical` finché il blocco
    // resta in modalità formattata, cioè quasi sempre — Flutter salta quindi
    // interamente rebuild/relayout/riparsing di `MarkdownBody` per i blocchi
    // non coinvolti da una selezione in corso.
    final formattedItems = <Widget>[
      for (var blockIndex = 0; blockIndex < blocks.length; blockIndex++)
        KeyedSubtree(
          key: _blockKeys.putIfAbsent(blockIndex, () => GlobalKey()),
          child: wrapCentered(
            Padding(
              padding: EdgeInsets.only(bottom: gapAfterBlock(blockIndex)),
              child: MarkdownBody(
                data: blocks[blockIndex],
                selectable: false, // Gestita dal SelectionArea del genitore
                styleSheet: markdownStyleSheet,
                builders: {
                  'pre': _CodeBlockBuilder(fontSize: fontSize),
                  'code': _InlineCodeBuilder(
                    style: inlineCodeStyle,
                    isDark: isDark,
                    primaryColor: theme.colorScheme.primary,
                  ),
                },
                onTapLink: (text, href, title) async {
                  if (href != null) {
                    final uri = Uri.tryParse(href);
                    if (uri != null && await canLaunchUrl(uri)) {
                      await launchUrl(uri);
                    }
                  }
                },
              ),
            ),
          ),
        ),
    ];

    final titleWidget = hasTitle
        ? wrapCentered(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: AppTheme.getTextStyleForFont(
                    fontFamily,
                    fontSize: fontSize * 2.2,
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.onSurface,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 16),
                Divider(
                  color: theme.colorScheme.outline.withValues(alpha: 0.3),
                  thickness: 1,
                ),
                const SizedBox(height: 20),
              ],
            ),
          )
        : const SizedBox.shrink();

    // I blocchi sono cambiati: qualunque indice raw precedente non
    // corrisponde più necessariamente allo stesso contenuto — così come le
    // cache che indicizzano per posizione. Le puliamo tutte insieme.
    _rawBlockIndices = const {};
    _cachedRawItems.clear();
    _renderedPlainTextCache.clear();
    _blockKeys.removeWhere((index, _) => index >= blocks.length);

    _cachedBlocks = blocks;
    _cachedBlockIsListItem = blockIsListItem;
    _cachedFormattedItems = formattedItems;
    _cachedTitleWidget = titleWidget;
    _cachedHasTitle = hasTitle;
    _cachedRawTextStyle = rawTextStyle;
    _cachedTitle = title;
    _cachedContent = content;
    _cachedFontFamily = fontFamily;
    _cachedFontSize = fontSize;
    _cachedLineHeight = lineHeight;
    _cachedColorScheme = theme.colorScheme;
    _cachedBrightness = theme.brightness;
  }

  /// Versione "raw" (markdown grezzo, testo piatto) di un blocco, costruita
  /// pigramente e tenuta in cache: passare avanti e indietro più volte tra
  /// formattato e grezzo durante lo stesso drag di selezione non ricrea il
  /// widget ogni volta.
  Widget _rawItemFor(int blockIndex, {required Widget Function(Widget) wrapCentered}) {
    return _cachedRawItems.putIfAbsent(blockIndex, () {
      final gap = blockIndex >= (_cachedBlocks!.length - 1)
          ? 0.0
          : (_cachedBlockIsListItem![blockIndex] &&
                  _cachedBlockIsListItem![blockIndex + 1]
              ? 2.0
              : 16.0);
      return KeyedSubtree(
        key: _blockKeys.putIfAbsent(blockIndex, () => GlobalKey()),
        child: wrapCentered(
          Container(
            width: double.infinity,
            margin: EdgeInsets.only(bottom: gap),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: _cachedColorScheme!.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(_cachedBlocks![blockIndex], style: _cachedRawTextStyle),
          ),
        ),
      );
    });
  }

  /// Assembla il sottoalbero finale a partire dagli "ingredienti" già in
  /// cache (blocchi formattati, blocco titolo) e dallo stato di selezione
  /// corrente. È l'unica parte ricostruita quando cambia SOLO
  /// `_rawBlockIndices`: nessun reparse Markdown, nessuna ricostruzione
  /// dello stylesheet, e i blocchi non coinvolti vengono restituiti come
  /// istanze `identical` a quelle già disegnate (vedi doc di classe).
  Widget _buildListSubtree() {
    final blocks = _cachedBlocks!;
    final formattedItems = _cachedFormattedItems!;
    final hasTitle = _cachedHasTitle;
    final itemCount = (hasTitle ? 1 : 0) + blocks.length;

    Widget wrapCentered(Widget child) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: SizedBox(width: double.infinity, child: child),
          ),
        );

    Widget buildItem(BuildContext context, int index) {
      if (hasTitle && index == 0) {
        return _cachedTitleWidget!;
      }
      final blockIndex = hasTitle ? index - 1 : index;
      if (_rawBlockIndices.contains(blockIndex)) {
        return _rawItemFor(blockIndex, wrapCentered: wrapCentered);
      }
      return formattedItems[blockIndex];
    }

    // RepaintBoundary: isola il layer grafico della nota renderizzata da
    // quello del resto dell'interfaccia (toolbar, cursore, animazioni di
    // focus mode, ecc.), così un repaint "vicino" non forza mai Flutter a
    // ridisegnare anche questi pixel. `ListView.builder` aggiunge inoltre
    // automaticamente un `RepaintBoundary` per ciascun blocco costruito
    // (`addRepaintBoundaries`, attivo di default): lo scroll di una nota
    // enorme non richiede quindi mai di ridisegnare un unico layer gigante,
    // ma solo di ricompositare i pochi layer già rasterizzati dei blocchi
    // realmente visibili.
    return RepaintBoundary(
      child: SelectionArea(
        onSelectionChanged: _handleSelectionChanged,
        contextMenuBuilder: (context, selectableRegionState) {
          final items = selectableRegionState.contextMenuButtonItems
              .map((item) {
            if (item.type != ContextMenuButtonType.copy) return item;
            final originalOnPressed = item.onPressed;
            return item.copyWith(
              onPressed: () {
                // Esegue prima la copia originale (clipboard invariato),
                // poi riporta i blocchi coinvolti a Markdown formattato:
                // "fine della selezione" per copia esplicita, come da spec.
                originalOnPressed?.call();
                _revertAllRawBlocks();
              },
            );
          }).toList(growable: false);
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: selectableRegionState.contextMenuAnchors,
            buttonItems: items,
          );
        },
        child: ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
          itemCount: itemCount,
          itemBuilder: buildItem,
        ),
      ),
    );
  }
}

/// Suddivide una stringa Markdown in blocchi indipendenti da usare come
/// elementi di `ListView.builder`, preservando i casi che una divisione
/// ingenua per riga vuota romperebbe:
///  - i fenced code block (``` o ~~~) NON vengono mai spezzati internamente,
///    anche se contengono righe vuote al loro interno;
///  - le blockquote "loose" (separate da singole righe vuote) restano nello
///    stesso blocco.
///
/// Le liste puntate/numerate meritano un trattamento a parte: nel caso
/// d'uso più comune e più pesante per lo scroll (una lista "tight" lunga
/// centinaia di righe, SENZA alcuna riga vuota tra un elemento e l'altro —
/// es. una watchlist), dividere solo sulle righe vuote lascerebbe l'intera
/// lista come un unico, enorme blocco e la virtualizzazione non avrebbe
/// alcun effetto. Per questo ogni elemento di primo livello di una lista
/// (riga che inizia con `- `, `* `, `+ ` o `1. ` a colonna 0, quindi MAI
/// una riga rientrata: quelle restano correttamente unite come contenuto
/// annidato dell'elemento genitore) diventa comunque un blocco a sé,
/// indipendentemente dalla presenza di righe vuote.
///
/// Non introduce alcun caricamento incrementale né paginazione: il testo è
/// già interamente disponibile in memoria e viene scandito linearmente una
/// sola volta; il risultato serve solo a dare a `ListView.builder` unità
/// discrete su cui applicare la virtualizzazione del rendering.
final RegExp _topLevelListMarkerRe = RegExp(r'^(-|\*|\+)\s|^\d+[.)]\s');
final RegExp _fenceOpenRe = RegExp(r'^\s{0,3}(`{3,}|~{3,})');

bool _isTopLevelListMarkerLine(String line) =>
    _topLevelListMarkerRe.hasMatch(line);

/// Vero se il blocco (già suddiviso) è un elemento di lista di primo
/// livello, usato per decidere lo spacing minimo tra elementi consecutivi
/// della stessa lista in `gapAfterBlock`.
bool _isTopLevelListMarkerBlock(String block) {
  final firstLine = block.split('\n').first;
  return _isTopLevelListMarkerLine(firstLine);
}

List<String> _splitMarkdownIntoBlocks(String content) {
  final lines = content.split('\n');
  final blocks = <String>[];
  final buffer = <String>[];

  String? fenceMarker;

  bool isQuoteLine(String line) => line.trimLeft().startsWith('> ');

  bool bufferEndsInQuote() {
    for (var k = buffer.length - 1; k >= 0; k--) {
      if (buffer[k].trim().isEmpty) continue;
      return isQuoteLine(buffer[k]);
    }
    return false;
  }

  bool nextNonBlankContinuesQuote(int fromIndex) {
    for (var k = fromIndex; k < lines.length; k++) {
      if (lines[k].trim().isEmpty) continue;
      return isQuoteLine(lines[k]);
    }
    return false;
  }

  void flushBuffer() {
    if (buffer.isEmpty) return;
    final text = buffer.join('\n').trimRight();
    if (text.trim().isNotEmpty) blocks.add(text);
    buffer.clear();
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];

    if (fenceMarker != null) {
      buffer.add(line);
      if (line.trimLeft().startsWith(fenceMarker)) {
        fenceMarker = null;
      }
      i++;
      continue;
    }

    final fenceMatch = _fenceOpenRe.firstMatch(line);
    if (fenceMatch != null) {
      // Non spezzare mai l'INTERNO di un fenced code block (anche se
      // contiene righe vuote): resta unito al blocco corrente finché non
      // incontra la riga di chiusura.
      fenceMarker = fenceMatch.group(1);
      buffer.add(line);
      i++;
      continue;
    }

    if (_isTopLevelListMarkerLine(line)) {
      // Ogni elemento di lista di primo livello è sempre un blocco a sé,
      // riga vuota o meno prima di esso: chiude qualunque cosa precedesse
      // (paragrafo, elemento di lista precedente...) e ne apre uno nuovo.
      flushBuffer();
      buffer.add(line);
      i++;
      continue;
    }

    if (line.trim().isEmpty) {
      if (buffer.isNotEmpty) {
        if (bufferEndsInQuote() && nextNonBlankContinuesQuote(i + 1)) {
          // Riga vuota "interna" a una blockquote loose: resta nel blocco
          // corrente per non spezzarne l'aspetto in più widget separati.
          buffer.add(line);
        } else {
          flushBuffer();
        }
      }
      i++;
      continue;
    }

    // Riga di continuazione: testo di un paragrafo, oppure contenuto
    // annidato/rientrato di un elemento di lista già aperto sopra.
    buffer.add(line);
    i++;
  }
  flushBuffer();

  return blocks.isEmpty ? [content] : blocks;
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  final double fontSize;

  _CodeBlockBuilder({required this.fontSize});

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    String language = '';
    String code = element.textContent;

    // Detect language identifier if present
    if (element.children != null && element.children!.isNotEmpty) {
      final child = element.children!.first;
      if (child is md.Element && child.attributes.containsKey('class')) {
        final classAttr = child.attributes['class'] ?? '';
        if (classAttr.startsWith('language-')) {
          language = classAttr.replaceFirst('language-', '').trim();
        }
      }
    }

    if (code.endsWith('\n')) {
      code = code.substring(0, code.length - 1);
    }

    return CodeBlockWidget(
      code: code,
      language: language,
      fontSize: fontSize,
    );
  }
}

class _InlineCodeBuilder extends MarkdownElementBuilder {
  final TextStyle style;
  final bool isDark;
  final Color primaryColor;

  _InlineCodeBuilder({
    required this.style,
    required this.isDark,
    required this.primaryColor,
  });

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: primaryColor.withValues(alpha: isDark ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: primaryColor.withValues(alpha: isDark ? 0.28 : 0.2),
          width: 0.8,
        ),
      ),
      child: Text(
        element.textContent,
        style: style,
      ),
    );
  }
}

class CodeBlockWidget extends StatefulWidget {
  final String code;
  final String language;
  final double fontSize;

  const CodeBlockWidget({
    super.key,
    required this.code,
    required this.language,
    required this.fontSize,
  });

  @override
  State<CodeBlockWidget> createState() => _CodeBlockWidgetState();
}

class _CodeBlockWidgetState extends State<CodeBlockWidget> {
  bool _copied = false;
  Timer? _copyTimer;

  // Evidenziazione sintattica memorizzata e ricalcolata SOLO quando cambiano
  // davvero codice/linguaggio/tema (didUpdateWidget), non ad ogni build: il
  // toggle di `_copied` (pulsante "copia") altrimenti causerebbe una
  // retokenizzazione completa del blocco di codice solo per aggiornare
  // un'icona di spunta.
  TextSpan? _highlightedTextCache;
  bool? _highlightedForIsDark;

  TextSpan _highlightedText(bool isDark, TextStyle monoStyle) {
    if (_highlightedTextCache != null && _highlightedForIsDark == isDark) {
      return _highlightedTextCache!;
    }
    final span = ScriptaCodeHighlighter.highlight(
      code: widget.code,
      language: widget.language,
      isDark: isDark,
      baseStyle: monoStyle,
    );
    _highlightedTextCache = span;
    _highlightedForIsDark = isDark;
    return span;
  }

  @override
  void didUpdateWidget(covariant CodeBlockWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code ||
        oldWidget.language != widget.language ||
        oldWidget.fontSize != widget.fontSize) {
      // Invalida la cache: verrà ricalcolata pigramente al prossimo build.
      _highlightedTextCache = null;
      _highlightedForIsDark = null;
    }
  }

  @override
  void dispose() {
    _copyTimer?.cancel();
    super.dispose();
  }

  void _copyToClipboard() {
    Clipboard.setData(ClipboardData(text: widget.code));
    setState(() {
      _copied = true;
    });

    _copyTimer?.cancel();
    _copyTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _copied = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final blockBackground = isDark
        ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
        : const Color(0xFFF1F5F9);

    final displayLang = widget.language.trim().isNotEmpty
        ? widget.language.trim().toLowerCase()
        : null;

    final monoStyle = GoogleFonts.jetBrainsMono(
      fontSize: widget.fontSize * 0.9,
      height: 1.55,
      color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
    );

    final highlightedText = _highlightedText(isDark, monoStyle);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          color: blockBackground,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.25),
            width: 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // Code text with horizontal scrolling
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 75, 14),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text.rich(
                  highlightedText,
                ),
              ),
            ),

            // Discreet floating language & copy pill in top-right corner
            Positioned(
              top: 8,
              right: 8,
              child: SelectionContainer.disabled(
                child: Container(
                  decoration: BoxDecoration(
                    color: isDark
                        ? theme.colorScheme.surface.withValues(alpha: 0.85)
                        : Colors.white.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: theme.colorScheme.outline.withValues(alpha: 0.2),
                      width: 0.8,
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (displayLang != null) ...[
                        Text(
                          displayLang,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Container(
                          width: 1,
                          height: 10,
                          color: theme.colorScheme.outline.withValues(alpha: 0.3),
                        ),
                        const SizedBox(width: 5),
                      ],
                      InkWell(
                        onTap: _copyToClipboard,
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _copied
                                    ? Icons.check_rounded
                                    : Icons.content_copy_rounded,
                                size: 12,
                                color: _copied
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                              if (_copied) ...[
                                const SizedBox(width: 4),
                                Text(
                                  l10n.codeCopied,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
