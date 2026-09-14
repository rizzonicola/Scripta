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

// ===========================================================================
// 1. MODELLO DEGLI STATI DI SELEZIONE
// ===========================================================================

enum SelectionType { none, full, partial }

/// Risoluzione dello stato di selezione di un blocco.
@immutable
class BlockSelection {
  final SelectionType type;
  final int start;
  final int end;

  const BlockSelection.none()
      : type = SelectionType.none,
        start = 0,
        end = 0;

  const BlockSelection.full()
      : type = SelectionType.full,
        start = 0,
        end = 0;

  const BlockSelection.partial(this.start, this.end)
      : type = SelectionType.partial;

  bool get isSelected => type != SelectionType.none;
  bool get isFull => type == SelectionType.full;
  bool get isPartial => type == SelectionType.partial;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BlockSelection &&
          other.type == type &&
          other.start == start &&
          other.end == end;

  @override
  int get hashCode => Object.hash(type, start, end);
}

// ===========================================================================
// 2. INDICIZZAZIONE LOGICA DEL DOCUMENTO
// ===========================================================================

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

  /// Risolve in tempo O(1) lo stato di selezione per questo blocco rispetto
  /// all'intervallo globale di caratteri [globalStart, globalEnd].
  BlockSelection getSelection(int? globalStart, int? globalEnd) {
    if (globalStart == null || globalEnd == null || globalStart >= globalEnd) {
      return const BlockSelection.none();
    }
    // Completamente escluso
    if (globalEnd <= startOffset || globalStart >= endOffset) {
      return const BlockSelection.none();
    }
    // Totalmente selezionato
    if (globalStart <= startOffset && globalEnd >= endOffset) {
      return const BlockSelection.full();
    }
    // Parzialmente selezionato con calcolo esatto al singolo carattere e spazio
    final localStart = math.max(0, globalStart - startOffset);
    final localEnd = math.min(length, globalEnd - startOffset);

    if (localStart == 0 && localEnd == length) {
      return const BlockSelection.full();
    }
    if (localStart >= localEnd) {
      return const BlockSelection.none();
    }
    return BlockSelection.partial(localStart, localEnd);
  }
}

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

    // 1. Titolo
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

    // 2. Blocchi di Contenuto Markdown
    final rawBlocks = _splitIntoMarkdownBlocks(effectiveContent);
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

  static List<String> _splitIntoMarkdownBlocks(String content) {
    final lines = content.split('\n');
    final blocks = <String>[];
    final current = <String>[];
    bool inCodeFence = false;

    for (final line in lines) {
      if (line.trimLeft().startsWith('```')) {
        inCodeFence = !inCodeFence;
        current.add(line);
        if (!inCodeFence) {
          blocks.add(current.join('\n'));
          current.clear();
        }
        continue;
      }

      if (inCodeFence) {
        current.add(line);
        continue;
      }

      if (line.trim().isEmpty) {
        if (current.isNotEmpty) {
          blocks.add(current.join('\n'));
          current.clear();
        }
      } else {
        current.add(line);
      }
    }

    if (current.isNotEmpty) {
      blocks.add(current.join('\n'));
    }

    return blocks.isEmpty ? [''] : blocks;
  }
}

// ===========================================================================
// 3. INTENT TASTIERA
// ===========================================================================

class _SelectAllIntent extends Intent {
  const _SelectAllIntent();
}

class _CopyIntent extends Intent {
  const _CopyIntent();
}

class _ClearIntent extends Intent {
  const _ClearIntent();
}

