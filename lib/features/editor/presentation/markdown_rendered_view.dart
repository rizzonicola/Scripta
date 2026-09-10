import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_list_view/flutter_list_view.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/markdown_block_splitter.dart';
import '../../../core/utils/syntax_highlighter.dart';
import '../../settings/providers/settings_provider.dart';

/// Vista di sola lettura ("Preview") del contenuto Markdown di una nota.
///
/// LAZY LOADING / VIRTUALIZZAZIONE: il contenuto viene suddiviso in blocchi
/// indipendenti (vedi [MarkdownBlockSplitter]) e renderizzato tramite il
/// pacchetto open source `flutter_list_view` (MIT, di robert-luoqing —
/// https://github.com/robert-luoqing/flutter_list_view, compare
/// automaticamente nella pagina "Licenze open source" dell'app) invece che
/// con `ListView.builder`.
///
/// PERCHÉ NON `ListView.builder`: la vecchia implementazione (vedi storia
/// del file) usava `ListView.builder`, che per liste con altezza degli
/// item NON nota in anticipo (il nostro caso: un blocco Markdown può
/// essere una riga o un blocco di codice di 200 righe) può solo STIMARE
/// l'estensione scrollabile totale finché non ha effettivamente disposto
/// ogni blocco. Durante uno scroll veloce in una nota grande, questa stima
/// viene continuamente corretta man mano che nuovi blocchi vengono
/// disposti, il che può interrompere/alterare la simulazione fisica dello
/// scroll in corso — il sintomo osservato di micro-scatti che impediscono
/// di scendere velocemente (un trascinamento lento, che non innesca mai
/// una vera simulazione "fling", non ne risentiva). Aumentare il buffer di
/// pre-costruzione (`cacheExtent`) riduceva la frequenza del problema ma
/// non lo eliminava in note davvero grandi. `flutter_list_view` risolve
/// questo alla radice: tiene traccia dell'altezza REALE di ogni blocco già
/// disposto (non di una stima) e riusa gli elementi già misurati, quindi
/// l'estensione scrollabile nella zona già visitata è sempre esatta.
///
/// SELEZIONE TESTO: un'UNICA `SelectionArea` copre l'intero documento
/// (titolo incluso): si può trascinare una selezione che attraversi più
/// blocchi/paragrafi senza limitazioni.
///
/// EVIDENZIAZIONE CODICE: precalcolata tutta insieme all'apertura/cambio
/// della nota (vedi [_ensureHighlightCache]) invece che blocco per blocco
/// durante lo scroll, per evitare lavoro sincrono costoso nel thread UI
/// proprio nei frame in cui un blocco di codice entra in vista.
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
  late List<String> _blocks;
  late String _blocksSourceContent;

  // Vedi doc di classe: precalcolo dell'evidenziazione sintattica di tutti
  // i blocchi di codice, fatto una volta sola (non durante lo scroll).
  final Map<int, TextSpan> _highlightCache = {};
  bool? _highlightCacheIsDark;
  double? _highlightCacheFontSize;

  @override
  void initState() {
    super.initState();
    _blocksSourceContent = widget.content;
    _blocks = MarkdownBlockSplitter.split(widget.content);
  }

  @override
  void didUpdateWidget(covariant MarkdownRenderedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Ricalcola i blocchi SOLO quando cambia davvero il contenuto (es.
    // apertura di una nota diversa), non ad ogni rebuild dovuto a
    // tema/impostazioni: lo split è economico ma non ha motivo di essere
    // rifatto se il testo sorgente è lo stesso.
    if (widget.content != _blocksSourceContent) {
      _blocksSourceContent = widget.content;
      _blocks = MarkdownBlockSplitter.split(widget.content);
      // Il contenuto è cambiato: gli indici dei blocchi non corrispondono
      // più a quanto in cache (invalida tutto, verrà ripopolata in build).
      _highlightCache.clear();
    }
  }

  /// Se [block] è per intero un blocco di codice delimitato da ``` o ~~~
  /// (lo split garantisce che un fence non venga mai spezzato tra due
  /// blocchi — vedi `MarkdownBlockSplitter`), estrae linguaggio e codice.
  /// Altrimenti torna `null`.
  ({String language, String code})? _tryParseFencedCode(String block) {
    final lines = block.split('\n');
    if (lines.isEmpty) return null;
    final firstLine = lines.first.trimLeft();
    final openMatch =
        RegExp(r'^(`{3,}|~{3,})\s*(\S*)').firstMatch(firstLine);
    if (openMatch == null) return null;
    final fenceChar = openMatch.group(1)!.substring(0, 1);
    final fenceLen = openMatch.group(1)!.length;
    final language = openMatch.group(2) ?? '';

    final closeRegex =
        RegExp('^(${RegExp.escape(fenceChar)}{$fenceLen,})\\s*\$');
    var closeIndex = -1;
    for (var i = lines.length - 1; i >= 1; i--) {
      if (closeRegex.hasMatch(lines[i].trimLeft())) {
        closeIndex = i;
        break;
      }
    }
    if (closeIndex == -1) return null;

    return (language: language, code: lines.sublist(1, closeIndex).join('\n'));
  }

  /// Precalcola (se non già in cache per il tema/dimensione font correnti)
  /// l'evidenziazione sintattica di TUTTI i blocchi di codice della nota in
  /// un colpo solo. Chiamato da `build()`, non durante lo scroll.
  void _ensureHighlightCache({
    required List<String> blocks,
    required bool isDark,
    required double fontSize,
  }) {
    if (_highlightCacheIsDark == isDark &&
        _highlightCacheFontSize == fontSize &&
        _highlightCache.length ==
            blocks.where((b) => _tryParseFencedCode(b) != null).length) {
      return; // Cache già valida e completa per queste condizioni.
    }

    _highlightCache.clear();
    _highlightCacheIsDark = isDark;
    _highlightCacheFontSize = fontSize;

    final monoStyle = GoogleFonts.jetBrainsMono(
      fontSize: fontSize * 0.9,
      height: 1.55,
      color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
    );

    for (var i = 0; i < blocks.length; i++) {
      final fenced = _tryParseFencedCode(blocks[i]);
      if (fenced == null) continue;
      _highlightCache[i] = ScriptaCodeHighlighter.highlight(
        code: fenced.code,
        language: fenced.language,
        isDark: isDark,
        baseStyle: monoStyle,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final isDark = theme.brightness == Brightness.dark;
    final title = widget.title;

    final baseTextStyle = AppTheme.getTextStyleForFont(
      settings.fontFamily,
      fontSize: settings.fontSize,
      height: settings.lineHeight,
      color: theme.colorScheme.onSurface,
    );

    final inlineCodeStyle = GoogleFonts.jetBrainsMono(
      fontSize: settings.fontSize * 0.9,
      height: 1.4,
      color: theme.colorScheme.primary,
    );

    // Markdown stylesheet tailored to Scripta aesthetics
    final markdownStyleSheet = MarkdownStyleSheet(
      p: baseTextStyle,
      h1: AppTheme.getTextStyleForFont(
        settings.fontFamily,
        fontSize: settings.fontSize * 2.0,
        fontWeight: FontWeight.w800,
        color: theme.colorScheme.onSurface,
        height: 1.3,
      ),
      h2: AppTheme.getTextStyleForFont(
        settings.fontFamily,
        fontSize: settings.fontSize * 1.6,
        fontWeight: FontWeight.w700,
        color: theme.colorScheme.onSurface,
        height: 1.3,
      ),
      h3: AppTheme.getTextStyleForFont(
        settings.fontFamily,
        fontSize: settings.fontSize * 1.3,
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
        settings.fontFamily,
        fontSize: settings.fontSize * 0.95,
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.onSurface,
      ),
      tableBody: baseTextStyle.copyWith(
        fontSize: settings.fontSize * 0.95,
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

    final hasTitle = title.trim().isNotEmpty;
    // Nota senza alcun contenuto: un solo blocco-placeholder, stesso
    // comportamento di prima (nessuna virtualizzazione necessaria/utile per
    // un singolo blocco).
    final blocks = _blocks.isEmpty ? const ['*Nessun contenuto*'] : _blocks;

    // Vedi doc di `_ensureHighlightCache`: precalcola tutta l'evidenziazione
    // sintattica ORA (in questo build, non durante lo scroll) così che i
    // blocchi di codice trovino il risultato già pronto invece di doverlo
    // calcolare al volo mentre l'elemento entra in vista.
    _ensureHighlightCache(
      blocks: blocks,
      isDark: isDark,
      fontSize: settings.fontSize,
    );

    Future<void> onTapLink(String text, String? href, String linkTitle) async {
      if (href != null) {
        final uri = Uri.tryParse(href);
        if (uri != null && await canLaunchUrl(uri)) {
          await launchUrl(uri);
        }
      }
    }

    final itemCount = blocks.length + (hasTitle ? 1 : 0);

    // Padding orizzontale/verticale del documento: non essendoci un
    // parametro `padding` diretto su `FlutterListView` (a differenza di
    // `ListView`), lo applichiamo per-item: 28px orizzontali su ogni
    // blocco (dentro il vincolo di larghezza massima 840), 24px sopra il
    // primo elemento e 64px sotto l'ultimo — stesso risultato visivo di
    // prima.
    Widget centered(Widget child, {required int index}) => Padding(
          padding: EdgeInsets.fromLTRB(
            28,
            index == 0 ? 24 : 0,
            28,
            index == itemCount - 1 ? 64 : 0,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: child,
            ),
          ),
        );

    Widget buildItem(BuildContext context, int index) {
      if (hasTitle && index == 0) {
        return centered(
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: AppTheme.getTextStyleForFont(
                    settings.fontFamily,
                    fontSize: settings.fontSize * 2.2,
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
              ],
            ),
          ),
          index: index,
        );
      }

      final blockIndex = index - (hasTitle ? 1 : 0);
      return centered(
        MarkdownBody(
          data: blocks[blockIndex],
          selectable: false, // Gestita dalla SelectionArea del documento
          styleSheet: markdownStyleSheet,
          builders: {
            'pre': _CodeBlockBuilder(
              fontSize: settings.fontSize,
              // Risultato già pronto da `_ensureHighlightCache`: se
              // presente, `CodeBlockWidget` lo userà direttamente senza
              // ricalcolarlo durante lo scroll (vedi doc di classe).
              precomputedHighlight: _highlightCache[blockIndex],
            ),
            'code': _InlineCodeBuilder(
              style: inlineCodeStyle,
              isDark: isDark,
              primaryColor: theme.colorScheme.primary,
            ),
          },
          onTapLink: onTapLink,
        ),
        index: index,
      );
    }

    // Un'UNICA `SelectionArea` copre l'intero documento (selezione fluida
    // anche tra blocchi diversi): nessun compromesso su questo.
    return SelectionArea(
      child: FlutterListView(
        delegate: FlutterListViewDelegate(
          buildItem,
          childCount: itemCount,
          // Chiave stabile per blocco: permette a `flutter_list_view` di
          // riconoscere lo stesso blocco quando viene ricreato dopo essere
          // uscito e rientrato dalla finestra visibile (riuso corretto).
          onItemKey: (index) => 'md_block_$index',
        ),
      ),
    );
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  final double fontSize;
  final TextSpan? precomputedHighlight;

  _CodeBlockBuilder({required this.fontSize, this.precomputedHighlight});

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
      precomputedHighlight: precomputedHighlight,
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
  // Evidenziazione già calcolata da `_MarkdownRenderedViewState` PRIMA dello
  // scroll (vedi `_ensureHighlightCache`). Se presente ed valida per il
  // tema corrente, viene usata direttamente: evita di rifare la
  // tokenizzazione del codice nel frame in cui questo blocco entra nel
  // buffer di pre-caricamento di `flutter_list_view` durante lo scroll — la
  // causa dei micro-scatti nelle note grandi con molto codice.
  // `_highlightedTextCache` resta comunque come rete di sicurezza per gli
  // eventuali casi non coperti.
  final TextSpan? precomputedHighlight;

  const CodeBlockWidget({
    super.key,
    required this.code,
    required this.language,
    required this.fontSize,
    this.precomputedHighlight,
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
    // Percorso rapido: risultato già pronto dal precalcolo a livello di
    // nota (vedi doc di `precomputedHighlight`) — nessuna tokenizzazione
    // da fare qui, quindi nessun rischio di jank durante lo scroll.
    if (widget.precomputedHighlight != null) {
      _highlightedTextCache = widget.precomputedHighlight;
      _highlightedForIsDark = isDark;
      return widget.precomputedHighlight!;
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
