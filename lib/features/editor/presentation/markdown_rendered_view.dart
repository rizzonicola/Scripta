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
/// riporta il contenuto testuale non appena una selezione diventa attiva
/// (tap-and-hold o doppio tap, sia touch che desktop) — anche quando quel
/// contenuto è composto SOLO da whitespace (uno spazio tra due parole, una
/// riga vuota): vedi `_handleSelectionChanged` per il perché è
/// deliberatamente `content.plainText.isNotEmpty`, non `.trim().isNotEmpty`.
/// È il segnale stesso di "gesture di selezione iniziata" richiesto dalla
/// spec, semplicemente osservato dal livello giusto invece che da un
/// `Listener`/`GestureDetector` grezzo che dovrebbe poi reimplementare la
/// logica di long-press/doppio tap già presente (e testata) dentro
/// `SelectionArea`. Il testo selezionato viene confrontato (via cache) con
/// il testo "reso" di ciascun blocco per capire quale blocco coinvolge, e
/// SOLO quello passa a raw.
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
  List<Widget>? _cachedRawItems;
  final Map<String, String> _renderedPlainTextCache = {};

  /// Unico interruttore di modalità: quando è `true` TUTTO il documento (ogni
  /// blocco, non solo quello toccato) viene mostrato come markdown grezzo,
  /// non formattato — visivamente simile a "modalità modifica", ma senza che
  /// diventi mai editabile: resta un `Text` semplice dentro un
  /// `SelectionArea` di sola lettura, mai un campo di input. Attivato/
  /// disattivato in blocco da `_handleSelectionChanged`.
  bool _isRawMode = false;

  /// Debounce per il ritorno a Markdown formattato (vedi
  /// `_handleSelectionChanged`): entrare in modalità grezza sostituisce il
  /// widget selezionato (da `MarkdownBody` a `Text`), il che DISTRUGGE il
  /// `Selectable` a cui la selezione nativa era agganciata. Se l'utente
  /// solleva il dito subito dopo un tap-and-hold, senza trascinare, non c'è
  /// alcun evento successivo che "riattacchi" la selezione al nuovo testo
  /// grezzo: la selezione risulta quindi momentaneamente vuota per un
  /// motivo puramente interno (lo scambio di widget appena fatto), non
  /// perché l'utente abbia davvero deselezionato. Reagire a QUELL'istante
  /// tornando subito a formattato produce il doppio scatto/artefatto visivo
  /// osservato (evidenziazione che resta "appesa" sul testo formattato). Un
  /// semplice debounce da solo non basta ad assorbirlo del tutto (vedi
  /// `_rawModeEnteredAt`): serve anche IGNORARE del tutto quel primo
  /// azzeramento, non solo rimandarlo.
  Timer? _pendingRevertTimer;

  /// Istante in cui siamo entrati in modalità grezza l'ultima volta. Per una
  /// brevissima finestra dopo questo istante (vedi `_recentlyEnteredRawMode`
  /// in `_handleSelectionChanged`), un azzeramento della selezione viene
  /// considerato quasi certamente un artefatto del nostro stesso scambio di
  /// widget (la distruzione del `Selectable` di cui sopra) e viene IGNORATO
  /// del tutto — non solo rimandato con un debounce: anche un debounce
  /// brevissimo, come si è visto, può comunque lasciare per un istante
  /// un'evidenziazione "orfana" sopra al testo già tornato formattato.
  /// Ignorare del tutto quel primo evento mantiene l'app nello stato
  /// coerente — grezzo, con la selezione visibile — finché non arriva un
  /// segnale di deselezione inequivocabile (un tap altrove dopo che questa
  /// finestra è trascorsa).
  DateTime? _rawModeEnteredAt;

  @override
  void dispose() {
    // Rilascia esplicitamente i riferimenti pesanti (testo della nota e
    // sottoalbero renderizzato) non appena la vista viene smontata, così non
    // restano agganciati più a lungo del necessario in attesa della GC.
    _pendingRevertTimer?.cancel();
    _cachedFormattedItems = null;
    _cachedRawItems = null;
    _cachedTitleWidget = null;
    _cachedContent = null;
    _blockKeys.clear();
    _renderedPlainTextCache.clear();
    _scrollController.dispose();
    super.dispose();
  }

  /// Testo "reso" approssimato di un blocco: il testo visibile dopo che il
  /// markdown è stato interpretato (es. `**bold**` → `bold`, `# Titolo` →
  /// `Titolo`), usato SOLO per individuare in quale blocco si trova il testo
  /// che `SelectionArea.onSelectionChanged` riporta come selezionato — serve
  /// a scegliere un buon "ancoraggio" per lo scroll (vedi
  /// `_swapPreservingScrollAnchor`), non a decidere quali blocchi mostrare
  /// grezzi: quello ora è un tutto-o-niente sull'intero documento. Calcolato
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
        // — nel peggiore dei casi l'ancoraggio sarà un po' meno preciso, ma
        // non blocca mai la funzionalità né fa fallire la build.
        return block;
      }
    });
  }

  /// Individua l'indice del blocco il cui testo reso contiene (o è
  /// contenuto in) il testo attualmente selezionato: usato per ancorare lo
  /// scroll esattamente sul punto che l'utente sta selezionando quando si
  /// entra in modalità grezza. `null` se nessun blocco corrisponde (es. la
  /// selezione attraversa un confine imprevisto) — in quel caso si ricade
  /// sull'ancoraggio generico basato sul blocco più in alto visibile.
  ///
  /// DISAMBIGUAZIONE PER PROSSIMITÀ (fix del disallineamento verticale
  /// osservato in rari casi): il confronto è puramente testuale, quindi
  /// PIÙ blocchi possono corrispondere allo stesso testo selezionato — due
  /// voci di lista che iniziano con la stessa parola, un titolo ripetuto,
  /// una frase breve comune. La versione precedente restituiva semplicemente
  /// il PRIMO blocco trovato scorrendo il documento dall'inizio: se quel
  /// primo match "testualmente compatibile" era un blocco ADIACENTE a
  /// quello realmente selezionato (tipicamente la riga subito sopra o
  /// subito sotto, essendo il caso più probabile di testo duplicato), la
  /// compensazione di scroll in `_swapPreservingScrollAnchor` veniva
  /// calcolata sulla geometria del blocco SBAGLIATO — da qui lo scarto di
  /// circa un'altezza di riga riportato. Il calcolo delle altezze/padding in
  /// sé è corretto (misurato via `RenderBox` reali, non stimato): il difetto
  /// era a monte, nella scelta di QUALE blocco misurare.
  ///
  /// La correzione: tra tutti i blocchi testualmente compatibili, si sceglie
  /// quello più vicino (per indice) al blocco attualmente in cima alla
  /// viewport (`_topVisibleBlockIndex`) — un riferimento geometrico reale,
  /// già disponibile, che rappresenta dove l'utente sta effettivamente
  /// guardando un istante prima dello swap. Un match esatto (l'intero
  /// blocco coincide col testo selezionato) resta comunque prioritario e
  /// univoco, senza bisogno di disambiguazione.
  int? _blockIndexContainingSelection(String selectedPlainText) {
    final blocks = _cachedBlocks;
    final normalizedSelected = selectedPlainText.trim();
    if (blocks == null || normalizedSelected.isEmpty) return null;

    // Riferimento di prossimità: il blocco più vicino al bordo superiore
    // della viewport nell'istante immediatamente precedente allo swap.
    final proximityIndex = _topVisibleBlockIndex();

    int? bestIndex;
    int bestDistance = 1 << 30;
    void consider(int index) {
      final distance =
          proximityIndex == null ? 0 : (index - proximityIndex).abs();
      if (bestIndex == null || distance < bestDistance) {
        bestIndex = index;
        bestDistance = distance;
      }
    }

    // 1) Match esatto: il blocco intero coincide col testo selezionato.
    //    Inequivocabile per costruzione, nessuna disambiguazione necessaria.
    for (var i = 0; i < blocks.length; i++) {
      if (_renderedPlainTextFor(blocks[i]).trim() == normalizedSelected) {
        return i;
      }
    }

    // 2) Match per contenimento: si raccolgono TUTTI i blocchi compatibili
    //    (non ci si ferma al primo) e si sceglie quello geometricamente più
    //    vicino a dove l'utente si trovava.
    for (var i = 0; i < blocks.length; i++) {
      final normalizedBlock = _renderedPlainTextFor(blocks[i]).trim();
      if (normalizedBlock.isEmpty) continue;
      if (normalizedBlock.contains(normalizedSelected) ||
          normalizedSelected.contains(normalizedBlock)) {
        consider(i);
      }
    }
    if (bestIndex != null) return bestIndex;

    // 3) Fallback sulla sola prima riga non vuota (selezione su più
    //    blocchi): stessa logica di disambiguazione per prossimità.
    final firstLine = normalizedSelected
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (firstLine.isEmpty) return null;
    for (var i = 0; i < blocks.length; i++) {
      if (_renderedPlainTextFor(blocks[i]).contains(firstLine)) {
        consider(i);
      }
    }
    return bestIndex;
  }

  /// Blocco attualmente più vicino al bordo superiore della vista:
  /// ancoraggio generico usato quando non è disponibile un testo di
  /// selezione da cui risalire al blocco esatto (tipicamente: ritorno a
  /// Markdown formattato dopo che la selezione è già stata azzerata).
  /// Basato su geometria realmente disposta (RenderBox), non su una stima.
  ///
  /// Usa `context` (quello di questo State, cioè della radice del
  /// sottoalbero costruito da `build()`) come riferimento invece della
  /// chiave del `ListView`: è l'unico riferimento stabile e presente in
  /// ENTRAMBE le modalità di rendering (`ListView.builder` virtualizzato in
  /// formattato, `SingleChildScrollView` non virtualizzato in grezzo — vedi
  /// `_buildListSubtree`), quindi funziona correttamente sia quando si
  /// entra sia quando si esce dalla modalità grezza.
  int? _topVisibleBlockIndex() {
    final viewportBox = context.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.attached) return null;
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;

    int? bestIndex;
    double bestDistance = double.infinity;
    _blockKeys.forEach((index, key) {
      final box = key.currentContext?.findRenderObject();
      if (box is RenderBox && box.attached) {
        final distance =
            (box.localToGlobal(Offset.zero).dy - viewportTop).abs();
        if (distance < bestDistance) {
          bestDistance = distance;
          bestIndex = index;
        }
      }
    });
    return bestIndex;
  }

  /// Callback di `SelectionArea.onSelectionChanged`: unico punto da cui la
  /// "gesture di selezione" viene osservata (vedi doc di classe). Non appena
  /// una selezione diventa non vuota, TUTTO il documento passa a markdown
  /// grezzo; non appena torna vuota (tap altrove / selezione azzerata),
  /// TUTTO torna formattato — con le cautele descritte nella doc di
  /// `_rawModeEnteredAt` e `_pendingRevertTimer`. Aggiorna anche l'aptica
  /// tramite lo stesso canale già usato dall'editor
  /// (`HapticsHelper.reportSelectionState`), così un tap-and-hold in
  /// sola-lettura si comporta in modo coerente con quello nel campo di
  /// modifica, invece di introdurre una logica aptica parallela.
  ///
  /// IMPORTANTE: `hasSelection` NON usa `.trim()` sul testo selezionato.
  /// Un `SelectedContent` che contiene SOLO spazi/ritorni a capo (es. un
  /// doppio-tap che atterra esattamente su uno spazio tra due parole, o un
  /// drag che parte da un margine/riga vuota) è comunque una selezione
  /// attiva agli occhi di `SelectionArea`: se la trattassimo come "nessuna
  /// selezione" (con `.trim().isNotEmpty`, come nella versione precedente),
  /// quel primo tratto di gesture continuerebbe a operare sul substrato
  /// FORMATTATO — quello con un `Selectable` indipendente per elemento,
  /// vedi doc di classe — invece di passare subito al `Text` piatto per
  /// blocco. È esattamente la causa della selezione che "non si aggancia"
  /// quando tap/drag intercetta whitespace: non è che lo swap arrivi
  /// tardi, è che la condizione per farlo scattare non veniva mai
  /// soddisfatta finché la selezione non copriva anche un carattere non di
  /// spaziatura.
  void _handleSelectionChanged(SelectedContent? content) {
    final hasSelection = content != null && content.plainText.isNotEmpty;
    HapticsHelper.reportSelectionState(isCollapsed: !hasSelection);

    if (hasSelection) {
      // Una selezione (ri)compare: un eventuale ritorno a formattato in
      // attesa a causa di un azzeramento solo momentaneo non ha più motivo
      // di scattare.
      _pendingRevertTimer?.cancel();
      _pendingRevertTimer = null;

      if (_isRawMode) return; // già in modalità grezza

      final anchorIndex = _blockIndexContainingSelection(content.plainText) ??
          _topVisibleBlockIndex();
      _swapPreservingScrollAnchor(
        anchorBlockIndex: anchorIndex,
        applyChange: () => setState(() => _isRawMode = true),
      );
      _rawModeEnteredAt = DateTime.now();
      return;
    }

    if (!_isRawMode) return; // già formattato, nessuna azione

    // Vedi la doc di `_rawModeEnteredAt`: se siamo appena entrati in
    // modalità grezza, il PRIMO azzeramento della selezione è quasi
    // certamente un artefatto del nostro stesso scambio di widget (la
    // distruzione del `Selectable` a cui la selezione era agganciata), non
    // una vera deselezione da parte dell'utente — tipicamente un
    // tap-and-hold seguito da un rilascio immediato, senza trascinamento.
    // Lo ignoriamo del tutto (niente debounce, niente timer): l'app resta
    // in modalità grezza, con la selezione ancora visibile e funzionante,
    // esattamente come farebbe una qualunque selezione di testo nativa.
    final enteredAt = _rawModeEnteredAt;
    if (enteredAt != null &&
        DateTime.now().difference(enteredAt) < const Duration(milliseconds: 400)) {
      return;
    }

    // Passata la finestra di grazia, un azzeramento è un segnale
    // sufficientemente affidabile (tap altrove, o la selezione che si è
    // davvero conclusa) — ma applichiamo comunque un brevissimo debounce
    // prima di agire, per assorbire eventuali ulteriori sfarfallii isolati
    // senza introdurre un ritardo percepibile per una deselezione vera.
    _pendingRevertTimer?.cancel();
    _pendingRevertTimer = Timer(const Duration(milliseconds: 160), () {
      _pendingRevertTimer = null;
      if (!mounted) return;
      _revertToFormatted();
    });
  }

  /// Riporta l'intero documento a Markdown formattato. Usata sia
  /// (con debounce) quando la selezione si azzera, sia esplicitamente e
  /// SENZA debounce dopo "Copia" dal menu contestuale (vedi
  /// `_buildListSubtree`): lì l'intento dell'utente è inequivocabile, non
  /// c'è motivo di attendere.
  void _revertToFormatted() {
    _pendingRevertTimer?.cancel();
    _pendingRevertTimer = null;
    _rawModeEnteredAt = null;
    if (!_isRawMode) return;
    _swapPreservingScrollAnchor(
      anchorBlockIndex: _topVisibleBlockIndex(),
      applyChange: () => setState(() => _isRawMode = false),
    );
  }

  /// Misura la posizione verticale REALE (non stimata) del blocco-ancora
  /// prima di applicare `applyChange`, e la rimisura a frame concluso,
  /// compensando lo `ScrollController` della differenza esatta così che il
  /// punto guardato dall'utente non "salti" quando ogni blocco cambia
  /// altezza passando in blocco da formattato a grezzo (o viceversa). Non è
  /// una stima "N px per riga": è una differenza tra due geometrie reali già
  /// disposte da Flutter, prima e dopo lo swap.
  ///
  /// C'è però un problema PRIMA ancora di poter misurare "dopo": lo swap tra
  /// `ListView.builder` (formattato) e `SingleChildScrollView` (grezzo, vedi
  /// `_buildListSubtree`) sostituisce l'intero widget scrollabile, non solo
  /// il suo contenuto. Flutter crea quindi una `ScrollPosition`
  /// COMPLETAMENTE NUOVA per il nuovo widget, che riparte da offset zero —
  /// perde cioè il punto di scroll precedente, anche se `_scrollController`
  /// è lo stesso oggetto Dart. Nel ramo FORMATTATO questo è particolarmente
  /// dannoso perché è virtualizzato: a offset zero, `ListView.builder`
  /// costruisce solo i blocchi vicini all'inizio della nota, quindi il
  /// blocco-ancora (magari a metà nota) semplicemente NON ESISTE ancora nel
  /// nuovo albero — la misurazione "dopo" fallisce silenziosamente, nessuna
  /// correzione scatta, e si resta bloccati in cima alla nota.
  ///
  /// Per questo, prima di rifinire con la misurazione esatta, ripristiniamo
  /// subito l'offset grezzo (lo stesso valore numerico di prima, applicato
  /// al nuovo `ScrollPosition`): non è preciso al pixel — l'altezza totale
  /// stimata da `ListView.builder` per i blocchi non ancora costruiti può
  /// differire leggermente da quella reale — ma è sufficiente a far
  /// costruire il blocco-ancora nella finestra di cache della lista
  /// virtualizzata, rendendo possibile la rifinitura esatta subito dopo.
  void _swapPreservingScrollAnchor({
    required int? anchorBlockIndex,
    required VoidCallback applyChange,
  }) {
    double? beforeTop;
    if (anchorBlockIndex != null) {
      final beforeBox =
          _blockKeys[anchorBlockIndex]?.currentContext?.findRenderObject();
      if (beforeBox is RenderBox && beforeBox.attached) {
        beforeTop = beforeBox.localToGlobal(Offset.zero).dy;
      }
    }
    final previousOffset =
        _scrollController.hasClients ? _scrollController.offset : null;

    applyChange();

    if (anchorBlockIndex == null) return;

    // Frame 1: il nuovo widget scrollabile è stato costruito (a offset
    // zero, per quanto appena spiegato). Ripristiniamo subito l'offset
    // precedente, grezzo ma sufficiente a portare il blocco-ancora nella
    // finestra di cache — così al frame successivo esisterà davvero da
    // misurare.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;

      if (previousOffset != null && previousOffset > 0) {
        final position = _scrollController.position;
        final coarseTarget = previousOffset.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        _scrollController.jumpTo(coarseTarget);
      }

      // Frame 2: con il blocco-ancora ora presumibilmente costruito (grazie
      // al ripristino grezzo appena fatto), lo rimisuriamo e applichiamo la
      // correzione ESATTA, pixel per pixel, rispetto alla posizione
      // originale catturata prima dello swap.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients || beforeTop == null) {
          return;
        }
        final afterBox =
            _blockKeys[anchorBlockIndex]?.currentContext?.findRenderObject();
        if (afterBox is! RenderBox || !afterBox.attached) return;

        final afterTop = afterBox.localToGlobal(Offset.zero).dy;
        final delta = afterTop - beforeTop!;
        if (delta.abs() < 0.5) return;

        final position = _scrollController.position;
        final target = (_scrollController.offset + delta)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
        _scrollController.jumpTo(target);
      });
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
          child: _FadeInOnMount(
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
        ),
    ];

    // Versione grezza (markdown non interpretato) dello STESSO elenco di
    // blocchi, con lo stesso wrapping/gap dei blocchi formattati in modo che
    // il layout resti il più possibile comparabile. Costruita eagerly qui
    // (non pigramente): a differenza di `MarkdownBody`, un `Text` semplice
    // non fa alcun parsing, quindi costruire tutta la lista in anticipo è
    // economico e permette lo swap istantaneo dell'intero documento al primo
    // frame utile, senza un "flash" del primo blocco mentre gli altri
    // vengono ancora costruiti pigramente al primo giro di `itemBuilder`.
    // Ogni blocco grezzo nel proprio `RepaintBoundary`. Non è un dettaglio
    // estetico: è la differenza tra le buone prestazioni della modalità
    // formattata e il calo di FPS osservato in quella grezza.
    // `ListView.builder` avvolge automaticamente ogni suo elemento in un
    // `RepaintBoundary` (`addRepaintBoundaries: true` di default): ogni
    // blocco diventa un layer di compositing indipendente, già rasterizzato,
    // e scorrere significa solo ricomporre layer esistenti — mai ridisegnare
    // i comandi di disegno del testo. `SingleChildScrollView` + `Column`
    // (necessari qui per evitare la virtualizzazione, vedi doc di
    // `_buildListSubtree`) NON lo fanno: senza questo confine esplicito,
    // l'intera colonna condivide un solo layer, e ogni frame di scroll può
    // dover ri-registrare da capo i comandi di disegno per l'INTERO
    // documento invece che solo per il rettangolo visibile — da qui il
    // calo di FPS peggiore persino della modalità modifica.
    final rawItems = <Widget>[
      for (var blockIndex = 0; blockIndex < blocks.length; blockIndex++)
        KeyedSubtree(
          key: _blockKeys.putIfAbsent(blockIndex, () => GlobalKey()),
          child: RepaintBoundary(
            child: _FadeInOnMount(
              child: wrapCentered(
                Padding(
                  padding: EdgeInsets.only(bottom: gapAfterBlock(blockIndex)),
                  child: Text(blocks[blockIndex], style: rawTextStyle),
                ),
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

    // I blocchi sono cambiati (nuova nota o nota modificata altrove): lo
    // stato "grezzo/formattato" precedente e le cache che indicizzano per
    // posizione non hanno più senso e vengono azzerati insieme.
    _pendingRevertTimer?.cancel();
    _pendingRevertTimer = null;
    _rawModeEnteredAt = null;
    _isRawMode = false;
    _renderedPlainTextCache.clear();
    _blockKeys.removeWhere((index, _) => index >= blocks.length);

    _cachedBlocks = blocks;
    _cachedFormattedItems = formattedItems;
    _cachedRawItems = rawItems;
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

  /// Assembla il sottoalbero finale a partire dagli "ingredienti" già in
  /// cache (blocchi formattati, blocchi grezzi, blocco titolo) e dalla
  /// modalità corrente. Nessun reparse Markdown né ricostruzione dello
  /// stylesheet quando cambia SOLO `_isRawMode`: entrambe le liste di
  /// blocchi sono già pronte in cache, qui si sceglie solo COME disporle.
  ///
  /// I due rami NON sono intercambiabili solo nell'aspetto, ma nella
  /// strategia di rendering, ed è una scelta deliberata:
  ///
  ///  - **Formattato (a riposo)** → `ListView.builder` VIRTUALIZZATO: solo i
  ///    blocchi vicini alla viewport vengono costruiti/disposti. Essenziale
  ///    per note lunghe, dato che ogni blocco è un `MarkdownBody` (parsing
  ///    Markdown non gratuito).
  ///  - **Grezzo (durante una selezione)** → `SingleChildScrollView` +
  ///    `Column` NON virtualizzato: TUTTI i blocchi vengono disposti subito.
  ///
  /// Il secondo punto è la correzione al problema del flash bianco: se la
  /// modalità grezza restasse dentro un `ListView.builder` virtualizzato,
  /// "Seleziona tutto" o un trascinamento veloce verso il basso
  /// chiederebbero a `SelectionArea` di selezionare testo il cui
  /// `RenderObject` non esiste ancora perché fuori dalla finestra
  /// costruita. Flutter prova allora ad auto-scrollare per "raggiungere"
  /// quel testo mancante; se la richiesta di selezione corre più veloce
  /// della costruzione dei nuovi elementi, entra in un ciclo di tentativi
  /// che blocca il thread di rendering — il flash bianco e il freeze
  /// osservati. Eliminare la virtualizzazione SOLO nella finestra
  /// temporale in cui è attiva una selezione toglie il problema alla
  /// radice invece di attenuarlo: i blocchi grezzi sono `Text` piatti senza
  /// parsing, quindi disporli tutti in una volta ha un costo contenuto ed è
  /// comunque transitorio (dura quanto la selezione). Non appena la
  /// selezione termina si torna al `ListView.builder` virtualizzato.
  Widget _buildListSubtree() {
    final blocks = _cachedBlocks!;
    final formattedItems = _cachedFormattedItems!;
    final rawItems = _cachedRawItems!;
    final hasTitle = _cachedHasTitle;
    final itemCount = (hasTitle ? 1 : 0) + blocks.length;

    Widget scrollableContent;
    if (_isRawMode) {
      scrollableContent = SingleChildScrollView(
        // Key di tipo diverso da quella del ramo formattato: forza Flutter
        // a trattarlo esplicitamente come uno scambio di widget (mai un
        // update "morbido" di un `ListView` con un `SingleChildScrollView`,
        // cosa che comunque non sarebbe permessa avendo runtimeType
        // diversi, ma la key esplicita rende l'intento leggibile).
        key: const ValueKey('markdown-raw-scrollview'),
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasTitle) _cachedTitleWidget!,
            ...rawItems,
          ],
        ),
      );
    } else {
      scrollableContent = ListView.builder(
        key: const ValueKey('markdown-formatted-listview'),
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (hasTitle && index == 0) return _cachedTitleWidget!;
          final blockIndex = hasTitle ? index - 1 : index;
          return formattedItems[blockIndex];
        },
      );
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
            if (item.type == ContextMenuButtonType.copy) {
              final originalOnPressed = item.onPressed;
              return item.copyWith(
                onPressed: () {
                  // Esegue prima la copia originale (clipboard invariato),
                  // poi riporta l'intero documento a Markdown formattato:
                  // "fine della selezione" per copia esplicita, come da
                  // spec.
                  originalOnPressed?.call();
                  _revertToFormatted();
                },
              );
            }
            if (item.type == ContextMenuButtonType.selectAll &&
                !_isRawMode) {
              // "Seleziona tutto" è il modo più diretto per innescare il
              // problema descritto in cima al file: chiede di selezionare
              // l'intero documento mentre è ancora virtualizzato. Passiamo
              // a grezzo (non virtualizzato) PRIMA di eseguire l'azione,
              // così quando "seleziona tutto" viene effettivamente
              // eseguita ogni blocco esiste già come `RenderObject` reale
              // — nessun testo mancante da inseguire.
              //
              // ATTENZIONE: qui NON si può semplicemente richiamare più
              // tardi `item.onPressed` originale. Quella chiusura fa
              // riferimento agli specifici `Selectable` (i `RenderParagraph`
              // dei blocchi ancora FORMATTATI) presenti nell'istante in cui
              // il menu è stato costruito. Il nostro `setState` appena sopra
              // smonta e ricrea quei blocchi (formattato → grezzo):
              // richiamare la chiusura originale dopo lo swap la fa operare
              // su riferimenti ormai non validi, e la selezione risultante
              // può "impazzire" calcolando un rettangolo di evidenziazione
              // esteso a tutto lo schermo — l'overlay grigio bloccato
              // osservato.
              //
              // La soluzione corretta è invece inviare l'Intent standard
              // `SelectAllTextIntent`, che `SelectableRegion` intercetta
              // internamente (è lo stesso meccanismo di Ctrl+A/Cmd+A da
              // tastiera): non porta con sé alcun riferimento agli oggetti
              // "vecchi", quindi opera correttamente su qualunque insieme
              // di `Selectable` esista nell'istante in cui viene ricevuto.
              // Usiamo il `context` fornito da `contextMenuBuilder` (non
              // quello di questo State): è un discendente di
              // `SelectionArea`, condizione necessaria perché
              // `Actions.invoke` trovi il gestore giusto risalendo
              // l'albero; resta valido dopo lo swap perché `SelectionArea`
              // stesso non viene mai smontato — cambia solo il suo
              // contenuto (`ListView.builder` ↔ `SingleChildScrollView`).
              return item.copyWith(
                onPressed: () {
                  setState(() => _isRawMode = true);
                  _rawModeEnteredAt = DateTime.now();
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    // A questo punto il frame con il documento grezzo per
                    // intero è già stato costruito E disposto (un
                    // `addPostFrameCallback` scatta dopo layout e paint):
                    // "seleziona tutto" ora opera su testo tutto reale.
                    if (!context.mounted) return;
                    Actions.maybeInvoke<SelectAllTextIntent>(
                      context,
                      const SelectAllTextIntent(SelectionChangedCause.toolbar),
                    );
                  });
                },
              );
            }
            return item;
          }).toList(growable: false);
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: selectableRegionState.contextMenuAnchors,
            buttonItems: items,
          );
        },
        child: scrollableContent,
      ),
    );
  }
}

