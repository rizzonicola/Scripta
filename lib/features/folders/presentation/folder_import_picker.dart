import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/desktop_strings.dart';
import '../models/external_open_destination.dart';
import '../providers/folder_provider.dart';
import 'folder_picker_dialog.dart';

/// Sceglie dove importare una cartella esterna.
///
/// Mostra lo stesso elenco di "Sposta cartella": la radice ("Tutte le note") o
/// una qualunque cartella esistente. Restituisce il percorso dei nomi delle
/// cartelle di destinazione (`[]` = radice), da anteporre al nome della
/// cartella importata; `null` se l'utente annulla.
Future<List<String>?> showFolderImportDestinationPicker(
  BuildContext context,
  WidgetRef ref, {
  required String folderName,
}) async {
  final destination = await showExternalOpenDestinationPicker(
    context,
    ref,
    targetName: folderName,
    isFolder: true,
  );
  return destination?.pathSegments;
}

/// Sceglie dove aprire un file o importare una cartella esterna.
///
/// Restituisce la cartella selezionata (radice inclusa), con l'id per aprire
/// un file e il percorso dei nomi per ricreare l'albero di una cartella.
/// `null` se l'utente annulla.
Future<ExternalOpenDestination?> showExternalOpenDestinationPicker(
  BuildContext context,
  WidgetRef ref, {
  required String targetName,
  required bool isFolder,
}) async {
  final strings = DesktopStrings.of(context);
  final cancelLabel = MaterialLocalizations.of(context).cancelButtonLabel;
  final folders = ref.read(folderProvider.notifier);
  final destinations = flattenFolders(ref.read(folderProvider).rootFolders);

  String? selectedId;
  var confirmed = false;

  await showDialog<void>(
    context: context,
    builder: (_) => FolderPickerDialog(
      title: isFolder
          ? strings.importFolderTitle(targetName)
          : strings.openFileTitle(targetName),
      titleIcon: isFolder
          ? Icons.create_new_folder_outlined
          : Icons.note_add_outlined,
      rootIcon: Icons.folder_special_outlined,
      rootLabel: strings.importFolderRoot,
      emptyLabel: strings.importFolderNoDestinations,
      cancelLabel: cancelLabel,
      destinations: destinations,
      // L'apertura/importazione non ha una posizione attuale: la radice è
      // solo il valore predefinito e deve poter essere confermata.
      currentFolderId: null,
      allowCurrentSelection: true,
      onSelected: (folderId) {
        selectedId = folderId;
        confirmed = true;
      },
    ),
  );

  if (!confirmed) return null;
  return ExternalOpenDestination(
    folderId: selectedId,
    pathSegments: selectedId == null
        ? const <String>[]
        : folders.folderPathSegments(selectedId),
  );
}
