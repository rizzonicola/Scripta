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
import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/haptics_helper.dart';
import '../../../core/utils/syntax_highlighter.dart';
import '../../settings/providers/settings_provider.dart';

/// Vista di sola lettura di una nota, renderizzata SEMPRE in Markdown
/// formattato: non esiste più una modalità "testo grezzo" separata.
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

  static const double _kIdleCacheExtent = 800.0;
  static const double _kActiveSelectionCacheExtent = 6000.0;
  static const double _kFullDocumentCacheExtent = 1.0e7;

  bool _hasActiveSelection = false;
  bool _forceFullRealization = false;

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

  List<String>? _cachedBlocks;
  String? _cachedContent;

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

  void _handleSelectionChanged(SelectedContent? content) {
    final isEmpty = content == null || content.plainText.isEmpty;

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

    return DefaultSelectionStyle(
      selectionColor: theme.colorScheme.primary.withValues(alpha: 0.35),
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
