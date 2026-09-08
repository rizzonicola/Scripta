import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/folders/models/folder_node.dart';
import '../../features/folders/providers/folder_provider.dart';
import '../../features/notes/providers/notes_provider.dart';

/// Voce grezza estratta da un file (ZIP o filesystem) durante l'import,
/// ancora priva di un folderId reale: [folderPathSegments] è il percorso
/// relativo (una cartella per elemento, radice esclusa) che verrà
/// risolto/creato in [FolderNode] soltanto al momento del commit, per poter
/// riutilizzare cartelle già esistenti con lo stesso nome invece di
/// duplicarle.
class _RawImportEntry {
  final List<String> folderPathSegments;
  final String fileName;
  final String rawContent;

  const _RawImportEntry({
    required this.folderPathSegments,
    required this.fileName,
    required this.rawContent,
  });
}

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
///  - NESSUN BLOCCO DELL'INTERFACCIA: la lettura di file/ZIP di grandi
///    dimensioni avviene con API asincrone (`Directory.list`, lettura bytes
///    async) invece delle controparti sincrone, e l'inserimento delle note
///    nello stato dell'app avviene in un'unica operazione di blocco (vedi
///    `NotesNotifier.importNotesBulk`) invece che nota per nota.
class ImportService {
  ImportService._();

  static const _supportedExtensions = ['.md', '.markdown', '.txt'];

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

