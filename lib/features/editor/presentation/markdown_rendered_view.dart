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

/// Vista di sola lettura di una nota Markdown con supporto a selezione fluida nativa.
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

  final TextEditingController _rawTextController = TextEditingController();
  final FocusNode _rawFocusNode = FocusNode();
  final GlobalKey<EditableTextState> _rawEditableTextKey =
      GlobalKey<EditableTextState>();
  TextSelection? _pendingRawSelection;
  double? _lastPointerGlobalY;

  bool _isRawMode = false;
  Timer? _revertTimer;

  List<String>? _cachedBlocks;
  String? _cachedContent;

  String get _fullText => widget.title.trim().isNotEmpty
      ? "${widget.title}\n\n${widget.content}"
      : widget.content;

  @override
  void dispose() {
    _revertTimer?.cancel();
    _scrollController.dispose();
    _rawTextController.dispose();
    _rawFocusNode.dispose();
    super.dispose();
  }

  TextSelection? _estimateRawSelection(String fullText, String? selectedText) {
    final word = selectedText?.trim();
    if (word == null || word.isEmpty) return null;

    final matches = <int>[];
    var searchStart = 0;
    while (true) {
      final idx = fullText.indexOf(word, searchStart);
      if (idx == -1) break;
      matches.add(idx);
      searchStart = idx + word.length;
    }
    if (matches.isEmpty) return null;

    var bestIndex = matches.first;
    if (matches.length > 1) {
      final hasExtent = _scrollController.hasClients &&
          _scrollController.position.maxScrollExtent > 0;
      final ratio = hasExtent
          ? (_scrollController.offset /
                  _scrollController.position.maxScrollExtent)
              .clamp(0.0, 1.0)
          : 0.0;
      final target = (fullText.length * ratio).round();
      bestIndex = matches.reduce(
        (a, b) => (a - target).abs() <= (b - target).abs() ? a : b,
      );
    }

    return TextSelection(
      baseOffset: bestIndex,
      extentOffset: bestIndex + word.length,
    );
  }

  void _switchToRawMode({String? selectedText}) {
    if (_isRawMode) return;
    final offset = _scrollController.hasClients ? _scrollController.offset : 0.0;
    final fullText = _fullText;
    final fingerY = _lastPointerGlobalY;

    if (_rawTextController.text != fullText) {
      _rawTextController.text = fullText;
    }
    _pendingRawSelection = _estimateRawSelection(fullText, selectedText);

    setState(() {
      _isRawMode = true;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(offset);
      }

      final pending = _pendingRawSelection;
      if (pending == null) return;

      _rawFocusNode.requestFocus();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _rawTextController.selection = pending;
        _pendingRawSelection = null;

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final editableState = _rawEditableTextKey.currentState;
          final renderEditable = editableState?.renderEditable;

          if (renderEditable != null &&
              fingerY != null &&
              _scrollController.hasClients) {
            final caretRect = renderEditable.getLocalRectForCaret(
              TextPosition(offset: pending.baseOffset),
            );
            final currentGlobalTop =
                renderEditable.localToGlobal(caretRect.topLeft).dy;
            final delta = currentGlobalTop - fingerY;
            if (delta.abs() > 0.5) {
              final position = _scrollController.position;
              final target = (_scrollController.offset + delta)
                  .clamp(position.minScrollExtent, position.maxScrollExtent);
              _scrollController.jumpTo(target);
            }
          } else {
            editableState?.bringIntoView(TextPosition(offset: pending.baseOffset));
          }

          editableState?.showToolbar();
          _lastPointerGlobalY = null;
        });
      });
    });
  }

  void _revertToFormatted() {
    if (!_isRawMode) return;
    _revertTimer?.cancel();
    final offset = _scrollController.hasClients ? _scrollController.offset : 0.0;
    _rawEditableTextKey.currentState?.hideToolbar();
    _rawFocusNode.unfocus();

    setState(() {
      _isRawMode = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(offset);
      }
    });
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
      _rawTextController.text = _fullText;
    }

    return PopScope(
      // Se siamo in Raw Mode, canPop è false (intercetta il gesto/tasto indietro per tornare in Formatted).
      // Se siamo già in Formatted View, canPop è true e Flutter esegue la chiusura nativa della pagina.
      canPop: !_isRawMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_isRawMode) {
          _revertToFormatted();
        }
      },
      child: _isRawMode
          ? _buildRawView(theme, fontSize, lineHeight)
          : _buildFormattedView(theme, fontFamily, fontSize, lineHeight),
    );
  }

  Widget _buildRawView(ThemeData theme, double fontSize, double lineHeight) {
    final monoStyle = GoogleFonts.jetBrainsMono(
      fontSize: fontSize * 0.95,
      height: lineHeight,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
    );

    return ScrollConfiguration(
      behavior: _NoGlowScrollBehavior(),
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: SizedBox(
              width: double.infinity,
              child: EditableText(
                key: _rawEditableTextKey,
                controller: _rawTextController,
                focusNode: _rawFocusNode,
                readOnly: true,
                enableInteractiveSelection: true,
                showCursor: false,
                showSelectionHandles: true,
                maxLines: null,
                style: monoStyle,
                cursorColor: theme.colorScheme.primary,
                backgroundCursorColor: theme.colorScheme.primary,
                selectionColor:
                    theme.colorScheme.primary.withValues(alpha: 0.35),
                selectionControls: materialTextSelectionHandleControls,
                contextMenuBuilder: (context, editableTextState) {
                  return AdaptiveTextSelectionToolbar.editableText(
                    editableTextState: editableTextState,
                  );
                },
                onSelectionChanged: (selection, cause) {
                  HapticsHelper.reportSelectionState(
                      isCollapsed: selection.isCollapsed);
                  if (selection.isCollapsed) {
                    _revertTimer?.cancel();
                    _revertTimer = Timer(const Duration(seconds: 3), () {
                      if (mounted && _isRawMode) {
                        _revertToFormatted();
                      }
                    });
                  } else {
                    _revertTimer?.cancel();
                  }
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFormattedView(
      ThemeData theme, String fontFamily, double fontSize, double lineHeight) {
    final blocks = _cachedBlocks!;
    final hasTitle = widget.title.trim().isNotEmpty;
    final itemCount = (hasTitle ? 1 : 0) + blocks.length;

    return Listener(
      onPointerDown: (event) => _lastPointerGlobalY = event.position.dy,
      child: SelectionArea(
        onSelectionChanged: (content) {
          if (content != null && content.plainText.isNotEmpty) {
            _switchToRawMode(selectedText: content.plainText);
          }
        },
        child: ScrollConfiguration(
          behavior: _NoGlowScrollBehavior(),
          child: ListView.builder(
            key: const ValueKey('markdown-formatted-listview'),
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
            itemCount: itemCount,
            itemBuilder: (context, index) {
              if (hasTitle && index == 0) {
                return _buildTitleWidget(theme, fontFamily, fontSize);
              }
              final blockIndex = hasTitle ? index - 1 : index;
              return _buildMarkdownBlock(
                context,
                blocks[blockIndex],
                theme,
                fontFamily,
                fontSize,
                lineHeight,
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTitleWidget(
      ThemeData theme, String fontFamily, double fontSize) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
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
      ),
    );
  }

  Widget _buildMarkdownBlock(
    BuildContext context,
    String blockText,
    ThemeData theme,
    String fontFamily,
    double fontSize,
    double lineHeight,
  ) {
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

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: MarkdownBody(
              data: blockText,
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

