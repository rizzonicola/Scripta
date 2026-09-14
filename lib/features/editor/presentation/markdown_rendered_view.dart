import 'dart:async';
import 'dart:math' as math;
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

// ===========================================================================
// 1. STATI LOGICI DEI BLOCCHI (Pattern Matching Dart 3)
// ===========================================================================

/// I 3 stati logici possibili in cui può trovarsi qualunque blocco del documento.
sealed class BlockSelectionState {
  const BlockSelectionState();

  bool get isSelected => this is! BlockUnselected;
  bool get isFullySelected => this is BlockFullySelected;
  bool get isPartiallySelected => this is BlockPartiallySelected;
}

/// Stato 1: Non selezionato di niente.
final class BlockUnselected extends BlockSelectionState {
  const BlockUnselected();

  @override
  String toString() => 'BlockUnselected';
}

/// Stato 2: Totalmente selezionato.
final class BlockFullySelected extends BlockSelectionState {
  const BlockFullySelected();

  @override
  String toString() => 'BlockFullySelected';
}

/// Stato 3: Parzialmente selezionato con tracciamento esatto dal carattere [start]
/// al carattere [end] (inclusi gli spazi).
final class BlockPartiallySelected extends BlockSelectionState {
  final int start;
  final int end;

  const BlockPartiallySelected({
    required this.start,
    required this.end,
  }) : assert(start >= 0),
       assert(end > start);

  int get length => end - start;

  @override
  String toString() => 'BlockPartiallySelected(chars: $start..$end)';
}

// ===========================================================================
// 2. MODELLO LOGICO DEL DOCUMENTO E INDICIZZAZIONE OFFSET
// ===========================================================================

/// Singolo blocco logico del documento con i suoi confini assoluti nel testo complessivo.
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

  /// Determina quale dei 3 stati si applica a questo blocco in base all'intervallo
  /// globale di selezione [globalStart, globalEnd].
  BlockSelectionState getSelectionState(int? globalStart, int? globalEnd) {
    if (globalStart == null || globalEnd == null || globalStart >= globalEnd) {
      return const BlockUnselected();
    }
    // Nessuna intersezione (blocco completamente prima o dopo la selezione)
    if (globalEnd <= startOffset || globalStart >= endOffset) {
      return const BlockUnselected();
    }
    // Completamente coperto
    if (globalStart <= startOffset && globalEnd >= endOffset) {
      return const BlockFullySelected();
    }
    // Parzialmente selezionato: calcolo dell'offset relativo al singolo carattere/spazio
    final localStart = math.max(0, globalStart - startOffset);
    final localEnd = math.min(length, globalEnd - startOffset);

    if (localStart == 0 && localEnd == length) {
      return const BlockFullySelected();
    }
    if (localStart >= localEnd) {
      return const BlockUnselected();
    }
    return BlockPartiallySelected(start: localStart, end: localEnd);
  }
}

