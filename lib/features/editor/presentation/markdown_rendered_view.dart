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
import '../../../core/utils/syntax_highlighter.dart';
import '../../settings/providers/settings_provider.dart';

/// Vista di sola lettura di una nota Markdown.
///
/// OTTIMIZZAZIONE PERFORMANCE (note di grandi dimensioni):
/// `flutter_markdown_plus` riparsa `data` in un AST e ricostruisce l'intero
/// albero di widget ogni volta che `build()` viene invocato — non fa alcun
/// caching proprio. Nell'albero originale, `build()` veniva rieseguito ad
/// ogni piccolo rebuild "collaterale" del genitore (toggle del focus mode,
/// cambio di un'impostazione non correlata al rendering come la lingua o
/// l'intensità haptic, animazioni), anche quando titolo/contenuto della nota
/// non erano affatto cambiati: su una nota lunga, questo produceva un
/// parsing + relayout Markdown completo più volte al secondo → il
/// lag/freeze osservato.
///
/// La correzione, senza introdurre lazy loading o paginazione del testo:
///  1. Si osservano da Riverpod SOLO i campi di `AppSettings` che influenzano
///     realmente il rendering (font/size/line-height), tramite `.select`,
///     invece dell'intero oggetto impostazioni.
///  2. Il sottoalbero renderizzato (titolo + `MarkdownBody`) viene
///     memorizzato in `State` e ricostruito SOLO quando uno degli input che
///     lo determinano (contenuto, titolo, font, tema) è realmente cambiato
///     rispetto all'ultima build. Se `build()` viene rieseguito per un
///     motivo estraneo, si restituisce la STESSA istanza di widget già
///     costruita in precedenza: Flutter la riconosce (`identical`) e salta
///     interamente rebuild/relayout/repaint di quel sottoalbero, senza
///     bisogno di spezzettare o ritardare il rendering del testo.
///  3. Il sottoalbero è avvolto in un `RepaintBoundary`, così viene isolato
///     sul proprio layer grafico: qualunque repaint circostante (cursore,
///     hover, animazioni della toolbar, ecc.) non forza mai un repaint dei
///     pixel già renderizzati della nota.
///  4. Il contenuto è renderizzato con `ListView.builder`, un blocco
///     Markdown di primo livello per elemento (vedi
///     `_splitMarkdownIntoBlocks`), invece di un unico `MarkdownBody`
///     dentro una `Column`/`SingleChildScrollView` non virtualizzata: su
///     note molto lunghe, quest'ultima è la causa reale del lag durante lo
///     SCROLL (Flutter deve comunque layoutare/dipingere anche i blocchi
///     fuori schermo). Il testo resta parsato per intero, in un solo
///     passaggio, prima di essere suddiviso: non è lazy loading né
///     paginazione del contenuto, solo virtualizzazione del rendering dei
///     blocchi già pronti.
///
/// Il ripristino "a caldo" resta corretto: quando l'utente passa in modalità
/// modifica e poi torna in visualizzazione, `NoteEditorPane` smonta questo
/// widget (vedi `AnimatedSwitcher`/`KeyedSubtree` in note_editor_pane.dart),
/// quindi lo `State` — e con esso la cache — viene ricreato da zero e il
/// testo più recente viene renderizzato correttamente; da quel momento in
/// poi la cache torna a garantire fluidità sui rebuild superflui successivi.
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
  // Sottoalbero già costruito (titolo + MarkdownBody) e gli input esatti che
  // lo hanno prodotto. Finché questi input non cambiano, `build()` restituisce
  // sempre questa stessa istanza invece di ricostruire/riparsare da capo.
  Widget? _cachedSubtree;
  String? _cachedTitle;
  String? _cachedContent;
  String? _cachedFontFamily;
  double? _cachedFontSize;
  double? _cachedLineHeight;
  ColorScheme? _cachedColorScheme;
  Brightness? _cachedBrightness;

  @override
  void dispose() {
    // Rilascia esplicitamente i riferimenti pesanti (testo della nota e
    // sottoalbero renderizzato) non appena la vista viene smontata, così non
    // restano agganciati più a lungo del necessario in attesa della GC.
    _cachedSubtree = null;
    _cachedContent = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // `.select` sui SOLI campi che influenzano il rendering del testo: un
    // cambio di lingua, tema (scuro/chiaro è già gestito da Theme.of sotto),
    // colore d'accento dell'app o intensità haptic NON invalida la cache e
    // NON forza un nuovo parsing del Markdown.
    final (fontFamily, fontSize, lineHeight) = ref.watch(
      settingsProvider.select((s) => (s.fontFamily, s.fontSize, s.lineHeight)),
    );

    final canReuseCache = _cachedSubtree != null &&
        _cachedTitle == widget.title &&
        _cachedContent == widget.content &&
        _cachedFontFamily == fontFamily &&
        _cachedFontSize == fontSize &&
        _cachedLineHeight == lineHeight &&
        _cachedColorScheme == theme.colorScheme &&
        _cachedBrightness == theme.brightness;

    if (canReuseCache) {
      return _cachedSubtree!;
    }

    final subtree = _buildSubtree(
      context: context,
      theme: theme,
      fontFamily: fontFamily,
      fontSize: fontSize,
      lineHeight: lineHeight,
    );

    _cachedSubtree = subtree;
    _cachedTitle = widget.title;
    _cachedContent = widget.content;
    _cachedFontFamily = fontFamily;
    _cachedFontSize = fontSize;
    _cachedLineHeight = lineHeight;
    _cachedColorScheme = theme.colorScheme;
    _cachedBrightness = theme.brightness;

    return subtree;
  }

  Widget _buildSubtree({
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

    // Markdown stylesheet tailored to Scripta aesthetics
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

    // Suddivisione in blocchi di primo livello: il testo è già interamente
    // in memoria e viene attraversato una sola volta qui (nessun
    // caricamento incrementale, nessuna paginazione) — serve solo a dare a
    // ListView.builder unità discrete da costruire/disegnare una alla
    // volta, invece dell'intero documento in un'unica Column non
    // virtualizzata (il vero collo di bottiglia per lo scroll su note
    // molto lunghe: senza virtualizzazione, Flutter deve layoutare e
    // dipingere anche i blocchi fuori schermo).
    final effectiveContent = content.isEmpty ? '*Nessun contenuto*' : content;
    final blocks = _splitMarkdownIntoBlocks(effectiveContent);
    final hasTitle = title.trim().isNotEmpty;
    final itemCount = (hasTitle ? 1 : 0) + blocks.length;

    Widget wrapCentered(Widget child) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: child,
          ),
        );

    Widget buildItem(BuildContext context, int index) {
      if (hasTitle && index == 0) {
        return wrapCentered(
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
        );
      }

      final blockIndex = hasTitle ? index - 1 : index;
      final isLastBlock = blockIndex == blocks.length - 1;

      return wrapCentered(
        Padding(
          // Riproduce lo spacing verticale che, in un documento renderizzato
          // in blocco unico, `MarkdownStyleSheet.blockSpacing` applica
          // automaticamente tra un blocco e il successivo.
          padding: EdgeInsets.only(
            bottom: isLastBlock ? 0 : markdownStyleSheet.blockSpacing,
          ),
          child: MarkdownBody(
            data: blocks[blockIndex],
            selectable: false, // Gestita da SelectionArea nel genitore
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
      );
    }

    // RepaintBoundary: isola il layer grafico della nota renderizzata da
    // quello del resto dell'interfaccia (toolbar, cursore, animazioni di
    // focus mode, ecc.), così un repaint "vicino" non forza mai Flutter a
    // ridisegnare anche questi pixel. `ListView.builder` aggiunge inoltre
    // automaticamente un `RepaintBoundary` per ciascun blocco costruito
    // (`addRepaintBoundaries`, attivo di default): lo scroll di una nota
    // enorme non richiede quindi mai di ridisegnare un unico layer gigante,
    // ma solo di ricompositare i pochi layer già rasterizzati dei blocchi
    // realmente visibili.
    return RepaintBoundary(
      child: SelectionArea(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
          itemCount: itemCount,
          itemBuilder: buildItem,
        ),
      ),
    );
  }
}

