import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../database/notes_dao.dart';
import '../database/folders_dao.dart';
import '../database/sync_meta_dao.dart';
import '../../features/notes/models/note_model.dart';
import '../../features/folders/models/folder_node.dart';

final importServiceProvider = Provider<ImportService>((ref) {
  return ImportService(
    ref.read(notesDaoProvider),
    ref.read(foldersDaoProvider),
    ref.read(syncMetaDaoProvider),
  );
});

enum ImportSourceType { jsonBackup, zipArchive, markdownFiles, markdownFolder }

class ImportResult {
  final int notesImported;
  final int foldersImported;
  final int skipped;
  final List<String> errors;

  const ImportResult({
    required this.notesImported,
    required this.foldersImported,
    required this.skipped,
    required this.errors,
  });

  bool get isSuccess => errors.isEmpty;
  int get totalImported => notesImported + foldersImported;
}

class ImportService {
  final NotesDao _notesDao;
  final FoldersDao _foldersDao;
  final SyncMetaDao _syncMetaDao;

  ImportService(
    this._notesDao,
    this._foldersDao,
    this._syncMetaDao,
  );

  /// Helper safe pick per FilePicker API 12.2.0 (restituisce PlatformFile direttamente)
  Future<List<PlatformFile>> _pickFilesSafe({
    required FileType type,
    List<String>? allowedExtensions,
    bool allowMultiple = false,
  }) async {
    try {
      final files = await FilePicker.pickFiles(
        type: type,
        allowedExtensions: allowedExtensions,
        allowMultiple: allowMultiple,
      );
      return files;
    } catch (e) {
      debugPrint('Error picking files: $e');
      return [];
    }
  }

  /// Helper safe directory picker per FilePicker API 12.2.0
  Future<String?> _getDirectoryPathSafe() async {
    try {
      final dirPath = await FilePicker.getDirectoryPath();
      return dirPath;
    } catch (e) {
      debugPrint('Error picking directory: $e');
      return null;
    }
  }

  Future<ImportResult> importBackupJson() async {
    final errors = <String>[];
    int notesCount = 0;
    int foldersCount = 0;
    int skippedCount = 0;

    final picked = await _pickFilesSafe(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );

    if (picked.isEmpty || picked.first.path == null) {
      return ImportResult(
        notesImported: 0,
        foldersImported: 0,
        skipped: 0,
        errors: errors,
      );
    }

    final file = File(picked.first.path!);

    try {
      final rawString = await file.readAsString();
      final decoded = jsonDecode(rawString);

      if (decoded is! Map<String, dynamic>) {
        errors.add('Formato JSON non valido: attesa una struttura oggetto.');
        return ImportResult(
          notesImported: 0,
          foldersImported: 0,
          skipped: 0,
          errors: errors,
        );
      }

      final now = DateTime.now().millisecondsSinceEpoch;

      if (decoded.containsKey('folders') && decoded['folders'] is List) {
        final rawFolders = decoded['folders'] as List;
        for (final item in rawFolders) {
          try {
            if (item is Map<String, dynamic>) {
              final folder = FolderNode.fromJson(item);
              await _foldersDao.insertFolder(folder);
              foldersCount++;
            }
          } catch (e) {
            skippedCount++;
            errors.add('Impossibile importare cartella: $e');
          }
        }
      }

      if (decoded.containsKey('notes') && decoded['notes'] is List) {
        final rawNotes = decoded['notes'] as List;
        for (final item in rawNotes) {
          try {
            if (item is Map<String, dynamic>) {
              final note = NoteModel.fromJson(item);
              await _notesDao.insertNote(note);

              await _syncMetaDao.setSyncState(
                entityType: 'note',
                entityId: note.id,
                action: 'upsert',
                updatedAt: now,
              );
              notesCount++;
            }
          } catch (e) {
            skippedCount++;
            errors.add('Impossibile importare nota: $e');
          }
        }
      }
    } catch (e) {
      errors.add('Errore durante il parsing del file JSON: $e');
    }

    return ImportResult(
      notesImported: notesCount,
      foldersImported: foldersCount,
      skipped: skippedCount,
      errors: errors,
    );
  }

