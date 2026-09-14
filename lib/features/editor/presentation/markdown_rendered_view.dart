import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/haptics_helper.dart';
import '../../settings/providers/settings_provider.dart';

// ---------------------------------------------------------------------------
// Modello Dati Logico del Documento
// ---------------------------------------------------------------------------

/// Rappresenta un singolo blocco logico del documento Markdown con i relativi
/// offset globali [startOffset] ed [endOffset] nel testo complessivo serializzato.
@immutable
class DocumentBlock {
  final int index;
  final String text;
  final int startOffset;
  final int endOffset;
  final bool isTitle;

  const DocumentBlock({
    required this.index,
    required this.text,
    required this.startOffset,
    required this.endOffset,
    this.isTitle = false,
  });

  int get length => endOffset - startOffset;

  /// Calcola con precisione al singolo carattere/spazio quale porzione di testo
  /// di questo blocco è inclusa nell'intervallo di selezione globale [globalStart, globalEnd].
  /// Ritorna una tupla (localStart, localEnd) relativa a questo blocco, oppure null.
  (int, int)? getLocalSelection(int globalStart, int globalEnd) {
    if (globalStart >= globalEnd) return null;
    final s = math.max(startOffset, globalStart);
    final e = math.min(endOffset, globalEnd);
    if (s < e) {
      return (s - startOffset, e - startOffset);
    }
    return null;
  }

  /// Indica se il blocco è completamente selezionato.
  bool isFullySelected(int globalStart, int globalEnd) {
    return globalStart <= startOffset && globalEnd >= endOffset;
  }
}

/// Rappresentazione completa del documento logico con testo serializzato per gli appunti.
@immutable
class LogicalDocument {
  final String fullText;
  final List<DocumentBlock> blocks;

  const LogicalDocument({
    required this.fullText,
    required this.blocks,
  });

  factory LogicalDocument.parse({
    required String title,
    required String content,
  }) {
    final cleanTitle = title.trim();
    final hasTitle = cleanTitle.isNotEmpty;
    final effectiveContent = content.isEmpty ? '*Nessun contenuto*' : content;

    final blocks = <DocumentBlock>[];
    final buffer = StringBuffer();
    var currentOffset = 0;
    var blockIndex = 0;

    // Blocco 0: Titolo (se presente)
    if (hasTitle) {
      blocks.add(DocumentBlock(
        index: blockIndex++,
        text: cleanTitle,
        startOffset: currentOffset,
        endOffset: currentOffset + cleanTitle.length,
        isTitle: true,
      ));
      buffer.write(cleanTitle);
      buffer.write('\n\n');
      currentOffset += cleanTitle.length + 2;
    }

    // Blocchi Markdown del contenuto
    final rawBlocks = _splitMarkdownIntoBlocks(effectiveContent);
    for (int i = 0; i < rawBlocks.length; i++) {
      final blockText = rawBlocks[i];
      final start = currentOffset;
      final end = start + blockText.length;

      blocks.add(DocumentBlock(
        index: blockIndex++,
        text: blockText,
        startOffset: start,
        endOffset: end,
        isTitle: false,
      ));
      buffer.write(blockText);
      currentOffset = end;

      if (i < rawBlocks.length - 1) {
        buffer.write('\n\n');
        currentOffset += 2;
      }
    }

    return LogicalDocument(
      fullText: buffer.toString(),
      blocks: blocks,
    );
  }

