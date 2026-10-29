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
import '../../features/settings/providers/settings_provider.dart';
import '../../features/sync/models/sync_models.dart';
import 'backup_manifest.dart';
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
  static const int maxImportedFiles =
      5000; // file .md/.markdown/.txt importabili
  static const int maxEntryBytes = 10 * 1024 * 1024; // singola nota: 10 MiB
  static const int maxTotalUncompressedBytes =
      200 * 1024 * 1024; // somma: 200 MiB
  static const int maxFolderDepth = 32;
  static const int maxImportedFolders = 5000;

  /// Il manifest contiene una copia del testo di TUTTE le note (serve a
  /// ripristinare titolo/contenuto esatti quando il Markdown è ambiguo), quindi
  /// non può essere soggetto al limite di 10 MiB di una singola nota: un
  /// backup grande ma legittimo diventerebbe non ripristinabile.
  static const int maxManifestBytes = maxTotalUncompressedBytes;

  static String _mb(int bytes) => '${bytes ~/ (1024 * 1024)} MiB';

  /// Mostra un piccolo selettore con le due modalità di importazione
  /// supportate (file ZIP o cartella), richiamato dalla voce "Importa" nel
  /// menu principale (tre punti) della sidebar delle cartelle.
  static Future<void> showImportOptions(BuildContext context, WidgetRef ref) {
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
                subtitle: const Text(
                  'Una cartella di file .md sul dispositivo',
                ),
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
      final pickedSize = pickedPath != null
          ? await File(pickedPath).length()
          : null;
      if (pickedSize != null && pickedSize > maxZipBytes) {
        if (context.mounted) {
          _showSnack(
            context,
            'File ZIP troppo grande (massimo ${_mb(maxZipBytes)}).',
            isError: true,
          );
        }
        return;
      }
      final Uint8List bytes;
      try {
        bytes = await picked.readAsBytes();
      } catch (_) {
        if (context.mounted) {
          _showSnack(
            context,
            'Impossibile leggere il file selezionato.',
            isError: true,
          );
        }
        return;
      }

      if (!context.mounted) return;
      await _runImport(context, ref, () async => _extractFromZipBytes(bytes));
    } catch (e) {
      if (context.mounted) {
        _showSnack(
          context,
          'Errore durante la lettura dello ZIP: $e',
          isError: true,
        );
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
        () async => ImportBundle(
          entries: await extractFromDirectory(Directory(dirPath)),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        _showSnack(
          context,
          'Errore durante la lettura della cartella: $e',
          isError: true,
        );
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
    Future<ImportBundle> Function() extract,
  ) async {
    _showLoadingDialog(context);
    try {
      final bundle = await extract();
      final result = await _commitEntries(ref, bundle);
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();

      if (bundle.entries.isEmpty && bundle.emptyFolderPaths.isEmpty) {
        if (context.mounted) {
          _showSnack(context, 'Nessuna nota Markdown trovata da importare.');
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
        _showSnack(
          context,
          'Errore durante l\'importazione: $e',
          isError: true,
        );
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

  static void _showSnack(
    BuildContext context,
    String message, {
    bool isError = false,
  }) {
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
  static Future<ImportBundle> _extractFromZipBytes(Uint8List bytes) {
    return compute(decodeZipBundle, bytes);
  }

  /// Parte sincrona di [_extractFromZipBytes]. Pubblica solo perché i test
  /// la invocano direttamente, senza isolate.
  @visibleForTesting
  static List<ImportEntry> decodeZipEntries(Uint8List bytes) =>
      decodeZipBundle(bytes).entries;

  /// Validazione del central directory ZIP eseguita PRIMA di `ZipDecoder`.
  /// Non decomprime nulla: limita numero di voci, dimensione complessiva,
  /// singola voce, ZIP64, cifratura e symlink.
  static void _preflightZip(Uint8List bytes) {
    if (bytes.length < 22) {
      throw const FormatException('ZIP non valido o troncato.');
    }

    var eocd = -1;
    final minOffset = bytes.length - 22 - 0xffff;
    for (var i = bytes.length - 22; i >= (minOffset < 0 ? 0 : minOffset); i--) {
      if (_u32(bytes, i) != 0x06054b50) continue;
      final commentLength = _u16(bytes, i + 20);
      if (i + 22 + commentLength <= bytes.length) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) {
      throw const FormatException('ZIP non valido: central directory assente.');
    }

    final disk = _u16(bytes, eocd + 4);
    final cdDisk = _u16(bytes, eocd + 6);
    final entriesOnDisk = _u16(bytes, eocd + 8);
    final entries = _u16(bytes, eocd + 10);
    final cdSize = _u32(bytes, eocd + 12);
    final cdOffset = _u32(bytes, eocd + 16);

    if (disk != 0 || cdDisk != 0 || entriesOnDisk != entries) {
      throw const FormatException('ZIP multi-volume non supportato.');
    }
    if (entries == 0xffff || cdOffset == 0xffffffff || cdSize == 0xffffffff) {
      throw const FormatException('ZIP64 non supportato per l\'importazione.');
    }
    if (entries > maxZipEntries) {
      throw const FormatException(
        'ZIP con troppe voci (massimo $maxZipEntries).',
      );
    }
    if (cdOffset + cdSize > bytes.length) {
      throw const FormatException(
        'ZIP non valido: central directory corrotta.',
      );
    }

    var position = cdOffset;
    var totalBytes = 0;
    for (var i = 0; i < entries; i++) {
      if (position + 46 > bytes.length || _u32(bytes, position) != 0x02014b50) {
        throw const FormatException(
          'ZIP non valido: voce del central directory corrotta.',
        );
      }

      final madeBy = _u16(bytes, position + 4);
      final flags = _u16(bytes, position + 8);
      final method = _u16(bytes, position + 10);
      final compressedSize = _u32(bytes, position + 20);
      final uncompressedSize = _u32(bytes, position + 24);
      final nameLength = _u16(bytes, position + 28);
      final extraLength = _u16(bytes, position + 30);
      final commentLength = _u16(bytes, position + 32);
      final externalAttributes = _u32(bytes, position + 38);
      final nameStart = position + 46;
      final nextPosition = nameStart + nameLength + extraLength + commentLength;
      if (nextPosition > bytes.length) {
        throw const FormatException(
          'ZIP non valido: nome della voce fuori dai limiti.',
        );
      }
      if (compressedSize == 0xffffffff || uncompressedSize == 0xffffffff) {
        throw const FormatException(
          'ZIP64 non supportato per l\'importazione.',
        );
      }
      if (flags & 0x0001 != 0) {
        throw const FormatException('ZIP cifrato non supportato.');
      }
      if (method != 0 && method != 8) {
        throw const FormatException('Metodo di compressione non supportato.');
      }

      // Creatore Unix + permessi 0xA000: symlink. Non va mai importato.
      if (madeBy >> 8 == 3 && ((externalAttributes >> 16) & 0xf000) == 0xa000) {
        throw const FormatException(
          'Il backup contiene un collegamento simbolico non supportato.',
        );
      }

      final rawName = utf8.decode(
        bytes.sublist(nameStart, nameStart + nameLength),
        allowMalformed: true,
      );
      final limit = _normalizeManifestPath(rawName) == backupManifestFileName
          ? maxManifestBytes
          : maxEntryBytes;
      if (uncompressedSize > limit) {
        throw FormatException('La voce "$rawName" supera ${_mb(limit)}.');
      }
      totalBytes += uncompressedSize;
      if (totalBytes > maxTotalUncompressedBytes) {
        throw FormatException(
          'Contenuto complessivo troppo grande (massimo ${_mb(maxTotalUncompressedBytes)} decompressi).',
        );
      }
      position = nextPosition;
    }
  }

  static int _u16(Uint8List bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int _u32(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  @visibleForTesting
  static ImportBundle decodeZipBundle(Uint8List bytes) {
    if (bytes.length > maxZipBytes) {
      throw FormatException('ZIP troppo grande (massimo ${_mb(maxZipBytes)}).');
    }

    // Il decoder dell'archivio legge TUTTO il central directory e, per le
    // voci symlink, ne decomprime subito il contenuto. La preflight legge
    // prima numero di voci, dimensioni dichiarate e tipo di file direttamente
    // dal central directory: un archivio ostile viene rifiutato senza
    // costruire l'Archive né decomprimere nulla.
    _preflightZip(bytes);

    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.files.length > maxZipEntries) {
      throw const FormatException(
        'ZIP con troppe voci (massimo $maxZipEntries).',
      );
    }
    final entries = <ImportEntry>[];
    var totalBytes = 0;

    // Il manifest è alla radice. Un manifest presente ma illeggibile NON
    // deve essere ignorato silenziosamente: perderemmo proprio i metadati che
    // il backup promette di conservare. Meglio un errore chiaro.
    BackupManifest? manifest;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (_normalizeManifestPath(file.name) != backupManifestFileName) {
        continue;
      }
      if (file.size > maxManifestBytes) {
        throw const FormatException('Manifest del backup troppo grande.');
      }
      final contentBytes = file.content as List<int>;
      if (contentBytes.length > maxManifestBytes) {
        throw const FormatException('Manifest del backup troppo grande.');
      }
      totalBytes += contentBytes.length;
      if (totalBytes > maxTotalUncompressedBytes) {
        throw FormatException(
          'Contenuto complessivo troppo grande (massimo ${_mb(maxTotalUncompressedBytes)} decompressi).',
        );
      }
      final raw = utf8.decode(contentBytes, allowMalformed: true);
      try {
        manifest = BackupManifest.decode(raw);
      } catch (e) {
        throw FormatException('Manifest del backup non valido: $e');
      }
      if (manifest.folders.length > maxImportedFiles ||
          manifest.notes.length > maxImportedFiles) {
        throw const FormatException('Manifest del backup con troppi elementi.');
      }
      break;
    }

    final notesByPath = <String, BackupNote>{
      if (manifest != null)
        for (final note in manifest.notes)
          _normalizeManifestPath(note.path): note,
    };

    for (final file in archive.files) {
      if (!file.isFile) continue;
      // Difesa in profondità e rumore dei sistemi operativi: uno ZIP
      // malformato/malevole non deve poter referenziare percorsi fuori dalla
      // gerarchia che stiamo costruendo (path traversal, percorsi assoluti,
      // lettere di unità Windows) e gli ZIP di macOS portano con sé cartelle
      // di metadati. `null` = voce da ignorare. Qui si decide anche che le
      // note di `Non_Catalogate/` tornano alla radice (vedi import_parser).
      if (file.isSymbolicLink) {
        throw const FormatException(
          'Il backup contiene un collegamento simbolico non supportato.',
        );
      }
      final location = mapZipEntryPath(file.name);
      if (location == null) continue;
      if (location.folders.length > maxFolderDepth) {
        throw const FormatException(
          'Percorso troppo profondo (massimo $maxFolderDepth livelli).',
        );
      }
      final fileName = location.fileName;

      // Limiti verificati sulla dimensione DICHIARATA, prima di accedere a
      // `file.content` (che è ciò che decomprime davvero il contenuto).
      if (entries.length >= maxImportedFiles) {
        throw const FormatException(
          'Troppi file da importare (massimo $maxImportedFiles).',
        );
      }
      if (file.size > maxEntryBytes) {
        throw FormatException(
          'Il file "$fileName" supera ${_mb(maxEntryBytes)}.',
        );
      }
      final contentBytes = file.content as List<int>;
      // La dimensione dichiarata nell'header può mentire: si ricontrolla
      // quella effettiva.
      if (contentBytes.length > maxEntryBytes) {
        throw FormatException(
          'Il file "$fileName" supera ${_mb(maxEntryBytes)}.',
        );
      }
      totalBytes += contentBytes.length;
      if (totalBytes > maxTotalUncompressedBytes) {
        throw FormatException(
          'Contenuto complessivo troppo grande (massimo ${_mb(maxTotalUncompressedBytes)} decompressi).',
        );
      }
      final rawContent = utf8.decode(contentBytes, allowMalformed: true);

      entries.add(
        ImportEntry(
          folderPathSegments: location.folders,
          fileName: fileName,
          rawContent: rawContent,
          manifestNote: notesByPath[_normalizeManifestPath(file.name)],
        ),
      );
    }

    return ImportBundle(
      entries: entries,
      emptyFolderPaths: [
        if (manifest != null)
          for (final folder in manifest.folders) folder.path,
      ],
      settings: manifest?.settings,
    );
  }

  static String _normalizeManifestPath(String path) =>
      path.replaceAll('\\', '/').replaceFirst(RegExp(r'^\./'), '');

  // ---------------------------------------------------------------------
  // Estrazione: cartella su filesystem
  // ---------------------------------------------------------------------

  /// Legge ricorsivamente una cartella scelta dall'utente. Pubblica solo
  /// perché i test la invocano su una cartella temporanea reale.
  @visibleForTesting
  static Future<List<ImportEntry>> extractFromDirectory(Directory root) async {
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
      if (location.folders.length > maxFolderDepth) {
        throw const FormatException(
          'Percorso troppo profondo (massimo $maxFolderDepth livelli).',
        );
      }
      final fileName = location.fileName;

      // Stessi limiti dello ZIP, controllati sulla dimensione su disco PRIMA
      // di leggere il file.
      if (entries.length >= maxImportedFiles) {
        throw const FormatException(
          'Troppi file da importare (massimo $maxImportedFiles).',
        );
      }
      final size = await entity.length();
      if (size > maxEntryBytes) {
        throw FormatException(
          'Il file "$fileName" supera ${_mb(maxEntryBytes)}.',
        );
      }
      totalBytes += size;
      if (totalBytes > maxTotalUncompressedBytes) {
        throw FormatException(
          'Contenuto complessivo troppo grande (massimo ${_mb(maxTotalUncompressedBytes)}).',
        );
      }

      String rawContent;
      try {
        rawContent = await entity.readAsString();
      } catch (_) {
        final bytes = await entity.readAsBytes();
        rawContent = utf8.decode(bytes, allowMalformed: true);
      }

      entries.add(
        ImportEntry(
          folderPathSegments: location.folders,
          fileName: fileName,
          rawContent: rawContent,
        ),
      );
    }

    return entries;
  }

  // ---------------------------------------------------------------------
  // Commit: risolve/crea cartelle e inserisce le note in blocco
  // ---------------------------------------------------------------------

  static Future<({int importedNotes, int importedFolders})> _commitEntries(
    WidgetRef ref,
    ImportBundle bundle,
  ) async {
    final result = await commitEntries(
      ref.read(folderProvider.notifier),
      ref.read(notesProvider.notifier),
      bundle.entries,
      emptyFolderPaths: bundle.emptyFolderPaths,
    );

    // Le impostazioni sono parte del backup completo. `applyRemoteSettings`
    // scrive le preferenze e NON le rimanda al server: un import locale non
    // deve sovrascrivere le impostazioni dell'account senza che l'utente
    // abbia scelto di sincronizzarle.
    final rawSettings = bundle.settings;
    if (rawSettings != null) {
      try {
        final dto = UserSettingsDto.fromJson(
          Map<String, dynamic>.from(rawSettings),
        );
        await ref.read(settingsProvider.notifier).applyRemoteSettings(dto);
      } catch (_) {
        // Un manifest di una versione futura può avere impostazioni con
        // campi sconosciuti: le note sono già importate, non buttiamo via
        // tutto per una preferenza.
      }
    }
    return result;
  }

  /// Materializza [entries] in cartelle e note. Riceve i due notifier invece
  /// di un `WidgetRef` così i test lo usano con DAO finti, senza UI.
  @visibleForTesting
  static Future<({int importedNotes, int importedFolders})> commitEntries(
    FolderNotifier folders,
    NotesNotifier notes,
    List<ImportEntry> entries, {
    List<String> emptyFolderPaths = const [],
  }) async {
    if (entries.isEmpty && emptyFolderPaths.isEmpty) {
      return (importedNotes: 0, importedFolders: 0);
    }

    final folderIdByPath = <String, String?>{};
    var importedFolders = 0;

    // Le cartelle vuote del manifest non compaiono in nessun percorso di
    // nota: vanno create esplicitamente, altrimenti un backup di una
    // struttura di sole cartelle si "svuota" all'importazione. Le note poi
    // riusano le stesse cartelle grazie alla cache dei path.
    for (final path in emptyFolderPaths) {
      final segments = path
          .split('/')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      _ensureFolderPath(
        folders,
        segments,
        folderIdByPath,
        onFolderCreated: () => importedFolders++,
      );
    }

    final notesToImport = <ImportedNote>[];

    for (final entry in entries) {
      // Percorso vuoto = radice: nessuna cartella, la nota compare in
      // "Tutte le note".
      final folderId = _ensureFolderPath(
        folders,
        entry.folderPathSegments,
        folderIdByPath,
        onFolderCreated: () => importedFolders++,
      );

      final manifest = entry.manifestNote;
      if (manifest != null) {
        notesToImport.add(
          ImportedNote(
            title: manifest.title,
            content: manifest.content,
            folderId: folderId,
            createdAt: manifest.createdAt,
            updatedAt: manifest.updatedAt,
            isFavorite: manifest.isFavorite,
            isPinned: manifest.isPinned,
            orderIndex: manifest.orderIndex,
          ),
        );
        continue;
      }

      final parsed = parseNoteFile(entry.rawContent, entry.fileName);
      notesToImport.add(
        ImportedNote(
          title: parsed.title,
          content: parsed.content,
          folderId: folderId,
        ),
      );
    }

    final importedNotes = await notes.importNotesBulkDetailed(notesToImport);

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
    if (segments.length > maxFolderDepth) {
      throw const FormatException(
        'Percorso troppo profondo (massimo $maxFolderDepth livelli).',
      );
    }

    String pathKey = '';
    String? parentId;

    for (final rawSegment in segments) {
      final segment = rawSegment.trim().isEmpty
          ? 'Senza nome'
          : rawSegment.trim();
      pathKey = pathKey.isEmpty
          ? segment.toLowerCase()
          : '$pathKey/${segment.toLowerCase()}';

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
      if (cache.length > maxImportedFolders) {
        throw const FormatException(
          'Troppe cartelle da importare (massimo $maxImportedFolders).',
        );
      }
      parentId = resolvedId;
    }

    return parentId;
  }

  static List<FolderNode> _siblingsOf(
    FolderNotifier folders,
    String? parentId,
  ) {
    if (parentId == null) return folders.rootFolders;
    final parent = folders.findNode(parentId);
    return parent?.children ?? const [];
  }
}
