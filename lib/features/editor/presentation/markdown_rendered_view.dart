import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart'
    show cupertinoTextSelectionControls, cupertinoDesktopTextSelectionControls;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/haptics_helper.dart';
import '../../settings/providers/settings_provider.dart';

/// Vista di sola lettura di una nota, renderizzata SEMPRE in Markdown
/// formattato: non esiste più una modalità "testo grezzo" separata.
///
/// ARCHITETTURA DELLA SELEZIONE — STATO LOGICO, NON VISIVO
/// ---------------------------------------------------------------------
/// La nota è renderizzata a blocchi in una `ListView.builder` virtualizzata
/// (necessaria per note lunghe: costruire centinaia di blocchi Markdown
/// fuori schermo sarebbe puro spreco). Il framework di selezione nativo di
/// Flutter (`SelectableRegion`) però "vede" solo i widget effettivamente
/// montati: una riga scrollata fuori dall'area visibile smette di
/// partecipare alla selezione.
///
/// Per non dipendere da quanti blocchi risultano montati in un dato
/// istante, questa vista mantiene un piccolo stato LOGICO, indipendente
/// dall'albero dei widget:
///  - [_LogicalDocument]: il testo "in chiaro" dell'intera nota (titolo +
///    contenuto reso senza i marcatori Markdown), calcolato una sola volta
///    per cambio di nota, sempre disponibile per intero in memoria — a
///    prescindere da cosa sia realmente disegnato a schermo in quel
///    momento (vedi doc di classe più sotto).
///  - `_isFullDocumentSelected` / `_lastSelectedPlainText`: due semplici
///    campi di stato (non legati a nessun `RenderObject`) che registrano
///    COSA risulta selezionato, aggiornati ad ogni notifica di
///    `onSelectionChanged`. Essendo campi di `State`, sopravvivono
///    naturalmente a ogni scroll: una riga che esce e rientra
///    nell'area visibile non li tocca in alcun modo.
///
/// "Seleziona tutto" non simula più un trascinamento né forza la
/// costruzione sincrona dell'intera lista (il vecchio meccanismo, rimosso,
/// portava `cacheExtent` a valori enormi solo per materializzare
/// abbastanza widget da poter chiamare `selectAll()`): imposta invece
/// direttamente lo stato logico, fa scorrere la nota fino all'inizio per
/// mostrare la selezione e apre lo stesso menu contestuale nativo di
/// sempre. Copia (da menu contestuale o da scorciatoia) legge il testo da
/// copiare dallo stato logico — mai dal sottoinsieme di widget realmente
/// montati — quindi è corretta carattere per carattere indipendentemente
/// da quanto della nota sia stato materialmente disegnato.
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

  final GlobalKey<SelectableRegionState> _selectableRegionKey =
      GlobalKey<SelectableRegionState>();
  final FocusNode _selectionFocusNode = FocusNode(debugLabel: 'markdown-selection');

  /// Extent di cache "a riposo": basta a garantire uno scroll fluido senza
  /// materializzare blocchi lontani dall'area visibile.
  static const double _kIdleCacheExtent = 800.0;

  /// Extent più ampio, applicato solo mentre è attiva una selezione
  /// parziale: mantiene montati (e quindi selezionabili/trascinabili) un
  /// numero maggiore di blocchi appena fuori schermo, per un trascinamento
  /// meno "a scatti" vicino ai bordi della viewport. Non ha nulla a che
  /// fare con "Seleziona tutto", che non dipende più dal numero di widget
  /// montati (vedi [_performLogicalSelectAll]).
  static const double _kActiveSelectionCacheExtent = 4000.0;

  /// true quando ESISTE una selezione (parziale o totale) attualmente
  /// nota al widget — pilota solo l'extent di cache sopra, non la
  /// correttezza del testo copiato.
  bool _hasActiveSelection = false;

  /// Stato logico: l'intero documento risulta selezionato. Impostato da
  /// [_performLogicalSelectAll] e riconfermato/azzerato in
  /// [_handleSelectionChanged]; guidato da [_selectAllInFlight] per non
  /// essere azzerato dall'eco della stessa chiamata a `selectAll()` nativa
  /// (che il framework può riportare come selezione "solo" dei blocchi
  /// attualmente montati, non dell'intero documento).
  bool _isFullDocumentSelected = false;

  /// true nel breve intervallo fra l'inizio di [_performLogicalSelectAll]
  /// e il primo `onSelectionChanged` che ne consegue: serve a distinguere
  /// "questa notifica è l'eco della nostra selectAll()" da "l'utente ha
  /// iniziato un nuovo trascinamento manuale altrove".
  bool _selectAllInFlight = false;

  /// Ultimo testo effettivamente selezionato riportato dal framework
  /// (`SelectedContent.plainText`), per una selezione parziale. È già
  /// preciso al singolo carattere — Flutter calcola il testo selezionato a
  /// livello di `TextPainter`, non per riga — la parte "logica" che
  /// questa vista aggiunge è conservarlo come campo di stato indipendente
  /// dal widget invece di ricalcolarlo dall'albero ad ogni utilizzo (per
  /// esempio per Copia), così resta corretto anche se nel frattempo un
  /// blocco coinvolto è uscito dall'area visibile ed è stato smontato.
  String _lastSelectedPlainText = '';

  double get _effectiveCacheExtent =>
      _hasActiveSelection ? _kActiveSelectionCacheExtent : _kIdleCacheExtent;

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

  List<String>? _cachedBlocks;
  String? _cachedContent;
  String? _cachedTitle;
  _LogicalDocument? _logicalDocument;

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

  /// Azzera lo stato logico di selezione: chiamato quando la nota
  /// visualizzata cambia (nuovo titolo/contenuto), perché una selezione
  /// calcolata sul documento precedente non ha più alcun significato sul
  /// nuovo.
  void _resetSelectionState() {
    _hasActiveSelection = false;
    _isFullDocumentSelected = false;
    _selectAllInFlight = false;
    _lastSelectedPlainText = '';
  }

  /// Implementa "Seleziona tutto" sul piano dello stato logico: nessun
  /// trascinamento simulato, nessuna costruzione forzata dell'intera
  /// lista. Si limita a (1) dichiarare selezionato l'intero documento nel
  /// nostro stato — operazione O(1), già disponibile in [_logicalDocument]
  /// — (2) scorrere la nota fino all'inizio, così l'utente vede da dove
  /// parte la selezione, e (3) invocare la `selectAll()` nativa per
  /// ottenere comunque l'evidenziazione visiva e il menu contestuale già
  /// esistenti sul sottoinsieme di blocchi che risultano montati in quel
  /// momento. Cosa venga poi effettivamente copiato non dipende da quel
  /// sottoinsieme: vedi l'override del pulsante "Copia" più sotto.
  Future<void> _performLogicalSelectAll() async {
    final doc = _logicalDocument;
    if (doc == null || doc.plainText.isEmpty) return;

    setState(() {
      _isFullDocumentSelected = true;
      _hasActiveSelection = true;
      _selectAllInFlight = true;
    });
    HapticsHelper.reportSelectionState(isCollapsed: false);

    if (_scrollController.hasClients) {
      await _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
    if (!mounted) return;

    // Un frame in più per essere certi che i blocchi in cima alla lista
    // (target dello scroll appena completato) siano stati costruiti prima
    // di chiedere al framework di selezionarli.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    _selectableRegionKey.currentState
        ?.selectAll(SelectionChangedCause.keyboard);

    // Rilascia la "guardia" al frame successivo: a quel punto l'eventuale
    // notifica di `onSelectionChanged` innescata dalla chiamata qui sopra
    // è già stata processata, quindi le notifiche successive possono di
    // nuovo aggiornare liberamente lo stato logico.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectAllInFlight = false;
    });
  }

  void _handleSelectionChanged(SelectedContent? content) {
    final selectedText = content?.plainText ?? '';
    final isEmpty = selectedText.isEmpty;

    HapticsHelper.reportSelectionState(isCollapsed: isEmpty);

    // Mentre siamo nella breve finestra aperta da
    // `_performLogicalSelectAll`, questa notifica è solo l'eco della
    // nostra stessa chiamata a `selectAll()`: il testo che riporta copre
    // solo i blocchi montati in quell'istante, non l'intero documento, e
    // non deve quindi "declassare" lo stato logico che abbiamo appena
    // impostato.
    if (_selectAllInFlight) return;

    if (isEmpty) {
      if (_hasActiveSelection || _isFullDocumentSelected) {
        setState(() {
          _hasActiveSelection = false;
          _isFullDocumentSelected = false;
          _lastSelectedPlainText = '';
        });
      }
      return;
    }

    // Caso raro: l'utente seleziona "a mano" (drag) l'intera nota senza
    // passare dal pulsante/scorciatoia dedicati. Confronto normalizzato
    // (non uguaglianza stretta) perché la concatenazione nativa di più
    // `SelectableText.rich` e la nostra estrazione in chiaro possono
    // differire per spazi/interruzioni di riga senza che il contenuto
    // "sostanziale" selezionato sia diverso.
    final matchesFullDocument =
        _logicalDocument?.matchesFullText(selectedText) ?? false;

    if (!_hasActiveSelection ||
        _isFullDocumentSelected != matchesFullDocument ||
        _lastSelectedPlainText != selectedText) {
      setState(() {
        _hasActiveSelection = true;
        _isFullDocumentSelected = matchesFullDocument;
        _lastSelectedPlainText = selectedText;
      });
    }
  }

  /// Testo da copiare per lo stato logico corrente: l'intero documento se
  /// è attivo un "Seleziona tutto" logico, altrimenti l'ultima selezione
  /// parziale nota — mai ricalcolato interrogando l'albero dei widget.
  String get _textToCopy => _isFullDocumentSelected
      ? (_logicalDocument?.plainText ?? '')
      : _lastSelectedPlainText;

  void _copyLogicalSelection() {
    final text = _textToCopy;
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
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

    if (_cachedContent != widget.content || _cachedTitle != widget.title) {
      _cachedContent = widget.content;
      _cachedTitle = widget.title;
      final effectiveContent =
          widget.content.isEmpty ? '*Nessun contenuto*' : widget.content;
      _cachedBlocks = _splitMarkdownIntoBlocks(effectiveContent);
      _logicalDocument = _LogicalDocument.build(
        title: widget.title,
        blocks: _cachedBlocks!,
      );
      // La nota è cambiata: qualunque selezione precedente si riferiva al
      // documento vecchio e non ha più significato su quello nuovo.
      _resetSelectionState();
    }

    _ensureStyles(theme, fontFamily, fontSize, lineHeight);

    return _buildFormattedView(theme);
  }

  Widget _buildFormattedView(ThemeData theme) {
    final blocks = _cachedBlocks!;
    final hasTitle = widget.title.trim().isNotEmpty;
    final itemCount = (hasTitle ? 1 : 0) + blocks.length;

    return DefaultSelectionStyle(
      selectionColor: theme.colorScheme.primary.withValues(alpha: 0.35),
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.keyA, control: true):
              SelectAllTextIntent(SelectionChangedCause.keyboard),
          SingleActivator(LogicalKeyboardKey.keyA, meta: true):
              SelectAllTextIntent(SelectionChangedCause.keyboard),
          SingleActivator(LogicalKeyboardKey.keyC, control: true):
              CopySelectionTextIntent.copy,
          SingleActivator(LogicalKeyboardKey.keyC, meta: true):
              CopySelectionTextIntent.copy,
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(
              onInvoke: (intent) {
                unawaited(_performLogicalSelectAll());
                return null;
              },
            ),
            CopySelectionTextIntent:
                CallbackAction<CopySelectionTextIntent>(
              onInvoke: (intent) {
                _copyLogicalSelection();
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
              final items = selectableRegionState.contextMenuButtonItems
                  .map((item) {
                if (item.type == ContextMenuButtonType.selectAll) {
                  return ContextMenuButtonItem(
                    type: item.type,
                    label: item.label,
                    onPressed: () {
                      ContextMenuController.removeAny();
                      unawaited(_performLogicalSelectAll());
                    },
                  );
                }
                if (item.type == ContextMenuButtonType.copy &&
                    _isFullDocumentSelected) {
                  // Con l'intero documento logicamente selezionato, il
                  // pulsante nativo copierebbe solo il sottoinsieme di
                  // testo effettivamente montato: lo sostituiamo perché
                  // copi sempre l'intero documento logico.
                  return ContextMenuButtonItem(
                    type: item.type,
                    label: item.label,
                    onPressed: () {
                      ContextMenuController.removeAny();
                      _copyLogicalSelection();
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

  List<String> _splitMarkdownIntoBlocks(String content) {
    final lines = content.split('\n');
    final blocks = <String>[];
    final currentBlock = <String>[];
    bool inCodeBlock = false;

    for (final line in lines) {
      if (line.trimLeft().startsWith('```')) {
        inCodeBlock = !inCodeBlock;
        currentBlock.add(line);
        if (!inCodeBlock) {
          blocks.add(currentBlock.join('\n'));
          currentBlock.clear();
        }
        continue;
      }

      if (inCodeBlock) {
        currentBlock.add(line);
        continue;
      }

      if (line.trim().isEmpty) {
        if (currentBlock.isNotEmpty) {
          blocks.add(currentBlock.join('\n'));
          currentBlock.clear();
        }
      } else {
        currentBlock.add(line);
      }
    }

    if (currentBlock.isNotEmpty) {
      blocks.add(currentBlock.join('\n'));
    }

    return blocks.isEmpty ? [''] : blocks;
  }
}

/// Rappresentazione logica, puramente testuale, dell'intera nota — la
/// "fonte di verità" per selezione totale e copia, completamente
/// indipendente da quali blocchi risultano montati nella `ListView`
/// virtualizzata in un dato istante (si veda la documentazione di classe
/// di [MarkdownRenderedView]).
///
/// Ricostruita una sola volta per ogni cambio di `title`/`content` (non ad
/// ogni frame): il costo di attraversare il testo una volta è trascurabile
/// rispetto a quello di rendering dei blocchi Markdown stessi.
@immutable
class _LogicalDocument {
  const _LogicalDocument({required this.plainText});

  /// Testo "in chiaro" dell'intera nota: titolo (se presente) seguito dal
  /// contenuto reso senza marcatori Markdown superflui (`**`, `#`, `_`,
  /// link in forma `[testo](url)` ridotti al solo testo, ecc.), con
  /// l'impaginazione a blocchi preservata da righe vuote. È esattamente
  /// ciò che un utente si aspetterebbe copiando l'intera nota renderizzata.
  final String plainText;

  factory _LogicalDocument.build({
    required String title,
    required List<String> blocks,
  }) {
    final buffer = StringBuffer();
    final trimmedTitle = title.trim();
    if (trimmedTitle.isNotEmpty) {
      buffer.writeln(trimmedTitle);
      buffer.writeln();
    }

    final parser = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
    var wroteAnyBlock = false;
    for (final block in blocks) {
      final plain = _plainTextForBlock(parser, block);
      if (plain.isEmpty) continue;
      if (wroteAnyBlock) buffer.write('\n\n');
      buffer.write(plain);
      wroteAnyBlock = true;
    }

    return _LogicalDocument(plainText: buffer.toString());
  }

  static String _plainTextForBlock(md.Document parser, String blockMarkdown) {
    final nodes = parser.parseLines(blockMarkdown.split('\n'));
    final buffer = StringBuffer();
    for (final node in nodes) {
      _writePlainText(node, buffer);
    }
    return buffer.toString().trim();
  }

  static const _kBlockLevelTags = {
    'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'li', 'blockquote', 'pre', 'tr',
  };

  static void _writePlainText(md.Node node, StringBuffer buffer) {
    if (node is md.Text) {
      buffer.write(node.text);
      return;
    }
    if (node is md.Element) {
      if (node.tag == 'br') {
        buffer.write('\n');
        return;
      }
      final children = node.children;
      if (children != null && children.isNotEmpty) {
        for (final child in children) {
          _writePlainText(child, buffer);
        }
      } else {
        buffer.write(node.textContent);
      }
      if (_kBlockLevelTags.contains(node.tag)) {
        buffer.write('\n');
      }
    }
  }

  /// Confronto "best-effort" (normalizzato sugli spazi bianchi) fra un
  /// testo effettivamente selezionato a video e l'intero documento
  /// logico. Usato solo per il caso raro in cui l'utente selezioni "a
  /// mano" l'intera nota senza passare dal pulsante/scorciatoia dedicati:
  /// per il percorso principale (`_performLogicalSelectAll`) lo stato
  /// viene impostato direttamente, senza bisogno di questo confronto.
  bool matchesFullText(String candidate) {
    if (candidate.isEmpty || plainText.isEmpty) return false;
    return _normalize(candidate) == _normalize(plainText);
  }

  static String _normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();
}

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
      _cachedStyleSheet == widget.styleSheet &&
      _cachedFontSize == widget.fontSize &&
      _cachedIsDark == widget.isDark &&
      _cachedPrimaryColor == widget.primaryColor;

  @override
  Widget build(BuildContext context) {
    if (_cacheHit) {
      return _cachedChild!;
    }

    _cachedText = widget.blockText;
    _cachedStyleSheet = widget.styleSheet;
    _cachedFontSize = widget.fontSize;
    _cachedIsDark = widget.isDark;
    _cachedPrimaryColor = widget.primaryColor;

    _cachedChild = MarkdownBody(
      data: widget.blockText,
      selectable: false,
      styleSheet: widget.styleSheet,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      onTapLink: (text, href, title) async {
        if (href != null && href.isNotEmpty) {
          final uri = Uri.tryParse(href);
          if (uri != null && await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        }
      },
      builders: {
        'code': _CodeBlockBuilder(
          inlineCodeStyle: widget.inlineCodeStyle,
          fontSize: widget.fontSize,
          isDark: widget.isDark,
        ),
      },
    );

    return _cachedChild!;
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  final TextStyle inlineCodeStyle;
  final double fontSize;
  final bool isDark;

  _CodeBlockBuilder({
    required this.inlineCodeStyle,
    required this.fontSize,
    required this.isDark,
  });

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final String text = element.textContent;

    if (element.attributes.containsKey('class') || text.contains('\n')) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(
            text.trimRight(),
            style: GoogleFonts.jetBrainsMono(
              fontSize: fontSize * 0.85,
              height: 1.4,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEFEFEF),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: inlineCodeStyle,
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

