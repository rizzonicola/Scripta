import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/app_localizations.dart';
import '../../../core/l10n/desktop_strings.dart';
import '../../../core/services/export_service.dart';
import '../../../core/services/import_service.dart';
import '../../../core/utils/app_commands.dart';
import '../../../core/widgets/context_menu.dart';
import '../../../core/widgets/shortcuts_help_dialog.dart';
import '../../notes/providers/notes_provider.dart';
import '../models/folder_node.dart';
import '../providers/folder_provider.dart';
import 'folder_dialogs.dart';

/// Menu di "Tutte le note" / spazio vuoto della barra laterale.
List<ContextMenuEntry> workspaceMenuEntries(BuildContext context, WidgetRef ref) {
  final l10n = AppLocalizations.of(context);
  final ds = DesktopStrings.of(context);
  return [
    ContextMenuEntry(
      label: l10n.newNote,
      icon: Icons.note_add_outlined,
      shortcut: commandShortcutLabel(AppCommand.newNote),
      onSelected: () {
        ref.read(folderProvider.notifier).selectFolder(null);
        ref.read(notesProvider.notifier).createNote();
      },
    ),
    ContextMenuEntry(
      label: l10n.newFolder,
      icon: Icons.create_new_folder_outlined,
      shortcut: commandShortcutLabel(AppCommand.newFolder),
      onSelected: () => showAddFolderDialog(context, ref),
    ),
    const ContextMenuEntry.divider(),
    ContextMenuEntry(
      label: ds.exportAllZip,
      icon: Icons.archive_outlined,
      onSelected: () => ExportService.exportAllAsZip(context, ref),
    ),
    ContextMenuEntry(
      label: ds.importNotes,
      icon: Icons.file_upload_outlined,
      onSelected: () => ImportService.showImportOptions(context, ref),
    ),
    const ContextMenuEntry.divider(),
    ContextMenuEntry(
      label: ds.keyboardShortcuts,
      icon: Icons.keyboard_alt_outlined,
      shortcut: commandShortcutLabel(AppCommand.help),
      onSelected: () => ShortcutsHelpDialog.show(context),
    ),
  ];
}

/// Voci del menu di una cartella: le stesse del bottom sheet mobile ("..."),
/// più "Nuova nota qui" ed "Espandi/Comprimi".
List<ContextMenuEntry> folderMenuEntries(
  BuildContext context,
  WidgetRef ref,
  FolderNode node,
) {
  final l10n = AppLocalizations.of(context);
  final ds = DesktopStrings.of(context);
  return [
    ContextMenuEntry(
      label: ds.newNoteHere,
      icon: Icons.note_add_outlined,
      onSelected: () {
        ref.read(folderProvider.notifier).selectFolder(node.id);
        ref.read(notesProvider.notifier).createNote(folderId: node.id);
      },
    ),
    ContextMenuEntry(
      label: l10n.newSubfolder,
      icon: Icons.create_new_folder_outlined,
      onSelected: () => showAddFolderDialog(context, ref, parentId: node.id),
    ),
    if (node.children.isNotEmpty)
      ContextMenuEntry(
        label: node.isExpanded ? ds.collapse : ds.expand,
        icon: node.isExpanded
            ? Icons.unfold_less_rounded
            : Icons.unfold_more_rounded,
        onSelected: () =>
            ref.read(folderProvider.notifier).toggleExpand(node.id),
      ),
    const ContextMenuEntry.divider(),
    ContextMenuEntry(
      label: l10n.renameFolder,
      icon: Icons.edit_outlined,
      onSelected: () => showRenameFolderDialog(context, ref, node),
    ),
    ContextMenuEntry(
      label: ds.moveFolder,
      icon: Icons.drive_file_move_outlined,
      onSelected: () => showMoveFolderDialog(context, ref, node),
    ),
    ContextMenuEntry(
      label: ds.exportFolderZip,
      icon: Icons.folder_zip_outlined,
      onSelected: () => ExportService.exportFolderAsZip(context, ref, node),
    ),
    const ContextMenuEntry.divider(),
    ContextMenuEntry(
      label: l10n.deleteFolder,
      icon: Icons.delete_outline,
      isDestructive: true,
      onSelected: () => showDeleteFolderDialog(context, ref, node),
    ),
  ];
}
