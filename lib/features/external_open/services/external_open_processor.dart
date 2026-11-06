import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../folders/models/external_open_destination.dart';
import '../../folders/providers/folder_provider.dart';
import '../../notes/providers/notes_provider.dart';
import '../../../core/services/external_open_service.dart';
import '../../import/services/import_parser.dart';
import '../../import/services/import_service.dart';

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

/// Chiede all'utente dove aprire una voce esterna e restituisce la
/// destinazione scelta, oppure `null` se annulla.
typedef ExternalOpenDestinationPicker =
    Future<ExternalOpenDestination?> Function(String targetName);

/// Trasforma percorsi e cartelle ricevuti dall'esterno in note dell'app.
///
/// - un FILE `.md`/`.markdown`/`.txt` diventa UNA nuova nota, con le stesse
///   regole di titolo/contenuto dell'importazione (vedi `parseNoteFile`), e
///   viene inserito nella cartella scelta tramite [chooseFileDestination]
///   oppure in [defaultFileFolderId];
/// - una CARTELLA viene importata ricorsivamente con `ImportService`, quindi
///   conserva la struttura delle sottocartelle e non modifica note esistenti;
///   la cartella stessa viene ricreata (con il suo nome) sotto la
///   destinazione scelta tramite [chooseFolderDestination];
/// - ogni voce è indipendente: un file illeggibile non impedisce di aprire gli
///   altri della stessa operazione.
class ExternalOpenProcessor {
  ExternalOpenProcessor._();

  /// [chooseFolderDestination] e [chooseFileDestination] sono separati perché
  /// le due sorgenti hanno esigenze diverse:
  ///  * una cartella importata deve ricreare il proprio albero sotto una
  ///    destinazione scelta (percorso di nomi);
  ///  * un file aperto da "Apri con Scripta" chiede la cartella, mentre un
  ///    file trascinato sulla finestra va nella cartella attualmente
  ///    selezionata nell'app tramite [defaultFileFolderId], senza dialog.
  ///
  /// Senza callback la cartella usa la radice e il file usa
  /// [defaultFileFolderId] (che può essere `null`, cioè la radice).
  static Future<ExternalOpenOutcome> openPaths(
    Iterable<String> rawPaths, {
    required NotesNotifier notes,
    required FolderNotifier folders,
    ExternalOpenDestinationPicker? chooseFolderDestination,
    ExternalOpenDestinationPicker? chooseFileDestination,
    String? defaultFileFolderId,
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
        final folderName = _importedFolderName(path);
        final List<String> destination;
        if (chooseFolderDestination == null) {
          destination = const <String>[];
        } else {
          // La scelta arriva prima della lettura: l'utente vede subito che
          // l'app ha ricevuto la cartella e non si legge nulla se annulla.
          final chosen = await chooseFolderDestination(folderName);
          if (chosen == null) continue;
          destination = chosen.pathSegments;
        }

        try {
          final entries = await ImportService.extractFromDirectory(
            Directory(path),
          );
          if (entries.isEmpty) {
            openedFolders++;
            continue;
          }

          final result = await ImportService.commitEntries(
            folders,
            notes,
            nestImportEntriesUnderFolder(
              entries,
              rootFolderName: folderName,
              destinationPath: destination,
            ),
          );
          openedFolders++;
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
        final nextTotalBytes = totalBytes + size;
        if (size > ImportService.maxEntryBytes ||
            nextTotalBytes > ImportService.maxTotalUncompressedBytes) {
          failed.add(path);
          continue;
        }

        // "Apri con Scripta" chiede dove mettere il file; il drag & drop usa
        // invece la cartella già selezionata nell'app (nessun dialog).
        var folderId = defaultFileFolderId;
        if (chooseFileDestination != null) {
          final chosen = await chooseFileDestination(p.basename(path));
          if (chosen == null) continue;
          folderId = chosen.folderId;
        }
        totalBytes = nextTotalBytes;

        final rawContent = utf8.decode(
          await file.readAsBytes(),
          allowMalformed: true,
        );
        final parsed = parseNoteFile(rawContent, p.basename(path));
        await notes.createNoteFromContent(
          title: parsed.title,
          content: parsed.content,
          folderId: folderId,
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

  /// Nome con cui ricreare la cartella importata. Per una radice di filesystem
  /// (caso limite) non esiste un basename utile: si usa un nome neutro invece
  /// di creare una cartella chiamata "/".
  static String _importedFolderName(String path) {
    final name = p.basename(p.normalize(path)).trim();
    if (name.isEmpty || name == p.separator || name == '/' || name == r'\') {
      return 'Cartella importata';
    }
    return name;
  }
}