/// Suddivide una stringa Markdown nei suoi blocchi di primo livello
/// (separati da una riga vuota), preservando due casi che una divisione
/// ingenua per riga vuota romperebbe:
///  - i fenced code block (``` o ~~~) NON vengono mai spezzati, anche se
///    contengono righe vuote al loro interno;
///  - gli elementi di una lista puntata/numerata o di una blockquote
///    "loose" (separati da singole righe vuote) restano nello stesso
///    blocco, così numerazione e aspetto visivo restano identici a un
///    rendering monolitico.
///
/// Non introduce alcun caricamento incrementale né paginazione: il testo è
/// già interamente disponibile in memoria e viene scandito linearmente una
/// sola volta; il risultato serve solo a dare a `ListView.builder` unità
/// discrete su cui applicare la virtualizzazione del rendering.
List<String> _splitMarkdownIntoBlocks(String content) {
  final lines = content.split('\n');
  final blocks = <String>[];
  final buffer = <String>[];

  final fenceOpenRe = RegExp(r'^\s{0,3}(`{3,}|~{3,})');
  String? fenceMarker;

  bool isListOrQuoteLine(String line) {
    final trimmed = line.trimLeft();
    final indented = line.startsWith('  ') || line.startsWith('\t');
    return indented ||
        trimmed.startsWith('- ') ||
        trimmed.startsWith('* ') ||
        trimmed.startsWith('+ ') ||
        trimmed.startsWith('> ') ||
        RegExp(r'^\d+[.)]\s').hasMatch(trimmed);
  }

  bool bufferEndsInListOrQuote() {
    for (var i = buffer.length - 1; i >= 0; i--) {
      if (buffer[i].trim().isEmpty) continue;
      return isListOrQuoteLine(buffer[i]);
    }
    return false;
  }

  bool nextNonBlankContinuesListOrQuote(int fromIndex) {
    for (var j = fromIndex; j < lines.length; j++) {
      if (lines[j].trim().isEmpty) continue;
      return isListOrQuoteLine(lines[j]);
    }
    return false;
  }

  void flushBuffer() {
    if (buffer.isEmpty) return;
    final text = buffer.join('\n').trimRight();
    if (text.trim().isNotEmpty) blocks.add(text);
    buffer.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];

    if (fenceMarker != null) {
      buffer.add(line);
      if (line.trimLeft().startsWith(fenceMarker)) {
        fenceMarker = null;
      }
      continue;
    }

    final fenceMatch = fenceOpenRe.firstMatch(line);
    if (fenceMatch != null) {
      fenceMarker = fenceMatch.group(1);
      buffer.add(line);
      continue;
    }

    if (line.trim().isEmpty) {
      if (buffer.isEmpty) continue;
      if (bufferEndsInListOrQuote() &&
          nextNonBlankContinuesListOrQuote(i + 1)) {
        // Riga vuota "interna" a una lista/blockquote loose: resta nel
        // blocco corrente per non spezzarne numerazione/aspetto in più
        // widget separati.
        buffer.add(line);
        continue;
      }
      flushBuffer();
      continue;
    }

    buffer.add(line);
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
