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
import 'package:flutter/rendering.dart' show SelectedContent;

/// Vista di sola lettura di una nota Markdown con supporto a selezione fluida.
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
  // Cache per ottimizzazione rendering
  List<String>? _cachedBlocks;
  List<Widget>? _cachedFormattedItems;
  List<Widget>? _cachedRawItems;
  Widget? _cachedTitleWidget;
  bool _cachedHasTitle = false;

  String? _cachedTitle;
  String? _cachedContent;
  String? _cachedFontFamily;
  double? _cachedFontSize;
  double? _cachedLineHeight;
  ColorScheme? _cachedColorScheme;
  Brightness? _cachedBrightness;

  // Stato e scroll stabili
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _blockKeys = {};
  
  bool _isRawMode = false;
  Timer? _pendingRevertTimer;
  DateTime? _rawModeEnteredAt;

  @override
  void dispose() {
    _pendingRevertTimer?.cancel();
    _cachedFormattedItems = null;
    _cachedRawItems = null;
    _cachedTitleWidget = null;
    _cachedContent = null;
    _blockKeys.clear();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleSelectionChanged(SelectedContent? content) {
    final hasSelection = content != null && content.plainText.isNotEmpty;
    HapticsHelper.reportSelectionState(isCollapsed: !hasSelection);

    if (hasSelection) {
      _pendingRevertTimer?.cancel();
      _pendingRevertTimer = null;

      if (_isRawMode) return;

      setState(() {
        _isRawMode = true;
      });
      _rawModeEnteredAt = DateTime.now();
      return;
    }

    if (!_isRawMode) return;

    final enteredAt = _rawModeEnteredAt;
    if (enteredAt != null &&
        DateTime.now().difference(enteredAt) < const Duration(milliseconds: 350)) {
      return;
    }

    _pendingRevertTimer?.cancel();
    _pendingRevertTimer = Timer(const Duration(milliseconds: 150), () {
      _pendingRevertTimer = null;
      if (!mounted) return;
      _revertToFormatted();
    });
  }

  void _revertToFormatted() {
    _pendingRevertTimer?.cancel();
    _pendingRevertTimer = null;
    _rawModeEnteredAt = null;
    if (!_isRawMode) return;
    setState(() {
      _isRawMode = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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

    final effectiveContent = content.isEmpty ? '*Nessun contenuto*' : content;
    List<String> blocks;
    try {
      blocks = _splitMarkdownIntoBlocks(effectiveContent);
    } catch (_) {
      blocks = [effectiveContent];
    }
    
    final blockIsListItem =
        blocks.map(_isTopLevelListMarkerBlock).toList(growable: false);
    final hasTitle = title.trim().isNotEmpty;

    double gapAfterBlock(int blockIndex) {
      if (blockIndex >= blocks.length - 1) return 0;
      if (blockIsListItem[blockIndex] && blockIsListItem[blockIndex + 1]) {
        return 2.0;
      }
      return markdownStyleSheet.blockSpacing ?? 16.0;
    }

    Widget wrapCentered(Widget child) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: SizedBox(width: double.infinity, child: child),
          ),
        );

    final rawTextStyle = GoogleFonts.jetBrainsMono(
      fontSize: fontSize * 0.95,
      height: lineHeight,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.87),
    );

    final formattedItems = <Widget>[
      for (var blockIndex = 0; blockIndex < blocks.length; blockIndex++)
        KeyedSubtree(
          key: _blockKeys.putIfAbsent(blockIndex, () => GlobalKey()),
          child: wrapCentered(
            Padding(
              padding: EdgeInsets.only(bottom: gapAfterBlock(blockIndex)),
              child: MarkdownBody(
                data: blocks[blockIndex],
                selectable: false,
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

    final rawItems = <Widget>[
      for (var blockIndex = 0; blockIndex < blocks.length; blockIndex++)
        KeyedSubtree(
          key: _blockKeys.putIfAbsent(blockIndex, () => GlobalKey()),
          child: RepaintBoundary(
            child: wrapCentered(
              Padding(
                padding: EdgeInsets.only(bottom: gapAfterBlock(blockIndex)),
                child: Text(blocks[blockIndex], style: rawTextStyle),
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

    _pendingRevertTimer?.cancel();
    _pendingRevertTimer = null;
    _rawModeEnteredAt = null;
    _isRawMode = false;
    _blockKeys.removeWhere((index, _) => index >= blocks.length);

    _cachedBlocks = blocks;
    _cachedFormattedItems = formattedItems;
    _cachedRawItems = rawItems;
    _cachedTitleWidget = titleWidget;
    _cachedHasTitle = hasTitle;
    _cachedTitle = title;
    _cachedContent = content;
    _cachedFontFamily = fontFamily;
    _cachedFontSize = fontSize;
    _cachedLineHeight = lineHeight;
    _cachedColorScheme = theme.colorScheme;
    _cachedBrightness = theme.brightness;
  }

  Widget _buildListSubtree() {
    final blocks = _cachedBlocks!;
    final formattedItems = _cachedFormattedItems!;
    final rawItems = _cachedRawItems!;
    final hasTitle = _cachedHasTitle;
    final itemCount = (hasTitle ? 1 : 0) + blocks.length;

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
                  originalOnPressed?.call();
                  _revertToFormatted();
                },
              );
            }
            if (item.type == ContextMenuButtonType.selectAll && !_isRawMode) {
              return item.copyWith(
                onPressed: () {
                  setState(() => _isRawMode = true);
                  _rawModeEnteredAt = DateTime.now();
                  WidgetsBinding.instance.addPostFrameCallback((_) {
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
        child: ScrollConfiguration(
          behavior: _NoGlowScrollBehavior(),
          child: ListView.builder(
            key: const ValueKey('markdown-unified-listview'),
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
            itemCount: itemCount,
            itemBuilder: (context, index) {
              if (hasTitle && index == 0) return _cachedTitleWidget!;
              final blockIndex = hasTitle ? index - 1 : index;
              return _isRawMode
                  ? rawItems[blockIndex]
                  : formattedItems[blockIndex];
            },
          ),
        ),
      ),
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

final RegExp _topLevelListMarkerRe = RegExp(r'^(-|\*|\+)\s|^\d+[.)]\s');
final RegExp _fenceOpenRe = RegExp(r'^\s{0,3}(`{3,}|~{3,})');

bool _isTopLevelListMarkerLine(String line) =>
    _topLevelListMarkerRe.hasMatch(line);

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
