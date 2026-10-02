import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/l10n/desktop_strings.dart';
import '../../../core/utils/app_commands.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/context_menu.dart';
import '../../../core/services/export_service.dart';
import '../../../core/theme/color_schemes.dart';
import '../../folders/presentation/folder_picker_dialog.dart';
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

  String _formatDate(DateTime dt, String locale) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return DateFormat.Hm(locale).format(dt);
    }
    // Anno esplicito per le note di anni precedenti: "12 mar" da solo è
    // ambiguo quando si ordina per data di creazione.
    if (dt.year != now.year) {
      return DateFormat.yMMMd(locale).format(dt);
    }
    return DateFormat.MMMd(locale).format(dt);
  }

  /// Dialog "Sposta in cartella": pubblico perché usato anche dal menu
  /// contestuale e dalla scorciatoia Ctrl+Shift+M.
  static void showMoveNoteDialog(BuildContext context, WidgetRef ref, NoteModel note) {
    // Notifier e messenger si leggono PRIMA di aprire il dialog: dopo la
    // scelta non si usa più `ref`/`context` (la card potrebbe nel frattempo
    // essere stata ricostruita o rimossa dalla lista).
    final notes = ref.read(notesProvider.notifier);
    final sync = ref.read(syncProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final destinations = flattenFolders(ref.read(folderProvider).rootFolders);

    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => FolderPickerDialog(
          title: 'Sposta nota',
          rootIcon: Icons.notes_rounded,
          rootLabel: 'Nessuna cartella (Tutte le note)',
          emptyLabel: 'Nessuna cartella creata',
          cancelLabel: 'Annulla',
          destinations: destinations,
          currentFolderId: note.folderId,
          onSelected: (targetId) {
            notes.moveNote(note.id, targetId);
            sync.onFolderStructureChanged();
            final String message = targetId == null
                ? 'Nota spostata in "Nessuna cartella"'
                : 'Nota spostata in "${destinations.firstWhere((d) => d.node.id == targetId).node.name}"';
            messenger.showSnackBar(
              SnackBar(
                content: Text(message),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
        ),
      ),
    );
  }

  static void confirmDelete(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    NoteModel note,
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

  /// Voci del menu contestuale di una nota (tasto destro).
  static List<ContextMenuEntry> contextMenuEntries(
    BuildContext context,
    WidgetRef ref,
    NoteModel note,
  ) {
    final l10n = AppLocalizations.of(context);
    final ds = DesktopStrings.of(context);
    final notifier = ref.read(notesProvider.notifier);
    return [
      ContextMenuEntry(
        label: note.isPinned ? ds.unpin : ds.pin,
        icon: note.isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
        shortcut: commandShortcutLabel(AppCommand.pinNote),
        onSelected: () => notifier.togglePin(note.id),
      ),
      ContextMenuEntry(
        label: ds.moveTo,
        icon: Icons.drive_file_move_outlined,
        shortcut: commandShortcutLabel(AppCommand.moveNote),
        onSelected: () => showMoveNoteDialog(context, ref, note),
      ),
      ContextMenuEntry(
        label: ds.duplicate,
        icon: Icons.copy_rounded,
        shortcut: commandShortcutLabel(AppCommand.duplicateNote),
        onSelected: () =>
            notifier.duplicateNote(note.id, copySuffix: ds.copySuffix),
      ),
      ContextMenuEntry(
        label: ds.exportMarkdown,
        icon: Icons.file_download_outlined,
        shortcut: commandShortcutLabel(AppCommand.exportNote),
        onSelected: () => ExportService.exportNoteAsMarkdown(context, note),
      ),
      const ContextMenuEntry.divider(),
      ContextMenuEntry(
        label: l10n.delete,
        icon: Icons.delete_outline_rounded,
        isDestructive: true,
        shortcut: commandShortcutLabel(AppCommand.deleteNote),
        onSelected: () => confirmDelete(context, ref, l10n, note),
      ),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ContextMenuRegion(
      enabled: isDesktopPlatform,
      // Il tasto destro apre il menu della nota e NON quello dello spazio
      // vuoto della lista (regione più esterna).
      entriesBuilder: (ctx) => contextMenuEntries(ctx, ref, note),
      child: _buildCard(context, ref),
    );
  }

  Widget _buildCard(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final sortOrder = ref.watch(notesProvider.select((s) => s.sortOrder));

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
                            _formatDate(
                              // La data mostrata è quella per cui la lista è
                              // ordinata: prima con "data creazione" si vedeva
                              // sempre la data di modifica, quindi l'ordine
                              // sembrava sbagliato.
                              (sortOrder == NoteSortOrder.createdDesc ||
                                      sortOrder == NoteSortOrder.createdAsc)
                                  ? note.createdAt
                                  : note.updatedAt,
                              Localizations.localeOf(context).toString(),
                            ),
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
                          _NoteCardActions(note: note),
                        ],
                      ),
                    ],
                  ),
                ),
                if (showDragHandle && dragIndex != null) ...[
                  const SizedBox(width: 10),
                  _NoteDragHandle(index: dragIndex!, isSelected: isSelected),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pulsanti rapidi in fondo alla card: fissa, sposta, esporta, elimina.
class _NoteCardActions extends ConsumerWidget {
  const _NoteCardActions({required this.note});

  final NoteModel note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Row(
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
          onPressed: () => NoteCard.showMoveNoteDialog(context, ref, note),
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
          onPressed: () => NoteCard.confirmDelete(context, ref, l10n, note),
        ),
      ],
    );
  }
}

/// Maniglia di trascinamento per il riordino manuale.
class _NoteDragHandle extends StatelessWidget {
  const _NoteDragHandle({required this.index, required this.isSelected});

  final int index;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final borderColor = isSelected
        ? theme.colorScheme.primary.withValues(alpha: isDark ? 0.35 : 0.22)
        : theme.colorScheme.outline.withValues(alpha: isDark ? 0.18 : 0.12);
    final bgColor = isSelected
        ? theme.colorScheme.primary.withValues(alpha: isDark ? 0.12 : 0.08)
        : (isDark
            ? Colors.white.withValues(alpha: 0.03)
            : Colors.black.withValues(alpha: 0.02));
    final iconColor = isSelected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withValues(alpha: 0.3);

    return ReorderableDragStartListener(
      index: index,
      child: Tooltip(
        message: 'Trascina per riordinare',
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor, width: 1),
            ),
            child: Icon(
              Icons.drag_indicator_rounded,
              size: 18,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}