/// Documento indicizzato: unisce titolo e corpo Markdown e permette ricerche di offset.
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

    // Indicizzazione Titolo
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

    // Indicizzazione Blocchi Markdown
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

  /// Converte il testo selezionato graficamente a schermo in un range di offset logici.
  (int, int)? findRangeForPlainText(String plainText) {
    if (plainText.isEmpty) return null;

    // 1. Ricerca diretta per sottostringa esatta
    final directIndex = fullText.indexOf(plainText);
    if (directIndex != -1) {
      return (directIndex, directIndex + plainText.length);
    }

    // 2. Ricerca con trim (tolleranza a spaziature di riga terminali)
    final trimmed = plainText.trim();
    final trimmedIndex = fullText.indexOf(trimmed);
    if (trimmedIndex != -1) {
      return (trimmedIndex, trimmedIndex + trimmed.length);
    }

    // 3. Fallback per selezioni multilinea complesse
    if (trimmed.length > 20) {
      final head = trimmed.substring(0, math.min(15, trimmed.length));
      final tail = trimmed.substring(math.max(0, trimmed.length - 15));
      final hIdx = fullText.indexOf(head);
      if (hIdx != -1) {
        final tIdx = fullText.indexOf(tail, hIdx);
        if (tIdx != -1) {
          return (hIdx, tIdx + tail.length);
        }
      }
    }

    return null;
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

// ===========================================================================
// 3. VISTA PRINCIPALE
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
  final FocusNode _selectionFocusNode = FocusNode(debugLabel: 'markdown-selection');
  final GlobalKey<SelectableRegionState> _selectableRegionKey =
      GlobalKey<SelectableRegionState>();

  // CacheExtent fissa e stabile per mantenere 60/120 fps senza salti di memoria
  static const double _kStableCacheExtent = 600.0;

  late LogicalDocument _document;
  TextSelection? _logicalSelection;

  // Caching stili Markdown
  (ThemeData, String, double, double)? _cachedStyleKey;
  late MarkdownStyleSheet _markdownStyleSheet;
  late MarkdownStyleSheet _selectedMarkdownStyleSheet;
  late TextStyle _inlineCodeStyle;
  late TextStyle _titleTextStyle;
  late bool _isDark;
  late Color _primaryColor;
  late Color _selectionColor;
  late double _fontSize;

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

  bool get _hasLogicalSelection =>
      _logicalSelection != null &&
      !_logicalSelection!.isCollapsed &&
      _logicalSelection!.isValid;

  int? get _selectionStart => _hasLogicalSelection ? _logicalSelection!.start : null;
  int? get _selectionEnd => _hasLogicalSelection ? _logicalSelection!.end : null;

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
        _logicalSelection = null;
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _selectionFocusNode.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Sincronizzazione Selezione Visiva <-> Selezione Logica
  // -------------------------------------------------------------------------

  void _handleSelectionChanged(SelectedContent? content) {
    final isEmpty = content == null || content.plainText.isEmpty;
    HapticsHelper.reportSelectionState(isCollapsed: isEmpty);

    if (isEmpty) {
      if (_logicalSelection != null) {
        setState(() {
          _logicalSelection = null;
        });
      }
      return;
    }

    // Traduce la porzione di testo selezionata a schermo in offset logici
    final range = _document.findRangeForPlainText(content.plainText);
    if (range != null) {
      final newSelection = TextSelection(baseOffset: range.$1, extentOffset: range.$2);
      if (_logicalSelection != newSelection) {
        setState(() {
          _logicalSelection = newSelection;
        });
      }
    }
  }

  /// "Seleziona Tutto" eseguito a livello logico: nessun freeze, O(1).
  void _performFullDocumentSelectAll() {
    if (_document.fullText.isEmpty) return;

    setState(() {
      _logicalSelection = TextSelection(
        baseOffset: 0,
        extentOffset: _document.fullText.length,
      );
    });

    HapticsHelper.reportSelectionState(isCollapsed: false);

    // Se l'utente era sceso in basso, auto-scroll fluido verso l'inizio
    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// Copia il testo garantendo il prelievo dal testo logico completo
  Future<void> _copySelection() async {
    String textToCopy = '';

    if (_hasLogicalSelection) {
      final s = _selectionStart!.clamp(0, _document.fullText.length);
      final e = _selectionEnd!.clamp(0, _document.fullText.length);
      if (s < e) {
        textToCopy = _document.fullText.substring(s, e);
      }
    } else {
      final fallback = _selectableRegionKey.currentState?.getSelectedContent();
      if (fallback != null) {
        textToCopy = fallback.plainText;
      }
    }

    if (textToCopy.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: textToCopy));
      HapticsHelper.reportSelectionState(isCollapsed: true);
    }
  }

  // -------------------------------------------------------------------------
  // Stili e Configurazioni
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

    // Stile normale non selezionato
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

    // Stile totalmente selezionato: evidenziazione visiva naturale dietro ogni glifo e riga
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

    return DefaultSelectionStyle(
      selectionColor: _selectionColor,
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
              onInvoke: (_) {
                _performFullDocumentSelectAll();
                return null;
              },
            ),
            CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
              onInvoke: (_) {
                _copySelection();
                return null;
              },
            ),
          },
          // L'esterno mantiene SelectableRegion per l'interazione grafica nativa
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
                      _copySelection();
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
              behavior: const _NoGlowScrollBehavior(),
              child: ListView.builder(
                key: const ValueKey('markdown-formatted-listview'),
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
                cacheExtent: _kStableCacheExtent,
                itemCount: _document.blocks.length,
                itemBuilder: (context, index) {
                  final block = _document.blocks[index];
                  // Risoluzione istantanea dello stato del blocco tra i 3 stati
                  final blockState = block.getSelectionState(
                    _selectionStart,
                    _selectionEnd,
                  );

                  if (block.isTitle) {
                    return _buildTitleWidget(
                      theme: theme,
                      block: block,
                      selectionState: blockState,
                    );
                  }

                  return _buildMarkdownBlockWidget(
                    block: block,
                    selectionState: blockState,
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
    required BlockSelectionState selectionState,
  }) {
    // Reindirizzamento visivo della selezione sul titolo
    final Widget titleWidget = switch (selectionState) {
      BlockUnselected() => Text(
          block.text,
          style: _titleTextStyle,
        ),
      BlockFullySelected() => Text(
          block.text,
          style: _titleTextStyle.copyWith(backgroundColor: _selectionColor),
        ),
      BlockPartiallySelected(:final start, :final end) => Text.rich(
          TextSpan(
            style: _titleTextStyle,
            children: [
              if (start > 0)
                TextSpan(text: block.text.substring(0, start)),
              TextSpan(
                text: block.text.substring(start, end),
                style: TextStyle(backgroundColor: _selectionColor),
              ),
              if (end < block.text.length)
                TextSpan(text: block.text.substring(end)),
            ],
          ),
        ),
    };

    return Align(
      key: const ValueKey('rendered-block-title'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
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
    );
  }

  Widget _buildMarkdownBlockWidget({
    required DocumentBlock block,
    required BlockSelectionState selectionState,
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
            child: _MarkdownBlockView(
              blockText: block.text,
              selectionState: selectionState,
              normalStyleSheet: _markdownStyleSheet,
              selectedStyleSheet: _selectedMarkdownStyleSheet,
              inlineCodeStyle: _inlineCodeStyle,
              fontSize: _fontSize,
              isDark: _isDark,
              primaryColor: _primaryColor,
              selectionColor: _selectionColor,
            ),
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// 4. RENDER DEL SINGOLO BLOCCO CON REINDIRIZZAMENTO VISIVO
// ===========================================================================

class _MarkdownBlockView extends StatefulWidget {
  final String blockText;
  final BlockSelectionState selectionState;
  final MarkdownStyleSheet normalStyleSheet;
  final MarkdownStyleSheet selectedStyleSheet;
  final TextStyle inlineCodeStyle;
  final double fontSize;
  final bool isDark;
  final Color primaryColor;
  final Color selectionColor;

  const _MarkdownBlockView({
    super.key,
    required this.blockText,
    required this.selectionState,
    required this.normalStyleSheet,
    required this.selectedStyleSheet,
    required this.inlineCodeStyle,
    required this.fontSize,
    required this.isDark,
    required this.primaryColor,
    required this.selectionColor,
  });

  @override
  State<_MarkdownBlockView> createState() => _MarkdownBlockViewState();
}

class _MarkdownBlockViewState extends State<_MarkdownBlockView> {
  Widget? _cachedChild;
  String? _cachedText;
  BlockSelectionState? _cachedState;
  double? _cachedFontSize;
  bool? _cachedIsDark;

  bool get _cacheHit =>
      _cachedChild != null &&
      _cachedText == widget.blockText &&
      _cachedState == widget.selectionState &&
      _cachedFontSize == widget.fontSize &&
      _cachedIsDark == widget.isDark;

  @override
  Widget build(BuildContext context) {
    if (_cacheHit) {
      return _cachedChild!;
    }

    _cachedText = widget.blockText;
    _cachedState = widget.selectionState;
    _cachedFontSize = widget.fontSize;
    _cachedIsDark = widget.isDark;

    // Se il blocco è parzialmente selezionato e privo di sintassi markdown complessa
    // (es. paragrafo semplice), applichiamo la precisione al singolo carattere/spazio
    if (widget.selectionState is BlockPartiallySelected) {
      final partial = widget.selectionState as BlockPartiallySelected;
      final s = partial.start;
      final e = partial.end;

      if (!widget.blockText.startsWith('```') &&
          !widget.blockText.startsWith('#') &&
          !widget.blockText.startsWith('-') &&
          !widget.blockText.startsWith('|')) {
        _cachedChild = Text.rich(
          TextSpan(
            style: widget.normalStyleSheet.p,
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
        return _cachedChild!;
      }
    }

    // Altrimenti renderizziamo con MarkdownBody usando il foglio di stile
    // appropriato (normale o interamente evidenziato)
    final effectiveSheet = widget.selectionState.isFullySelected
        ? widget.selectedStyleSheet
        : widget.normalStyleSheet;

    _cachedChild = MarkdownBody(
      data: widget.blockText,
      selectable: false,
      styleSheet: effectiveSheet,
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
          selectionState: widget.selectionState,
          selectionColor: widget.selectionColor,
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
  final BlockSelectionState selectionState;
  final Color selectionColor;

  _CodeBlockBuilder({
    required this.inlineCodeStyle,
    required this.fontSize,
    required this.isDark,
    required this.selectionState,
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

    // Gestione dei 3 stati per il testo del blocco codice
    Widget codeContentWidget;
    switch (selectionState) {
      case BlockUnselected():
        codeContentWidget = Text(
          isMultiline ? text.trimRight() : text,
          style: isMultiline ? codeStyle : inlineCodeStyle,
        );
      case BlockFullySelected():
        codeContentWidget = Text(
          isMultiline ? text.trimRight() : text,
          style: (isMultiline ? codeStyle : inlineCodeStyle)
              .copyWith(backgroundColor: selectionColor),
        );
      case BlockPartiallySelected(:final start, :final end):
        final cleanText = isMultiline ? text.trimRight() : text;
        final s = math.min(start, cleanText.length);
        final e = math.min(end, cleanText.length);
        if (s < e) {
          codeContentWidget = Text.rich(
            TextSpan(
              style: isMultiline ? codeStyle : inlineCodeStyle,
              children: [
                if (s > 0)
                  TextSpan(text: cleanText.substring(0, s)),
                TextSpan(
                  text: cleanText.substring(s, e),
                  style: TextStyle(backgroundColor: selectionColor),
                ),
                if (e < cleanText.length)
                  TextSpan(text: cleanText.substring(e)),
              ],
            ),
          );
        } else {
          codeContentWidget = Text(
            cleanText,
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
          child: codeContentWidget,
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEFEFEF),
        borderRadius: BorderRadius.circular(4),
      ),
      child: codeContentWidget,
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