      await _runImport(
        context,
        ref,
        () async => _extractFromZipBytes(bytes),
      );
    } catch (e) {
      _showSnack(context, 'Errore durante la lettura dello ZIP: $e',
          isError: true);
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

      await _runImport(
        context,
        ref,
        () => _extractFromDirectory(Directory(dirPath)),
      );
    } catch (e) {
      _showSnack(context, 'Errore durante la lettura della cartella: $e',
          isError: true);
    }
  }

  /// Pipeline comune: mostra un indicatore di avanzamento non-bloccante per
  /// l'utente (ma senza mai freezare l'app, dato che tutto il lavoro pesante
  /// è asincrono), estrae le voci grezze, le materializza in cartelle/note
  /// reali e mostra un riepilogo finale.
  static Future<void> _runImport(
    BuildContext context,
    WidgetRef ref,
    Future<List<_RawImportEntry>> Function() extract,
  ) async {
    _showLoadingDialog(context);
    try {
      final entries = await extract();
      final result = await _commitEntries(ref, entries);
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();

      if (entries.isEmpty) {
        _showSnack(
          context,
          'Nessuna nota Markdown trovata da importare.',
        );
        return;
      }

      _showSnack(
        context,
        'Importazione completata: ${result.importedNotes} note'
        '${result.importedFolders > 0 ? ' e ${result.importedFolders} nuove cartelle' : ''}.',
      );
    } catch (e) {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      _showSnack(context, 'Errore durante l\'importazione: $e', isError: true);
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
  /// isolate dedicato, lasciando la UI reattiva; [_decodeZipEntriesSync] è
  /// un metodo statico (non una closure) proprio perché è questo il
  /// requisito di `compute` per poter essere invocato nel nuovo isolate.
  static Future<List<_RawImportEntry>> _extractFromZipBytes(
    Uint8List bytes,
  ) {
    return compute(_decodeZipEntriesSync, bytes);
  }

  static List<_RawImportEntry> _decodeZipEntriesSync(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final entries = <_RawImportEntry>[];

    for (final file in archive.files) {
      if (!file.isFile) continue;
      final normalized = file.name.replaceAll('\\', '/');
      if (!_hasSupportedExtension(normalized)) continue;
      // Difesa in profondità: uno ZIP malformato/malevolo non deve poter
      // referenziare percorsi fuori dalla gerarchia che stiamo costruendo.
      if (normalized.split('/').contains('..')) continue;

      final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) continue;
      final fileName = segments.removeLast();

      final contentBytes = file.content as List<int>;
      final rawContent = utf8.decode(contentBytes, allowMalformed: true);

      entries.add(_RawImportEntry(
        folderPathSegments: segments,
        fileName: fileName,
        rawContent: rawContent,
      ));
    }

    return entries;
  }

  // ---------------------------------------------------------------------
  // Estrazione: cartella su filesystem
  // ---------------------------------------------------------------------

  static Future<List<_RawImportEntry>> _extractFromDirectory(
    Directory root,
  ) async {
    final entries = <_RawImportEntry>[];
    final rootPath = root.path.replaceAll('\\', '/');

    // Directory.list (async) invece di listSync: evita di bloccare
    // l'isolate principale mentre si attraversano cartelle potenzialmente
    // molto grandi.
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final entityPath = entity.path.replaceAll('\\', '/');
      if (!_hasSupportedExtension(entityPath)) continue;

      var relative = entityPath.startsWith(rootPath)
          ? entityPath.substring(rootPath.length)
          : entityPath;
      if (relative.startsWith('/')) relative = relative.substring(1);

      final segments = relative.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) continue;
      final fileName = segments.removeLast();

      String rawContent;
      try {
        rawContent = await entity.readAsString();
      } catch (_) {
        final bytes = await entity.readAsBytes();
        rawContent = utf8.decode(bytes, allowMalformed: true);
      }

      entries.add(_RawImportEntry(
        folderPathSegments: segments,
        fileName: fileName,
        rawContent: rawContent,
      ));
    }

    return entries;
  }

  static bool _hasSupportedExtension(String path) {
    final lower = path.toLowerCase();
    return _supportedExtensions.any(lower.endsWith);
  }

  // ---------------------------------------------------------------------
  // Commit: risolve/crea cartelle e inserisce le note in blocco
  // ---------------------------------------------------------------------

  static Future<({int importedNotes, int importedFolders})> _commitEntries(
    WidgetRef ref,
    List<_RawImportEntry> entries,
  ) async {
    if (entries.isEmpty) return (importedNotes: 0, importedFolders: 0);

    final folderIdByPath = <String, String?>{};
    var importedFolders = 0;
    final notesToImport = <({String title, String content, String? folderId})>[];

    for (final entry in entries) {
      final folderId = _ensureFolderPath(
        ref,
        entry.folderPathSegments,
        folderIdByPath,
        onFolderCreated: () => importedFolders++,
      );

      final parsed = _parseTitleAndContent(entry.rawContent, entry.fileName);
      notesToImport.add((
        title: parsed.title,
        content: parsed.content,
        folderId: folderId,
      ));
    }

    final importedNotes = await ref
        .read(notesProvider.notifier)
        .importNotesBulk(notesToImport);

    return (importedNotes: importedNotes, importedFolders: importedFolders);
  }

  /// Risolve la catena di segmenti di percorso in un folderId, riusando le
  /// cartelle già esistenti con lo stesso nome allo stesso livello (ricerca
  /// case-insensitive) e creando solo i segmenti mancanti tramite
  /// [FolderNotifier.addFolder] (già sincrono nello stato in-memory, quindi
  /// visibile immediatamente alla prossima iterazione).
  static String? _ensureFolderPath(
    WidgetRef ref,
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

      final siblings = _siblingsOf(ref, parentId);
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
        final created = ref
            .read(folderProvider.notifier)
            .addFolder(segment, parentId: parentId);
        resolvedId = created.id;
        onFolderCreated();
      }

      cache[pathKey] = resolvedId;
      parentId = resolvedId;
    }

    return parentId;
  }

  static List<FolderNode> _siblingsOf(WidgetRef ref, String? parentId) {
    if (parentId == null) {
      return ref.read(folderProvider).rootFolders;
    }
    final parent = ref.read(folderProvider.notifier).findNode(parentId);
    return parent?.children ?? const [];
  }

  /// Ricava titolo/contenuto da un file Markdown importato.
  ///
  /// Simmetrico rispetto a `ExportService`, che per l'esportazione antepone
  /// al contenuto grezzo della nota una riga `# Titolo` (solo nel file
  /// esportato, MAI nel campo `content` salvato nel database): qui, se il
  /// file importato inizia con un heading di primo livello, lo trattiamo
  /// come titolo e lo rimuoviamo dal corpo così da non duplicarlo nell'editor
  /// (che mostra titolo e corpo in due campi separati). Se non è presente
  /// alcun heading iniziale, il titolo viene derivato dal nome del file.
  static ({String title, String content}) _parseTitleAndContent(
    String raw,
    String fileName,
  ) {
    final lines = raw.split('\n');
    var idx = 0;
    while (idx < lines.length && lines[idx].trim().isEmpty) {
      idx++;
    }

    if (idx < lines.length && lines[idx].trimLeft().startsWith('# ')) {
      final headingTitle = lines[idx].trimLeft().substring(2).trim();
      var contentStart = idx + 1;
      if (contentStart < lines.length && lines[contentStart].trim().isEmpty) {
        contentStart++;
      }
      final body = lines.sublist(contentStart).join('\n');
      return (
        title: headingTitle.isEmpty ? _titleFromFileName(fileName) : headingTitle,
        content: body,
      );
    }

    return (title: _titleFromFileName(fileName), content: raw);
  }

  static String _titleFromFileName(String fileName) {
    final base = fileName.replaceAll(
      RegExp(r'\.(md|markdown|txt)$', caseSensitive: false),
      '',
    ).trim();
    return base.isEmpty ? 'Nota importata' : base;
  }
}
