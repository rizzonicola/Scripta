import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../features/folders/models/folder_node.dart';
import '../../features/folders/providers/folder_provider.dart';
import '../../features/notes/models/note_model.dart';
import '../../features/notes/providers/notes_provider.dart';

/// Parametri passati all'isolate dedicato per la codifica dello ZIP di UNA
/// cartella (vedi [ExportService.exportFolderAsZip]). Nessun riferimento a
/// `BuildContext`/`WidgetRef`/oggetti Flutter: solo dati puri, come richiesto
/// da [compute] per l'invio all'isolate.
class _FolderZipParams {
  final FolderNode rootFolder;
  final List<NoteModel> allNotes;

  const _FolderZipParams(this.rootFolder, this.allNotes);
}

/// Parametri per la codifica dello ZIP di backup completo (tutte le
/// cartelle/note), vedi [ExportService.exportAllAsZip].
class _AllNotesZipParams {
  final List<FolderNode> rootFolders;
  final List<NoteModel> allNotes;

  const _AllNotesZipParams(this.rootFolders, this.allNotes);
}

class _ZipEncodeResult {
  final Uint8List bytes;
  final int noteCount;

  const _ZipEncodeResult(this.bytes, this.noteCount);
}

String _sanitizeFileNameTopLevel(String name) => ExportService._sanitizeFileName(name);

String _noteMarkdownContent(NoteModel note) {
  var content = note.content;
  if (!content.startsWith('# ') && note.title.trim().isNotEmpty) {
    content = '# ${note.title}\n\n$content';
  }
  return content;
}

/// Costruisce e codifica l'archivio ZIP di una singola cartella. Funzione
/// TOP-LEVEL (non un metodo di istanza/statico legato alla UI) perché è il
/// requisito di [compute] per poter essere eseguita su un isolate dedicato:
/// `ZipEncoder().encode()` è CPU-bound e sincrono, quindi eseguito
/// direttamente sull'isolate principale bloccherebbe il thread della UI
/// (jank/freeze) per l'intera durata della compressione su backup
/// voluminosi — esattamente lo stesso ragionamento già applicato
/// all'importazione (vedi `import_service.dart`, `_decodeZipEntriesSync`).
_ZipEncodeResult _encodeFolderZip(_FolderZipParams params) {
  final archive = Archive();
  var exportedNotesCount = 0;

  void addFolderToArchive(FolderNode folder, String parentPath) {
    final currentPath =
        parentPath.isEmpty ? folder.name : '$parentPath/${folder.name}';

    final folderNotes =
        params.allNotes.where((n) => n.folderId == folder.id).toList();
    for (final note in folderNotes) {
      final noteTitle = _sanitizeFileNameTopLevel(
          note.title.trim().isEmpty ? 'Nota_${note.id.substring(0, 6)}' : note.title);
      final noteFileName = '$noteTitle.md';
      final bytes = utf8.encode(_noteMarkdownContent(note));
      archive.addFile(ArchiveFile('$currentPath/$noteFileName', bytes.length, bytes));
      exportedNotesCount++;
    }

    for (final child in folder.children) {
      addFolderToArchive(child, currentPath);
    }
  }

  addFolderToArchive(params.rootFolder, '');

  final encoded = ZipEncoder().encode(archive);
  return _ZipEncodeResult(Uint8List.fromList(encoded), exportedNotesCount);
}

/// Equivalente di [_encodeFolderZip] per il backup completo (tutte le
/// cartelle radice + tutte le note, con risoluzione del percorso completo
/// per ciascuna nota). Stessa motivazione: esecuzione su isolate via
/// [compute] per non bloccare la UI.
_ZipEncodeResult _encodeAllNotesZip(_AllNotesZipParams params) {
  final archive = Archive();
  var exportedNotesCount = 0;

  final folderPathMap = <String, String>{};
  void mapPaths(FolderNode node, String parentPath) {
    final p = parentPath.isEmpty ? node.name : '$parentPath/${node.name}';
    folderPathMap[node.id] = p;
    for (final child in node.children) {
      mapPaths(child, p);
    }
  }

  for (final root in params.rootFolders) {
    mapPaths(root, '');
  }

  for (final note in params.allNotes) {
    final folderPath = note.folderId != null && folderPathMap.containsKey(note.folderId)
        ? folderPathMap[note.folderId]!
        : 'Non_Catalogate';
    final noteTitle = _sanitizeFileNameTopLevel(
        note.title.trim().isEmpty ? 'Nota_${note.id.substring(0, 6)}' : note.title);
    final noteFileName = '$noteTitle.md';
    final bytes = utf8.encode(_noteMarkdownContent(note));
    archive.addFile(ArchiveFile('$folderPath/$noteFileName', bytes.length, bytes));
    exportedNotesCount++;
  }

  final encoded = ZipEncoder().encode(archive);
  return _ZipEncodeResult(Uint8List.fromList(encoded), exportedNotesCount);
}

