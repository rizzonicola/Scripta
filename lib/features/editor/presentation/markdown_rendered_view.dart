import 'dart:async' show Timer;
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderBox, RenderObject, RenderParagraph, TextBox;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/haptics_helper.dart';
import '../../settings/providers/settings_provider.dart';
import '../domain/models/markdown_selection_range.dart';
import '../models/markdown_ast_nodes.dart';
import '../services/markdown_ast_parser.dart';
import 'providers/markdown_selection_provider.dart';
import 'widgets/blocks/markdown_block_style.dart';
import 'widgets/blocks/markdown_block_widget.dart';

/// Blocco individuato dalla risoluzione puntatore → offset documento, con
/// la `RenderBox` del suo wrapper.
///
/// Dichiarato a livello di file: un `typedef` non può essere annidato
/// dentro una classe (errore di compilazione), quindi vive qui pur
/// essendo un dettaglio privato di `_MarkdownRenderedViewState`.
typedef _BlockHit = ({MarkdownBlockNode node, RenderBox box});

/// Vista di sola lettura di una nota, renderizzata SEMPRE in Markdown
/// formattato: non esiste una modalità "testo grezzo" separata.
///
/// MOTORE DI VIRTUALIZZAZIONE (Fase 2, invariato): il testo sorgente viene
/// parsato UNA SOLA VOLTA in un albero [MarkdownBlockNode] (vedi
/// `MarkdownAstParser`) quando [content] cambia; durante lo scroll l'albero
/// non viene mai ricalcolato — solo i blocchi di primo livello effettivamente
/// vicini alla viewport corrente vengono istanziati come widget, tramite
/// `ListView.builder`. Il titolo della nota occupa sempre l'indice 0 dello
/// scroll, così da scorrere in perfetta sincronia coi blocchi del documento.
///
/// ## SELEZIONE TOUCH & DESKTOP (offset AST + Riverpod)
///
/// Questa vista NON contiene alcun pezzo del motore di selezione nativo di
/// Flutter: niente `SelectableRegion`, `SelectionArea`, `SelectionContainer`
/// né `SelectionRegistrar`. Il suo ruolo è quello di **orchestratore**:
///
/// 1. esporre la superficie (scroll virtuale + titolo) renderizzata dai
///    [MarkdownBlockWidget], che si autosottoscrivono a
///    [markdownSelectionProvider] e si evidenziano da soli;
/// 2. tradurre i gesti del puntatore in offset del documento (vedi
///    [_resolveDocumentOffset]) e pilotare il ciclo
///    `startSelection` → `updateSelection` → `endSelection` e `selectWordAt`;
/// 3. gestire il Long-Press con Word-Snap su touch/tablet;
/// 4. visualizzare le maniglie di selezione (Selection Handles) per la
///    regolazione fine ai bordi della selezione (`updateStartHandle`/`updateEndHandle`);
/// 5. mostrare la toolbar contestuale nativa (`AdaptiveTextSelectionToolbar.buttonItems`)
///    ancorata al testo selezionato;
/// 6. azionare l'auto-scroll durante il trascinamento vicino ai bordi;
/// 7. installare le scorciatoie desktop (Ctrl/Cmd+A, Ctrl/Cmd+C) tramite
///    [MarkdownSelectionShortcuts].
class MarkdownRenderedView extends ConsumerStatefulWidget {
  /// Titolo della nota, renderizzato in testa allo scroll. NON fa parte del
  /// sorgente Markdown ([content]): un drag che parte dall'area del titolo
  /// viene risolto per clamp sull'offset `0`, così "Seleziona tutto"/copia
  /// restituiscono sempre e solo il documento Markdown, mai il titolo
  /// mescolato al corpo (stessa semantica della versione a selezione nativa).
  final String title;

