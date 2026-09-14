import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// Solo i controlli di selezione Cupertino: `show` evita qualunque rischio
// di export ambiguo con `material.dart`. Servono per replicare la scelta
// platform-adaptive che `SelectionArea` faceva implicitamente di default
// (Material su Android/desktop non-Apple, Cupertino su iOS/macOS), ora che
// usiamo `SelectableRegion` esplicito e dobbiamo specificarli noi stessi.
import 'package:flutter/cupertino.dart'
    show cupertinoTextSelectionControls, cupertinoDesktopTextSelectionControls;
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

/// Vista di sola lettura di una nota, renderizzata SEMPRE in Markdown
/// formattato: non esiste più una modalità "testo grezzo" separata.
///
/// La selezione del testo avviene direttamente sui blocchi formattati
/// tramite [SelectableRegion] (l'equivalente esplicito di [SelectionArea],
/// necessario qui per poter intervenire su "Seleziona tutto" — vedi sotto).
/// Per restare fluida anche su note molto estese,
/// questa vista porta al suo interno le ottimizzazioni che in precedenza
/// erano riservate alla (ex) modalità testo grezzo:
///  - gli stili derivati da tema/font (incluso il [MarkdownStyleSheet])
///    vengono calcolati UNA SOLA VOLTA per build e condivisi da tutti i
///    blocchi, invece di essere ricostruiti da capo per ciascuno;
///  - ogni blocco vive nel proprio [_MarkdownBlockView], che ricorda
///    l'ultimo albero di widget prodotto da `MarkdownBody` e lo
///    restituisce inalterato finché testo e stile non cambiano
///    realmente: Flutter riconosce l'identità del widget e salta la
///    ricostruzione (e il re-parsing Markdown) di quel sottoalbero anche
///    quando il genitore si ricostruisce per motivi non correlati (es.
///    notifiche di scroll, cambi di stato altrove nell'albero);
///  - ogni blocco riceve una [ValueKey] stabile basata su indice e hash
///    del contenuto, cosicché lo scheletro di `ListView.builder` possa
///    riutilizzare correttamente Element/RenderObject anche se l'indice
///    del titolo/blocco dovesse spostarsi;
///  - la lista sfrutta un `cacheExtent` dinamico per mantenere "caldi" (cioè
///    montati, anche se fuori dalla viewport) i blocchi coinvolti in una
///    selezione attiva. In assenza di selezione il `cacheExtent` resta
///    piccolo (leggero, poca RAM); non appena l'utente inizia a
///    selezionare/trascinare cresce per evitare sia il "flash bianco" di
///    blocchi ri-costruiti da zero al rientro in viewport, sia — nel caso
///    di "Seleziona tutto" — l'esclusione dei blocchi non ancora montati
///    dal `SelectionRegistrar` (che altrimenti li lascia fuori dalla
///    selezione, essendo `SelectionArea`/`SelectableRegion` in grado di
///    selezionare solo i `Selectable` correntemente registrati, cioè
///    quelli effettivamente costruiti da `ListView.builder`). Il
///    `cacheExtent` maggiorato viene rilasciato non appena la selezione
///    collassa, per non appesantire la RAM in modo permanente.
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

class _MarkdownRenderedViewState extends ConsumerState<MarkdownRenderedView> {
  final ScrollController _scrollController = ScrollController();

  // --- Gestione selezione full-document (vedi doc-comment della classe) ---

  // Sostituisce `SelectionArea` con `SelectableRegion` esplicito: serve la
  // GlobalKey per poter invocare programmaticamente `selectAll()` sull'intero
  // documento (non disponibile tramite la sola API di `SelectionArea`).
  final GlobalKey<SelectableRegionState> _selectableRegionKey =
      GlobalKey<SelectableRegionState>();
  final FocusNode _selectionFocusNode = FocusNode(debugLabel: 'markdown-selection');

