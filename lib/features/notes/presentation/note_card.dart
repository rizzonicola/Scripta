import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/services/export_service.dart';
import '../../../core/theme/color_schemes.dart';
import '../../folders/models/folder_node.dart';
import '../../folders/providers/folder_provider.dart';
import '../../sync/providers/sync_provider.dart';
import '../models/note_model.dart';
import '../providers/notes_provider.dart';

class NoteCard extends ConsumerWidget {
  final NoteModel note;
  final bool isSelected;
  final VoidCallback onTap;
  final bool showDragHandle;
  final int? dragIndex;

  const NoteCard({
    super.key,
    required this.note,
    required this.isSelected,
    required this.onTap,
    this.showDragHandle = false,
    this.dragIndex,
  });

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return DateFormat.Hm().format(dt);
    }
    return DateFormat('d MMM').format(dt);
  }

  void _showMoveNoteDialog(BuildContext context, WidgetRef ref, NoteModel note) {
    final folderState = ref.read(folderProvider);
    final theme = Theme.of(context);

    // Flatten folder hierarchy for clear selection
    final flattened = <_FolderFlatItem>[];
    void collect(List<FolderNode> nodes, int depth) {
      for (final n in nodes) {
        flattened.add(_FolderFlatItem(node: n, depth: depth));
        if (n.children.isNotEmpty) {
          collect(n.children, depth + 1);
        }
      }
    }
    collect(folderState.rootFolders, 0);

    showDialog(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.drive_file_move_outlined, size: 22, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              const Expanded(child: Text('Sposta nota')),
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
                  // Root option: No folder (All notes)
                  ListTile(
                    leading: Icon(
                      Icons.notes_rounded,
                      color: note.folderId == null
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    title: const Text('Nessuna cartella (Tutte le note)'),
                    trailing: note.folderId == null
                        ? Icon(Icons.check_rounded, color: theme.colorScheme.primary, size: 18)
                        : null,
                    selected: note.folderId == null,
                    onTap: () {
                      ref.read(notesProvider.notifier).moveNote(note.id, null);
                      ref.read(syncProvider.notifier).onFolderStructureChanged();
                      Navigator.of(dialogCtx).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Nota spostata in "Nessuna cartella"'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                  ),
                  const Divider(height: 1),
                  if (flattened.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Nessuna cartella creata',
                        style: TextStyle(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                          fontSize: 13,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    )
                  else
                    ...flattened.map((item) {
                      final isCurrent = note.folderId == item.node.id;
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
                          color: isCurrent
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                        title: Text(
                          item.node.name,
                          style: TextStyle(
                            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                            color: isCurrent ? theme.colorScheme.primary : null,
                          ),
                        ),
                        trailing: isCurrent
                            ? Icon(Icons.check_rounded, color: theme.colorScheme.primary, size: 18)
                            : null,
                        selected: isCurrent,
                        onTap: () {
                          ref.read(notesProvider.notifier).moveNote(note.id, item.node.id);
                          ref.read(syncProvider.notifier).onFolderStructureChanged();
                          Navigator.of(dialogCtx).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Nota spostata in "${item.node.name}"'),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
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

  void _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(l10n.deleteNoteConfirmationTitle),
        content: Text(l10n.deleteNoteConfirmation),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true) {
        ref.read(notesProvider.notifier).deleteNote(note.id);
      }
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final handleBorderColor = isSelected
        ? theme.colorScheme.primary.withValues(alpha: isDark ? 0.35 : 0.22)
        : theme.colorScheme.outline.withValues(alpha: isDark ? 0.18 : 0.12);
    final handleBgColor = isSelected
        ? theme.colorScheme.primary.withValues(alpha: isDark ? 0.12 : 0.08)
        : (isDark
            ? Colors.white.withValues(alpha: 0.03)
            : Colors.black.withValues(alpha: 0.02));
    final handleIconColor = isSelected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withValues(alpha: 0.3);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Material(
        color: isSelected
            ? theme.colorScheme.primary.withValues(alpha: 0.12)
            : (isDark
                ? theme.colorScheme.surface
                : theme.surfaceElevated),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected
                    ? theme.colorScheme.primary.withValues(alpha: 0.6)
                    : theme.colorScheme.outline.withValues(alpha: 0.3),
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (note.isPinned) ...[
                            Icon(
                              Icons.push_pin_rounded,
                              size: 14,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              note.title.trim().isEmpty
                                  ? l10n.untitledNote
                                  : note.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: isSelected
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                          Text(
                            _formatDate(note.updatedAt),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        note.previewSnippet,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              '${note.wordCount} words • ${note.readingTimeMinutes} min',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                                fontSize: 10,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(
                                  note.isPinned
                                      ? Icons.push_pin_rounded
                                      : Icons.push_pin_outlined,
                                  size: 14,
                                  color: note.isPinned
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSurface.withValues(alpha: 0.4),
                                ),
                                visualDensity: VisualDensity.compact,
                                splashRadius: 12,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () => ref
                                    .read(notesProvider.notifier)
                                    .togglePin(note.id),
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.drive_file_move_outlined,
                                  size: 15,
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                ),
                                tooltip: 'Sposta in un\'altra cartella',
                                visualDensity: VisualDensity.compact,
                                splashRadius: 12,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () => _showMoveNoteDialog(context, ref, note),
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.file_download_outlined,
                                  size: 15,
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                ),
                                tooltip: 'Esporta come Markdown (.md)',
                                visualDensity: VisualDensity.compact,
                                splashRadius: 12,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () => ExportService.exportNoteAsMarkdown(context, note),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: Icon(
                                  Icons.delete_outline_rounded,
                                  size: 14,
                                  color: Colors.red.withValues(alpha: 0.7),
                                ),
                                visualDensity: VisualDensity.compact,
                                splashRadius: 12,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () =>
                                    _confirmDelete(context, ref, l10n),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (showDragHandle && dragIndex != null) ...[
                  const SizedBox(width: 10),
                  ReorderableDragStartListener(
                    index: dragIndex!,
                    child: Tooltip(
                      message: 'Trascina per riordinare',
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: handleBgColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: handleBorderColor,
                              width: 1,
                            ),
                          ),
                          child: Icon(
                            Icons.drag_indicator_rounded,
                            size: 18,
                            color: handleIconColor,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
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