  /// Testo Markdown integrale della nota: unica fonte di verità per AST,
  /// risoluzione puntatore→offset, `selectAll` e copia non distruttiva.
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

class _MarkdownRenderedViewState extends ConsumerState<MarkdownRenderedView>
    with SingleTickerProviderStateMixin {
  /// Controller dello scroll virtuale: è l'unico attuatore dell'auto-scroll
  /// durante il trascinamento della selezione (vedi [_handleAutoScrollTick]).
  final ScrollController _scrollController = ScrollController();

  /// FocusNode della superficie: passato a [MarkdownSelectionShortcuts] così
  /// le scorciatoie desktop (Ctrl/Cmd+A, Ctrl/Cmd+C) sono vive appena l'utente
  /// tocca la vista (vedi [_handlePointerDown]). Ownership e dispose restano
  /// di questo State: il wrapper dispone solo i nodi che crea internamente.
  final FocusNode _surfaceFocusNode =
      FocusNode(debugLabel: 'markdown-rendered-view-surface');

  /// Key della superficie di scroll (il [Listener] più esterno): fornisce la
  /// `RenderBox` della viewport usata per calcolare le soglie di bordo
  /// dell'auto-scroll in coordinate globali e locali.
  final GlobalKey _scrollSurfaceKey =
      GlobalKey(debugLabel: 'markdown-scroll-surface');

  /// Registry dei blocchi di primo livello renderizzati: nodo → `GlobalKey`
  /// del wrapper del blocco.
  final Map<MarkdownBlockNode, GlobalKey> _blockKeys =
      <MarkdownBlockNode, GlobalKey>{};

  /// Ticker dell'auto-scroll: attivo solo mentre un drag di selezione o di
  /// maniglia è in corso; a ogni frame applica il delta di scroll e ri-proietta
  /// l'estremo mobile della selezione.
  late final Ticker _autoScrollTicker;

  // Parser dell'AST: stateless e privo di side-effect
  static const MarkdownAstParser _astParser = MarkdownAstParser();

  /// Margine di pre-materializzazione oltre la viewport, in px logici.
  static const double _kIdleCacheExtent = 800.0;

  /// Soglia di movimento (px logici) oltre la quale un pointer-down passa da
  /// "tap candidato" a "drag di selezione". Allineata a `kTouchSlop` (18).
  static const double _kSelectionDragSlop = 18.0;

  /// Durata della pressione prolungata (long-press) su touch / tablet / stilo
  /// per attivare la modalità di selezione del testo (~300ms).
  static const Duration _kLongPressTimeout = Duration(milliseconds: 300);

  /// Banda di bordo (superiore/inferiore) della viewport che attiva
  /// l'auto-scroll durante il trascinamento, in px logici (~48dp).
  static const double _kAutoScrollEdgeThreshold = 48.0;

  /// Velocità massima di auto-scroll, in px logici al secondo.
  static const double _kAutoScrollMaxVelocity = 900.0;

  /// Tetto sul delta-tempo per singolo tick dell'auto-scroll.
  static const double _kMaxFrameDeltaSeconds = 0.1;

  // Cache dell'AST
  List<MarkdownBlockNode>? _cachedBlocks;
  String? _cachedContent;

  (ThemeData, String, double, double)? _cachedStyleKey;
  late MarkdownBlockStyle _blockStyle;
  late TextStyle _titleTextStyle;

  // ---------------------------------------------------------------------
  // Stato del gesto
  // ---------------------------------------------------------------------

  Timer? _longPressTimer;
  int? _trackedPointer;
  Offset? _pointerDownPosition;
  Offset _lastPointerPosition = Offset.zero;

  bool _selectionDragActive = false;
  bool _pointerCanDragSelect = false;

  /// Flag per il trascinamento attivo di una delle maniglie di selezione.
  bool _isDraggingHandle = false;
  bool _draggingStartHandle = false;

  /// Visibilità della toolbar contestuale di sistema.
  bool _toolbarVisible = false;

  Duration _lastAutoScrollElapsed = Duration.zero;

  MarkdownSelectionNotifier get _selectionNotifier =>
      ref.read(markdownSelectionProvider.notifier);

  @override
  void initState() {
    super.initState();
    _autoScrollTicker = createTicker(_handleAutoScrollTick);
  }

  @override
  void dispose() {
    _cancelLongPressTimer();
    _stopAutoScrollTicker();
    _autoScrollTicker.dispose();
    _scrollController.dispose();
    _surfaceFocusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    final (String fontFamily, double fontSize, double lineHeight) = ref.watch(
      settingsProvider.select((s) => (s.fontFamily, s.fontSize, s.lineHeight)),
    );

    _ensureParsedContent();
    _ensureStyles(theme, fontFamily, fontSize, lineHeight);

    final List<MarkdownBlockNode> blocks = _cachedBlocks!;
    final bool hasTitle = widget.title.trim().isNotEmpty;
    final int itemCount =
        (hasTitle ? 1 : 0) + (blocks.isEmpty ? 1 : blocks.length);

    return MarkdownSelectionShortcuts(
      documentSource: () => widget.content,
      focusNode: _surfaceFocusNode,
      child: Listener(
        key: _scrollSurfaceKey,
        behavior: HitTestBehavior.opaque,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        onPointerCancel: _handlePointerCancel,
        child: Stack(
          children: [
            ScrollConfiguration(
              behavior: const _NoGlowScrollBehavior(),
              child: ListView.builder(
                key: const ValueKey('markdown-formatted-listview'),
                controller: _scrollController,
                physics: (_selectionDragActive || _isDraggingHandle)
                    ? const NeverScrollableScrollPhysics()
                    : null,
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 64),
                cacheExtent: _kIdleCacheExtent,
                itemCount: itemCount,
                itemBuilder: (BuildContext context, int index) {
                  if (hasTitle && index == 0) {
                    return _buildTitleWidget(theme);
                  }
                  final int blockIndex = hasTitle ? index - 1 : index;
                  if (blocks.isEmpty) {
                    return _buildEmptyPlaceholder(theme);
                  }
                  return _buildTopLevelBlock(blocks[blockIndex]);
                },
              ),
            ),
            // Layer mirato e reattivo per maniglie e toolbar:
            // la ListView non viene invalidata né ricostruita a ogni frame di drag
            _MarkdownSelectionLayer(
              scrollController: _scrollController,
              surfaceKey: _scrollSurfaceKey,
              resolveRect: _resolveRectForOffset,
              toolbarVisible: _toolbarVisible,
              content: widget.content,
              primaryColor: theme.colorScheme.primary,
              onCopy: _handleCopy,
              onSelectAll: _handleSelectAll,
              onHandleDragStart: _handleHandleDragStart,
              onHandleDragUpdate: _handleHandleDragUpdate,
              onHandleDragEnd: _handleHandleDragEnd,
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // CACHE: CONTENUTO E STILE
  // ---------------------------------------------------------------------

  void _ensureParsedContent() {
    if (_cachedContent == widget.content) return;
    _cachedContent = widget.content;
    _cachedBlocks = _astParser.parse(widget.content);
    _blockKeys.clear();
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

    final isDark = theme.brightness == Brightness.dark;
    final primaryColor = theme.colorScheme.primary;

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

    _titleTextStyle = AppTheme.getTextStyleForFont(
      fontFamily,
      fontSize: fontSize * 2.2,
      fontWeight: FontWeight.w800,
      color: theme.colorScheme.onSurface,
      height: 1.25,
    );

    final styleSheet = MarkdownStyleSheet(
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

    _blockStyle = MarkdownBlockStyle(
      styleSheet: styleSheet,
      inlineCodeStyle: inlineCodeStyle,
      titleTextStyle: _titleTextStyle,
      fontFamily: fontFamily,
      fontSize: fontSize,
      isDark: isDark,
      primaryColor: primaryColor,
      onSurfaceColor: theme.colorScheme.onSurface,
      outlineColor: theme.colorScheme.outline,
    );
  }

  // ---------------------------------------------------------------------
  // BUILDER DEGLI ITEM
  // ---------------------------------------------------------------------

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

  Widget _buildEmptyPlaceholder(ThemeData theme) {
    return Align(
      key: const ValueKey('rendered-block-empty'),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Text(
          'Nessun contenuto',
          style: _blockStyle.styleSheet.p?.copyWith(
            fontStyle: FontStyle.italic,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }

  Widget _buildTopLevelBlock(MarkdownBlockNode node) {
    final GlobalKey blockKey = _blockKeys.putIfAbsent(
      node,
      () => GlobalKey(debugLabel: 'markdown-block-${node.startOffset}'),
    );
    return Align(
      key: blockKey,
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: MarkdownBlockWidget(node: node, style: _blockStyle),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // GESTI: WORD-SNAP, DRAG, TAP E MANIGLIE
  // ---------------------------------------------------------------------

  void _startLongPressTimer() {
    _cancelLongPressTimer();
    _longPressTimer = Timer(_kLongPressTimeout, _handleLongPressTimeout);
  }

  void _cancelLongPressTimer() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  /// Long-Press con Word-Snap: seleziona la parola intera sotto il dito,
  /// fa scattare l'aptica, mostra la toolbar e blocca lo scroll.
  void _handleLongPressTimeout() {
    _longPressTimer = null;
    if (!mounted || _pointerDownPosition == null || _trackedPointer == null) {
      return;
    }

    HapticsHelper.reportSelectionState(isCollapsed: false);

    final int offset = _resolveDocumentOffset(_pointerDownPosition!);
    _selectionNotifier.selectWordAt(offset, widget.content);

    _toolbarVisible = true;
    _selectionDragActive = true;
    _startAutoScrollTicker();

    setState(() {});
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!_surfaceFocusNode.hasFocus) {
      _surfaceFocusNode.requestFocus();
    }

    if (_trackedPointer != null) return;

    final bool isPrimaryMouse = event.kind == PointerDeviceKind.mouse &&
        (event.buttons & kPrimaryButton) != 0;

    if (event.kind == PointerDeviceKind.mouse && !isPrimaryMouse) return;

    _trackedPointer = event.pointer;
    _pointerDownPosition = event.position;
    _lastPointerPosition = event.position;
    _selectionDragActive = false;
    _pointerCanDragSelect = isPrimaryMouse;

    final bool isTouchOrStylus = event.kind == PointerDeviceKind.touch ||
        event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;

    if (isTouchOrStylus) {
      _startLongPressTimer();
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_trackedPointer != event.pointer || _isDraggingHandle) return;
    _lastPointerPosition = event.position;

    if (_longPressTimer != null) {
      final double distance =
          (event.position - _pointerDownPosition!).distance;
      if (distance >= _kSelectionDragSlop) {
        _cancelLongPressTimer();
      }
    }

    if (!_selectionDragActive && !_pointerCanDragSelect) return;

    if (!_selectionDragActive) {
      final double distance =
          (event.position - _pointerDownPosition!).distance;
      if (distance < _kSelectionDragSlop) return;

      _selectionDragActive = true;
      _toolbarVisible = false;
      _selectionNotifier.startSelection(
        _resolveDocumentOffset(_pointerDownPosition!),
      );
      HapticsHelper.reportSelectionState(isCollapsed: false);
      _startAutoScrollTicker();
    }

    _selectionNotifier.updateSelection(_resolveDocumentOffset(event.position));
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_trackedPointer != event.pointer || _isDraggingHandle) return;
    _lastPointerPosition = event.position;
    _cancelLongPressTimer();
    _stopAutoScrollTicker();

    final bool isTap = _pointerDownPosition != null &&
        (event.position - _pointerDownPosition!).distance < _kSelectionDragSlop;

    if (_selectionDragActive) {
      _selectionDragActive = false;
      _selectionNotifier.updateSelection(
        _resolveDocumentOffset(event.position),
      );
      _selectionNotifier.endSelection();
      _toolbarVisible = true;
      setState(() {});
    } else if (isTap) {
      _handleTap(event.position);
    }

    _trackedPointer = null;
    _pointerDownPosition = null;
    _pointerCanDragSelect = false;
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (_trackedPointer != event.pointer || _isDraggingHandle) return;
    _cancelLongPressTimer();
    _stopAutoScrollTicker();

    if (_selectionDragActive) {
      _selectionDragActive = false;
      _selectionNotifier.endSelection();
      setState(() {});
    }

    _trackedPointer = null;
    _pointerDownPosition = null;
    _pointerCanDragSelect = false;
  }

  /// Gestione del tap: deseleziona SOLO se il tocco è avvenuto FUORI dall'area
  /// selezionata; se cade dentro, alterna la visibilità della toolbar senza
  /// perdere la selezione attiva.
  void _handleTap(Offset position) {
    final MarkdownSelectionRange selection =
        ref.read(markdownSelectionProvider);
    if (!selection.isValid || selection.isCollapsed) return;

    final int tappedOffset = _resolveDocumentOffset(position);

    if (tappedOffset >= selection.min && tappedOffset <= selection.max) {
      setState(() {
        _toolbarVisible = !_toolbarVisible;
      });
    } else {
      _selectionNotifier.clearSelection();
      HapticsHelper.reportSelectionState(isCollapsed: true);
      setState(() {
        _toolbarVisible = false;
      });
    }
  }

  // ---------------------------------------------------------------------
  // MANIPOLAZIONE MANIGLIE (SELECTION HANDLES)
  // ---------------------------------------------------------------------

  void _handleHandleDragStart(bool isStart) {
    _cancelLongPressTimer();
    setState(() {
      _isDraggingHandle = true;
      _draggingStartHandle = isStart;
      _toolbarVisible = false;
    });
    _startAutoScrollTicker();
  }

  void _handleHandleDragUpdate(Offset globalPosition, bool isStart) {
    _lastPointerPosition = globalPosition;

    // Normalizza il punto di ancoraggio leggermente sopra il dito verso la linea di testo
    final double verticalCorrection = _blockStyle.fontSize * 0.7 + 8.0;
    final Offset adjustedPosition = Offset(
      globalPosition.dx,
      globalPosition.dy - verticalCorrection,
    );
    final int newOffset = _resolveDocumentOffset(adjustedPosition);

    if (isStart) {
      _selectionNotifier.updateStartHandle(newOffset);
    } else {
      _selectionNotifier.updateEndHandle(newOffset);
    }
  }

  void _handleHandleDragEnd() {
    _stopAutoScrollTicker();
    _selectionNotifier.endSelection();
    setState(() {
      _isDraggingHandle = false;
      _toolbarVisible = true;
    });
  }

  // ---------------------------------------------------------------------
  // AZIONI TOOLBAR
  // ---------------------------------------------------------------------

  void _handleCopy() {
    _selectionNotifier.copySelectedText(widget.content);
    HapticsHelper.reportSelectionState(isCollapsed: true);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Testo copiato negli appunti'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _handleSelectAll() {
    _selectionNotifier.selectAll(widget.content.length);
    setState(() {
      _toolbarVisible = true;
    });
  }

  // ---------------------------------------------------------------------
  // AUTO-SCROLL DURANTE IL TRASCINAMENTO (SELEZIONE O MANIGLIE)
  // ---------------------------------------------------------------------

  void _startAutoScrollTicker() {
    _lastAutoScrollElapsed = Duration.zero;
    if (!_autoScrollTicker.isActive) {
      _autoScrollTicker.start();
    }
  }

  void _stopAutoScrollTicker() {
    if (_autoScrollTicker.isActive) {
      _autoScrollTicker.stop();
    }
  }

  void _handleAutoScrollTick(Duration elapsed) {
    if ((!_selectionDragActive && !_isDraggingHandle) ||
        (_trackedPointer == null && !_isDraggingHandle)) {
      return;
    }

    final Duration delta = elapsed - _lastAutoScrollElapsed;
    _lastAutoScrollElapsed = elapsed;
    final double deltaTime = math.min(
      delta.inMicroseconds / Duration.microsecondsPerSecond,
      _kMaxFrameDeltaSeconds,
    );
    if (deltaTime <= 0.0) return;

    final BuildContext? surfaceContext = _scrollSurfaceKey.currentContext;
    final RenderObject? surfaceObject = surfaceContext?.findRenderObject();
    if (surfaceObject is! RenderBox || !surfaceObject.attached) return;

    final Offset localPosition =
        surfaceObject.globalToLocal(_lastPointerPosition);
    final double viewportHeight = surfaceObject.size.height;

    double velocity = 0.0;
    if (localPosition.dy < _kAutoScrollEdgeThreshold) {
      final double proximity = _clamp01(
        (_kAutoScrollEdgeThreshold - localPosition.dy) /
            _kAutoScrollEdgeThreshold,
      );
      velocity = -_kAutoScrollMaxVelocity * proximity;
    } else if (localPosition.dy >
        viewportHeight - _kAutoScrollEdgeThreshold) {
      final double proximity = _clamp01(
        (localPosition.dy - (viewportHeight - _kAutoScrollEdgeThreshold)) /
            _kAutoScrollEdgeThreshold,
      );
      velocity = _kAutoScrollMaxVelocity * proximity;
    }

    if (velocity == 0.0 || !_scrollController.hasClients) return;

    final ScrollPosition position = _scrollController.position;
    final double clampedPixels = math.max(
      position.minScrollExtent,
      math.min(
        position.maxScrollExtent,
        position.pixels + velocity * deltaTime,
      ),
    );
    if (clampedPixels == position.pixels) return;

    position.jumpTo(clampedPixels);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_selectionDragActive) {
        _selectionNotifier
            .updateSelection(_resolveDocumentOffset(_lastPointerPosition));
      } else if (_isDraggingHandle) {
        final double verticalCorrection = _blockStyle.fontSize * 0.7 + 8.0;
        final Offset adjusted = Offset(
          _lastPointerPosition.dx,
          _lastPointerPosition.dy - verticalCorrection,
        );
        final int offset = _resolveDocumentOffset(adjusted);
        if (_draggingStartHandle) {
          _selectionNotifier.updateStartHandle(offset);
        } else {
          _selectionNotifier.updateEndHandle(offset);
        }
      }
    });
  }

  // ---------------------------------------------------------------------
  // RISOLUZIONE OFFSET <-> GEOMETRIA SCHERMO
  // ---------------------------------------------------------------------

  int _resolveDocumentOffset(Offset globalPosition) {
    final int documentLength = _cachedContent?.length ?? 0;

    _blockKeys.removeWhere(
      (MarkdownBlockNode node, GlobalKey key) => key.currentContext == null,
    );

    _BlockHit? containedHit;
    _BlockHit? bandHit;
    bool hasLiveBlocks = false;
    double topmostBandTop = 0.0;
    double bottomBandBottom = 0.0;

    for (final MapEntry<MarkdownBlockNode, GlobalKey> entry
        in _blockKeys.entries) {
      final BuildContext? elementContext = entry.value.currentContext;
      if (elementContext == null) continue;
      final RenderObject? renderObject = elementContext.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) continue;

      final double bandTop = renderObject.localToGlobal(Offset.zero).dy;
      final double bandBottom = bandTop + renderObject.size.height;
      if (!hasLiveBlocks) {
        hasLiveBlocks = true;
        topmostBandTop = bandTop;
        bottomBandBottom = bandBottom;
      } else {
        if (bandTop < topmostBandTop) topmostBandTop = bandTop;
        if (bandBottom > bottomBandBottom) bottomBandBottom = bandBottom;
      }

      if (globalPosition.dy < bandTop || globalPosition.dy > bandBottom) {
        continue;
      }

      final Offset local = renderObject.globalToLocal(globalPosition);
      final bool containsX =
          local.dx >= 0.0 && local.dx <= renderObject.size.width;
      if (containsX) {
        containedHit = (node: entry.key, box: renderObject);
      } else {
        bandHit ??= (node: entry.key, box: renderObject);
      }
    }

    final _BlockHit? hit = containedHit ?? bandHit;
    if (hit != null) {
      final int? viaTextGeometry =
          _resolveOffsetViaTextGeometry(hit, globalPosition);
      if (viaTextGeometry != null) return viaTextGeometry;
      return _resolveOffsetByBlockHeight(hit, globalPosition);
    }

    if (!hasLiveBlocks) return 0;
    if (globalPosition.dy < topmostBandTop) return 0;
    if (globalPosition.dy > bottomBandBottom) return documentLength;

    return (globalPosition.dy - topmostBandTop) <=
            (bottomBandBottom - globalPosition.dy)
        ? 0
        : documentLength;
  }

  int? _resolveOffsetViaTextGeometry(
      _BlockHit hit, Offset globalPosition) {
    final List<(RenderParagraph, int)> paragraphs = <(RenderParagraph, int)>[];
    _collectTextParagraphs(hit.box, paragraphs);
    if (paragraphs.isEmpty) return null;

    int totalCharacters = 0;
    for (final (_, int length) in paragraphs) {
      totalCharacters += length;
    }
    if (totalCharacters == 0) return null;

    int charactersBefore = 0;
    for (final (RenderParagraph paragraph, int length) in paragraphs) {
      final Offset local = paragraph.globalToLocal(globalPosition);
      if (!_containsPointInclusively(paragraph, local)) {
        charactersBefore += length;
        continue;
      }
      final TextPosition textPosition = paragraph.getPositionForOffset(local);
      final int relative =
          math.max(0, math.min(length, textPosition.offset));
      return _projectToSourceRange(
        hit.node,
        (charactersBefore + relative) / totalCharacters,
      );
    }
    return null;
  }

  int _resolveOffsetByBlockHeight(_BlockHit hit, Offset globalPosition) {
    final Offset local = hit.box.globalToLocal(globalPosition);
    final double height = hit.box.size.height;
    if (height <= 0.0) return hit.node.startOffset;
    return _projectToSourceRange(hit.node, local.dy / height);
  }

  int _projectToSourceRange(MarkdownBlockNode node, double fraction) {
    final double clamped = _clamp01(fraction);
    return node.startOffset + (clamped * node.length).round();
  }

  void _collectTextParagraphs(
    RenderObject renderObject,
    List<(RenderParagraph, int)> out,
  ) {
    if (renderObject is RenderParagraph) {
      out.add((renderObject, renderObject.text.toPlainText().length));
      return;
    }
    renderObject.visitChildren((RenderObject child) {
      _collectTextParagraphs(child, out);
    });
  }

  /// Risolve il rettangolo globale di un dato offset sorgente del documento
  /// per posizionare con precisione sub-pixel maniglie e toolbar.
  Rect? _resolveRectForOffset(int documentOffset, {bool isEnd = false}) {
    if (_cachedBlocks == null || _cachedBlocks!.isEmpty) return null;

    MarkdownBlockNode? targetNode;
    for (final node in _cachedBlocks!) {
      if (isEnd) {
        if (node.startOffset <= documentOffset && documentOffset <= node.endOffset) {
          targetNode = node;
          if (documentOffset <= node.endOffset) break;
        }
      } else {
        if (node.startOffset <= documentOffset && documentOffset < node.endOffset) {
          targetNode = node;
          break;
        } else if (node.startOffset <= documentOffset && documentOffset <= node.endOffset) {
          targetNode = node;
        }
      }
    }
    targetNode ??=
        (documentOffset <= 0 ? _cachedBlocks!.first : _cachedBlocks!.last);

    final GlobalKey? blockKey = _blockKeys[targetNode];
    final BuildContext? elementContext = blockKey?.currentContext;
    if (elementContext == null) return null;
    final RenderObject? renderObject = elementContext.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) return null;

    final double defaultLineHeight = _blockStyle.fontSize * 1.4;

    final List<(RenderParagraph, int)> paragraphs = <(RenderParagraph, int)>[];
    _collectTextParagraphs(renderObject, paragraphs);

    if (paragraphs.isNotEmpty) {
      int totalCharacters = 0;
      for (final (_, int len) in paragraphs) {
        totalCharacters += len;
      }

      if (totalCharacters > 0) {
        final double fraction = targetNode.length > 0
            ? ((documentOffset - targetNode.startOffset) / targetNode.length)
                .clamp(0.0, 1.0)
            : 0.0;
        final int targetChar =
            (fraction * totalCharacters).round().clamp(0, totalCharacters);

        int charactersBefore = 0;
        for (final (RenderParagraph paragraph, int length) in paragraphs) {
          if (targetChar <= charactersBefore + length ||
              paragraph == paragraphs.last.$1) {
            final int relative =
                (targetChar - charactersBefore).clamp(0, length);
            final TextPosition textPos = TextPosition(
              offset: relative,
              affinity: isEnd ? TextAffinity.upstream : TextAffinity.downstream,
            );

            final List<TextBox> boxes = paragraph.getBoxesForSelection(
              TextSelection(
                baseOffset: isEnd ? math.max(0, relative - 1) : relative,
                extentOffset: isEnd ? relative : math.min(length, relative + 1),
              ),
            );

            if (boxes.isNotEmpty) {
              final Rect localBox = boxes.first.toRect();
              final Offset globalTopLeft =
                  paragraph.localToGlobal(localBox.topLeft);
              return Rect.fromLTWH(
                isEnd ? (globalTopLeft.dx + localBox.width) : globalTopLeft.dx,
                globalTopLeft.dy,
                2.0,
                localBox.height > 0 ? localBox.height : defaultLineHeight,
              );
            }

            final Offset localCaret = paragraph.getOffsetForCaret(
              textPos,
              Rect.fromLTWH(0, 0, 2, defaultLineHeight),
            );
            final Offset globalCaret = paragraph.localToGlobal(localCaret);
            return Rect.fromLTWH(
              globalCaret.dx,
              globalCaret.dy,
              2.0,
              defaultLineHeight,
            );
          }
          charactersBefore += length;
        }
      }
    }

    final Offset blockGlobal = renderObject.localToGlobal(Offset.zero);
    final double height = renderObject.size.height;
    final double fraction = targetNode.length > 0
        ? ((documentOffset - targetNode.startOffset) / targetNode.length)
            .clamp(0.0, 1.0)
        : 0.0;
    return Rect.fromLTWH(
      blockGlobal.dx,
      blockGlobal.dy + (fraction * height),
      2.0,
      defaultLineHeight,
    );
  }

  bool _containsPointInclusively(RenderBox box, Offset local) {
    return local.dx >= 0.0 &&
        local.dy >= 0.0 &&
        local.dx <= box.size.width &&
        local.dy <= box.size.height;
  }

  double _clamp01(double value) {
    if (value < 0.0) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
  }
}

// -----------------------------------------------------------------------
// LAYER REATTIVO MIRATO PER MANIGLIE E TOOLBAR
// -----------------------------------------------------------------------

class _MarkdownSelectionLayer extends ConsumerWidget {
  final ScrollController scrollController;
  final GlobalKey surfaceKey;
  final Rect? Function(int offset, {bool isEnd}) resolveRect;
  final bool toolbarVisible;
  final String content;
  final Color primaryColor;
  final VoidCallback onCopy;
  final VoidCallback onSelectAll;
  final void Function(bool isStart) onHandleDragStart;
  final void Function(Offset pos, bool isStart) onHandleDragUpdate;
  final VoidCallback onHandleDragEnd;

  const _MarkdownSelectionLayer({
    required this.scrollController,
    required this.surfaceKey,
    required this.resolveRect,
    required this.toolbarVisible,
    required this.content,
    required this.primaryColor,
    required this.onCopy,
    required this.onSelectAll,
    required this.onHandleDragStart,
    required this.onHandleDragUpdate,
    required this.onHandleDragEnd,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MarkdownSelectionRange selection =
        ref.watch(markdownSelectionProvider);

    if (!selection.isValid || selection.isCollapsed) {
      return const SizedBox.shrink();
    }

    return ListenableBuilder(
      listenable: scrollController,
      builder: (BuildContext context, _) {
        final BuildContext? surfaceCtx = surfaceKey.currentContext;
        final RenderBox? surfaceBox =
            surfaceCtx?.findRenderObject() as RenderBox?;
        if (surfaceBox == null || !surfaceBox.attached) {
          return const SizedBox.shrink();
        }

        final Rect? startGlobalRect =
            resolveRect(selection.min, isEnd: false);
        final Rect? endGlobalRect =
            resolveRect(selection.max, isEnd: true);

        final Rect? startLocalRect = startGlobalRect != null
            ? Rect.fromLTWH(
                surfaceBox.globalToLocal(startGlobalRect.topLeft).dx,
                surfaceBox.globalToLocal(startGlobalRect.topLeft).dy,
                startGlobalRect.width,
                startGlobalRect.height,
              )
            : null;

        final Rect? endLocalRect = endGlobalRect != null
            ? Rect.fromLTWH(
                surfaceBox.globalToLocal(endGlobalRect.topLeft).dx,
                surfaceBox.globalToLocal(endGlobalRect.topLeft).dy,
                endGlobalRect.width,
                endGlobalRect.height,
              )
            : null;

        final Rect viewportRect = Offset.zero & surfaceBox.size;
        final bool showStartHandle = startLocalRect != null &&
            viewportRect.overlaps(
              Rect.fromLTWH(
                startLocalRect.left - 22.0,
                startLocalRect.top,
                44.0,
                startLocalRect.height + 36.0,
              ),
            );

        final bool showEndHandle = endLocalRect != null &&
            viewportRect.overlaps(
              Rect.fromLTWH(
                endLocalRect.left - 22.0,
                endLocalRect.top,
                44.0,
                endLocalRect.height + 36.0,
              ),
            );

        Widget? toolbarWidget;
        if (toolbarVisible) {
          Offset? primaryAnchor;
          Offset? secondaryAnchor;

          if (startLocalRect != null && endLocalRect != null) {
            final double anchorX =
                ((startLocalRect.center.dx + endLocalRect.center.dx) / 2)
                    .clamp(24.0, math.max(24.0, surfaceBox.size.width - 24.0));
            final double topY =
                math.min(startLocalRect.top, endLocalRect.top);
            final double bottomY =
                math.max(startLocalRect.bottom, endLocalRect.bottom);
            primaryAnchor = Offset(anchorX, math.max(0.0, topY));
            secondaryAnchor = Offset(anchorX, bottomY);
          } else if (startLocalRect != null) {
            final double anchorX = startLocalRect.center.dx
                .clamp(24.0, math.max(24.0, surfaceBox.size.width - 24.0));
            primaryAnchor =
                Offset(anchorX, math.max(0.0, startLocalRect.top));
            secondaryAnchor = Offset(anchorX, startLocalRect.bottom);
          } else if (endLocalRect != null) {
            final double anchorX = endLocalRect.center.dx
                .clamp(24.0, math.max(24.0, surfaceBox.size.width - 24.0));
            primaryAnchor =
                Offset(anchorX, math.max(0.0, endLocalRect.top));
            secondaryAnchor = Offset(anchorX, endLocalRect.bottom);
          }

          if (primaryAnchor != null) {
            toolbarWidget = Positioned.fill(
              child: AdaptiveTextSelectionToolbar.buttonItems(
                anchors: TextSelectionToolbarAnchors(
                  primaryAnchor: primaryAnchor,
                  secondaryAnchor: secondaryAnchor,
                ),
                buttonItems: <ContextMenuButtonItem>[
                  ContextMenuButtonItem(
                    onPressed: onCopy,
                    type: ContextMenuButtonType.copy,
                  ),
                  ContextMenuButtonItem(
                    onPressed: onSelectAll,
                    type: ContextMenuButtonType.selectAll,
                  ),
                ],
              ),
            );
          }
        }

        return Positioned.fill(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (showStartHandle)
                _SelectionHandleWidget(
                  caretRect: startLocalRect,
                  isStart: true,
                  color: primaryColor,
                  onDragStart: () => onHandleDragStart(true),
                  onDragUpdate: (pos) => onHandleDragUpdate(pos, true),
                  onDragEnd: onHandleDragEnd,
                ),
              if (showEndHandle)
                _SelectionHandleWidget(
                  caretRect: endLocalRect,
                  isStart: false,
                  color: primaryColor,
                  onDragStart: () => onHandleDragStart(false),
                  onDragUpdate: (pos) => onHandleDragUpdate(pos, false),
                  onDragEnd: onHandleDragEnd,
                ),
              if (toolbarWidget != null) toolbarWidget,
            ],
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------
// WIDGET E PAINTER MANIGLIE DI SELEZIONE
// -----------------------------------------------------------------------

class _SelectionHandleWidget extends StatelessWidget {
  final Rect caretRect;
  final bool isStart;
  final Color color;
  final VoidCallback onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;

  const _SelectionHandleWidget({
    required this.caretRect,
    required this.isStart,
    required this.color,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    const double touchWidth = 44.0;
    final double touchHeight = caretRect.height + 36.0;

    return Positioned(
      left: caretRect.left - (touchWidth / 2),
      top: caretRect.top,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => onDragStart(),
        onPanUpdate: (details) => onDragUpdate(details.globalPosition),
        onPanEnd: (_) => onDragEnd(),
        onPanCancel: onDragEnd,
        child: SizedBox(
          width: touchWidth,
          height: touchHeight,
          child: CustomPaint(
            painter: _SelectionHandlePainter(
              color: color,
              lineHeight: caretRect.height,
              isStart: isStart,
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionHandlePainter extends CustomPainter {
  final Color color;
  final double lineHeight;
  final bool isStart;

  _SelectionHandlePainter({
    required this.color,
    required this.lineHeight,
    required this.isStart,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double centerX = size.width / 2;

    final Paint linePaint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(
      Offset(centerX, 0),
      Offset(centerX, lineHeight),
      linePaint,
    );

    const double radius = 7.5;
    final double knobCenterX = isStart ? centerX - 5.0 : centerX + 5.0;
    final double knobCenterY = lineHeight + radius;

    final Path shadowPath = Path()
      ..addOval(
        Rect.fromCircle(
          center: Offset(knobCenterX, knobCenterY + 1.0),
          radius: radius,
        ),
      );
    canvas.drawShadow(shadowPath, Colors.black.withValues(alpha: 0.5), 3.0, true);

    final Paint fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final Path connectorPath = Path();
    connectorPath.moveTo(centerX - 1.0, lineHeight);
    connectorPath.lineTo(centerX + 1.0, lineHeight);
    connectorPath.lineTo(knobCenterX + (isStart ? 2.0 : -2.0), knobCenterY);
    connectorPath.lineTo(knobCenterX - (isStart ? 2.0 : -2.0), knobCenterY);
    connectorPath.close();
    canvas.drawPath(connectorPath, fillPaint);

    canvas.drawCircle(Offset(knobCenterX, knobCenterY), radius, fillPaint);
  }

  @override
  bool shouldRepaint(covariant _SelectionHandlePainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.lineHeight != lineHeight ||
        oldDelegate.isStart != isStart;
  }
}

/// Comportamento di scroll della superficie: nessun indicatore overscroll e
/// disattivazione drag per mouse.
class _NoGlowScrollBehavior extends ScrollBehavior {
  const _NoGlowScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
      BuildContext context, Widget child, ScrollableDetails details) {
    return child;
  }

  @override
  Set<PointerDeviceKind> get dragDevices => const <PointerDeviceKind>{
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.unknown,
      };
}