  // `cacheExtent` di riposo: leggero, sufficiente per uno scroll fluido
  // ordinario senza tenere in vita blocchi lontani dalla viewport.
  static const double _kIdleCacheExtent = 800.0;
  // `cacheExtent` usato mentre l'utente sta trascinando una selezione
  // "normale" (non un select-all): abbastanza ampio da coprire diversi
  // schermate fuori viewport, evitando che i blocchi coinvolti nel
  // trascinamento vengano scartati e poi ricostruiti da zero al rientro
  // (il "flash bianco").
  static const double _kActiveSelectionCacheExtent = 6000.0;
  // `cacheExtent` usato per garantire che un "Seleziona tutto" copra
  // davvero l'intero buffer: abbastanza grande da forzare la costruzione
  // di qualunque nota di dimensioni realistiche, ma finito (evitiamo
  // `double.infinity`, che nei calcoli di offset dello scrolling di
  // Flutter può propagare `NaN`/eccezioni di layout).
  static const double _kFullDocumentCacheExtent = 1.0e7;

  // true durante una selezione attiva (drag in corso o testo selezionato
  // non collassato), a prescindere dalla causa.
  bool _hasActiveSelection = false;
  // true solo mentre è in corso/valida una selezione "tutto il documento"
  // esplicitamente richiesta (scorciatoia da tastiera o voce di menu).
  bool _forceFullRealization = false;

  double get _effectiveCacheExtent {
    if (_forceFullRealization) return _kFullDocumentCacheExtent;
    if (_hasActiveSelection) return _kActiveSelectionCacheExtent;
    return _kIdleCacheExtent;
  }

  // Replica la scelta platform-adaptive che `SelectionArea` applicava di
  // default (maniglie/toolbar in stile Material ovunque tranne iOS/macOS,
  // dove usa lo stile Cupertino), ora che specifichiamo esplicitamente
  // `selectionControls` su `SelectableRegion`.
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

  // Cache del parsing in blocchi: invalidata solo quando il contenuto
  // della nota cambia davvero (non ad ogni build/rebuild del genitore).
  List<String>? _cachedBlocks;
  String? _cachedContent;

  // Cache degli stili derivati da tema/font/dimensione/interlinea.
  // Porting dell'ottimizzazione "un solo TextStyle condiviso" della ex
  // modalità testo grezzo: qui costruiamo `MarkdownStyleSheet` e gli
  // stili accessori una sola volta per combinazione di parametri, e li
  // passiamo per riferimento a TUTTI i blocchi della lista invece di
  // ricrearli per ciascuno di essi (potenzialmente decine/centinaia su
  // una nota lunga).
  (ThemeData, String, double, double)? _cachedStyleKey;
  late MarkdownStyleSheet _markdownStyleSheet;
  late TextStyle _inlineCodeStyle;
  late TextStyle _titleTextStyle;
  late bool _isDark;
  late Color _primaryColor;
  late double _fontSize;

  @override
  void dispose() {
    _scrollController.dispose();
    _selectionFocusNode.dispose();
    super.dispose();
  }