// ===========================================================================
// 4. VISTA PRINCIPALE
// ===========================================================================

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

  static const double _kStableCacheExtent = 500.0;

  late LogicalDocument _document;
  TextSelection? _selection;

  int? _dragAnchorOffset;

  // Stili
  (ThemeData, String, double, double)? _cachedStyleKey;
  late MarkdownStyleSheet _markdownStyleSheet;
  late MarkdownStyleSheet _selectedMarkdownStyleSheet;
  late TextStyle _inlineCodeStyle;
  late TextStyle _titleTextStyle;
  late bool _isDark;
  late Color _primaryColor;
  late Color _selectionColor;
  late double _fontSize;

  bool get _hasSelection =>
      _selection != null && !_selection!.isCollapsed && _selection!.isValid;

  int? get _selectionStart => _hasSelection ? _selection!.start : null;
  int? get _selectionEnd => _hasSelection ? _selection!.end : null;

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
        _dragAnchorOffset = null;
      });
      _hideToolbar();
    }
  }

  @override
  void dispose() {
    _hideToolbar();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Operazioni Logiche di Selezione
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

    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    }

    _showToolbar();
  }

  void _clearSelection() {
    if (!_hasSelection) return;
    setState(() {
      _selection = null;
      _dragAnchorOffset = null;
    });
    HapticsHelper.reportSelectionState(isCollapsed: true);
    _hideToolbar();
  }

  Future<void> _copySelection() async {
    if (!_hasSelection) return;
    final s = _selectionStart!.clamp(0, _document.fullText.length);
    final e = _selectionEnd!.clamp(0, _document.fullText.length);
    if (s >= e) return;

    final text = _document.fullText.substring(s, e);
    await Clipboard.setData(ClipboardData(text: text));
    HapticsHelper.reportSelectionState(isCollapsed: true);
    _hideToolbar();
  }

  void _setSelectionRange(int base, int extent, [Offset? position]) {
    final clampedBase = base.clamp(0, _document.fullText.length);
    final clampedExtent = extent.clamp(0, _document.fullText.length);
    final isCollapsed = clampedBase == clampedExtent;

    setState(() {
      _selection = TextSelection(
        baseOffset: clampedBase,
        extentOffset: clampedExtent,
      );
    });

    HapticsHelper.reportSelectionState(isCollapsed: isCollapsed);

    if (!isCollapsed) {
      _showToolbar(position);
    } else {
      _hideToolbar();
    }
  }

  // -------------------------------------------------------------------------
  // Menu Contestuale
  // -------------------------------------------------------------------------

  void _showToolbar([Offset? position]) {
    _contextMenuController.remove();

    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final Offset anchor;
    if (position != null) {
      anchor = position;
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

  void _hideToolbar() {
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

    // Stile normale
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

    // Stile interamente selezionato (l'evidenziazione si applica al testo dei blocchi)
    _selectedMarkdownStyleSheet = _markdownStyleSheet.copyWith(
      p: baseTextStyle.copyWith(backgroundColor: _selectionColor),
      h1: _markdownStyleSheet.h1?.copyWith(backgroundColor: _selectionColor),
      h2: _markdownStyleSheet.h2?.copyWith(backgroundColor: _selectionColor),
      h3: _markdownStyleSheet.h3?.copyWith(backgroundColor: _selectionColor),
      blockquote: _markdownStyleSheet.blockquote?.copyWith(backgroundColor: _selectionColor),
      code: _inlineCodeStyle.copyWith(backgroundColor: _selectionColor),
      tableHead: _markdownStyleSheet.tableHead?.copyWith(backgroundColor: _selectionColor),
      tableBody: _markdownStyleSheet.tableBody?.copyWith(backgroundColor: _selectionColor),
      listBullet: _markdownStyleSheet.listBullet?.copyWith(backgroundColor: _selectionColor),
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
          SingleActivator(LogicalKeyboardKey.escape): _ClearIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _SelectAllIntent: CallbackAction<_SelectAllIntent>(
              onInvoke: (_) {
                _selectAll();
                return null;
              },
            ),
            _CopyIntent: CallbackAction<_CopyIntent>(
              onInvoke: (_) {
                _copySelection();
                return null;
              },
            ),
            _ClearIntent: CallbackAction<_ClearIntent>(
              onInvoke: (_) {
                _clearSelection();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _clearSelection,
            child: ScrollConfiguration(
              behavior: const _NoGlowScrollBehavior(),
              child: ListView.builder(
                key: const ValueKey('markdown-rendered-view-list'),
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
                cacheExtent: _kStableCacheExtent,
                itemCount: _document.blocks.length,
                itemBuilder: (context, index) {
                  final block = _document.blocks[index];
                  // Costruzione logica della selezione per questo blocco
                  final selection = block.getSelection(
                    _selectionStart,
                    _selectionEnd,
                  );

                  if (block.isTitle) {
                    return _buildTitleWidget(
                      theme: theme,
                      block: block,
                      selection: selection,
                    );
                  }

                  return _buildMarkdownBlock(
                    block: block,
                    selection: selection,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Render dei Blocchi con Costruzione Precisa della Selezione
  // -------------------------------------------------------------------------

  Widget _buildTitleWidget({
    required ThemeData theme,
    required DocumentBlock block,
    required BlockSelection selection,
  }) {
    Widget titleWidget;

    switch (selection.type) {
      case SelectionType.none:
        titleWidget = Text(
          block.text,
          style: _titleTextStyle,
        );
      case SelectionType.full:
        titleWidget = Text(
          block.text,
          style: _titleTextStyle.copyWith(backgroundColor: _selectionColor),
        );
      case SelectionType.partial:
        titleWidget = Text.rich(
          TextSpan(
            style: _titleTextStyle,
            children: [
              if (selection.start > 0)
                TextSpan(text: block.text.substring(0, selection.start)),
              TextSpan(
                text: block.text.substring(selection.start, selection.end),
                style: TextStyle(backgroundColor: _selectionColor),
              ),
              if (selection.end < block.text.length)
                TextSpan(text: block.text.substring(selection.end)),
            ],
          ),
        );
    }

    return Align(
      key: const ValueKey('rendered-title-block'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTapDown: (d) => _setSelectionRange(
            block.startOffset,
            block.endOffset,
            d.globalPosition,
          ),
          onLongPressStart: (d) => _setSelectionRange(
            block.startOffset,
            block.endOffset,
            d.globalPosition,
          ),
          onSecondaryTapUp: (d) => _setSelectionRange(
            block.startOffset,
            block.endOffset,
            d.globalPosition,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              titleWidget,
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
    );
  }

  Widget _buildMarkdownBlock({
    required DocumentBlock block,
    required BlockSelection selection,
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
              onDoubleTapDown: (d) => _setSelectionRange(
                block.startOffset,
                block.endOffset,
                d.globalPosition,
              ),
              onLongPressStart: (d) => _setSelectionRange(
                block.startOffset,
                block.endOffset,
                d.globalPosition,
              ),
              onSecondaryTapUp: (d) => _setSelectionRange(
                block.startOffset,
                block.endOffset,
                d.globalPosition,
              ),
              onPanStart: (d) {
                _dragAnchorOffset = block.startOffset;
                _setSelectionRange(
                  block.startOffset,
                  block.endOffset,
                  d.globalPosition,
                );
              },
              onPanUpdate: (d) {
                if (_dragAnchorOffset != null) {
                  _setSelectionRange(
                    _dragAnchorOffset!,
                    block.endOffset,
                    d.globalPosition,
                  );
                }
              },
              child: _MarkdownBlockRenderer(
                blockText: block.text,
                selection: selection,
                normalSheet: _markdownStyleSheet,
                selectedSheet: _selectedMarkdownStyleSheet,
                inlineCodeStyle: _inlineCodeStyle,
                fontSize: _fontSize,
                isDark: _isDark,
                selectionColor: _selectionColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// 5. RENDERER DEL SINGOLO BLOCCO
// ===========================================================================

class _MarkdownBlockRenderer extends StatefulWidget {
  final String blockText;
  final BlockSelection selection;
  final MarkdownStyleSheet normalSheet;
  final MarkdownStyleSheet selectedSheet;
  final TextStyle inlineCodeStyle;
  final double fontSize;
  final bool isDark;
  final Color selectionColor;

  const _MarkdownBlockRenderer({
    required this.blockText,
    required this.selection,
    required this.normalSheet,
    required this.selectedSheet,
    required this.inlineCodeStyle,
    required this.fontSize,
    required this.isDark,
    required this.selectionColor,
  });

  @override
  State<_MarkdownBlockRenderer> createState() => _MarkdownBlockRendererState();
}

class _MarkdownBlockRendererState extends State<_MarkdownBlockRenderer> {
  Widget? _cachedWidget;
  String? _cachedText;
  BlockSelection? _cachedSelection;
  double? _cachedFontSize;
  bool? _cachedIsDark;

  bool get _cacheHit =>
      _cachedWidget != null &&
      _cachedText == widget.blockText &&
      _cachedSelection == widget.selection &&
      _cachedFontSize == widget.fontSize &&
      _cachedIsDark == widget.isDark;

  @override
  Widget build(BuildContext context) {
    if (_cacheHit) {
      return _cachedWidget!;
    }

    _cachedText = widget.blockText;
    _cachedSelection = widget.selection;
    _cachedFontSize = widget.fontSize;
    _cachedIsDark = widget.isDark;

    // Se parziale e testo semplice: evidenziazione visiva carattere per carattere
    if (widget.selection.isPartial) {
      final s = widget.selection.start;
      final e = widget.selection.end;

      if (!widget.blockText.startsWith('```') &&
          !widget.blockText.startsWith('#') &&
          !widget.blockText.startsWith('-') &&
          !widget.blockText.startsWith('|')) {
        _cachedWidget = Text.rich(
          TextSpan(
            style: widget.normalSheet.p,
            children: [
              if (s > 0)
                TextSpan(text: widget.blockText.substring(0, s)),
              TextSpan(
                text: widget.blockText.substring(s, e),
                style: TextStyle(backgroundColor: widget.selectionColor),
              ),
              if (e < widget.blockText.length)
                TextSpan(text: widget.blockText.substring(e)),
            ],
          ),
        );
        return _cachedWidget!;
      }
    }

    // Se pieno o normale: renderizzato tramite MarkdownBody con il rispettivo foglio stili
    final effectiveStyleSheet = widget.selection.isFull
        ? widget.selectedSheet
        : widget.normalSheet;

    _cachedWidget = MarkdownBody(
      data: widget.blockText,
      selectable: false,
      styleSheet: effectiveStyleSheet,
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
        'code': _CodeElementBuilder(
          inlineCodeStyle: widget.inlineCodeStyle,
          fontSize: widget.fontSize,
          isDark: widget.isDark,
          selection: widget.selection,
          selectionColor: widget.selectionColor,
        ),
      },
    );

    return _cachedWidget!;
  }
}

// ===========================================================================
// 6. BUILDER DEL CODICE SORGENTE
// ===========================================================================

class _CodeElementBuilder extends MarkdownElementBuilder {
  final TextStyle inlineCodeStyle;
  final double fontSize;
  final bool isDark;
  final BlockSelection selection;
  final Color selectionColor;

  _CodeElementBuilder({
    required this.inlineCodeStyle,
    required this.fontSize,
    required this.isDark,
    required this.selection,
    required this.selectionColor,
  });

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final String text = element.textContent;
    final isMultiline =
        element.attributes.containsKey('class') || text.contains('\n');

    final codeStyle = GoogleFonts.jetBrainsMono(
      fontSize: fontSize * 0.85,
      height: 1.4,
    );

    Widget contentWidget;
    switch (selection.type) {
      case SelectionType.none:
        contentWidget = Text(
          isMultiline ? text.trimRight() : text,
          style: isMultiline ? codeStyle : inlineCodeStyle,
        );
      case SelectionType.full:
        contentWidget = Text(
          isMultiline ? text.trimRight() : text,
          style: (isMultiline ? codeStyle : inlineCodeStyle)
              .copyWith(backgroundColor: selectionColor),
        );
      case SelectionType.partial:
        final clean = isMultiline ? text.trimRight() : text;
        final s = math.min(selection.start, clean.length);
        final e = math.min(selection.end, clean.length);

        if (s < e) {
          contentWidget = Text.rich(
            TextSpan(
              style: isMultiline ? codeStyle : inlineCodeStyle,
              children: [
                if (s > 0)
                  TextSpan(text: clean.substring(0, s)),
                TextSpan(
                  text: clean.substring(s, e),
                  style: TextStyle(backgroundColor: selectionColor),
                ),
                if (e < clean.length)
                  TextSpan(text: clean.substring(e)),
              ],
            ),
          );
        } else {
          contentWidget = Text(
            clean,
            style: isMultiline ? codeStyle : inlineCodeStyle,
          );
        }
    }

    if (isMultiline) {
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
          child: contentWidget,
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEFEFEF),
        borderRadius: BorderRadius.circular(4),
      ),
      child: contentWidget,
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
