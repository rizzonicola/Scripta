import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart'
    show cupertinoTextSelectionControls, cupertinoDesktopTextSelectionControls;
import 'package:flutter_md/flutter_md.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/haptics_helper.dart';
import '../../settings/providers/settings_provider.dart';

/// Vista di sola lettura di una nota, renderizzata SEMPRE in Markdown
/// formattato: non esiste più una modalità "testo grezzo" separata.
///
/// Il rendering usa `flutter_md` (vedi pubspec.yaml): la nota resta divisa in
/// blocchi dentro una `ListView.builder` virtualizzata (un blocco Markdown
/// per item, vedi `_buildMarkdownBlock`) per continuare a beneficiare della
/// virtualizzazione su note molto lunghe, ma a differenza del vecchio motore
/// (`flutter_markdown_plus`) la selezione di testo non richiede più alcun
/// trucco di realizzazione forzata: `MarkdownSelectionController` ancora la
/// selezione al modello dati immutabile (`Markdown`/`MD$...`) invece che ai
/// `RenderObject` a schermo, quindi resta corretta — "Seleziona tutto"
/// incluso — anche per blocchi mai costruiti o già scomparsi dalla
/// `cacheExtent` di default.
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

  // Il gruppo coordina la selezione "anchored al modello" del corpo
  // (`MarkdownSelectionController`, sotto) con la selezione nativa e
  // indipendente del titolo (un semplice `SelectableText`, vedi
  // `_buildTitleWidget`): flutter_md non ha un punto di estensione per
  // includere un widget arbitrario non-Markdown nella stessa selezione
  // ancorata, quindi il titolo resta un `SelectableText` a parte. Il gruppo
  // garantisce almeno che avviare una selezione nel titolo cancelli quella
  // nel corpo (vedi `onSelectionChanged` di `_buildTitleWidget`); il
  // percorso inverso (selezionare nel corpo mentre il titolo ha già una
  // selezione attiva) non è coperto da un punto di estensione equivalente
  // lato `SelectableText` e resta una piccola imperfezione nota — prima
  // della migrazione titolo e corpo condividevano un'unica `SelectableRegion`
  // nativa, quindi un'unica selezione continua tra i due non è più possibile.
  final MarkdownSelectionGroup _selectionGroup = MarkdownSelectionGroup();
  late final MarkdownSelectionController _selectionController =
      MarkdownSelectionController(group: _selectionGroup);

  // --- Problema 2: tocco a vuoto non annulla più la selezione -------------
  // L'API pubblica di `MarkdownSelectionScope`/`MarkdownSelectionScopeState`
  // (v0.2.0) non espone un parametro tipo `clearOnTapOutside`/`dismissOnTap`
  // (verificato su README/changelog del pacchetto): lo stato pubblico offre
  // solo `copySelection` / `selectAll` / `clearSelection` / `showToolbar` /
  // `contextMenuButtonItems` / `contextMenuAnchors`. Serve quindi gestirlo a
  // mano, con un `GlobalKey` sullo stato dello scope per poter chiamare
  // `clearSelection()` da fuori.
  final GlobalKey<MarkdownSelectionScopeState> _selectionScopeKey =
      GlobalKey<MarkdownSelectionScopeState>();
  MarkdownSelection? _activeSelection;

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

  List<MD$Block>? _cachedBlocks;

  (ThemeData, String, double, double)? _cachedThemeKey;
  late MarkdownThemeData _markdownTheme;
  late TextStyle _titleTextStyle;

  @override
  void initState() {
    super.initState();
    _updateBlocks(widget.content);
  }

  @override
  void didUpdateWidget(covariant MarkdownRenderedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      _updateBlocks(widget.content);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _selectionFocusNode.dispose();
    _selectionController.dispose();
    super.dispose();
  }

  // Ricalcola i blocchi e li registra sul controller di selezione. Chiamato
  // da `initState`/`didUpdateWidget` (mai da dentro `build`) perché
  // `setDocuments` notifica il controller, e farlo mentre QUESTO widget è a
  // sua volta nel mezzo del proprio `build` rischierebbe di richiedere un
  // nuovo rebuild di un discendente (`MarkdownSelectionScope`) già costruito
  // in questo stesso frame.
  void _updateBlocks(String content) {
    final effectiveContent = content.isEmpty ? '*Nessun contenuto*' : content;
    // `flutter_md` espone già i blocchi del documento tramite il proprio
    // modello (`Markdown.fromString(...).blocks`): non serve più uno
    // splitter manuale a righe/fence come nel vecchio
    // `_splitMarkdownIntoBlocks`.
    final blocks = Markdown.fromString(effectiveContent).blocks;
    _cachedBlocks = blocks;
    _selectionController.setDocuments([
      for (var i = 0; i < blocks.length; i++)
        MarkdownDocumentRef(
          id: 'block-$i',
          model: Markdown(
            markdown: markdownBlockRenderedText(blocks[i]),
            blocks: [blocks[i]],
          ),
          order: i,
        ),
    ]);
  }

  void _ensureTheme(
    ThemeData theme,
    String fontFamily,
    double fontSize,
    double lineHeight,
  ) {
    final key = (theme, fontFamily, fontSize, lineHeight);
    if (_cachedThemeKey == key) return;
    _cachedThemeKey = key;

    final isDark = theme.brightness == Brightness.dark;

    final baseTextStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize,
      height: lineHeight,
      color: theme.colorScheme.onSurface,
    );

    _titleTextStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize * 2.2,
      fontWeight: FontWeight.w800,
      color: theme.colorScheme.onSurface,
      height: 1.25,
    );

    TextStyle headingStyle(double scale, FontWeight weight, {Color? color}) {
      return AppTheme.getTextStyleForFont(
        fontFamily,
        fontSize: fontSize * scale,
        fontWeight: weight,
        color: color ?? theme.colorScheme.onSurface,
        height: 1.3,
      );
    }

    // Sfondo condiviso da citazioni, blocchi di codice e tabelle
    // (`MarkdownThemeData.surfaceColor` copre tutti e tre, non c'è un hook
    // separato per ciascuno come nel vecchio `MarkdownStyleSheet`): stessa
    // tinta usata prima per lo sfondo dei blocchi di codice, che resta
    // l'elemento visivamente più caratterizzato.
    final surfaceColor =
        isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5);
    // Sfondo del testo monospace (inline e a blocco condividono lo stesso
    // campo in questa versione del pacchetto): tinta leggermente più chiara,
    // vicina a quella usata prima solo per il code inline.
    final monospaceBackgroundColor =
        isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEFEFEF);

    _markdownTheme = MarkdownThemeData.mergeTheme(
      theme,
      textStyle: baseTextStyle,
      h1Style: headingStyle(2.0, FontWeight.w800),
      h2Style: headingStyle(1.6, FontWeight.w700),
      h3Style: headingStyle(1.3, FontWeight.w600),
      // h4-h6 non erano personalizzati nel vecchio MarkdownStyleSheet (si
      // affidava agli stili di default del pacchetto): questa scala
      // discendente è una scelta autonoma presa per questa migrazione, per
      // avere comunque una gerarchia coerente coi livelli superiori.
      h4Style: headingStyle(1.15, FontWeight.w600),
      h5Style: headingStyle(1.05, FontWeight.w600),
      h6Style: headingStyle(
        1.0,
        FontWeight.w600,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
      ),
      quoteStyle: baseTextStyle.copyWith(
        fontStyle: FontStyle.italic,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
      ),
      linkColor: theme.colorScheme.primary,
      linkStyle: const TextStyle(
        decoration: TextDecoration.underline,
        fontWeight: FontWeight.w500,
      ),
      surfaceColor: surfaceColor,
      monospaceBackgroundColor: monospaceBackgroundColor,
      dividerColor: theme.colorScheme.outline.withValues(alpha: 0.4),
      onLinkTap: (title, url) async {
        if (url.isEmpty) return;
        final uri = Uri.tryParse(url);
        if (uri != null && await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      // Problema 1: nessuna opzione dedicata trovata in `MarkdownThemeData`
      // per lo scroll automatico delle tabelle larghe (né `tableOverflow`
      // né equivalenti — verificato su README/changelog di flutter_md
      // 0.2.0). Si usa quindi l'hook di custom block painter documentato
      // (vedi `_HorizontalScrollTablePainter` sotto).
      builder: (block, theme) {
        if (block is MD$Table) {
          return _HorizontalScrollTablePainter(block: block, theme: theme);
        }
        return null;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (fontFamily, fontSize, lineHeight) = ref.watch(
      settingsProvider.select((s) => (s.fontFamily, s.fontSize, s.lineHeight)),
    );

    _ensureTheme(theme, fontFamily, fontSize, lineHeight);

    return _buildFormattedView(theme);
  }

  Widget _buildFormattedView(ThemeData theme) {
    final blocks = _cachedBlocks!;
    final hasTitle = widget.title.trim().isNotEmpty;
    final itemCount = (hasTitle ? 1 : 0) + blocks.length;
    final selectionColor = theme.colorScheme.primary.withValues(alpha: 0.35);

    return MarkdownSelectionScope(
      key: _selectionScopeKey,
      controller: _selectionController,
      focusNode: _selectionFocusNode,
      selectionColor: selectionColor,
      selectionControls: _platformSelectionControls,
      onSelectionChanged: (selection) {
        _activeSelection = selection;
        HapticsHelper.reportSelectionState(
          isCollapsed: selection == null || selection.isCollapsed,
        );
      },
      // Problema 2: `GestureDetector` "translucent" che avvolge tutto il
      // contenuto scrollabile, sotto lo scope di selezione. Un tap che
      // NON è l'inizio di un drag di selezione arriva sempre fin qui,
      // perché:
      //  - un drag (selezione da mouse) o un long-press-poi-drag
      //    (selezione touch) vengono riconosciuti e "vinti" prima, a
      //    livello di gesture arena, dai recognizer interni dello scope
      //    (che partono da subito su pan/long-press, non su tap) — quindi
      //    non fanno mai scattare `onTapUp` qui: nessun falso positivo
      //    sull'avvio selezione;
      //  - un tap sulle maniglie di selezione o sul menu Copia/Seleziona
      //    tutto non raggiunge affatto questo `GestureDetector`, perché
      //    quei controlli sono disegnati in un `Overlay` sopra la lista e
      //    intercettano il tocco prima che arrivi qui;
      //  - un tap "vuoto" genuino (testo non selezionato, area senza
      //    testo, o un blocco diverso da quello con la selezione attiva —
      //    il documento è virtualizzato ma `clearSelection()` agisce
      //    sull'intero `MarkdownSelectionController`, non sul singolo
      //    blocco) arriva invece qui e annulla la selezione.
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: _handleBackgroundTapUp,
        child: MarkdownTheme(
          data: _markdownTheme,
          child: ScrollConfiguration(
            behavior: _NoGlowScrollBehavior(),
            child: ListView.builder(
              key: const ValueKey('markdown-formatted-listview'),
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
              itemCount: itemCount,
              itemBuilder: (context, index) {
                if (hasTitle && index == 0) {
                  return _buildTitleWidget(theme, selectionColor);
                }
                final blockIndex = hasTitle ? index - 1 : index;
                return _buildMarkdownBlock(blockIndex, blocks[blockIndex]);
              },
            ),
          ),
        ),
      ),
    );
  }

  void _handleBackgroundTapUp(TapUpDetails details) {
    final selection = _activeSelection;
    if (selection == null || selection.isCollapsed) return;
    _selectionScopeKey.currentState?.clearSelection();
  }

  Widget _buildTitleWidget(ThemeData theme, Color selectionColor) {
    return Align(
      key: const ValueKey('rendered-block-title'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(
              widget.title,
              style: _titleTextStyle,
              selectionColor: selectionColor,
              onSelectionChanged: (selection, cause) {
                if (!selection.isCollapsed) {
                  _selectionGroup.clearExternal();
                }
              },
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

  Widget _buildMarkdownBlock(int blockIndex, MD$Block block) {
    return Align(
      key: ValueKey('rendered-block-$blockIndex'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: MarkdownWidget(
              markdown: Markdown(
                markdown: markdownBlockRenderedText(block),
                blocks: [block],
              ),
              documentId: 'block-$blockIndex',
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
      BuildContext context, Widget child, ScrollableDetails details) {
    return child;
  }
}

// ---------------------------------------------------------------------------
// Problema 1 — tabelle larghe scrollabili orizzontalmente.
//
// ATTENZIONE: questo painter delega layout/paint/selezione al painter di
// tabella di default del pacchetto (`BlockPainter$Table`, nome dedotto dalla
// convenzione `BlockPainter$Quote` citata nel changelog 0.0.7 di flutter_md
// — NON verificato contro il sorgente installato, perché in questo ambiente
// non ho accesso alla rete/pub-cache per scaricare e leggere
// `flutter_md-0.2.0` né un SDK Flutter per compilare). Stessa cosa per i nomi
// e le firme esatte di `layout`/`paint`/`hitTestSelectable`/il meccanismo di
// gesture: sono la mia migliore ricostruzione dalla API pubblica documentata
// (README: "Custom Block Painters" via `MarkdownThemeData.builder`, più
// `SelectableBlockPainter` citato come API pubblica nelle release notes
// 0.2.0), non un fatto verificato. PRIMA DI MERGIARE: apri
// `<pub-cache>/hosted/pub.dev/flutter_md-0.2.0/lib/src/...` (painter di
// tabella e classe base `SelectableBlockPainter`) e allinea i nomi dei
// metodi qui sotto a quelli reali — il resto della logica (layout a
// larghezza naturale, clip + offset di scroll, soglia di attivazione del
// drag orizzontale, delega dell'hit-test per la selezione) resta valido a
// prescindere dai nomi esatti.
class _HorizontalScrollTablePainter extends SelectableBlockPainter {
  _HorizontalScrollTablePainter({
    required MD$Table block,
    required MarkdownThemeData theme,
  })  : _inner = BlockPainter$Table(block: block, theme: theme),
        super(block: block, theme: theme);

  final BlockPainter$Table _inner;
  double _scrollOffset = 0;
  double _naturalWidth = 0;
  double _viewportWidth = 0;

  double get _maxScrollOffset =>
      (_naturalWidth - _viewportWidth).clamp(0.0, double.infinity);

  @override
  Size layout(BoxConstraints constraints) {
    // Lascia che la tabella prenda la sua larghezza naturale (somma delle
    // colonne), invece di essere forzata/troncata nella larghezza del
    // blocco padre: l'overflow orizzontale lo gestiamo noi con lo scroll,
    // non il layout stesso.
    final natural = _inner.layout(constraints.copyWith(maxWidth: double.infinity));
    _naturalWidth = natural.width;
    _viewportWidth = constraints.maxWidth;
    _scrollOffset = _scrollOffset.clamp(0.0, _maxScrollOffset);
    return Size(constraints.maxWidth, natural.height);
  }

  @override
  void paint(Canvas canvas, Offset offset) {
    canvas.save();
    canvas.clipRect(offset & size);
    _inner.paint(canvas, offset.translate(-_scrollOffset, 0));
    canvas.restore();
  }

  // Consuma un drag orizzontale che parte sopra la tabella SOLO se c'è
  // davvero overflow orizzontale da scrollare; altrimenti lascia che il
  // gesto risalga (scroll verticale della `ListView`/avvio selezione),
  // replicando l'isolamento nativo che aveva `flutter_markdown_plus`.
  @override
  bool handleHorizontalDragUpdate(double delta) {
    if (_maxScrollOffset <= 0) return false;
    final next = (_scrollOffset - delta).clamp(0.0, _maxScrollOffset);
    if (next == _scrollOffset) return false;
    _scrollOffset = next;
    markNeedsPaint();
    return true;
  }

  // Rimappa le coordinate locali tenendo conto dello scroll, così hit-test e
  // selezione (drag/long-press su una cella) restano corretti e la tabella
  // resta inclusa in "Copia"/selezione multi-blocco.
  @override
  MarkdownHitTestResult? hitTestSelectable(Offset localPosition) =>
      _inner.hitTestSelectable(localPosition.translate(_scrollOffset, 0));
}