  /// Gestore centrale di "Seleziona tutto" per l'intero buffer della nota.
  ///
  /// Porting dell'algoritmo della ex modalità testo grezzo: lì un singolo
  /// `EditableText` conteneva SEMPRE l'intero testo, quindi un
  /// `TextSelection` da 0 a `text.length` copriva per costruzione l'intero
  /// buffer, in modo sincrono, senza dipendere da cosa fosse attualmente
  /// montato a schermo.
  ///
  /// Qui il documento è invece frammentato in N blocchi Markdown dentro un
  /// `ListView.builder`: `SelectableRegion.selectAll()` può selezionare
  /// solo i `Selectable` attualmente registrati presso il suo
  /// `SelectionRegistrar`, cioè solo i blocchi correntemente montati. Se
  /// chiamato a `cacheExtent` normale, i blocchi fuori viewport (non
  /// montati) restano fuori dalla selezione: è esattamente il bug da
  /// correggere.
  ///
  /// La correzione forza quindi, in ordine:
  ///  1. l'espansione del `cacheExtent` della lista a un valore che copre
  ///     l'intero documento, cosicché `ListView.builder` costruisca (monti)
  ///     OGNI blocco, anche quelli lontanissimi dalla viewport corrente;
  ///  2. l'attesa di due frame (build + layout) affinché ogni blocco
  ///     appena montato abbia effettivamente completato la registrazione
  ///     presso il `SelectionRegistrar` (la registrazione avviene durante
  ///     l'attach/layout dei render object dei blocchi, non è sincrona
  ///     rispetto al solo `setState`);
  ///  3. SOLO a quel punto, l'invocazione di `selectAll()` sulla region,
  ///     che a questo punto vede l'intero documento come selezionabile.
  ///
  /// Il `cacheExtent` maggiorato resta attivo finché la selezione non
  /// collassa (vedi `onSelectionChanged`), poi viene rilasciato.
  void _performFullDocumentSelectAll() {
    if (!_forceFullRealization) {
      setState(() {
        _forceFullRealization = true;
        _hasActiveSelection = true;
      });
    }

    // Primo frame: il rebuild con `_effectiveCacheExtent` maggiorato ha
    // luogo e `ListView.builder`/`Sliver` iniziano a montare i blocchi
    // fuori viewport.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Secondo frame: layout completato, i nuovi `Selectable` si sono
      // registrati. Solo ora il `selectAll()` è garantito coprire l'intero
      // buffer, in modo sicuro (nessuna eccezione per Selectable non
      // ancora presenti nell'albero).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _selectableRegionKey.currentState
            ?.selectAll(SelectionChangedCause.keyboard);
      });
    });
  }

  void _handleSelectionChanged(SelectedContent? content) {
    final isEmpty = content == null || content.plainText.isEmpty;

    // Riusa lo stesso "gate" aptico centralizzato già usato dall'editor:
    // una sola vibrazione leggera all'avvio di ogni nuova selezione,
    // silenzio durante il trascinamento (o comportamento "strong"/"off"
    // secondo le impostazioni utente).
    HapticsHelper.reportSelectionState(isCollapsed: isEmpty);

    if (isEmpty) {
      // La selezione è stata deselezionata/collassata: rilascia la cache
      // di layout maggiorata, tornando al `cacheExtent` leggero di riposo.
      if (_hasActiveSelection || _forceFullRealization) {
        setState(() {
          _hasActiveSelection = false;
          _forceFullRealization = false;
        });
      }
    } else if (!_hasActiveSelection) {
      setState(() {
        _hasActiveSelection = true;
      });
    }
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

    _isDark = theme.brightness == Brightness.dark;
    _primaryColor = theme.colorScheme.primary;
    _fontSize = fontSize;

    final baseTextStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize,
      height: lineHeight,
      color: theme.colorScheme.onSurface,
    );

    _inlineCodeStyle = GoogleFonts.jetBrainsMono(
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

    _markdownStyleSheet = MarkdownStyleSheet(
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
      code: _inlineCodeStyle,
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
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (fontFamily, fontSize, lineHeight) = ref.watch(
      settingsProvider.select((s) => (s.fontFamily, s.fontSize, s.lineHeight)),
    );

    if (_cachedContent != widget.content) {
      _cachedContent = widget.content;
      final effectiveContent =
          widget.content.isEmpty ? '*Nessun contenuto*' : widget.content;
      _cachedBlocks = _splitMarkdownIntoBlocks(effectiveContent);
    }

    _ensureStyles(theme, fontFamily, fontSize, lineHeight);

    return _buildFormattedView(theme);
  }

  Widget _buildFormattedView(ThemeData theme) {
    final blocks = _cachedBlocks!;
    final hasTitle = widget.title.trim().isNotEmpty;
    final itemCount = (hasTitle ? 1 : 0) + blocks.length;

    // `DefaultSelectionStyle` allinea il colore di evidenziazione della
    // selezione a quello che aveva l'ex `EditableText` del testo grezzo,
    // per continuità visiva.
    return DefaultSelectionStyle(
      selectionColor: theme.colorScheme.primary.withValues(alpha: 0.35),
      // `Shortcuts`+`Actions` a livello di antenato intercettano
      // `SelectAllTextIntent` (Ctrl/Cmd+A) PRIMA che raggiunga l'azione di
      // default interna di `SelectableRegion`. Questo funziona perché
      // `SelectableRegion`, come `EditableText`, implementa le proprie
      // scorciatoie di editing tramite `Action<T>.overridable(...)`:
      // un'azione "overridable" cerca prima un antenato che gestisca lo
      // stesso tipo di `Intent` e, se lo trova (come in questo caso), le
      // cede il controllo invece di eseguire il comportamento di default
      // (che sarebbe un `selectAll()` limitato ai soli blocchi già
      // montati: esattamente il bug da correggere).
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.keyA, control: true):
              SelectAllTextIntent(SelectionChangedCause.keyboard),
          SingleActivator(LogicalKeyboardKey.keyA, meta: true):
              SelectAllTextIntent(SelectionChangedCause.keyboard),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(
              onInvoke: (intent) {
                _performFullDocumentSelectAll();
                return null;
              },
            ),
          },
          child: SelectableRegion(
            key: _selectableRegionKey,
            focusNode: _selectionFocusNode,
            selectionControls: _platformSelectionControls,
            onSelectionChanged: _handleSelectionChanged,
            contextMenuBuilder: (context, selectableRegionState) {
              // Ricostruisce il menu contestuale di default (che include
              // già "Copia" e "Seleziona tutto"), sostituendo però il
              // gestore della sola voce "Seleziona tutto" con la nostra
              // versione full-document: il comportamento predefinito di
              // `SelectableRegionState` chiamerebbe altrimenti un
              // `selectAll()` diretto, soggetto allo stesso bug dei
              // blocchi non montati.
              final items = selectableRegionState.contextMenuButtonItems
                  .map((item) {
                if (item.type == ContextMenuButtonType.selectAll) {
                  return ContextMenuButtonItem(
                    type: item.type,
                    label: item.label,
                    onPressed: () {
                      ContextMenuController.removeAny();
                      _performFullDocumentSelectAll();
                    },
                  );
                }
                return item;
              }).toList();

              return AdaptiveTextSelectionToolbar.buttonItems(
                anchors: selectableRegionState.contextMenuAnchors,
                buttonItems: items,
              );
            },
            child: ScrollConfiguration(
              behavior: _NoGlowScrollBehavior(),
              child: ListView.builder(
                key: const ValueKey('markdown-formatted-listview'),
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
                // Dinamico: leggero a riposo, maggiorato durante una
                // selezione attiva o un "Seleziona tutto" (vedi
                // `_effectiveCacheExtent` e il doc-comment della classe).
                cacheExtent: _effectiveCacheExtent,
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  if (hasTitle && index == 0) {
                    return _buildTitleWidget(theme);
                  }
                  final blockIndex = hasTitle ? index - 1 : index;
                  final blockText = blocks[blockIndex];
                  return _buildMarkdownBlock(blockIndex, blockText);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitleWidget(ThemeData theme) {
    return Align(
      key: const ValueKey('rendered-block-title'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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

  Widget _buildMarkdownBlock(int blockIndex, String blockText) {
    // Chiave stabile per indice+contenuto: protegge il riuso corretto di
    // Element/RenderObject da parte di `ListView.builder` anche nei rari
    // casi in cui l'indice di un blocco si sposti (es. comparsa/scomparsa
    // del titolo), senza dover ricorrere a `GlobalKey` più costose.
    return Align(
      key: ValueKey('rendered-block-$blockIndex-${blockText.hashCode}'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _MarkdownBlockView(
              blockText: blockText,
              styleSheet: _markdownStyleSheet,
              inlineCodeStyle: _inlineCodeStyle,
              fontSize: _fontSize,
              isDark: _isDark,
              primaryColor: _primaryColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// Singolo blocco Markdown con caching del proprio albero di rendering.
///
/// Questo è il porting più diretto del vantaggio principale che aveva la
/// ex modalità testo grezzo: lì un solo `EditableText` non doveva MAI
/// ricostruire il proprio `TextPainter`/layout a fronte di variazioni
/// legate alla sola selezione, perché testo e stile restavano identici.
/// Qui, ogni blocco vive nel proprio `State` e ricorda l'ultimo widget
/// (`MarkdownBody`, che internamente fa parsing dell'AST Markdown e
/// costruisce l'albero di widget) prodotto per una data combinazione di
/// (testo, stylesheet, fontSize, tema, colore primario): se in un
/// rebuild del genitore questi parametri non sono cambiati, si restituisce
/// la STESSA istanza di widget già costruita.
///
/// Questo è rilevante perché `Element.update` in Flutter esegue un
/// controllo `identical(newWidget, oldWidget)`: se il widget restituito
/// da `build()` è letteralmente la stessa istanza di prima, l'intero
/// sottoalbero viene considerato invariato e la ricostruzione (incluso il
/// re-parsing Markdown e le allocazioni che ne conseguirebbero) viene
/// saltata, riducendo sia il lavoro sia gli `object allocation` ad ogni
/// rebuild non correlato al contenuto del blocco stesso.
class _MarkdownBlockView extends StatefulWidget {
  final String blockText;
  final MarkdownStyleSheet styleSheet;
  final TextStyle inlineCodeStyle;
  final double fontSize;
  final bool isDark;
  final Color primaryColor;

  const _MarkdownBlockView({
    required this.blockText,
    required this.styleSheet,
    required this.inlineCodeStyle,
    required this.fontSize,
    required this.isDark,
    required this.primaryColor,
  });

  @override
  State<_MarkdownBlockView> createState() => _MarkdownBlockViewState();
}

class _MarkdownBlockViewState extends State<_MarkdownBlockView> {
  Widget? _cachedChild;
  String? _cachedText;
  MarkdownStyleSheet? _cachedStyleSheet;
  double? _cachedFontSize;
  bool? _cachedIsDark;
  Color? _cachedPrimaryColor;

  bool get _cacheHit =>
      _cachedChild != null &&
      _cachedText == widget.blockText &&
      // Lo stylesheet è condiviso per riferimento da `_ensureStyles` nel
      // genitore: un confronto per identità è quindi sufficiente e più
      // economico di un confronto approfondito campo per campo.
      identical(_cachedStyleSheet, widget.styleSheet) &&
      _cachedFontSize == widget.fontSize &&
      _cachedIsDark == widget.isDark &&
      _cachedPrimaryColor == widget.primaryColor;

  @override
  Widget build(BuildContext context) {
    if (_cacheHit) return _cachedChild!;

    final child = MarkdownBody(
      data: widget.blockText,
      selectable: false,
      styleSheet: widget.styleSheet,
      builders: {
        'pre': _CodeBlockBuilder(fontSize: widget.fontSize),
        'code': _InlineCodeBuilder(
          style: widget.inlineCodeStyle,
          isDark: widget.isDark,
          primaryColor: widget.primaryColor,
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
    );

    _cachedChild = child;
    _cachedText = widget.blockText;
    _cachedStyleSheet = widget.styleSheet;
    _cachedFontSize = widget.fontSize;
    _cachedIsDark = widget.isDark;
    _cachedPrimaryColor = widget.primaryColor;
    return child;
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

final RegExp _topLevelListMarkerRe = RegExp(r'^(-|\*|\+)\s|^\d+[.)]\s');
final RegExp _fenceOpenRe = RegExp(r'^\s{0,3}(`{3,}|~{3,})');

bool _isTopLevelListMarkerLine(String line) =>
    _topLevelListMarkerRe.hasMatch(line);

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
      fenceMarker = fenceMatch.group(1);
      buffer.add(line);
      i++;
      continue;
    }

    if (_isTopLevelListMarkerLine(line)) {
      flushBuffer();
      buffer.add(line);
      i++;
      continue;
    }

    if (line.trim().isEmpty) {
      if (buffer.isNotEmpty) {
        if (bufferEndsInQuote() && nextNonBlankContinuesQuote(i + 1)) {
          buffer.add(line);
        } else {
          flushBuffer();
        }
      }
      i++;
      continue;
    }

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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 75, 14),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text.rich(
                  highlightedText,
                ),
              ),
            ),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (displayLang != null) ...[
                        Text(
                          displayLang,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.55),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Container(
                          width: 1,
                          height: 10,
                          color: theme.colorScheme.outline
                              .withValues(alpha: 0.3),
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
                                    : theme.colorScheme.onSurface
                                        .withValues(alpha: 0.6),
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
