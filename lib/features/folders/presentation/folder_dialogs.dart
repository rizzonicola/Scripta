import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/app_localizations.dart';
import '../../../core/services/export_service.dart';
import '../../sync/providers/sync_provider.dart';
import '../models/folder_node.dart';
import '../providers/folder_provider.dart';
import 'folder_name_dialog.dart';
import 'folder_picker_dialog.dart';

/// Dialog "Nuova cartella" / "Nuova sottocartella" ([parentId] != null).
void showAddFolderDialog(
  BuildContext context,
  WidgetRef ref, {
  String? parentId,
}) {
  final l10n = AppLocalizations.of(context);
  // I notifier si leggono PRIMA di aprire il dialog: dopo la conferma non si
  // usa più `ref` (il widget che l'ha aperto potrebbe essere già stato
  // rimosso) e l'operazione confermata si completa comunque.
  final folders = ref.read(folderProvider.notifier);
  final sync = ref.read(syncProvider.notifier);
  unawaited(
    FolderNameDialog.show(
      context,
      title: parentId == null ? l10n.newFolder : l10n.newSubfolder,
      hintText: l10n.folderName,
      cancelLabel: l10n.cancel,
      confirmLabel: l10n.confirm,
    ).then((name) {
      if (name == null) return;
      folders.addFolder(name, parentId: parentId);
      sync.onFolderStructureChanged();
    }),
  );
}

/// Dialog "Rinomina cartella".
void showRenameFolderDialog(
  BuildContext context,
  WidgetRef ref,
  FolderNode node,
) {
  final l10n = AppLocalizations.of(context);
  final folders = ref.read(folderProvider.notifier);
  final sync = ref.read(syncProvider.notifier);
  unawaited(
    FolderNameDialog.show(
      context,
      title: l10n.renameFolder,
      hintText: l10n.folderName,
      cancelLabel: l10n.cancel,
      confirmLabel: l10n.save,
      initialName: node.name,
    ).then((name) {
      if (name == null) return;
      folders.renameFolder(node.id, name);
      // Come per le altre modifiche strutturali (nuova cartella, sposta,
      // elimina): senza questa chiamata la rinomina restava `dirty` fino a un
      // trigger di sync non correlato (cambio nota, inattivita', ...).
      sync.onFolderStructureChanged();
    }),
  );
}

/// Dialog "Sposta cartella": elenca tutte le cartelle tranne [nodeToMove] e
/// i suoi discendenti (spostarla dentro se stessa creerebbe un ciclo).
void showMoveFolderDialog(
  BuildContext context,
  WidgetRef ref,
  FolderNode nodeToMove,
) {
  // Catturati PRIMA di aprire il dialog: restano validi anche se, spostando la
  // cartella, il widget che ha aperto il dialog viene ricostruito o rimosso.
  final messenger = ScaffoldMessenger.of(context);
  final folders = ref.read(folderProvider.notifier);
  final sync = ref.read(syncProvider.notifier);
  final destinations = flattenFolders(
    ref.read(folderProvider).rootFolders,
    excludeSubtreeOf: nodeToMove.id,
  );

  unawaited(
    showDialog<void>(
      context: context,
      builder: (_) => FolderPickerDialog(
        title: 'Sposta "${nodeToMove.name}"',
        rootIcon: Icons.folder_special_outlined,
        rootLabel: 'Livello principale (Radice)',
        emptyLabel: 'Nessun\'altra cartella disponibile',
        cancelLabel: 'Annulla',
        destinations: destinations,
        currentFolderId: nodeToMove.parentId,
        onSelected: (targetId) {
          final moved = folders.moveFolder(nodeToMove.id, targetId);
          if (!moved) return;
          sync.onFolderStructureChanged();

          final String message;
          if (targetId == null) {
            message = 'Cartella "${nodeToMove.name}" spostata alla radice';
          } else {
            final targetName =
                destinations.firstWhere((d) => d.node.id == targetId).node.name;
            message = 'Cartella "${nodeToMove.name}" spostata in "$targetName"';
          }
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

void showDeleteFolderDialog(
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
              // NB: la generazione precedente non lo faceva qui, quindi
              // una cartella cancellata non veniva mai propagata al
              // server. La cascade locale (vedi FolderNotifier.deleteFolder)
              // resta comunque immediata e corretta anche offline; questa
              // chiamata garantisce solo che raggiunga il server appena
              // possibile.
              ref.read(syncProvider.notifier).onFolderStructureChanged();
              Navigator.of(dialogCtx).pop();
            },
            child: Text(l10n.confirm),
          ),
        ],
      );
    },
  );
}

void showFolderOptionsSheet(
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
                showAddFolderDialog(context, ref, parentId: node.id);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l10n.renameFolder),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                showRenameFolderDialog(context, ref, node);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outlined),
              title: const Text('Sposta cartella...'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                showMoveFolderDialog(context, ref, node);
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
                showDeleteFolderDialog(context, ref, node);
              },
            ),
          ],
        ),
      );
    },
  );
}
