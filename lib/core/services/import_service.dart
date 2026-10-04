import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/folders/models/folder_node.dart';
import '../../features/folders/providers/folder_provider.dart';
import '../../features/notes/providers/notes_provider.dart';
import 'import_parser.dart';

/// Importazione di note/cartelle da un backup ZIP (creato da
/// [ExportService.exportAllAsZip]/[ExportService.exportFolderAsZip]) o da una
/// cartella scelta direttamente sul filesystem.
///
/// PRINCIPI:
///  - SOLO ADDITIVO: non viene mai modificata o cancellata una nota o una
///    cartella esistente. Le cartelle il cui nome coincide (case-insensitive)
///    con una già presente nello stesso "livello" vengono riutilizzate (le
///    note vengono quindi aggiunte al loro interno); le note vengono SEMPRE
///    create come nuove entità con un id fresco, mai fatte combaciare con
///    una esistente, per evitare qualunque rischio di sovrascrittura
///    distruttiva di contenuto già presente.
///  - STRUTTURA E TITOLI COME NELL'ESPORTAZIONE: le note che l'esportazione
///    raccoglie in `Non_Catalogate/` tornano alla radice ("Tutte le note")
///    invece di ricreare quella cartella, e il titolo di una nota è il nome
///    del suo file (un `# Titolo` in testa lo sostituisce solo se ne è
///    l'eco). Le regole stanno in `import_parser.dart`, accanto alle
///    convenzioni dell'esportazione che condividono.
///  - NESSUN BLOCCO DELL'INTERFACCIA: la lettura di file/ZIP di grandi
///    dimensioni avviene con API asincrone (`Directory.list`, lettura bytes
///    async) invece delle controparti sincrone, e l'inserimento delle note
///    nello stato dell'app avviene in un'unica operazione di blocco (vedi
///    `NotesNotifier.importNotesBulk`) invece che nota per nota.
class ImportService {
  ImportService._();

  // ---- Limiti anti "zip bomb" / import fuori scala -------------------------
  // Uno ZIP (o una cartella) scelto dall'utente può essere malevolo o
  // semplicemente enorme: senza limiti un archivio piccolo che si espande a
  // gigabyte, o con milioni di voci, esaurirebbe memoria/CPU e bloccherebbe
  // l'app. Tutti i limiti sono verificati PRIMA di decomprimere/leggere il
  // contenuto (dimensioni dichiarate) e, dove possibile, anche dopo.
  static const int maxZipBytes = 100 * 1024 * 1024; // ZIP compresso: 100 MiB
  static const int maxZipEntries = 20000; // voci totali nell'archivio
  static const int maxImportedFiles = 5000; // file .md/.markdown/.txt importabili
  static const int maxEntryBytes = 10 * 1024 * 1024; // singola nota: 10 MiB
  static const int maxTotalUncompressedBytes = 200 * 1024 * 1024; // somma: 200 MiB

  static String _mb(int bytes) => '${bytes ~/ (1024 * 1024)} MiB';

