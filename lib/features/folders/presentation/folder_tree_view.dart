import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/services/export_service.dart';
import '../../settings/presentation/settings_view.dart';
import '../models/folder_node.dart';
import '../providers/folder_provider.dart';

class FolderTreeView extends ConsumerWidget {
  const FolderTreeView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folderState = ref.watch(folderProvider);
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

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
          // Header
          Padding(
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
                  icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                  tooltip: l10n.newFolder,
                  onPressed: () => _showAddFolderDialog(context, ref),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                  tooltip: 'Altro',
                  onSelected: (val) {
                    if (val == 'export_all') {
                      ExportService.exportAllAsZip(context, ref);
                    }
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(
                      value: 'export_all',
                      child: Row(
                        children: [
                          Icon(Icons.archive_outlined, size: 18),
                          SizedBox(width: 8),
                          Text('Esporta tutte le note (ZIP)'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // "All Notes" item
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: _FolderItemTile(
              title: l10n.allNotes,
              icon: Icons.notes_rounded,
              isSelected: folderState.selectedFolderId == null,
              onTap: () =>
                  ref.read(folderProvider.notifier).selectFolder(null),
            ),
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Divider(height: 1),
          ),

          // Folders Tree
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              children: folderState.rootFolders
                  .map((node) => _buildFolderNode(context, ref, node, 0))
                  .toList(),
            ),
          ),

          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: _FolderItemTile(
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

  Widget _buildFolderNode(
    BuildContext context,
    WidgetRef ref,
    FolderNode node,
    int depth,
  ) {
    final folderState = ref.watch(folderProvider);
    final isSelected = folderState.selectedFolderId == node.id;
    final hasChildren = node.children.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FolderItemTile(
          title: node.name,
          icon: node.isExpanded
              ? Icons.folder_open_outlined
              : Icons.folder_outlined,
          depth: depth,
          isSelected: isSelected,
          hasChildren: hasChildren,
          isExpanded: node.isExpanded,
          onToggleExpand: () =>
              ref.read(folderProvider.notifier).toggleExpand(node.id),
          onTap: () =>
              ref.read(folderProvider.notifier).selectFolder(node.id),
          onMoreOptions: () => _showFolderOptions(context, ref, node),
        ),
        if (hasChildren && node.isExpanded)
          ...node.children
              .map((child) => _buildFolderNode(context, ref, child, depth + 1)),
      ],
    );
  }

  void _showAddFolderDialog(
    BuildContext context,
    WidgetRef ref, {
    String? parentId,
  }) {
    final controller = TextEditingController();
    final l10n = AppLocalizations.of(context);

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          title: Text(parentId == null ? l10n.newFolder : l10n.newSubfolder),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: l10n.folderName,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (val) {
              if (val.trim().isNotEmpty) {
                ref.read(folderProvider.notifier).addFolder(
                      val,
                      parentId: parentId,
                    );
                Navigator.of(dialogCtx).pop();
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  ref.read(folderProvider.notifier).addFolder(
                        controller.text,
                        parentId: parentId,
                      );
                  Navigator.of(dialogCtx).pop();
                }
              },
              child: Text(l10n.confirm),
            ),
          ],
        );
      },
    );
  }

  void _showFolderOptions(
    BuildContext context,
    WidgetRef ref,
    FolderNode node,
  ) {
    final l10n = AppLocalizations.of(context);

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: Text(l10n.newSubfolder),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _showAddFolderDialog(context, ref, parentId: node.id);
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(l10n.renameFolder),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _showRenameFolderDialog(context, ref, node);
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_move_outlined),
                title: const Text('Sposta cartella...'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _showMoveFolderDialog(context, ref, node);
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_zip_outlined),
                title: const Text('Esporta cartella come ZIP'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  ExportService.exportFolderAsZip(context, ref, node);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: Text(
                  l10n.deleteFolder,
                  style: const TextStyle(color: Colors.red),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _showDeleteConfirmDialog(context, ref, node);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showMoveFolderDialog(
    BuildContext context,
    WidgetRef ref,
    FolderNode nodeToMove,
  ) {
    final folderState = ref.read(folderProvider);
    final theme = Theme.of(context);

    // Collect all nodes except nodeToMove and its descendants
    final validDestinations = <_FolderFlatItem>[];
    void collect(List<FolderNode> nodes, int depth) {
      for (final n in nodes) {
        if (n.id == nodeToMove.id) {
          // Skip self and all children
          continue;
        }
        validDestinations.add(_FolderFlatItem(node: n, depth: depth));
        if (n.children.isNotEmpty) {
          collect(n.children, depth + 1);
        }
      }
    }
    collect(folderState.rootFolders, 0);

    showDialog(
      context: context,
      builder: (dialogCtx) {
        final isAlreadyAtRoot = nodeToMove.parentId == null;
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.drive_file_move_outlined, size: 22, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sposta "${nodeToMove.name}"',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Root option
                  ListTile(
                    leading: Icon(
                      Icons.folder_special_outlined,
                      color: isAlreadyAtRoot
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                    title: const Text('Livello principale (Radice)'),
                    trailing: isAlreadyAtRoot
                        ? Icon(Icons.check_rounded, color: theme.colorScheme.primary, size: 18)
                        : null,
                    selected: isAlreadyAtRoot,
                    onTap: () {
                      if (!isAlreadyAtRoot) {
                        ref.read(folderProvider.notifier).moveFolder(nodeToMove.id, null);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Cartella "${nodeToMove.name}" spostata alla radice'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                      Navigator.of(dialogCtx).pop();
                    },
                  ),
                  const Divider(height: 1),
                  if (validDestinations.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Nessun\'altra cartella disponibile',
                        style: TextStyle(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                          fontSize: 13,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    )
                  else
                    ...validDestinations.map((item) {
                      final isCurrentParent = nodeToMove.parentId == item.node.id;
                      return ListTile(
                        contentPadding: EdgeInsets.only(
                          left: 16.0 + (item.depth * 16.0),
                          right: 16,
                        ),
                        leading: Icon(
                          item.node.children.isNotEmpty
                              ? Icons.folder_outlined
                              : Icons.folder_open_outlined,
                          size: 20,
                          color: isCurrentParent
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                        title: Text(
                          item.node.name,
                          style: TextStyle(
                            fontWeight: isCurrentParent ? FontWeight.bold : FontWeight.normal,
                            color: isCurrentParent ? theme.colorScheme.primary : null,
                          ),
                        ),
                        trailing: isCurrentParent
                            ? Icon(Icons.check_rounded, color: theme.colorScheme.primary, size: 18)
                            : null,
                        selected: isCurrentParent,
                        onTap: () {
                          if (!isCurrentParent) {
                            ref.read(folderProvider.notifier).moveFolder(nodeToMove.id, item.node.id);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Cartella "${nodeToMove.name}" spostata in "${item.node.name}"'),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                          Navigator.of(dialogCtx).pop();
                        },
                      );
                    }),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Annulla'),
            ),
          ],
        );
      },
    );
  }

  void _showRenameFolderDialog(
    BuildContext context,
    WidgetRef ref,
    FolderNode node,
  ) {
    final controller = TextEditingController(text: node.name);
    final l10n = AppLocalizations.of(context);

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          title: Text(l10n.renameFolder),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: l10n.folderName,
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  ref.read(folderProvider.notifier).renameFolder(
                        node.id,
                        controller.text,
                      );
                  Navigator.of(dialogCtx).pop();
                }
              },
              child: Text(l10n.save),
            ),
          ],
        );
      },
    );
  }

  void _showDeleteConfirmDialog(
    BuildContext context,
    WidgetRef ref,
    FolderNode node,
  ) {
    final l10n = AppLocalizations.of(context);

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          title: Text(l10n.deleteFolder),
          content: Text(l10n.deleteFolderConfirmation),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () {
                ref.read(folderProvider.notifier).deleteFolder(node.id);
                Navigator.of(dialogCtx).pop();
              },
              child: Text(l10n.confirm),
            ),
          ],
        );
      },
    );
  }
}

