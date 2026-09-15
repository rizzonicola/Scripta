import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/theme/app_theme.dart';
import '../../settings/providers/settings_provider.dart';
import 'markdown_quill/divider_embed.dart';
import 'markdown_quill/markdown_delta_converter.dart';
import 'markdown_quill/table_embed.dart';

/// Vista di sola lettura di una nota, renderizzata SEMPRE in Markdown
/// formattato.
///
/// ARCHITETTURA — SELEZIONE NATIVA SU UN DOCUMENTO UNICO
/// ---------------------------------------------------------------------
/// A differenza della versione precedente (motore di selezione "logico"
/// scritto a mano sopra una `ListView` virtualizzata, con doppi invisibili
/// e hit-test custom — vedi la cronologia del file per i dettagli di
/// quell'approccio e perché è stato abbandonato), questa vista converte il
/// Markdown della nota in un [quill.Document] — la struttura dati nativa di
/// `flutter_quill` — e lo mostra con un singolo [quill.QuillEditor] in
/// `readOnly: true`.
///
/// Non c'è più alcun bisogno di codice di selezione nostro: [quill.QuillEditor]
/// usa lo stesso stack di selezione nativo di un `TextField`/`EditableText`
/// di Flutter, ma su un `Document` che rappresenta l'INTERA nota come
/// un'unica sequenza logica di caratteri con un solo offset globale — non
/// come N widget indipendenti in una lista virtualizzata. La spiegazione
/// tecnica completa di come questo risolve i problemi originali è nel
/// messaggio di consegna che accompagna questo file.
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
  final FocusNode _focusNode = FocusNode(debugLabel: 'markdown-rendered-view');
  final ScrollController _scrollController = ScrollController();

  String? _cachedContent;
  late quill.QuillController _controller;

  @override
  void initState() {
    super.initState();
    _controller = _buildController(widget.content);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  quill.QuillController _buildController(String content) {
    _cachedContent = content;
    final document = MarkdownDeltaConverter.toDocument(content);
    return quill.QuillController(
      document: document,
      selection: const TextSelection.collapsed(offset: 0),
    );
  }

  @override
  void didUpdateWidget(covariant MarkdownRenderedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // La nota è cambiata: ricostruiamo il Document (una sola volta, non ad
    // ogni frame — vedi `_cachedContent`) e con esso un nuovo controller,
    // scartando qualunque selezione precedente, che si riferiva al
    // documento vecchio.
    if (widget.content != _cachedContent) {
      final newController = _buildController(widget.content);
      final oldController = _controller;
      setState(() => _controller = newController);
      oldController.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (fontFamily, fontSize, lineHeight) = ref.watch(
      settingsProvider.select((s) => (s.fontFamily, s.fontSize, s.lineHeight)),
    );

    final isDark = theme.brightness == Brightness.dark;
    final primaryColor = theme.colorScheme.primary;
    final onSurface = theme.colorScheme.onSurface;

    final baseStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize,
      height: lineHeight,
      color: onSurface,
    );
    final inlineCodeStyle = GoogleFonts.jetBrainsMono(
      fontSize: fontSize * 0.9,
      height: 1.4,
      color: primaryColor,
    );
    final titleTextStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize * 2.2,
      fontWeight: FontWeight.w800,
      color: onSurface,
      height: 1.25,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTitle(theme, titleTextStyle),
        Expanded(
          child: quill.QuillEditor(
            controller: _controller,
            focusNode: _focusNode,
            scrollController: _scrollController,
            config: quill.QuillEditorConfig(
              // Sola lettura: nessuna tastiera, nessun cursore lampeggiante,
              // ma la SELEZIONE resta attiva — è lo stesso meccanismo nativo
              // usato da `SelectableText`, non disabilitato da `readOnly`.
              readOnly: true,
              scrollable: true,
              expands: true,
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
              enableInteractiveSelection: true,
              showCursor: false,
              placeholder: null,
              // Il menu contestuale (Copia, Seleziona tutto, ...) NON viene
              // sovrascritto: lasciandolo `null`/di default, flutter_quill
              // mostra lo stesso `AdaptiveTextSelectionToolbar` nativo che
              // userebbe qualunque `EditableText` — Material su
              // Android/desktop, Cupertino su iOS/macOS — con "Seleziona
              // tutto" risolto internamente come selezione dell'intero
              // `Document` (offset 0 → fine), non una nostra
              // reimplementazione.
              customStyles: _buildCustomStyles(
                theme: theme,
                baseStyle: baseStyle,
                inlineCodeStyle: inlineCodeStyle,
              ),
              embedBuilders: [
                TableEmbedBuilder(
                  isDark: isDark,
                  primaryColor: primaryColor,
                  headerStyle: baseStyle.copyWith(fontWeight: FontWeight.bold),
                  cellStyle: baseStyle.copyWith(fontSize: fontSize * 0.95),
                ),
                DividerEmbedBuilder(
                  color: theme.colorScheme.outline.withValues(alpha: 0.4),
                ),
              ],
              onLaunchUrl: (link) async {
                final uri = Uri.tryParse(link);
                if (uri != null && await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTitle(ThemeData theme, TextStyle titleTextStyle) {
    if (widget.title.trim().isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // `SelectableText`: widget standard di Flutter, non un
              // meccanismo custom — il titolo non fa parte del `Document`
              // di Quill (ha uno stile dedicato, più grande, indipendente
              // da qualunque H1 dentro il corpo), ma resta comunque
              // selezionabile e copiabile nativamente per conto proprio.
              SelectableText(widget.title, style: titleTextStyle),
              const SizedBox(height: 16),
              Divider(
                color: theme.colorScheme.outline.withValues(alpha: 0.3),
                thickness: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // API-CHECK: `DefaultStyles` è l'API di flutter_quill con la superficie
  // più soggetta a piccoli rename fra major version (i nomi dei campi,
  // `DefaultTextBlockStyle`/`VerticalSpacing`/`DefaultListBlockStyle`, sono
  // comunque stabili concettualmente). Se `flutter pub get` risolve una
  // versione con firme leggermente diverse, il file `default_styles.dart`
  // dentro il pacchetto scaricato
  // (`~/.pub-cache/hosted/pub.dev/flutter_quill-*/lib/src/.../styles/`) è
  // la fonte di verità più aggiornata: qui sotto ogni stile del vecchio
  // `MarkdownStyleSheet` è mappato 1:1 sul suo corrispettivo Quill.
  quill.DefaultStyles _buildCustomStyles({
    required ThemeData theme,
    required TextStyle baseStyle,
    required TextStyle inlineCodeStyle,
  }) {
    final fontSize = baseStyle.fontSize ?? 16.0;
    final onSurface = theme.colorScheme.onSurface;
    final primaryColor = theme.colorScheme.primary;
    final isDark = theme.brightness == Brightness.dark;

    quill.DefaultTextBlockStyle heading(double scale, FontWeight weight) {
      return quill.DefaultTextBlockStyle(
        baseStyle.copyWith(
          fontSize: fontSize * scale,
          fontWeight: weight,
          color: onSurface,
          height: 1.3,
        ),
        const quill.HorizontalSpacing(0, 0),
        const quill.VerticalSpacing(16, 0),
        const quill.VerticalSpacing(0, 0),
        null,
      );
    }

    return quill.DefaultStyles(
      h1: heading(2.0, FontWeight.w800),
      h2: heading(1.6, FontWeight.w700),
      h3: heading(1.3, FontWeight.w600),
      paragraph: quill.DefaultTextBlockStyle(
        baseStyle,
        const quill.HorizontalSpacing(0, 0),
        const quill.VerticalSpacing(6, 0),
        const quill.VerticalSpacing(0, 0),
        null,
      ),
      bold: const TextStyle(fontWeight: FontWeight.bold),
      italic: const TextStyle(fontStyle: FontStyle.italic),
      strikeThrough: const TextStyle(decoration: TextDecoration.lineThrough),
      link: TextStyle(
        color: primaryColor,
        decoration: TextDecoration.underline,
        fontWeight: FontWeight.w500,
      ),
      inlineCode: quill.InlineCodeStyle(
        style: inlineCodeStyle,
        backgroundColor:
            isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEFEFEF),
        radius: const Radius.circular(4),
      ),
      code: quill.DefaultTextBlockStyle(
        GoogleFonts.jetBrainsMono(
          fontSize: fontSize * 0.85,
          height: 1.4,
          color: onSurface,
        ),
        const quill.HorizontalSpacing(0, 0),
        const quill.VerticalSpacing(8, 8),
        const quill.VerticalSpacing(0, 0),
        BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      quote: quill.DefaultTextBlockStyle(
        baseStyle.copyWith(
          fontStyle: FontStyle.italic,
          color: onSurface.withValues(alpha: 0.75),
        ),
        const quill.HorizontalSpacing(16, 0),
        const quill.VerticalSpacing(8, 8),
        const quill.VerticalSpacing(0, 0),
        BoxDecoration(
          color: primaryColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border(left: BorderSide(color: primaryColor, width: 4)),
        ),
      ),
      lists: quill.DefaultListBlockStyle(
        baseStyle,
        const quill.HorizontalSpacing(0, 0),
        const quill.VerticalSpacing(6, 0),
        const quill.VerticalSpacing(0, 0),
        null,
        null,
      ),
    );
  }
}
