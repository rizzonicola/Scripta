import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/l10n/desktop_strings.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/context_menu.dart';
import '../../settings/presentation/settings_view.dart';
import '../../sync/providers/sync_provider.dart';
import '../models/folder_node.dart';
import '../providers/folder_provider.dart';
import 'folder_dialogs.dart';
import 'folder_item_tile.dart';
import 'folder_menus.dart';

/// Dato trasportato dal trascinamento di una cartella. Un tipo dedicato (e
/// non una semplice `String`) evita che DragTarget di altre parti dell'app
/// accettino per errore un id di cartella.
class _FolderDragData {
  const _FolderDragData(this.folderId);

  final String folderId;
}

class FolderTreeView extends ConsumerStatefulWidget {
  const FolderTreeView({super.key});

  @override
  ConsumerState<FolderTreeView> createState() => _FolderTreeViewState();
}

class _FolderTreeViewState extends ConsumerState<FolderTreeView> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _listKey = GlobalKey();

  Timer? _autoScrollTimer;
  Offset? _dragGlobalPosition;
  String? _draggingFolderId;

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// Albero visibile appiattito: ogni nodo espanso è seguito dai figli, così
  /// la ListView può costruire solo le righe davvero visibili (prima la
  /// ricorsione creava comunque un widget per ogni discendente).
  List<({FolderNode node, int depth})> _visibleFolders(List<FolderNode> roots) {
    final result = <({FolderNode node, int depth})>[];
    void visit(FolderNode node, int depth) {
      result.add((node: node, depth: depth));
      if (!node.isExpanded) return;
      for (final child in node.children) {
        visit(child, depth + 1);
      }
    }

    for (final root in roots) {
      visit(root, 0);
    }
    return result;
  }

  void _onDragStarted(String folderId) {
    _autoScrollTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _autoScrollTick(),
    );
    setState(() => _draggingFolderId = folderId);
  }

  void _onDragUpdate(Offset globalPosition) {
    _dragGlobalPosition = globalPosition;
  }

  void _onDragEnd() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _dragGlobalPosition = null;
    if (mounted && _draggingFolderId != null) {
      setState(() => _draggingFolderId = null);
    }
  }

  /// Scorrimento automatico quando il puntatore si avvicina ai bordi della
  /// lista: senza questo, una cartella in fondo a un albero lungo non potrebbe
  /// essere trascinata in cima (o viceversa) in un solo gesto.
  void _autoScrollTick() {
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    final pointer = _dragGlobalPosition;
    if (box == null ||
        !box.attached ||
        pointer == null ||
        !_scrollController.hasClients) {
      return;
    }

    const edge = 56.0;
    const maxStep = 14.0;
    final local = box.globalToLocal(pointer);
    double delta = 0;
    if (local.dy < edge) {
      delta = -((edge - local.dy) / edge).clamp(0.0, 1.0) * maxStep;
    } else if (local.dy > box.size.height - edge) {
      delta =
          ((local.dy - (box.size.height - edge)) / edge).clamp(0.0, 1.0) *
          maxStep;
    }
    if (delta == 0) return;

    final position = _scrollController.position;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target != position.pixels) {
      _scrollController.jumpTo(target);
    }
  }

  void _dropFolder(
    String draggedId,
    String targetId,
    FolderDropPosition position,
  ) {
    final folders = ref.read(folderProvider.notifier);
    final oldParent = folders.findNode(draggedId)?.parentId;
    if (!folders.moveFolderRelative(draggedId, targetId, position)) return;
    final newParent = folders.findNode(draggedId)?.parentId;
    // L'ordine è locale, il cambio di genitore no: solo quest'ultimo deve
    // raggiungere il server.
    if (oldParent != newParent) {
      ref.read(syncProvider.notifier).onFolderStructureChanged();
    }
  }

  void _dropToRoot(String draggedId) {
    final folders = ref.read(folderProvider.notifier);
    final oldParent = folders.findNode(draggedId)?.parentId;
    if (!folders.moveFolder(draggedId, null)) return;
    if (oldParent != null) {
      ref.read(syncProvider.notifier).onFolderStructureChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Due `.select` mirati invece di un `ref.watch(folderProvider)` pieno:
    // questo widget NON deve ricostruirsi per una selezione di un nodo
    // (quello lo gestisce il singolo `_DraggableFolderRow`), solo quando
    // cambia l'albero delle cartelle o si passa a/da "Tutte le note".
    final rootFolders = ref.watch(folderProvider.select((s) => s.rootFolders));
    final isAllNotesSelected = ref.watch(
      folderProvider.select((s) => s.selectedFolderId == null),
    );
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final visibleFolders = _visibleFolders(rootFolders);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          right: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.4),
            width: 1,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header (tasto destro: stesso menu di "Tutte le note")
          ContextMenuRegion(
            enabled: isDesktopPlatform,
            behavior: HitTestBehavior.opaque,
            entriesBuilder: (ctx) => workspaceMenuEntries(ctx, ref),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_copy_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.folders,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 20,
                    ),
                    tooltip: l10n.newFolder,
                    onPressed: () => showAddFolderDialog(context, ref),
                  ),
                  Builder(
                    builder: (buttonContext) => IconButton(
                      icon: const Icon(Icons.more_vert_rounded, size: 20),
                      tooltip: 'Altro',
                      onPressed: () {
                        final box =
                            buttonContext.findRenderObject() as RenderBox;
                        showContextMenu(
                          buttonContext,
                          box.localToGlobal(Offset(0, box.size.height + 4)),
                          workspaceOverflowEntries(buttonContext, ref),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),

          // "All Notes" item (l'intera riga, margini compresi, risponde)
          ContextMenuRegion(
            enabled: isDesktopPlatform,
            behavior: HitTestBehavior.opaque,
            entriesBuilder: (ctx) => workspaceMenuEntries(ctx, ref),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: FolderItemTile(
                title: l10n.allNotes,
                icon: Icons.notes_rounded,
                isSelected: isAllNotesSelected,
                onTap: () =>
                    ref.read(folderProvider.notifier).selectFolder(null),
              ),
            ),
          ),

          ContextMenuRegion(
            enabled: isDesktopPlatform,
            behavior: HitTestBehavior.opaque,
            entriesBuilder: (ctx) => workspaceMenuEntries(ctx, ref),
            // Nessun padding verticale: il riquadro di "Tutte le note" ha
            // già 4 px sopra e sotto, così dista 4 px sia dalla linea
            // sopra sia da quella sotto (prima: 4 px sopra, 10 sotto).
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Divider(height: 1),
            ),
          ),

          // Folders Tree
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Tasto destro sullo spazio vuoto sotto/tra le cartelle:
                // stesso menu di "Tutte le note". Le cartelle hanno il
                // proprio menu (regione più interna, ha la precedenza).
                ContextMenuRegion(
                  enabled: isDesktopPlatform,
                  behavior: HitTestBehavior.opaque,
                  entriesBuilder: (ctx) => workspaceMenuEntries(ctx, ref),
                  child: ListView.builder(
                    key: _listKey,
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    itemCount: visibleFolders.length,
                    itemBuilder: (context, index) {
                      final item = visibleFolders[index];
                      return _DraggableFolderRow(
                        key: ValueKey(item.node.id),
                        node: item.node,
                        depth: item.depth,
                        draggingFolderId: _draggingFolderId,
                        onDragStarted: _onDragStarted,
                        onDragUpdate: _onDragUpdate,
                        onDragEnd: _onDragEnd,
                        onDrop: _dropFolder,
                      );
                    },
                  ),
                ),

                // Zona di rilascio "radice": compare solo durante il
                // trascinamento e non occupa spazio quando non serve.
                if (_draggingFolderId != null)
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: _RootDropTarget(onDrop: _dropToRoot),
                  ),
              ],
            ),
          ),

          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: FolderItemTile(
              title: l10n.settings,
              icon: Icons.settings_outlined,
              isSelected: false,
              onTap: () {
                SettingsView.show(context);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Riga dell'albero con long-press drag (touch e mouse) e zone di rilascio
/// relative alla riga:
///  * bordo superiore -> prima della cartella;
///  * centro -> dentro la cartella;
///  * bordo inferiore -> dopo la cartella (o come prima figlia, se la
///    cartella è espansa: è il "buco" visivo subito sotto la riga).
class _DraggableFolderRow extends ConsumerStatefulWidget {
  final FolderNode node;
  final int depth;
  final String? draggingFolderId;
  final ValueChanged<String> onDragStarted;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final void Function(String draggedId, String targetId, FolderDropPosition)
  onDrop;

  const _DraggableFolderRow({
    super.key,
    required this.node,
    required this.depth,
    required this.draggingFolderId,
    required this.onDragStarted,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDrop,
  });

  @override
  ConsumerState<_DraggableFolderRow> createState() =>
      _DraggableFolderRowState();
}

class _DraggableFolderRowState extends ConsumerState<_DraggableFolderRow> {
  final GlobalKey _rowKey = GlobalKey();
  FolderDropPosition? _zone;
  Timer? _autoExpandTimer;

  @override
  void dispose() {
    _autoExpandTimer?.cancel();
    super.dispose();
  }

  FolderDropPosition? _zoneFor(Offset globalPointer) {
    final box = _rowKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return null;
    final local = box.globalToLocal(globalPointer);
    final height = box.size.height;
    if (height <= 0) return null;
    if (local.dy < height * 0.3) return FolderDropPosition.before;
    if (local.dy > height * 0.7) return FolderDropPosition.after;
    return FolderDropPosition.inside;
  }

  void _cancelAutoExpand() {
    _autoExpandTimer?.cancel();
    _autoExpandTimer = null;
  }

  void _handleMove(DragTargetDetails<_FolderDragData> details) {
    final draggedId = details.data.folderId;
    if (!ref
        .read(folderProvider.notifier)
        .canMoveFolder(draggedId, widget.node.id)) {
      return;
    }

    final zone = _zoneFor(details.offset);
    if (zone != _zone) setState(() => _zone = zone);

    // Una cartella compressa su cui si indugia al centro si apre da sola, così
    // si può rilasciare dentro un figlio senza un gesto separato.
    if (zone == FolderDropPosition.inside &&
        !widget.node.isExpanded &&
        widget.node.children.isNotEmpty) {
      _autoExpandTimer ??= Timer(const Duration(milliseconds: 550), () {
        _autoExpandTimer = null;
        if (!mounted ||
            _zone != FolderDropPosition.inside ||
            widget.draggingFolderId != draggedId) {
          return;
        }
        ref.read(folderProvider.notifier).toggleExpand(widget.node.id);
      });
    } else {
      _cancelAutoExpand();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSelected = ref.watch(
      folderProvider.select((s) => s.selectedFolderId == widget.node.id),
    );
    final hasChildren = widget.node.children.isNotEmpty;

    final tile = ContextMenuRegion(
      enabled: isDesktopPlatform,
      entriesBuilder: (ctx) => folderMenuEntries(ctx, ref, widget.node),
      child: FolderItemTile(
        title: widget.node.name,
        icon: widget.node.isExpanded
            ? Icons.folder_open_outlined
            : Icons.folder_outlined,
        depth: widget.depth,
        isSelected: isSelected,
        hasChildren: hasChildren,
        isExpanded: widget.node.isExpanded,
        onToggleExpand: () =>
            ref.read(folderProvider.notifier).toggleExpand(widget.node.id),
        onTap: () =>
            ref.read(folderProvider.notifier).selectFolder(widget.node.id),
        // Desktop: menu a comparsa ancorato al pulsante "..." (identico
        // al tasto destro). Mobile/tablet: bottom sheet come prima.
        onMoreOptions: (buttonPosition) {
          if (isDesktopPlatform) {
            showContextMenu(
              context,
              buttonPosition,
              folderMenuEntries(context, ref, widget.node),
            );
          } else {
            showFolderOptionsSheet(context, ref, widget.node);
          }
        },
      ),
    );

    return DragTarget<_FolderDragData>(
      onWillAcceptWithDetails: (details) {
        return ref
            .read(folderProvider.notifier)
            .canMoveFolder(details.data.folderId, widget.node.id);
      },
      onMove: _handleMove,
      onLeave: (_) {
        _cancelAutoExpand();
        if (_zone != null) setState(() => _zone = null);
      },
      onAcceptWithDetails: (details) {
        final zone = _zone;
        _cancelAutoExpand();
        if (zone != null) {
          widget.onDrop(details.data.folderId, widget.node.id, zone);
        }
        if (mounted && _zone != null) setState(() => _zone = null);
      },
      builder: (context, candidates, rejected) {
        final active = candidates.isNotEmpty;
        final zone = active ? _zone : null;
        final isInside = zone == FolderDropPosition.inside;
        final afterIsFirstChild =
            zone == FolderDropPosition.after &&
            widget.node.isExpanded &&
            widget.node.children.isNotEmpty;
        final lineDepth = afterIsFirstChild ? widget.depth + 1 : widget.depth;

        return Stack(
          key: _rowKey,
          clipBehavior: Clip.none,
          children: [
            LongPressDraggable<_FolderDragData>(
              data: _FolderDragData(widget.node.id),
              delay: const Duration(milliseconds: 400),
              dragAnchorStrategy: pointerDragAnchorStrategy,
              hapticFeedbackOnStart: true,
              onDragStarted: () => widget.onDragStarted(widget.node.id),
              onDragUpdate: (details) =>
                  widget.onDragUpdate(details.globalPosition),
              onDragEnd: (_) => widget.onDragEnd(),
              feedback: _FolderDragFeedback(node: widget.node),
              childWhenDragging: Opacity(opacity: 0.35, child: tile),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  color: isInside
                      ? Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                // Il bordo è in foreground: non partecipa al layout, quindi la
                // riga non cambia dimensione (e non fa "saltare" le righe
                // sotto il puntatore) quando la zona centrale è attiva.
                foregroundDecoration: isInside
                    ? BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.55),
                        ),
                      )
                    : null,
                child: tile,
              ),
            ),
            if (zone == FolderDropPosition.before)
              Positioned(
                left: lineDepth * 12.0 + 10,
                right: 6,
                top: -1,
                child: const _InsertionLine(),
              ),
            if (zone == FolderDropPosition.after)
              Positioned(
                left: lineDepth * 12.0 + 10,
                right: 6,
                bottom: -1,
                child: const _InsertionLine(),
              ),
          ],
        );
      },
    );
  }
}

