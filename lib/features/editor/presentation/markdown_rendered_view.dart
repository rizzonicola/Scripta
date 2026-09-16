import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart'
    show cupertinoTextSelectionControls, cupertinoDesktopTextSelectionControls;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/haptics_helper.dart';
import '../../settings/providers/settings_provider.dart';
import 'widgets/blocks/markdown_block_style.dart';
import 'widgets/blocks/markdown_block_widget.dart';
import '../models/markdown_ast_nodes.dart';
import '../services/markdown_ast_parser.dart';
import '../services/markdown_selection_source_mapper.dart';

/// Vista di sola lettura di una nota, renderizzata SEMPRE in Markdown
/// formattato: non esiste una modalità "testo grezzo" separata.
///
/// MOTORE DI VIRTUALIZZAZIONE (Fase 2): il testo sorgente viene parsato
/// UNA SOLA VOLTA in un albero [MarkdownBlockNode] (vedi
/// `MarkdownAstParser`) quando [content] cambia; durante lo scroll
/// l'albero non viene mai ricalcolato — solo i blocchi di primo livello
/// effettivamente vicini alla viewport corrente vengono istanziati come
/// widget, tramite `ListView.builder`. Il titolo della nota occupa
/// sempre l'indice 0 dello scroll, cosi da scorrere in perfetta sincronia
/// coi blocchi del documento.
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

  // Parser dell'AST: stateless e privo di side-effect (vedi
  // `MarkdownAstParser`), può essere condiviso in modo sicuro per tutta
  // la vita di questo State senza mai toccare DAO/database/sync.
  static const MarkdownAstParser _astParser = MarkdownAstParser();

  static const double _kIdleCacheExtent = 800.0;
  static const double _kActiveSelectionCacheExtent = 6000.0;
  static const double _kFullDocumentCacheExtent = 1.0e7;

  bool _hasActiveSelection = false;
  bool _forceFullRealization = false;

  // FASE 3 — Selezione logica + copia non distruttiva: traduce la
  // selezione VISUALE riportata da `SelectableRegion` nel testo Markdown
  // SORGENTE esatto corrispondente, tramite l'AST (vedi
  // `MarkdownSelectionSourceMapper`). Ricostruito solo quando l'AST
  // cambia (stesso ciclo di vita di `_cachedBlocks`), mai durante lo
  // scroll.
  final MarkdownSelectionController _selectionController =
      MarkdownSelectionController();

  double get _effectiveCacheExtent {
    if (_forceFullRealization) return _kFullDocumentCacheExtent;
    if (_hasActiveSelection) return _kActiveSelectionCacheExtent;
    return _kIdleCacheExtent;
  }

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

  // Cache dell'AST: ricalcolato SOLO quando `widget.content` cambia
  // davvero (confronto per identità/valore stringa in `build`), mai
  // durante lo scroll — è questo, insieme alla virtualizzazione della
  // ListView sotto, a garantire 60+ FPS anche su documenti > 50.000
  // parole (vedi il benchmark del parser in
  // `markdown_ast_parser_test.dart`).
  List<MarkdownBlockNode>? _cachedBlocks;
  String? _cachedContent;

  (ThemeData, String, double, double)? _cachedStyleKey;
  late MarkdownBlockStyle _blockStyle;
  late TextStyle _titleTextStyle;

  @override
  void dispose() {
    _scrollController.dispose();
    _selectionFocusNode.dispose();
    // FASE 4 — `MarkdownSelectionController` è ora un `ChangeNotifier`
    // (vedi `markdown_selection_source_mapper.dart`): va smaltito come
    // ogni altro Listenable posseduto da questo `State`, per non
    // trattenere listener di blocchi già smontati.
    _selectionController.dispose();
    super.dispose();
  }

  void _performFullDocumentSelectAll() {
    if (!_forceFullRealization) {
      setState(() {
        _forceFullRealization = true;
        _hasActiveSelection = true;
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _selectableRegionKey.currentState
            ?.selectAll(SelectionChangedCause.keyboard);
      });
    });
  }

  /// Copia "non distruttiva" (criterio di accettazione 2): scrive nella
  /// clipboard di sistema il testo Markdown SORGENTE esatto della
  /// selezione corrente — cancelletti, asterischi, backtick e sintassi
  /// tabelle/formule inclusi — anziché il testo formattato che
  /// `SelectableRegion` produrrebbe di default. La risoluzione passa
  /// sempre dall'AST (vedi `MarkdownSelectionController`); se per
  /// qualunque motivo non trova una corrispondenza affidabile, ricade sul
  /// testo renderizzato così com'è, così la copia non si rompe mai.
  void _performLogicalCopy() {
    final text = _selectionController.resolveClipboardText();
    if (text == null || text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
  }

  void _handleSelectionChanged(SelectedContent? content) {
    final isEmpty = content == null || content.plainText.isEmpty;

    _selectionController.updateSelection(content);
    HapticsHelper.reportSelectionState(isCollapsed: isEmpty);

    if (isEmpty) {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (fontFamily, fontSize, lineHeight) = ref.watch(
      settingsProvider.select((s) => (s.fontFamily, s.fontSize, s.lineHeight)),
    );

    // Ri-parsing dell'AST SOLO se il testo sorgente è realmente cambiato:
    // questo è ciò che rende il costo del parsing indipendente dal numero
    // di frame di scroll/rebuild — non dal numero di caratteri del
    // documento, che viene pagato una volta sola per modifica.
    if (_cachedContent != widget.content) {
      _cachedContent = widget.content;
      _cachedBlocks = _astParser.parse(widget.content);
      _selectionController.updateDocument(
        MarkdownAstDocument(source: widget.content, blocks: _cachedBlocks!),
      );
    }

    _ensureStyles(theme, fontFamily, fontSize, lineHeight);

    return _buildFormattedView(theme);
  }

  Widget _buildFormattedView(ThemeData theme) {
    final blocks = _cachedBlocks!;
    final hasTitle = widget.title.trim().isNotEmpty;
    final itemCount = (hasTitle ? 1 : 0) + (blocks.isEmpty ? 1 : blocks.length);

    return DefaultSelectionStyle(
      selectionColor: theme.colorScheme.primary.withValues(alpha: 0.35),
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.keyA, control: true):
              SelectAllTextIntent(SelectionChangedCause.keyboard),
          SingleActivator(LogicalKeyboardKey.keyA, meta: true):
              SelectAllTextIntent(SelectionChangedCause.keyboard),
          SingleActivator(LogicalKeyboardKey.keyC, control: true):
              _LogicalCopyIntent(),
          SingleActivator(LogicalKeyboardKey.keyC, meta: true):
              _LogicalCopyIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(
              onInvoke: (intent) {
                _performFullDocumentSelectAll();
                return null;
              },
            ),
            // `_LogicalCopyIntent` è un intent locale (vedi sotto la
            // classe): non dipende da alcun tipo interno di Flutter,
            // eliminando il rischio di "tipo non definito" in fase di
            // build. Intercetta Ctrl+C/Cmd+C per instradarli sulla copia
            // non distruttiva; il pulsante "Copia" del menu contestuale
            // sotto usa lo stesso `_performLogicalCopy()` come percorso
            // alternativo, sempre disponibile.
            _LogicalCopyIntent: CallbackAction<_LogicalCopyIntent>(
              onInvoke: (intent) {
                _performLogicalCopy();
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
                      _performFullDocumentSelectAll();
                    },
                  );
                }
                if (item.type == ContextMenuButtonType.copy) {
                  return ContextMenuButtonItem(
                    type: item.type,
                    label: item.label,
                    onPressed: () {
                      ContextMenuController.removeAny();
                      _performLogicalCopy();
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
              // `ListView.builder` opera unicamente sui nodi di primo
              // livello dell'AST: solo i blocchi effettivamente vicini
              // alla viewport corrente (più il margine dato da
              // `cacheExtent`) vengono istanziati nel widget tree. Il
              // titolo occupa sempre l'indice 0, cosi da scorrere in
              // sincronia con i blocchi sottostanti.
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
                  if (blocks.isEmpty) {
                    return _buildEmptyPlaceholder(theme);
                  }
                  return _buildTopLevelBlock(blocks[blockIndex]);
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
            // Il titolo NON fa parte del sorgente Markdown (`widget
            // .content`, l'unica fonte di verità per la copia non
            // distruttiva): viene escluso dalla selezione logica così
            // che "Seleziona Tutto"/copia restituiscano sempre e solo il
            // documento Markdown, mai il titolo mescolato al corpo.
            SelectionContainer.disabled(
              child: Text(
                widget.title,
                style: _titleTextStyle,
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
      ),
    );
  }

  Widget _buildEmptyPlaceholder(ThemeData theme) {
    return Align(
      key: const ValueKey('rendered-block-empty'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: SelectionContainer.disabled(
          child: Text(
            'Nessun contenuto',
            style: _blockStyle.styleSheet.p?.copyWith(
              fontStyle: FontStyle.italic,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }

  /// Costruisce il wrapper (allineamento + larghezza massima + spaziatura
  /// verticale) di UN SINGOLO blocco di primo livello, delegando il
  /// contenuto vero e proprio al dispatcher [MarkdownBlockWidget]. La
  /// key è derivata dagli offset ESATTI del nodo nel testo sorgente
  /// (garanzia dell'AST, vedi `MarkdownNode`), non da un hash del testo:
  /// identifica quindi lo stesso blocco logico in modo stabile tra un
  /// rebuild e l'altro, anche quando il suo contenuto interno cambia.
  ///
  /// FASE 4 — Selezione Visiva Virtualizzata (fix sincronizzazione):
  /// `_selectionController` (Fase 3 — già mantenuto aggiornato ad ogni
  /// `onSelectionChanged`, indipendentemente da `setState`, vedi
  /// `_handleSelectionChanged`) viene passato per ISTANZA, non più il suo
  /// `logicalSourceSelection` letto una tantum qui dentro `itemBuilder`.
  /// È `MarkdownBlockWidget` (e, ricorsivamente, ogni widget contenitore
  /// a cui lo ripassa) ad abbonarsi direttamente al controller tramite un
  /// `ListenableBuilder` locale: così un blocco che `ListView.builder`
  /// sta istanziando per la prima volta — perché appena entrato nel
  /// viewport durante uno scroll a selezione già attiva — legge lo stato
  /// "live" del controller fin dalla sua PRIMA build, E resta
  /// sincronizzato ad ogni notifica successiva (es. il drag prosegue)
  /// senza che questo `ListView.builder` debba mai rieseguire un
  /// `setState` per l'intera lista solo per propagare la variazione.
  Widget _buildTopLevelBlock(MarkdownBlockNode node) {
    return Align(
      key: ValueKey('rendered-block-${node.type}-${node.startOffset}-${node.endOffset}'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: MarkdownBlockWidget(
              node: node,
              style: _blockStyle,
              selectionController: _selectionController,
            ),
          ),
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

/// Intent locale, senza alcuna dipendenza da tipi interni di Flutter la
/// cui esistenza/firma non è verificabile in questo ambiente: usato per
/// intercettare Ctrl+C/Cmd+C e instradarli sulla copia "non distruttiva"
/// (Fase 3), esattamente con lo stesso pattern Shortcuts+Actions già
/// usato sopra per "Seleziona Tutto". Il pulsante "Copia" del menu
/// contestuale (vedi `contextMenuBuilder`) resta comunque il percorso
/// garantito per la copia non distruttiva indipendentemente da questo
/// binding da tastiera.
class _LogicalCopyIntent extends Intent {
  const _LogicalCopyIntent();
}