  Future<ImportResult> importZipArchive() async {
    final errors = <String>[];
    int notesCount = 0;
    int foldersCount = 0;
    int skippedCount = 0;

    final picked = await _pickFilesSafe(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );

    if (picked.isEmpty || picked.first.path == null) {
      return ImportResult(
        notesImported: 0,
        foldersImported: 0,
        skipped: 0,
        errors: errors,
      );
    }

    final zipFile = File(picked.first.path!);

    try {
      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final folderPathToIdMap = <String, String>{};

      final now = DateTime.now().millisecondsSinceEpoch;

      for (final archiveFile in archive) {
        if (archiveFile.isDirectory) {
          final cleanDirPath = p.normalize(archiveFile.name).replaceAll(RegExp(r'[/\\]+$'), '');
          if (cleanDirPath.isEmpty || cleanDirPath == '.') continue;

          final folderName = p.basename(cleanDirPath);
          final parentDirPath = p.dirname(cleanDirPath);
          final parentId = (parentDirPath != '.' && parentDirPath.isNotEmpty)
              ? folderPathToIdMap[parentDirPath]
              : null;

          final folderId = 'folder_${now}_${folderPathToIdMap.length}';

          final folder = FolderNode(
            id: folderId,
            name: folderName,
            parentId: parentId,
            createdAt: now,
            updatedAt: now,
          );

          await _foldersDao.insertFolder(folder);
          folderPathToIdMap[cleanDirPath] = folderId;
          foldersCount++;
        }
      }

      for (final archiveFile in archive) {
        if (!archiveFile.isDirectory) {
          final ext = p.extension(archiveFile.name).toLowerCase();
          if (ext == '.md' || ext == '.txt') {
            final cleanFilePath = p.normalize(archiveFile.name);
            final fileName = p.basenameWithoutExtension(cleanFilePath);
            final parentDirPath = p.dirname(cleanFilePath);

            final folderId = (parentDirPath != '.' && parentDirPath.isNotEmpty)
                ? folderPathToIdMap[parentDirPath]
                : null;

            final contentBytes = archiveFile.content as List<int>;
            final content = utf8.decode(contentBytes, allowMalformed: true);

            final noteId = 'note_${now}_$notesCount';

            final note = NoteModel(
              id: noteId,
              title: fileName.isEmpty ? 'Untitled' : fileName,
              content: content,
              folderId: folderId,
              createdAt: now,
              updatedAt: now,
            );

            await _notesDao.insertNote(note);

            await _syncMetaDao.setSyncState(
              entityType: 'note',
              entityId: noteId,
              action: 'upsert',
              updatedAt: now,
            );

            notesCount++;
          }
        }
      }
    } catch (e) {
      errors.add('Errore durante l\'estrazione e importazione dello ZIP: $e');
    }

    return ImportResult(
      notesImported: notesCount,
      foldersImported: foldersCount,
      skipped: skippedCount,
      errors: errors,
    );
  }