/// Anteprima che segue il puntatore durante il trascinamento. È volutamente
/// più compatta della riga originale (niente freccia né "..."): comunica solo
/// "stai trasportando questa cartella".
class _FolderDragFeedback extends StatelessWidget {
  final FolderNode node;

  const _FolderDragFeedback({required this.node});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Transform.translate(
      offset: const Offset(-8, -46),
      child: Transform.scale(
        scale: 1.02,
        alignment: Alignment.centerLeft,
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh,
          elevation: 10,
          shadowColor: theme.shadowColor.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            constraints: const BoxConstraints(minWidth: 120, maxWidth: 220),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  node.isExpanded
                      ? Icons.folder_open_outlined
                      : Icons.folder_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  Icons.drag_indicator_rounded,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Linea di inserimento tra due righe, con un pallino iniziale che la rende
/// visibile anche su sfondi poco contrastati.
class _InsertionLine extends StatelessWidget {
  const _InsertionLine();

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: 6,
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: primary, shape: BoxShape.circle),
          ),
          Expanded(
            child: Container(
              height: 2,
              margin: const EdgeInsets.only(left: 2),
              decoration: BoxDecoration(
                color: primary,
                borderRadius: BorderRadius.circular(2),
                boxShadow: [
                  BoxShadow(
                    color: primary.withValues(alpha: 0.35),
                    blurRadius: 4,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pillola flottante mostrata in fondo alla barra laterale durante il drag:
/// rilasciandoci sopra la cartella torna al livello principale.
class _RootDropTarget extends StatelessWidget {
  final void Function(String folderId) onDrop;

  const _RootDropTarget({required this.onDrop});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ds = DesktopStrings.of(context);
    return DragTarget<_FolderDragData>(
      hitTestBehavior: HitTestBehavior.opaque,
      onAcceptWithDetails: (details) => onDrop(details.data.folderId),
      builder: (context, candidates, rejected) {
        final highlight = candidates.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          height: 42,
          decoration: BoxDecoration(
            color: highlight
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHigh.withValues(
                    alpha: 0.96,
                  ),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: highlight
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
            boxShadow: [
              BoxShadow(
                color: theme.shadowColor.withValues(alpha: 0.16),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.vertical_align_top_rounded,
                size: 18,
                color: highlight
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                ds.moveToRoot,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: highlight
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
