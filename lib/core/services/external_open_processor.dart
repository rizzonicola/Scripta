import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../features/folders/providers/folder_provider.dart';
import '../../features/notes/providers/notes_provider.dart';
import 'external_open_service.dart';
import 'import_parser.dart';
import 'import_service.dart';

/// Esito di un'apertura esterna (una o più voci, anche eterogenee).
///
/// [ignoredPaths] contiene file con estensione non supportata (es. un PDF
/// trascinato per errore), mentre [failedPaths] contiene voci che sembravano
/// apribili ma non lo erano (file illeggibile, troppo grande, cartella con
/// errori...). La separazione serve alla UI per distinguere "formato non
/// supportato" da "apertura fallita".
class ExternalOpenOutcome {
  final int openedFiles;
  final int importedNotes;
  final int importedFolders;
  final int openedFolders;
  final List<String> ignoredPaths;
  final List<String> failedPaths;

  const ExternalOpenOutcome({
    this.openedFiles = 0,
    this.importedNotes = 0,
    this.importedFolders = 0,
    this.openedFolders = 0,
    this.ignoredPaths = const <String>[],
    this.failedPaths = const <String>[],
  });
}

/// Trasforma percorsi e cartelle ricevuti dall'esterno in note dell'app.
///
/// - un FILE `.md`/`.markdown`/`.txt` diventa UNA nuova nota, con le stesse
///   regole di titolo/contenuto dell'importazione (vedi `parseNoteFile`);
/// - una CARTELLA viene importata ricorsivamente con `ImportService`, quindi
///   conserva la struttura delle sottocartelle e non modifica note esistenti;
/// - ogni voce è indipendente: un file illeggibile non impedisce di aprire gli
///   altri della stessa operazione.
class ExternalOpenProcessor {
  ExternalOpenProcessor._();

  static Future<ExternalOpenOutcome> openPaths(
    Iterable<String> rawPaths, {
    required NotesNotifier notes,
    required FolderNotifier folders,
  }) async {
    var openedFiles = 0;
    var importedNotes = 0;
    var importedFolders = 0;
    var openedFolders = 0;
    var totalBytes = 0;
    final ignored = <String>[];
    final failed = <String>[];
    final seen = <String>{};

    for (final raw in rawPaths) {
      final path = ExternalOpenService.normalizeOpenTarget(raw);
      if (path == null || !seen.add(path)) continue;

      final FileSystemEntityType type;
      try {
        type = await FileSystemEntity.type(path);
      } catch (_) {
        failed.add(path);
        continue;
      }

      if (type == FileSystemEntityType.directory) {
        openedFolders++;
        try {
          final entries = await ImportService.extractFromDirectory(
            Directory(path),
          );
          if (entries.isEmpty) continue;
          final result = await ImportService.commitEntries(
            folders,
            notes,
            entries,
          );
          importedNotes += result.importedNotes;
          importedFolders += result.importedFolders;
        } catch (_) {
          failed.add(path);
        }
        continue;
      }

      if (type != FileSystemEntityType.file) {
        failed.add(path);
        continue;
      }

      if (!hasImportableExtension(path)) {
        ignored.add(path);
        continue;
      }

      if (openedFiles + importedNotes >= ImportService.maxImportedFiles) {
        failed.add(path);
        continue;
      }

      try {
        final file = File(path);
        final size = await file.length();
        if (size > ImportService.maxEntryBytes ||
            totalBytes + size > ImportService.maxTotalUncompressedBytes) {
          failed.add(path);
          continue;
        }
        totalBytes += size;

        final rawContent = utf8.decode(
          await file.readAsBytes(),
          allowMalformed: true,
        );
        final parsed = parseNoteFile(rawContent, p.basename(path));
        await notes.createNoteFromContent(
          title: parsed.title,
          content: parsed.content,
        );
        openedFiles++;
      } catch (_) {
        failed.add(path);
      }
    }

    return ExternalOpenOutcome(
      openedFiles: openedFiles,
      importedNotes: importedNotes,
      importedFolders: importedFolders,
      openedFolders: openedFolders,
      ignoredPaths: ignored,
      failedPaths: failed,
    );
  }
}
