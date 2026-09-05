import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../features/folders/models/folder_node.dart';
import '../../features/folders/providers/folder_provider.dart';
import '../../features/notes/models/note_model.dart';
import '../../features/notes/providers/notes_provider.dart';

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
      final archive = Archive();

      int exportedNotesCount = 0;

      void addFolderToArchive(FolderNode folder, String parentPath) {
        final currentPath = parentPath.isEmpty ? folder.name : '$parentPath/${folder.name}';

        // Find notes belonging directly to this folder
        final folderNotes = allNotes.where((n) => n.folderId == folder.id).toList();
        for (final note in folderNotes) {
          final noteTitle = _sanitizeFileName(note.title.trim().isEmpty ? 'Nota_${note.id.substring(0, 6)}' : note.title);
          final noteFileName = '$noteTitle.md';
          String content = note.content;
          if (!content.startsWith('# ') && note.title.trim().isNotEmpty) {
            content = '# ${note.title}\n\n$content';
          }

          final bytes = utf8.encode(content);
          archive.addFile(ArchiveFile('$currentPath/$noteFileName', bytes.length, bytes));
          exportedNotesCount++;
        }

        // Recursively add subfolders
        for (final child in folder.children) {
          addFolderToArchive(child, currentPath);
        }
      }

      addFolderToArchive(rootFolder, '');

      final encoded = ZipEncoder().encode(archive);
      final zipBytes = Uint8List.fromList(encoded);

      final saved = await _saveExportFile(
        fileName: zipFileName,
        bytes: zipBytes,
        mimeType: 'application/zip',
        dialogTitle: 'Esporta cartella come ZIP',
        allowedExtensions: ['zip'],
      );

      if (saved && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cartella esportata con successo ($exportedNotesCount note in $zipFileName)'),
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
      final archive = Archive();

      int exportedNotesCount = 0;

      // Map folder ids to their full path
      final folderPathMap = <String, String>{};
      void mapPaths(FolderNode node, String parentPath) {
        final p = parentPath.isEmpty ? node.name : '$parentPath/${node.name}';
        folderPathMap[node.id] = p;
        for (final child in node.children) {
          mapPaths(child, p);
        }
      }

      for (final root in folderState.rootFolders) {
        mapPaths(root, '');
      }

      for (final note in allNotes) {
        final folderPath = note.folderId != null && folderPathMap.containsKey(note.folderId)
            ? folderPathMap[note.folderId]!
            : 'Non_Catalogate';
        final noteTitle = _sanitizeFileName(note.title.trim().isEmpty ? 'Nota_${note.id.substring(0, 6)}' : note.title);
        final noteFileName = '$noteTitle.md';
        String content = note.content;
        if (!content.startsWith('# ') && note.title.trim().isNotEmpty) {
          content = '# ${note.title}\n\n$content';
        }

        final bytes = utf8.encode(content);
        archive.addFile(ArchiveFile('$folderPath/$noteFileName', bytes.length, bytes));
        exportedNotesCount++;
      }

      final encoded = ZipEncoder().encode(archive);
      final zipBytes = Uint8List.fromList(encoded);

      final saved = await _saveExportFile(
        fileName: zipFileName,
        bytes: zipBytes,
        mimeType: 'application/zip',
        dialogTitle: 'Esporta tutte le note come ZIP',
        allowedExtensions: ['zip'],
      );

      if (saved && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backup completato ($exportedNotesCount note esportate in $zipFileName)'),
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