  static List<String> _splitMarkdownIntoBlocks(String content) {
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

// ---------------------------------------------------------------------------
// Intent Tastiera
// ---------------------------------------------------------------------------

class _SelectAllIntent extends Intent {
  const _SelectAllIntent();
}

class _CopyIntent extends Intent {
  const _CopyIntent();
}

class _ClearSelectionIntent extends Intent {
  const _ClearSelectionIntent();
}

// ---------------------------------------------------------------------------
// Vista Principale
// ---------------------------------------------------------------------------

/// Vista di sola lettura di una nota renderizzata in Markdown, dotata di
/// gestione logica della selezione su base offset indipendente dalla virtualizzazione.
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
  final FocusNode _focusNode = FocusNode(debugLabel: 'markdown-rendered-view');
  final ContextMenuController _contextMenuController = ContextMenuController();

  // Dimensione fissa di cache per garantire fluidità a 60/120 fps
  static const double _kStableCacheExtent = 600.0;

  late LogicalDocument _document;
  TextSelection? _selection;

  (ThemeData, String, double, double)? _cachedStyleKey;
  late MarkdownStyleSheet _markdownStyleSheet;
  late TextStyle _inlineCodeStyle;
  late TextStyle _titleTextStyle;
  late bool _isDark;
  late Color _primaryColor;
  late Color _selectionColor;
  late double _fontSize;

  bool get _hasSelection =>
      _selection != null && !_selection!.isCollapsed && _selection!.isValid;

  int get _selectionStart => _selection?.start ?? 0;
  int get _selectionEnd => _selection?.end ?? 0;

  @override
  void initState() {
    super.initState();
    _document = LogicalDocument.parse(
      title: widget.title,
      content: widget.content,
    );
  }

  @override
  void didUpdateWidget(covariant MarkdownRenderedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title || oldWidget.content != widget.content) {
      setState(() {
        _document = LogicalDocument.parse(
          title: widget.title,
          content: widget.content,
        );
        _selection = null;
      });
      _hideContextMenu();
    }
  }

  @override
  void dispose() {
    _hideContextMenu();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Logica di Selezione Logica (Offset-Based)
  // -------------------------------------------------------------------------

  void _selectAll() {
    if (_document.fullText.isEmpty) return;

    setState(() {
      _selection = TextSelection(
        baseOffset: 0,
        extentOffset: _document.fullText.length,
      );
    });

    HapticsHelper.reportSelectionState(isCollapsed: false);

    // Auto-scroll fluido all'inizio per mostrare la selezione se l'utente ha scrollato
    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    }

    _showContextMenu();
  }

  void _clearSelection() {
    if (!_hasSelection) return;
    setState(() {
      _selection = null;
    });
    HapticsHelper.reportSelectionState(isCollapsed: true);
    _hideContextMenu();
  }

  Future<void> _copySelection() async {
    if (!_hasSelection) return;
    final s = _selectionStart.clamp(0, _document.fullText.length);
    final e = _selectionEnd.clamp(0, _document.fullText.length);
    if (s >= e) return;

    final textToCopy = _document.fullText.substring(s, e);
    await Clipboard.setData(ClipboardData(text: textToCopy));
    HapticsHelper.reportSelectionState(isCollapsed: true);

    _hideContextMenu();
  }

  void _selectBlock(DocumentBlock block, [Offset? anchorPosition]) {
    setState(() {
      _selection = TextSelection(
        baseOffset: block.startOffset,
        extentOffset: block.endOffset,
      );
    });
    HapticsHelper.reportSelectionState(isCollapsed: false);
    _showContextMenu(anchorPosition);
  }

  // -------------------------------------------------------------------------
  // Menu Contestuale Adattivo
  // -------------------------------------------------------------------------