  Future<ImportResult> importMarkdownFiles({String? targetFolderId}) async {
    final errors = <String>[];
    int notesCount = 0;
    int skippedCount = 0;

    final pickedFiles = await _pickFilesSafe(
      type: FileType.custom,
      allowedExtensions: ['md', 'txt', 'markdown'],
      allowMultiple: true,
    );

    if (pickedFiles.isEmpty) {
      return ImportResult(
        notesImported: 0,
        foldersImported: 0,
        skipped: 0,
        errors: errors,
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch;

    for (final platformFile in pickedFiles) {
      if (platformFile.path == null) {
        skippedCount++;
        continue;
      }

      try {
        final file = File(platformFile.path!);
        final title = p.basenameWithoutExtension(file.path);
        final content = await file.readAsString();

        final noteId = 'note_${now}_$notesCount';

        final note = NoteModel(
          id: noteId,
          title: title.trim().isEmpty ? 'Untitled Note' : title,
          content: content,
          folderId: targetFolderId,
          createdAt: now,
          updatedAt: now,
        );

        await _notesDao.insertNote(note);

        await _syncMetaDao.setSyncState(
          entityType: 'note',
          entityId: noteId,
          action: 'upsert',
          updatedAt: now,
        );

        notesCount++;
      } catch (e) {
        skippedCount++;
        errors.add('Errore durante l\'importazione del file ${platformFile.name}: $e');
      }
    }

    return ImportResult(
      notesImported: notesCount,
      foldersImported: 0,
      skipped: skippedCount,
      errors: errors,
    );
  }

  Future<ImportResult> importMarkdownDirectory({String? targetFolderId}) async {
    final errors = <String>[];
    int notesCount = 0;
    int foldersCount = 0;
    int skippedCount = 0;

    final dirPath = await _getDirectoryPathSafe();
    if (dirPath == null || dirPath.isEmpty) {
      return ImportResult(
        notesImported: 0,
        foldersImported: 0,
        skipped: 0,
        errors: errors,
      );
    }

    final rootDir = Directory(dirPath);
    if (!await rootDir.exists()) {
      errors.add('La cartella selezionata non esiste sul disco.');
      return ImportResult(
        notesImported: 0,
        foldersImported: 0,
        skipped: 0,
        errors: errors,
      );
    }

    final folderMap = <String, String>{};
    final now = DateTime.now().millisecondsSinceEpoch;

    try {
      final entities = await rootDir.list(recursive: true, followLinks: false).toList();

      for (final entity in entities) {
        if (entity is Directory) {
          final relativePath = p.relative(entity.path, from: rootDir.path);
          if (relativePath == '.' || relativePath.isEmpty) continue;

          final folderName = p.basename(entity.path);
          final parentRelative = p.dirname(relativePath);

          final parentId = (parentRelative != '.' && parentRelative.isNotEmpty)
              ? folderMap[parentRelative]
              : targetFolderId;

          final newFolderId = 'folder_${now}_${folderMap.length}';

          final folder = FolderNode(
            id: newFolderId,
            name: folderName,
            parentId: parentId,
            createdAt: now,
            updatedAt: now,
          );

          await _foldersDao.insertFolder(folder);
          folderMap[relativePath] = newFolderId;
          foldersCount++;
        }
      }

      for (final entity in entities) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (ext == '.md' || ext == '.txt' || ext == '.markdown') {
            try {
              final relativePath = p.relative(entity.path, from: rootDir.path);
              final title = p.basenameWithoutExtension(entity.path);
              final parentRelative = p.dirname(relativePath);

              final folderId = (parentRelative != '.' && parentRelative.isNotEmpty)
                  ? folderMap[parentRelative]
                  : targetFolderId;

              final content = await entity.readAsString();
              final noteId = 'note_${now}_$notesCount';

              final note = NoteModel(
                id: noteId,
                title: title.trim().isEmpty ? 'Untitled' : title,
                content: content,
                folderId: folderId,
                createdAt: now,
                updatedAt: now,
              );

              await _notesDao.insertNote(note);

              await _syncMetaDao.setSyncState(
                entityType: 'note',
                entityId: noteId,
                action: 'upsert',
                updatedAt: now,
              );

              notesCount++;
            } catch (e) {
              skippedCount++;
              errors.add('Impossibile leggere ${entity.path}: $e');
            }
          }
        }
      }
    } catch (e) {
      errors.add('Errore durante la scansione della cartella: $e');
    }

    return ImportResult(
      notesImported: notesCount,
      foldersImported: foldersCount,
      skipped: skippedCount,
      errors: errors,
    );
  }
}
