import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart' show kTouchSlop;
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

  // Rilevamento del "tap a vuoto" fatto a mano su eventi puntatore grezzi
  // (`Listener`), non con un `GestureDetector`/`TapGestureRecognizer`.
  // Motivo: un `TapGestureRecognizer` partecipa alla gesture arena, e se da
  // qualche parte nell'albero (verosimilmente dentro `MarkdownSelectionScope`,
  // per il doppio-tap-seleziona-parola) esiste anche un
  // `DoubleTapGestureRecognizer` sulla stessa arena, QUALSIASI tap recognizer
  // — incluso questo — deve attendere la finestra di disambiguazione
  // doppio-tap (~300ms) prima di potersi dichiarare vincitore: è il ritardo
  // percepito segnalato. Un `Listener` riceve gli eventi subito, fuori
  // dall'arena, quindi non ha questo ritardo — a costo di dover replicare a
  // mano la logica minima di "è stato un tap breve, non un drag né un
  // long-press" (soglia di spostamento + soglia di durata), usando le stesse
  // costanti che userebbe Flutter internamente.
  static const double _tapTouchSlop = kTouchSlop; // ~18px
  static const Duration _tapMaxDuration = Duration(milliseconds: 500); // ~kLongPressTimeout
  final Map<int, _PendingTap> _pendingTapPointers = <int, _PendingTap>{};

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
    _pendingTapPointers.clear();
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
      // Dopo "Copia" (o "Taglia", se mai presente) la selezione deve
      // terminare, come nel comportamento nativo di copia/incolla — il menu
      // di default del pacchetto copia ma lascia la selezione attiva.
      // Ricostruiamo la stessa toolbar di default (`state.contextMenuButtonItems`,
      // pattern documentato nel README di flutter_md) avvolgendo solo i
      // pulsanti "copia"/"taglia": eseguono prima l'azione originale (deve
      // ancora leggere la selezione attiva) e poi chiudono la selezione.
      // "Seleziona tutto" lascia la selezione com'è, ma deve garantire che la
      // toolbar resti visibile anche se la selezione di partenza era fuori
      // schermo (vedi [_keepToolbarVisibleAfterSelectAll]). Le ancore sono
      // inoltre sempre riportate dentro il viewport (vedi
      // [_clampAnchorsToViewport]).
      contextMenuBuilder: (context, state) =>
          AdaptiveTextSelectionToolbar.buttonItems(
        anchors: _clampAnchorsToViewport(state.contextMenuAnchors),
        buttonItems: [
          for (final item in state.contextMenuButtonItems)
            _wrapMenuItem(item, state),
        ],
      ),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handleBackgroundPointerDown,
        onPointerMove: _handleBackgroundPointerMove,
        onPointerUp: _handleBackgroundPointerUp,
        onPointerCancel: _handleBackgroundPointerCancel,
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

  ContextMenuButtonItem _wrapMenuItem(
    ContextMenuButtonItem item,
    MarkdownSelectionScopeState state,
  ) {
    final originalOnPressed = item.onPressed;
    if (originalOnPressed == null) return item;

    if (item.type == ContextMenuButtonType.copy ||
        item.type == ContextMenuButtonType.cut) {
      return ContextMenuButtonItem(
        type: item.type,
        label: item.label,
        onPressed: () {
          originalOnPressed();
          state.clearSelection();
        },
      );
    }

    if (item.type == ContextMenuButtonType.selectAll) {
      return ContextMenuButtonItem(
        type: item.type,
        label: item.label,
        onPressed: () {
          originalOnPressed();
          _keepToolbarVisibleAfterSelectAll(state);
        },
      );
    }

    return item;
  }

  // BUG ("Seleziona tutto" con selezione di partenza fuori schermo): la
  // selezione di `flutter_md` è ancorata al modello, non ai `RenderObject`,
  // quindi sopravvive anche quando il blocco che la contiene esce dalla
  // `cacheExtent` della `ListView` e viene smontato. Se in quello stato si
  // preme "Seleziona tutto", la toolbar sparisce e non torna più finché
  // non si ri-seleziona a mano; con la selezione di partenza visibile il
  // problema non c'è. (Il sorgente privato del pacchetto non è stato
  // ispezionato: la causa esatta lato pacchetto è un'ipotesi, il rimedio
  // sotto è volutamente difensivo e usa solo API pubbliche.)
  //
  // Rimedio: subito dopo "Seleziona tutto", per qualche frame (il tempo di
  // far assestare layout/registry del pacchetto), se la selezione è ancora
  // attiva ma la toolbar non è visibile, la ri-mostriamo con l'API pubblica
  // `showToolbar()` (che ricalcola le ancore dalla geometria corrente).
  // Si ferma da sola se nel frattempo la selezione viene annullata.
  void _keepToolbarVisibleAfterSelectAll(MarkdownSelectionScopeState state) {
    void check(int retriesLeft) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !state.mounted) return;
        final selection = _activeSelection;
        if (selection == null || selection.isCollapsed) return;
        if (!state.toolbarIsVisible) state.showToolbar();
        if (retriesLeft > 0) check(retriesLeft - 1);
      });
      // `addPostFrameCallback` da solo non pianifica un frame.
      WidgetsBinding.instance.ensureVisualUpdate();
    }

    check(2);
  }

  // Rettangolo globale della viewport di scroll (l'area in cui il contenuto
  // è realmente visibile), o `null` se non ancora disponibile.
  Rect? _viewportGlobalRect() {
    if (!_scrollController.hasClients) return null;
    final box = _scrollController.position.context.storageContext
        .findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  static const double _toolbarExtent = 48.0;
  static const double _toolbarEdgeMargin = 8.0;

  // Le ancore di default di `flutter_md` sono calcolate sulla geometria dei
  // soli blocchi MONTATI (top/bottom del bounding box della selezione), che
  // con "Seleziona tutto" o con una selezione scrollata via possono cadere
  // ben fuori dalla viewport (blocchi nella `cacheExtent`, o fallback sui
  // bordi dell'intero scope): la toolbar verrebbe posizionata fuori schermo
  // e risulterebbe "scomparsa". Qui le ancore che escono dalla viewport
  // vengono riportate sul bordo visibile più vicino (toolbar agganciata al
  // bordo superiore/inferiore); quelle già dentro non vengono toccate, così
  // il flip sopra/sotto della toolbar per selezioni vicine al bordo resta
  // quello nativo.
  TextSelectionToolbarAnchors _clampAnchorsToViewport(
    TextSelectionToolbarAnchors anchors,
  ) {
    final viewport = _viewportGlobalRect();
    if (viewport == null ||
        viewport.height < 2 * (_toolbarExtent + _toolbarEdgeMargin)) {
      return anchors;
    }

    double clampX(double x) =>
        x.clamp(viewport.left, viewport.right).toDouble();

    // Ancora primaria: la toolbar viene disegnata SOPRA questo punto.
    Offset clampPrimary(Offset p) {
      if (p.dy < viewport.top) {
        return Offset(
          clampX(p.dx),
          viewport.top + _toolbarExtent + _toolbarEdgeMargin,
        );
      }
      if (p.dy > viewport.bottom) {
        return Offset(clampX(p.dx), viewport.bottom - _toolbarEdgeMargin);
      }
      return p;
    }

    // Ancora secondaria: la toolbar viene disegnata SOTTO questo punto (solo
    // se sopra non c'è spazio).
    Offset clampSecondary(Offset p) {
      if (p.dy > viewport.bottom) {
        return Offset(
          clampX(p.dx),
          viewport.bottom - _toolbarExtent - _toolbarEdgeMargin,
        );
      }
      if (p.dy < viewport.top) {
        return Offset(clampX(p.dx), viewport.top + _toolbarEdgeMargin);
      }
      return p;
    }

    final secondary = anchors.secondaryAnchor;
    return TextSelectionToolbarAnchors(
      primaryAnchor: clampPrimary(anchors.primaryAnchor),
      secondaryAnchor: secondary == null ? null : clampSecondary(secondary),
    );
  }

  void _handleBackgroundPointerDown(PointerDownEvent event) {
    _pendingTapPointers[event.pointer] = _PendingTap(event.position, DateTime.now());
  }

  void _handleBackgroundPointerMove(PointerMoveEvent event) {
    _pendingTapPointers[event.pointer]?.registerPosition(event.position);
  }

  void _handleBackgroundPointerCancel(PointerCancelEvent event) {
    _pendingTapPointers.remove(event.pointer);
  }

  void _handleBackgroundPointerUp(PointerUpEvent event) {
    final pending = _pendingTapPointers.remove(event.pointer);
    if (pending == null) return;

    // Non un tap: si è spostato oltre la soglia (drag/scroll/table-scroll) o
    // è stato tenuto premuto oltre la soglia di long-press (avvio selezione
    // touch). In entrambi i casi non deve annullare nulla.
    if (pending.maxDistanceFromOrigin > _tapTouchSlop) return;
    if (DateTime.now().difference(pending.downTime) > _tapMaxDuration) return;

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

  // Problema 1: nessun hook di gesture nel `BlockPainter`. Il log di build
  // ha rivelato l'interfaccia reale di `BlockPainter`/`SelectableBlockPainter`
  // (flutter_md 0.2.0):
  //   abstract final Size size;
  //   Size layout(double width);
  //   void paint(Canvas canvas, Size size, double offset);
  //   void handleTapDown(PointerDownEvent event);
  //   void handleTapUp(PointerUpEvent event);
  //   String get renderedText;
  //   int offsetForLocalPosition(Offset local);
  //   List<Rect> boxesForRange(int start, int end);
  //   TextRange wordBoundaryForLocal(Offset local);
  //   bool isLinkAtLocal(Offset local);
  // Nessun metodo di pan/drag: un `BlockPainter` riceve solo tap, non
  // possiede un proprio gesture arena per un drag orizzontale. Il drag di
  // selezione multi-blocco è quindi orchestrato da un livello sopra (la
  // `MarkdownWidget`/`MarkdownSelectionScope`), non dal singolo painter —
  // motivo per cui il mio precedente `_HorizontalScrollTablePainter`
  // (custom drag consumato dentro il painter) non poteva funzionare: quel
  // punto di estensione non esiste in questa API.
  //
  // Soluzione corretta con l'API reale: non toccare affatto il rendering
  // interno di flutter_md per le tabelle (lasciamo che disegni/selezioni la
  // tabella esattamente come per ogni altro blocco), e diamo invece più
  // spazio orizzontale con un vero `Scrollable` a livello di widget
  // (`SingleChildScrollView(scrollDirection: Axis.horizontal)`) attorno al
  // `MarkdownWidget` di quel singolo blocco. Questo non richiede alcun
  // codice custom per isolare i gesti: la disambiguazione nativa di Flutter
  // fra `Scrollable` con assi ortogonali fa già esattamente quello che
  // serve — un drag verticale che parte sopra la tabella risale comunque
  // alla `ListView` esterna, un drag orizzontale resta isolato qui, e un
  // long-press-poi-drag per la selezione touch (gestito da
  // `MarkdownSelectionScope`, non da uno `Scrollable`) non è in
  // competizione con un semplice `HorizontalDragGestureRecognizer`. Dando
  // al figlio un vincolo di larghezza non limitato (`maxWidth: infinity`,
  // che `SingleChildScrollView` fornisce di default sull'asse di scroll),
  // la tabella può calcolare la sua larghezza naturale (somma colonne)
  // esattamente come richiesto, invece di essere forzata/troncata nella
  // larghezza del blocco padre.
  Widget _buildMarkdownBlock(int blockIndex, MD$Block block) {
    final markdownWidget = MarkdownWidget(
      markdown: Markdown(
        markdown: markdownBlockRenderedText(block),
        blocks: [block],
      ),
      documentId: 'block-$blockIndex',
    );

    final content = block is MD$Table
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: markdownWidget,
          )
        : SizedBox(width: double.infinity, child: markdownWidget);

    return Align(
      key: ValueKey('rendered-block-$blockIndex'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: content,
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

/// Stato di un puntatore ancora "in corsa" fra `PointerDown` e `PointerUp`,
/// usato da `_MarkdownRenderedViewState` per riconoscere a mano un tap breve
/// senza passare dalla gesture arena (vedi commento su `_pendingTapPointers`).
class _PendingTap {
  _PendingTap(this.origin, this.downTime);

  final Offset origin;
  final DateTime downTime;
  double maxDistanceFromOrigin = 0;

  void registerPosition(Offset position) {
    final distance = (position - origin).distance;
    if (distance > maxDistanceFromOrigin) {
      maxDistanceFromOrigin = distance;
    }
  }
}