class _FolderItemTile extends StatelessWidget {
  final String title;
  final IconData icon;
  final int depth;
  final bool isSelected;
  final bool hasChildren;
  final bool isExpanded;
  final VoidCallback onTap;
  final VoidCallback? onToggleExpand;
  final VoidCallback? onMoreOptions;

  const _FolderItemTile({
    required this.title,
    required this.icon,
    this.depth = 0,
    required this.isSelected,
    this.hasChildren = false,
    this.isExpanded = false,
    required this.onTap,
    this.onToggleExpand,
    this.onMoreOptions,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.only(
          left: (depth * 14.0) + 6.0,
          right: 4,
          top: 6,
          bottom: 6,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            if (hasChildren)
              GestureDetector(
                onTap: onToggleExpand,
                child: Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_right_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              )
            else
              const SizedBox(width: 18),
            const SizedBox(width: 4),
            Icon(
              icon,
              size: 18,
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
              ),
            ),
            if (onMoreOptions != null)
              IconButton(
                icon: const Icon(Icons.more_horiz, size: 16),
                visualDensity: VisualDensity.compact,
                splashRadius: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: onMoreOptions,
              ),
          ],
        ),
      ),
    );
  }
}

class _FolderFlatItem {
  final FolderNode node;
  final int depth;

  const _FolderFlatItem({required this.node, required this.depth});
}

