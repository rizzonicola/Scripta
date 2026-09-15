import 'package:flutter/foundation.dart' show compute;
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
/// Il Markdown della nota viene convertito in un [quill.Document] — la
/// struttura dati nativa di `flutter_quill` — e mostrato con un unico
/// [quill.QuillEditor] in sola lettura (`controller.readOnly = true`). La
/// selezione (singola, drag, "Seleziona tutto") e il menu contestuale
/// nativo derivano direttamente da quel `Document`, che rappresenta
/// l'INTERA nota come un'unica sequenza logica di caratteri con un solo
/// offset globale — non più N widget indipendenti in una lista
/// virtualizzata con hit-test scritto a mano.
///
/// PRESTAZIONI
/// ---------------------------------------------------------------------
/// Il parsing Markdown→Delta è puro Dart (CPU-bound) e per note molto
/// lunghe può costare qualche decina di millisecondi: eseguito sulla UI
/// thread esattamente quando si apre/cambia nota rischierebbe un frame
/// perso proprio durante la transizione di navigazione. Sopra
/// [_asyncParseThreshold] caratteri la conversione viene quindi delegata a
/// `compute()` (isolate Dart separato — vedi
/// `MarkdownDeltaConverter.toDeltaJsonString`), mentre per le note comuni
/// resta sincrona: spawnare un isolate ha un costo fisso non trascurabile,
/// non conviene per un parsing che costa già meno di un frame.
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
  /// Sotto questa soglia (in caratteri) il parsing resta sincrono: costa
  /// tipicamente meno di un frame, mentre lo spawn di un isolate da solo
  /// costerebbe di più. Sopra, si passa a `compute()` in background.
  static const int _asyncParseThreshold = 15000;

  final FocusNode _focusNode = FocusNode(debugLabel: 'markdown-rendered-view');
  final ScrollController _scrollController = ScrollController();

  String? _cachedContent;
  int _requestId = 0;

  /// `null` solo nella finestra (di norma sub-frame) in cui una nota molto
  /// grande sta ancora convertendo in background al primo caricamento.
  quill.QuillController? _controller;

  @override
  void initState() {
    super.initState();
    _cachedContent = widget.content;
    if (widget.content.length < _asyncParseThreshold) {
      _controller =
          _controllerFromDocument(MarkdownDeltaConverter.toDocument(widget.content));
    } else {
      _loadAsync(widget.content, ++_requestId);
    }
  }

  @override
  void didUpdateWidget(covariant MarkdownRenderedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.content == _cachedContent) return;
    _cachedContent = widget.content;
    final requestId = ++_requestId;

    if (widget.content.length < _asyncParseThreshold) {
      final newController =
          _controllerFromDocument(MarkdownDeltaConverter.toDocument(widget.content));
      _swapController(newController);
      return;
    }
    _loadAsync(widget.content, requestId);
  }

  Future<void> _loadAsync(String content, int requestId) async {
    final jsonString = await compute(MarkdownDeltaConverter.toDeltaJsonString, content);
    // Il widget potrebbe essere stato smontato, o la nota potrebbe essere
    // cambiata di nuovo mentre questa conversione era in volo: in quel
    // caso il risultato è superato e va scartato, altrimenti rischieremmo
    // di sovrascrivere una selezione/nota più recente con dati vecchi.
    if (!mounted || requestId != _requestId) return;
    final document = MarkdownDeltaConverter.documentFromJsonString(jsonString);
    _swapController(_controllerFromDocument(document));
  }

  void _swapController(quill.QuillController newController) {
    final old = _controller;
    setState(() => _controller = newController);
    old?.dispose();
  }

  quill.QuillController _controllerFromDocument(quill.Document document) {
    final controller = quill.QuillController(
      document: document,
      selection: const TextSelection.collapsed(offset: 0),
    );
    // In flutter_quill 11.5.1 il flag di sola lettura si imposta sul
    // controller (non su QuillEditorConfig, che non lo espone): è il
    // controller a dire all'editor se disabilitare tastiera/cursore,
    // mantenendo però la selezione nativa attiva.
    controller.readOnly = true;
    return controller;
  }

  @override
  void dispose() {
    _controller?.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Memoization degli stili: `_buildCustomStyles`/`_buildEmbedBuilders`
  // dipendono solo da tema, font e dimensione testo — non da ogni singolo
  // `build()`. Li ricalcoliamo solo quando quella "chiave" cambia
  // davvero (es. l'utente cambia tema o font nelle impostazioni), non ad
  // ogni rebuild innescato da altro (es. un provider non correlato più in
  // alto nell'albero).
  // ---------------------------------------------------------------------
  Object? _styleCacheKey;
  quill.DefaultStyles? _stylesCache;
  List<quill.EmbedBuilder>? _embedBuildersCache;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (fontFamily, fontSize, lineHeight) = ref.watch(
      settingsProvider.select((s) => (s.fontFamily, s.fontSize, s.lineHeight)),
    );

    final key = (
      theme.brightness,
      theme.colorScheme.primary.toARGB32(),
      theme.colorScheme.onSurface.toARGB32(),
      theme.colorScheme.outline.toARGB32(),
      fontFamily,
      fontSize,
      lineHeight,
    );
    if (_styleCacheKey != key) {
      _styleCacheKey = key;
      final built = _buildStylesAndEmbeds(
        theme: theme,
        fontFamily: fontFamily,
        fontSize: fontSize,
        lineHeight: lineHeight,
      );
      _stylesCache = built.$1;
      _embedBuildersCache = built.$2;
    }

    final titleTextStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize * 2.2,
      fontWeight: FontWeight.w800,
      color: theme.colorScheme.onSurface,
      height: 1.25,
    );

    final controller = _controller;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTitle(theme, titleTextStyle),
        Expanded(
          child: controller == null
              ? const _LoadingPlaceholder()
              : RepaintBoundary(
                  child: quill.QuillEditor(
                    controller: controller,
                    focusNode: _focusNode,
                    scrollController: _scrollController,
                    config: quill.QuillEditorConfig(
                      scrollable: true,
                      expands: true,
                      padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
                      enableInteractiveSelection: true,
                      showCursor: false,
                      placeholder: null,
                      // Il menu contestuale (Copia, Seleziona tutto, ...)
                      // NON viene sovrascritto: lasciandolo di default,
                      // flutter_quill mostra lo stesso
                      // `AdaptiveTextSelectionToolbar` nativo che
                      // userebbe qualunque `EditableText` — Material su
                      // Android/desktop, Cupertino su iOS/macOS — con
                      // "Seleziona tutto" risolto internamente come
                      // selezione dell'intero `Document`, non una nostra
                      // reimplementazione.
                      customStyles: _stylesCache,
                      embedBuilders: _embedBuildersCache,
                      onLaunchUrl: (link) async {
                        final uri = Uri.tryParse(link);
                        if (uri != null && await canLaunchUrl(uri)) {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                        }
                      },
                    ),
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
  // più soggetta a piccoli rename fra major version. Se `flutter pub get`
  // risolve una versione con firme leggermente diverse, il file
  // `default_styles.dart` dentro il pacchetto scaricato
  // (`~/.pub-cache/hosted/pub.dev/flutter_quill-*/lib/src/.../styles/`) è
  // la fonte di verità più aggiornata.
  (quill.DefaultStyles, List<quill.EmbedBuilder>) _buildStylesAndEmbeds({
    required ThemeData theme,
    required String fontFamily,
    required double fontSize,
    required double lineHeight,
  }) {
    final onSurface = theme.colorScheme.onSurface;
    final primaryColor = theme.colorScheme.primary;
    final isDark = theme.brightness == Brightness.dark;

    final baseStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize,
      height: lineHeight,
      color: onSurface,
    );
    final codeFontStyle = GoogleFonts.jetBrainsMono();

    quill.DefaultTextBlockStyle heading(double scale, FontWeight weight) {
      return quill.DefaultTextBlockStyle(
        baseStyle.copyWith(
          fontSize: fontSize * scale,
          fontWeight: weight,
          color: onSurface,
          height: 1.3,
        ),
        const quill.HorizontalSpacing(0, 0),
        // Spaziatura sopra più generosa: separa visivamente i titoli dal
        // paragrafo precedente, come nello stile della vecchia vista
        // Markdown ("ordinata" — vedi feedback).
        const quill.VerticalSpacing(22, 4),
        const quill.VerticalSpacing(0, 0),
        null,
      );
    }

    final styles = quill.DefaultStyles(
      h1: heading(2.0, FontWeight.w800),
      h2: heading(1.6, FontWeight.w700),
      h3: heading(1.3, FontWeight.w600),
      paragraph: quill.DefaultTextBlockStyle(
        baseStyle,
        const quill.HorizontalSpacing(0, 0),
        const quill.VerticalSpacing(8, 0),
        const quill.VerticalSpacing(0, 0),
        null,
      ),
      bold: const TextStyle(fontWeight: FontWeight.bold),
      italic: const TextStyle(fontStyle: FontStyle.italic),
      strikeThrough: const TextStyle(decoration: TextDecoration.lineThrough),
      link: TextStyle(
        color: primaryColor,
        decoration: TextDecoration.underline,
        decorationColor: primaryColor.withValues(alpha: 0.5),
        fontWeight: FontWeight.w500,
      ),
      inlineCode: quill.InlineCodeStyle(
        style: codeFontStyle.copyWith(
          fontSize: fontSize * 0.9,
          height: 1.4,
          color: primaryColor,
        ),
        backgroundColor:
            isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEFEFEF),
        radius: const Radius.circular(4),
      ),
      code: quill.DefaultTextBlockStyle(
        codeFontStyle.copyWith(
          fontSize: fontSize * 0.85,
          height: 1.5,
          color: onSurface,
        ),
        const quill.HorizontalSpacing(0, 0),
        const quill.VerticalSpacing(10, 10),
        const quill.VerticalSpacing(0, 0),
        BoxDecoration(
          color: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF4F4F5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.08),
          ),
        ),
      ),
      quote: quill.DefaultTextBlockStyle(
        baseStyle.copyWith(
          fontStyle: FontStyle.italic,
          color: onSurface.withValues(alpha: 0.8),
        ),
        const quill.HorizontalSpacing(16, 0),
        const quill.VerticalSpacing(10, 10),
        const quill.VerticalSpacing(0, 0),
        BoxDecoration(
          color: primaryColor.withValues(alpha: 0.08),
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(8),
            bottomRight: Radius.circular(8),
          ),
          border: Border(left: BorderSide(color: primaryColor, width: 4)),
        ),
      ),
      lists: quill.DefaultListBlockStyle(
        baseStyle,
        const quill.HorizontalSpacing(0, 0),
        const quill.VerticalSpacing(6, 0),
        const quill.VerticalSpacing(4, 0),
        null,
        null,
      ),
    );

    final embeds = <quill.EmbedBuilder>[
      TableEmbedBuilder(
        isDark: isDark,
        primaryColor: primaryColor,
        borderColor: theme.colorScheme.outline.withValues(alpha: 0.3),
        headerStyle: baseStyle.copyWith(fontWeight: FontWeight.w700),
        cellStyle: baseStyle.copyWith(fontSize: fontSize * 0.95),
      ),
      DividerEmbedBuilder(color: theme.colorScheme.outline.withValues(alpha: 0.4)),
    ];

    return (styles, embeds);
  }
}

/// Placeholder minimale mostrato solo nella finestra (in genere un solo
/// frame) in cui una nota molto grande sta convertendo in background su
/// isolate — evita uno schermo vuoto durante quel breve intervallo.
class _LoadingPlaceholder extends StatelessWidget {
  const _LoadingPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    );
  }
}