  /// Mostra un piccolo selettore con le due modalità di importazione
  /// supportate (file ZIP o cartella), richiamato dalla voce "Importa" nel
  /// menu principale (tre punti) della sidebar delle cartelle.
  static Future<void> showImportOptions(
    BuildContext context,
    WidgetRef ref,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Text(
                      'Importa note',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.folder_zip_outlined),
                title: const Text('Da file ZIP'),
                subtitle: const Text('Un backup esportato in precedenza'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  importFromZipFile(context, ref);
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_folder_upload_outlined),
                title: const Text('Da cartella'),
                subtitle: const Text('Una cartella di file .md sul dispositivo'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  importFromFolder(context, ref);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Importa selezionando un singolo file .zip.
  static Future<void> importFromZipFile(
    BuildContext context,
    WidgetRef ref,
  ) async {
    try {
      // file_picker v12+ (architettura federata): FilePicker.platform è
      // stato rimosso, pickFiles() ora restituisce direttamente
      // List<PlatformFile> (lista vuota se annullato), e 'withData'/
      // 'PlatformFile.bytes' sono deprecati in favore di
      // PlatformFile.readAsBytes(), che carica i byte on-demand in modo
      // uniforme su tutte le piattaforme (che il file sia già in memoria o
      // vada letto da 'path').
      final result = await FilePicker.pickFiles(
        dialogTitle: 'Seleziona un backup ZIP da importare',
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (result.isEmpty) return;

      final picked = result.single;
      // PlatformFile.size non esiste più in file_picker v12: la dimensione
      // si ricava dal file su disco (se disponibile) prima di caricarlo in
      // memoria; in assenza di path si applica comunque il controllo sui
      // byte letti (ripetuto in _extractFromZipBytes).
      final pickedPath = picked.path;
      final pickedSize =
          pickedPath != null ? await File(pickedPath).length() : null;
      if (pickedSize != null && pickedSize > maxZipBytes) {
        if (context.mounted) {
          _showSnack(context, 'File ZIP troppo grande (massimo ${_mb(maxZipBytes)}).',
              isError: true);
        }
        return;
      }
      final Uint8List bytes;
      try {
        bytes = await picked.readAsBytes();
      } catch (_) {
        if (context.mounted) {
          _showSnack(context, 'Impossibile leggere il file selezionato.',
              isError: true);
        }
        return;
      }

      if (!context.mounted) return;
      await _runImport(
        context,
        ref,
        () async => _extractFromZipBytes(bytes),
      );
    } catch (e) {
      if (context.mounted) {
        _showSnack(context, 'Errore durante la lettura dello ZIP: $e',
            isError: true);
      }
    }
  }

  /// Importa selezionando direttamente una cartella dal filesystem.
  static Future<void> importFromFolder(
    BuildContext context,
    WidgetRef ref,
  ) async {
    try {
      final dirPath = await FilePicker.getDirectoryPath(
        dialogTitle: 'Seleziona la cartella da importare',
      );
      if (dirPath == null) return;

      if (!context.mounted) return;
      await _runImport(
        context,
        ref,
        () => extractFromDirectory(Directory(dirPath)),
      );
    } catch (e) {
      if (context.mounted) {
        _showSnack(context, 'Errore durante la lettura della cartella: $e',
            isError: true);
      }
    }
  }

  /// Pipeline comune: mostra un indicatore di avanzamento non-bloccante per
  /// l'utente (ma senza mai freezare l'app, dato che tutto il lavoro pesante
  /// è asincrono), estrae le voci grezze, le materializza in cartelle/note
  /// reali e mostra un riepilogo finale.
  static Future<void> _runImport(
    BuildContext context,
    WidgetRef ref,
    Future<List<ImportEntry>> Function() extract,
  ) async {
    _showLoadingDialog(context);
    try {
      final entries = await extract();
      final result = await _commitEntries(ref, entries);
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();

      if (entries.isEmpty) {
        if (context.mounted) {
          _showSnack(
            context,
            'Nessuna nota Markdown trovata da importare.',
          );
        }
        return;
      }

      if (context.mounted) {
        _showSnack(
          context,
          'Importazione completata: ${result.importedNotes} note'
          '${result.importedFolders > 0 ? ' e ${result.importedFolders} nuove cartelle' : ''}.',
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _showSnack(context, 'Errore durante l\'importazione: $e', isError: true);
      }
    }
  }

  static void _showLoadingDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('Importazione in corso...')),
          ],
        ),
      ),
    );
  }

  static void _showSnack(BuildContext context, String message,
      {bool isError = false}) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade800 : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Estrazione: ZIP
  // ---------------------------------------------------------------------

  /// Decodifica ed estrae le voci di uno ZIP potenzialmente grande.
  ///
  /// `ZipDecoder().decodeBytes` è CPU-bound e sincrono: eseguito
  /// direttamente sull'isolate principale bloccherebbe il thread della UI
  /// (frame freeze/jank) per l'intera durata della decompressione su backup
  /// voluminosi. Con [compute] il lavoro pesante viene invece eseguito su un
  /// isolate dedicato, lasciando la UI reattiva; [decodeZipEntries] è
  /// un metodo statico (non una closure) proprio perché è questo il
  /// requisito di `compute` per poter essere invocato nel nuovo isolate.
  static Future<List<ImportEntry>> _extractFromZipBytes(
    Uint8List bytes,
  ) {
    return compute(decodeZipEntries, bytes);
  }

  /// Parte sincrona di [_extractFromZipBytes]. Pubblica solo perché i test
  /// la invocano direttamente, senza isolate.
  @visibleForTesting
  static List<ImportEntry> decodeZipEntries(Uint8List bytes) {
    if (bytes.length > maxZipBytes) {
      throw FormatException('ZIP troppo grande (massimo ${_mb(maxZipBytes)}).');
    }
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.files.length > maxZipEntries) {
      throw const FormatException('ZIP con troppe voci (massimo $maxZipEntries).');
    }
    final entries = <ImportEntry>[];
    var totalBytes = 0;

    for (final file in archive.files) {
      if (!file.isFile) continue;
      // Difesa in profondità e rumore dei sistemi operativi: uno ZIP
      // malformato/malevolo non deve poter referenziare percorsi fuori dalla
      // gerarchia che stiamo costruendo (path traversal, percorsi assoluti,
      // lettere di unità Windows) e gli ZIP di macOS portano con sé cartelle
      // di metadati. `null` = voce da ignorare. Qui si decide anche che le
      // note di `Non_Catalogate/` tornano alla radice (vedi import_parser).
      final location = mapZipEntryPath(file.name);
      if (location == null) continue;
      final fileName = location.fileName;

      // Limiti verificati sulla dimensione DICHIARATA, prima di accedere a
      // `file.content` (che è ciò che decomprime davvero il contenuto).
      if (entries.length >= maxImportedFiles) {
        throw const FormatException('Troppi file da importare (massimo $maxImportedFiles).');
      }
      if (file.size > maxEntryBytes) {
        throw FormatException('Il file "$fileName" supera ${_mb(maxEntryBytes)}.');
      }
      totalBytes += file.size;
      if (totalBytes > maxTotalUncompressedBytes) {
        throw FormatException(
            'Contenuto complessivo troppo grande (massimo ${_mb(maxTotalUncompressedBytes)} decompressi).');
      }

      final contentBytes = file.content as List<int>;
      // La dimensione dichiarata nell'header può mentire: si ricontrolla
      // quella effettiva.
      if (contentBytes.length > maxEntryBytes) {
        throw FormatException('Il file "$fileName" supera ${_mb(maxEntryBytes)}.');
      }
      final rawContent = utf8.decode(contentBytes, allowMalformed: true);

      entries.add(ImportEntry(
        folderPathSegments: location.folders,
        fileName: fileName,
        rawContent: rawContent,
      ));
    }

    return entries;
  }

  // ---------------------------------------------------------------------
  // Estrazione: cartella su filesystem
  // ---------------------------------------------------------------------

  /// Legge ricorsivamente una cartella scelta dall'utente. Pubblica solo
  /// perché i test la invocano su una cartella temporanea reale.
  @visibleForTesting
  static Future<List<ImportEntry>> extractFromDirectory(
    Directory root,
  ) async {
    final entries = <ImportEntry>[];
    var totalBytes = 0;

    // Directory.list (async) invece di listSync: evita di bloccare
    // l'isolate principale mentre si attraversano cartelle potenzialmente
    // molto grandi.
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;

      // Percorso relativo alla cartella scelta, calcolato e spezzato con le
      // regole NATIVE della piattaforma (`\` e lettere di unità su Windows,
      // `/` altrove). Prima si confrontava il prefisso testuale dopo aver
      // trasformato ogni `\` in `/`, anche su piattaforme dove `\` è un
      // carattere legale di un nome di file.
      final location = mapFilePath(entity.path, rootPath: root.path);
      if (location == null) continue;
      final fileName = location.fileName;

      // Stessi limiti dello ZIP, controllati sulla dimensione su disco PRIMA
      // di leggere il file.
      if (entries.length >= maxImportedFiles) {
        throw const FormatException('Troppi file da importare (massimo $maxImportedFiles).');
      }
      final size = await entity.length();
      if (size > maxEntryBytes) {
        throw FormatException('Il file "$fileName" supera ${_mb(maxEntryBytes)}.');
      }
      totalBytes += size;
      if (totalBytes > maxTotalUncompressedBytes) {
        throw FormatException('Contenuto complessivo troppo grande (massimo ${_mb(maxTotalUncompressedBytes)}).');
      }

      String rawContent;
      try {
        rawContent = await entity.readAsString();
      } catch (_) {
        final bytes = await entity.readAsBytes();
        rawContent = utf8.decode(bytes, allowMalformed: true);
      }

      entries.add(ImportEntry(
        folderPathSegments: location.folders,
        fileName: fileName,
        rawContent: rawContent,
      ));
    }

    return entries;
  }

  // ---------------------------------------------------------------------
  // Commit: risolve/crea cartelle e inserisce le note in blocco
  // ---------------------------------------------------------------------

  static Future<({int importedNotes, int importedFolders})> _commitEntries(
    WidgetRef ref,
    List<ImportEntry> entries,
  ) {
    return commitEntries(
      ref.read(folderProvider.notifier),
      ref.read(notesProvider.notifier),
      entries,
    );
  }

  /// Materializza [entries] in cartelle e note. Riceve i due notifier invece
  /// di un `WidgetRef` così i test lo usano con DAO finti, senza UI.
  @visibleForTesting
  static Future<({int importedNotes, int importedFolders})> commitEntries(
    FolderNotifier folders,
    NotesNotifier notes,
    List<ImportEntry> entries,
  ) async {
    if (entries.isEmpty) return (importedNotes: 0, importedFolders: 0);

    final folderIdByPath = <String, String?>{};
    var importedFolders = 0;
    final notesToImport = <({String title, String content, String? folderId})>[];

    for (final entry in entries) {
      // Percorso vuoto = radice: nessuna cartella, la nota compare in
      // "Tutte le note".
      final folderId = _ensureFolderPath(
        folders,
        entry.folderPathSegments,
        folderIdByPath,
        onFolderCreated: () => importedFolders++,
      );

      final parsed = parseNoteFile(entry.rawContent, entry.fileName);
      notesToImport.add((
        title: parsed.title,
        content: parsed.content,
        folderId: folderId,
      ));
    }

    final importedNotes = await notes.importNotesBulk(notesToImport);

    return (importedNotes: importedNotes, importedFolders: importedFolders);
  }

  /// Risolve la catena di segmenti di percorso in un folderId, riusando le
  /// cartelle già esistenti con lo stesso nome allo stesso livello (ricerca
  /// case-insensitive) e creando solo i segmenti mancanti tramite
  /// [FolderNotifier.addFolder] (già sincrono nello stato in-memory, quindi
  /// visibile immediatamente alla prossima iterazione). Una catena vuota è la
  /// radice e restituisce `null`.
  static String? _ensureFolderPath(
    FolderNotifier folders,
    List<String> segments,
    Map<String, String?> cache, {
    required VoidCallback onFolderCreated,
  }) {
    if (segments.isEmpty) return null;

    String pathKey = '';
    String? parentId;

    for (final rawSegment in segments) {
      final segment = rawSegment.trim().isEmpty ? 'Senza nome' : rawSegment.trim();
      pathKey = pathKey.isEmpty ? segment.toLowerCase() : '$pathKey/${segment.toLowerCase()}';

      if (cache.containsKey(pathKey)) {
        parentId = cache[pathKey];
        continue;
      }

      final siblings = _siblingsOf(folders, parentId);
      FolderNode? existing;
      for (final node in siblings) {
        if (node.name.toLowerCase() == segment.toLowerCase()) {
          existing = node;
          break;
        }
      }

      final String resolvedId;
      if (existing != null) {
        resolvedId = existing.id;
      } else {
        final created = folders.addFolder(segment, parentId: parentId);
        resolvedId = created.id;
        onFolderCreated();
      }

      cache[pathKey] = resolvedId;
      parentId = resolvedId;
    }

    return parentId;
  }

  static List<FolderNode> _siblingsOf(FolderNotifier folders, String? parentId) {
    if (parentId == null) return folders.rootFolders;
    final parent = folders.findNode(parentId);
    return parent?.children ?? const [];
  }
}
