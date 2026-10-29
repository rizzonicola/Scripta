import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../../features/folders/models/folder_node.dart';
import '../../features/folders/providers/folder_provider.dart';
import '../../features/notes/models/note_model.dart';
import '../../features/notes/providers/notes_provider.dart';
import '../../features/settings/providers/settings_provider.dart';
import '../../features/sync/models/sync_models.dart';
import 'export_archive.dart';

typedef _SaveResult = ({bool saved, String? fallbackPath});

class ExportService {
  static String _sanitizeFileName(String name) => sanitizeFileName(name);

  /// Dati minimi di una nota per l'archivio (vedi [ExportNote]).
  static ExportNote _toExportNote(NoteModel n) => (
    id: n.id,
    title: n.title,
    content: n.content,
    folderId: n.folderId,
    isFavorite: n.isFavorite,
    isPinned: n.isPinned,
    orderIndex: n.orderIndex,
    createdAtMs: n.createdAt.toUtc().millisecondsSinceEpoch,
    updatedAtMs: n.updatedAt.toUtc().millisecondsSinceEpoch,
  );

  /// Le preferenze di aspetto viaggiano solo nel backup completo. Il formato
  /// è lo stesso DTO usato dalla sync, così import/export non divergono.
  static Map<String, Object?> _settingsSnapshot(WidgetRef ref) {
    final s = ref.read(settingsProvider);
    return UserSettingsDto(
      theme: s.themeMode == ThemeMode.dark
          ? 'dark'
          : s.themeMode == ThemeMode.light
          ? 'light'
          : 'system',
      colorScheme: s.selectedThemeId,
      language: s.locale?.languageCode ?? 'it',
      fontFamily: s.fontFamily,
      fontSize: s.fontSize.toInt(),
      lineSpacing: s.lineHeight,
      layout: 'split',
    ).toJson();
  }

  /// Helper to save file across platforms with native picker and Android SAF support
  static Future<_SaveResult> _saveExportFile({
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
      return (saved: uri != null, fallbackPath: null);
    } catch (_) {
      // Se il picker di sistema non è disponibile, il fallback resta nella
      // directory privata dell'app: mai storage esterno condiviso o
      // app-specific, dove un backup non cifrato sarebbe leggibile da altre
      // app (SEC-03). Il percorso viene mostrato all'utente.
      if (Platform.isAndroid || Platform.isIOS) {
        final dir = await getApplicationDocumentsDirectory();
        final file = await uniqueFallbackFile(dir, fileName);
        await file.writeAsBytes(bytes);
        return (saved: true, fallbackPath: file.path);
      }
      rethrow;
    }
  }

  /// Nome univoco nel fallback, per non sovrascrivere un export precedente.
  @visibleForTesting
  static Future<File> uniqueFallbackFile(Directory dir, String fileName) async {
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    final extension = dot > 0 ? fileName.substring(dot) : '';
    var candidate = File('${dir.path}/$fileName');
    var suffix = 2;
    while (await candidate.exists()) {
      candidate = File('${dir.path}/$base-$suffix$extension');
      suffix++;
    }
    return candidate;
  }

  static String _successMessage(String message, String? fallbackPath) =>
      fallbackPath == null
      ? message
      : '$message\nFile salvato in: $fallbackPath';

  /// Export a single note as Markdown (.md)
  static Future<void> exportNoteAsMarkdown(
    BuildContext context,
    NoteModel note,
  ) async {
    final title = note.title.trim().isEmpty
        ? 'Nota_senza_titolo'
        : note.title.trim();
    final fileName = '${_sanitizeFileName(title)}.md';

    final bytes = Uint8List.fromList(
      utf8.encode(noteMarkdownContent(note.title, note.content)),
    );

    try {
      final saveResult = await _saveExportFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: 'text/markdown',
        dialogTitle: 'Esporta nota come Markdown',
        allowedExtensions: ['md'],
      );

      if (saveResult.saved && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _successMessage(
                'Nota esportata con successo ($fileName)',
                saveResult.fallbackPath,
              ),
            ),
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
  static Future<void> exportFolderAsZip(
    BuildContext context,
    WidgetRef ref,
    FolderNode rootFolder,
  ) async {
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
      final result = await compute(buildNotesZip, (
        folders: folders,
        notes: notes,
        settings: null,
      ));

      final saveResult = await _saveExportFile(
        fileName: zipFileName,
        bytes: result.bytes,
        mimeType: 'application/zip',
        dialogTitle: 'Esporta cartella come ZIP',
        allowedExtensions: ['zip'],
      );

      if (saveResult.saved && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _successMessage(
                'Cartella esportata con successo (${result.noteCount} note in $zipFileName)',
                saveResult.fallbackPath,
              ),
            ),
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
  static Future<void> exportAllAsZip(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final now = DateTime.now();
    final zipFileName =
        'Scripta_Backup_${now.year}_${now.month}_${now.day}.zip';

    try {
      final allNotes = ref.read(notesProvider).notes;
      final folderState = ref.read(folderProvider);

      // Vedi commento analogo in exportFolderAsZip: codifica su isolate
      // dedicato per non bloccare la UI durante backup voluminosi.
      final result = await compute(buildNotesZip, (
        folders: flattenFolderTree(folderState.rootFolders),
        notes: [for (final n in allNotes) _toExportNote(n)],
        settings: _settingsSnapshot(ref),
      ));

      final saveResult = await _saveExportFile(
        fileName: zipFileName,
        bytes: result.bytes,
        mimeType: 'application/zip',
        dialogTitle: 'Esporta tutte le note come ZIP',
        allowedExtensions: ['zip'],
      );

      if (saveResult.saved && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _successMessage(
                'Backup completato (${result.noteCount} note esportate in $zipFileName)',
                saveResult.fallbackPath,
              ),
            ),
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