class ExportService {
  static String _sanitizeFileName(String name) {
    final sanitized = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return sanitized.isEmpty ? 'untitled' : sanitized;
  }

  /// Helper to save file across platforms with native picker and Android SAF support
  static Future<bool> _saveExportFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    required String dialogTitle,
    required List<String> allowedExtensions,
  }) async {
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: dialogTitle,
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
        type: FileType.custom,
        allowedExtensions: allowedExtensions,
      );
      return uri != null;
    } catch (pickerError) {
      // Mobile fallback if system SAF picker activity cannot be resolved
      if (Platform.isAndroid || Platform.isIOS) {
        Directory? dir;
        if (Platform.isAndroid) {
          try {
            dir = await getDownloadsDirectory();
          } catch (_) {}
        }
        dir ??= await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory();

        final file = File('${dir.path}/$fileName');
        await file.writeAsBytes(bytes);
        return true;
      }
      rethrow;
    }
  }

  /// Export a single note as Markdown (.md)
  static Future<void> exportNoteAsMarkdown(BuildContext context, NoteModel note) async {
    final title = note.title.trim().isEmpty ? 'Nota_senza_titolo' : note.title.trim();
    final fileName = '${_sanitizeFileName(title)}.md';

    String content = note.content;
    if (!content.startsWith('# ') && note.title.trim().isNotEmpty) {
      content = '# ${note.title}\n\n$content';
    }

    final bytes = Uint8List.fromList(utf8.encode(content));

    try {
      final saved = await _saveExportFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: 'text/markdown',
        dialogTitle: 'Esporta nota come Markdown',
        allowedExtensions: ['md'],
      );

      if (saved && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Nota esportata con successo ($fileName)'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Errore durante l\'esportazione: $e'),
            backgroundColor: Colors.red.shade800,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// Export a folder and all its subfolders and notes as a ZIP archive
  static Future<void> exportFolderAsZip(BuildContext context, WidgetRef ref, FolderNode rootFolder) async {
    final folderName = _sanitizeFileName(rootFolder.name);
    final zipFileName = '$folderName.zip';

    try {
      final allNotes = ref.read(notesProvider).notes;

      // Codifica ZIP CPU-bound eseguita su isolate dedicato (vedi
      // `_encodeFolderZip`): non blocca il thread della UI, stesso pattern
      // già usato per la decompressione in fase di importazione.
      final result = await compute(
        _encodeFolderZip,
        _FolderZipParams(rootFolder, allNotes),
      );

      final saved = await _saveExportFile(
        fileName: zipFileName,
        bytes: result.bytes,
        mimeType: 'application/zip',
        dialogTitle: 'Esporta cartella come ZIP',
        allowedExtensions: ['zip'],
      );

      if (saved && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cartella esportata con successo (${result.noteCount} note in $zipFileName)'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Errore durante l\'esportazione ZIP: $e'),
            backgroundColor: Colors.red.shade800,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// Export ALL notes in all folders as a complete backup ZIP
  static Future<void> exportAllAsZip(BuildContext context, WidgetRef ref) async {
    final zipFileName = 'Scripta_Backup_${DateTime.now().year}_${DateTime.now().month}_${DateTime.now().day}.zip';

    try {
      final allNotes = ref.read(notesProvider).notes;
      final folderState = ref.read(folderProvider);

      // Vedi commento analogo in exportFolderAsZip: codifica su isolate
      // dedicato per non bloccare la UI durante backup voluminosi.
      final result = await compute(
        _encodeAllNotesZip,
        _AllNotesZipParams(folderState.rootFolders, allNotes),
      );

      final saved = await _saveExportFile(
        fileName: zipFileName,
        bytes: result.bytes,
        mimeType: 'application/zip',
        dialogTitle: 'Esporta tutte le note come ZIP',
        allowedExtensions: ['zip'],
      );

      if (saved && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backup completato (${result.noteCount} note esportate in $zipFileName)'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Errore durante il backup ZIP: $e'),
            backgroundColor: Colors.red.shade800,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}