/// Piccola dissolvenza in ingresso usata per ammorbidire la PERCEZIONE dello
/// scambio tra Markdown formattato e testo grezzo (e viceversa).
///
/// Il blocco cambia letteralmente tipo di widget a ogni scambio
/// (`MarkdownBody` ↔ `Text`): Flutter lo smonta e ne monta uno nuovo, non
/// esiste un "morph" continuo tra i due. Questo widget sfrutta esattamente
/// quel nuovo montaggio — parte da opacità alta (non zero, vedi sotto) e
/// sale a 1 in pochi millisecondi — così quello che altrimenti sarebbe un
/// taglio netto diventa una dissolvenza breve e naturale. È SICURO farlo
/// qui, a differenza di un `AnimatedSwitcher`/crossfade tradizionale: non
/// tiene mai in vita contemporaneamente il widget vecchio E quello nuovo (il
/// vecchio è già stato smontato, con il proprio `Selectable`, prima che
/// questo venga creato), quindi non introduce mai due `Selectable`
/// sovrapposti per lo stesso blocco — che avrebbe rotto la selezione
/// seamless.
///
/// PERCHÉ NON SI PARTE DA OPACITÀ ZERO (fix del flash da un frame): un
/// `AnimationController` con `.forward()` chiamato nel costruttore/
/// inizializzatore del `late final` NON avanza sincronamente — il suo primo
/// tick reale arriva dal `Ticker` solo al FRAME SUCCESSIVO, schedulato dallo
/// scheduler. Il primissimo `build()` di questo `State` (quello eseguito
/// nello stesso frame in cui il blocco viene montato, insieme allo smontaggio
/// del blocco precedente) vede quindi ancora `_controller.value == 0.0`. Se
/// quel valore venisse usato direttamente come opacità (`FadeTransition(
/// opacity: _controller, ...)`, come nella versione precedente), quel primo
/// frame dipingerebbe il blocco a opacità ESATTAMENTE zero — completamente
/// trasparente — lasciando intravedere per un singolo frame lo sfondo
/// sottostante (Scaffold/superficie): esattamente il "flash" riportato,
/// percepibile solo nei rari casi in cui lo swap capita ad allinearsi in
/// modo sfavorevole con il refresh dello schermo.
///
/// La correzione non è "aspettare" il primo tick (il problema è proprio che
/// il primissimo frame dipinto usa il valore pre-tick, qualunque sia il
/// momento in cui `.forward()` viene invocato): è rimappare il range
/// dell'`AnimationController` — che PARTE sempre da 0.0, per definizione —
/// su un intervallo di opacità che non tocca mai lo zero. Un
/// `Tween(begin: 0.55, end: 1.0)` fa sì che il valore "pre-tick" (0.0)
/// produca un'opacità reale dello 0.55, non 0: percettivamente un blocco già
/// quasi completamente visibile fin dal primissimo frame, che poi rifinisce
/// la dissolvenza fino a piena opacità nei successivi ~110ms — nessun frame
/// realmente trasparente, quindi nessun fotogramma di sfondo "nudo" da
/// intravedere.
class _FadeInOnMount extends StatefulWidget {
  final Widget child;

  const _FadeInOnMount({required this.child});

  @override
  State<_FadeInOnMount> createState() => _FadeInOnMountState();
}

class _FadeInOnMountState extends State<_FadeInOnMount>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 110),
  )..forward();

  // Vedi doc di classe: il Tween rimappa il valore "pre-tick" del
  // controller (sempre 0.0 sul primissimo frame dipinto) su un'opacità
  // reale di 0.55 invece che 0.0, eliminando il singolo frame
  // completamente trasparente che causava il flash.
  late final Animation<double> _opacity = Tween<double>(
    begin: 0.55,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _opacity, child: widget.child);
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