  void _showContextMenu([Offset? globalPosition]) {
    _contextMenuController.remove();

    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final Offset anchor;
    if (globalPosition != null) {
      anchor = globalPosition;
    } else if (box != null && box.hasSize) {
      final size = box.size;
      final topLeft = box.localToGlobal(Offset.zero);
      anchor = Offset(topLeft.dx + (size.width / 2), topLeft.dy + 80);
    } else {
      anchor = const Offset(200, 100);
    }

    _contextMenuController.show(
      context: context,
      contextMenuBuilder: (context) {
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: TextSelectionToolbarAnchors(primaryAnchor: anchor),
          buttonItems: [
            ContextMenuButtonItem(
              type: ContextMenuButtonType.copy,
              onPressed: () {
                _copySelection();
              },
            ),
            ContextMenuButtonItem(
              type: ContextMenuButtonType.selectAll,
              onPressed: () {
                _selectAll();
              },
            ),
          ],
        );
      },
    );
  }

  void _hideContextMenu() {
    if (_contextMenuController.isShown) {
      _contextMenuController.remove();
    }
  }

  // -------------------------------------------------------------------------
  // Stili
  // -------------------------------------------------------------------------

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
    _selectionColor = _primaryColor.withValues(alpha: 0.28);
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

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (fontFamily, fontSize, lineHeight) = ref.watch(
      settingsProvider.select((s) => (s.fontFamily, s.fontSize, s.lineHeight)),
    );

    _ensureStyles(theme, fontFamily, fontSize, lineHeight);

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.keyA, control: true): _SelectAllIntent(),
          SingleActivator(LogicalKeyboardKey.keyA, meta: true): _SelectAllIntent(),
          SingleActivator(LogicalKeyboardKey.keyC, control: true): _CopyIntent(),
          SingleActivator(LogicalKeyboardKey.keyC, meta: true): _CopyIntent(),
          SingleActivator(LogicalKeyboardKey.escape): _ClearSelectionIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _SelectAllIntent: CallbackAction<_SelectAllIntent>(
              onInvoke: (_) => _selectAll(),
            ),
            _CopyIntent: CallbackAction<_CopyIntent>(
              onInvoke: (_) => _copySelection(),
            ),
            _ClearSelectionIntent: CallbackAction<_ClearSelectionIntent>(
              onInvoke: (_) => _clearSelection(),
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _clearSelection,
            child: ScrollConfiguration(
              behavior: const _NoGlowScrollBehavior(),
              child: ListView.builder(
                key: const ValueKey('markdown-logical-rendered-listview'),
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
                cacheExtent: _kStableCacheExtent,
                itemCount: _document.blocks.length,
                itemBuilder: (context, index) {
                  final block = _document.blocks[index];
                  final localSelection = _hasSelection
                      ? block.getLocalSelection(_selectionStart, _selectionEnd)
                      : null;
                  final isFullySelected = _hasSelection &&
                      block.isFullySelected(_selectionStart, _selectionEnd);

                  if (block.isTitle) {
                    return _buildTitleWidget(
                      theme: theme,
                      block: block,
                      localSelection: localSelection,
                      isFullySelected: isFullySelected,
                    );
                  }

                  return _buildMarkdownBlockWidget(
                    block: block,
                    localSelection: localSelection,
                    isFullySelected: isFullySelected,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitleWidget({
    required ThemeData theme,
    required DocumentBlock block,
    required (int, int)? localSelection,
    required bool isFullySelected,
  }) {
    Widget titleTextWidget;

    if (localSelection != null && !isFullySelected) {
      final (s, e) = localSelection;
      titleTextWidget = Text.rich(
        TextSpan(
          children: [
            if (s > 0)
              TextSpan(text: block.text.substring(0, s)),
            TextSpan(
              text: block.text.substring(s, e),
              style: TextStyle(
                backgroundColor: _selectionColor,
              ),
            ),
            if (e < block.text.length)
              TextSpan(text: block.text.substring(e)),
          ],
          style: _titleTextStyle,
        ),
      );
    } else {
      titleTextWidget = Text(
        block.text,
        style: _titleTextStyle,
      );
    }

    return Align(
      key: const ValueKey('rendered-block-title'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTapDown: (details) => _selectBlock(block, details.globalPosition),
          onLongPressStart: (details) => _selectBlock(block, details.globalPosition),
          onSecondaryTapUp: (details) => _selectBlock(block, details.globalPosition),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: isFullySelected ? _selectionColor : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                titleTextWidget,
                const SizedBox(height: 16),
                Divider(
                  color: theme.colorScheme.outline.withValues(alpha: 0.3),
                  thickness: 1,
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMarkdownBlockWidget({
    required DocumentBlock block,
    required (int, int)? localSelection,
    required bool isFullySelected,
  }) {
    return Align(
      key: ValueKey('rendered-block-${block.index}'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTapDown: (details) => _selectBlock(block, details.globalPosition),
              onLongPressStart: (details) => _selectBlock(block, details.globalPosition),
              onSecondaryTapUp: (details) => _selectBlock(block, details.globalPosition),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: BoxDecoration(
                  color: isFullySelected
                      ? _selectionColor
                      : (localSelection != null
                          ? _selectionColor.withValues(alpha: 0.15)
                          : Colors.transparent),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(4),
                child: _MarkdownBlockView(
                  blockText: block.text,
                  styleSheet: _markdownStyleSheet,
                  inlineCodeStyle: _inlineCodeStyle,
                  fontSize: _fontSize,
                  isDark: _isDark,
                  primaryColor: _primaryColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Render del Blocco Markdown
// ---------------------------------------------------------------------------

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
  const _NoGlowScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
      BuildContext context, Widget child, ScrollableDetails details) {
    return child;
  }
}
