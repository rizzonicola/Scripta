import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../features/folders/models/folder_node.dart';
import '../../features/folders/providers/folder_provider.dart';
import '../../features/notes/models/note_model.dart';
import '../../features/notes/providers/notes_provider.dart';
import 'export_archive.dart';

class ExportService {
  static String _sanitizeFileName(String name) => sanitizeFileName(name);

  /// Dati minimi di una nota per l'archivio (vedi [ExportNote]).
  static ExportNote _toExportNote(NoteModel n) =>
      (id: n.id, title: n.title, content: n.content, folderId: n.folderId);

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

    final bytes = Uint8List.fromList(
      utf8.encode(noteMarkdownContent(note.title, note.content)),
    );

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

      // Solo le note del sottoalbero (e solo i campi che servono) vengono
      // inviate all'isolate: prima partiva l'intera collezione.
      final folders = flattenFolderTree([rootFolder]);
      final subtreeIds = {for (final f in folders) f.id};
      final notes = [
        for (final n in allNotes)
          if (n.folderId != null && subtreeIds.contains(n.folderId))
            _toExportNote(n),
      ];

      // Codifica ZIP CPU-bound eseguita su isolate dedicato (vedi
      // `buildNotesZip`): non blocca il thread della UI, stesso pattern
      // già usato per la decompressione in fase di importazione.
      final result = await compute(
        buildNotesZip,
        (folders: folders, notes: notes),
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
    final now = DateTime.now();
    final zipFileName = 'Scripta_Backup_${now.year}_${now.month}_${now.day}.zip';

    try {
      final allNotes = ref.read(notesProvider).notes;
      final folderState = ref.read(folderProvider);

      // Vedi commento analogo in exportFolderAsZip: codifica su isolate
      // dedicato per non bloccare la UI durante backup voluminosi.
      final result = await compute(
        buildNotesZip,
        (
          folders: flattenFolderTree(folderState.rootFolders),
          notes: [for (final n in allNotes) _toExportNote(n)],
        ),
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
