import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/features/sync/models/sync_models.dart';

void main() {
  group('SyncModels Unit Tests', () {
    test('FolderChangeDto serializes and deserializes properly', () {
      const change = FolderChangeDto(
        id: 'folder-1',
        name: 'Lavoro',
        parentId: null,
        updatedAt: 1756900000000,
        deletedAt: null,
      );

      final jsonMap = change.toJson();
      expect(jsonMap['id'], 'folder-1');
      expect(jsonMap['name'], 'Lavoro');
      expect(jsonMap['parent_id'], isNull);
      expect(jsonMap['updated_at'], 1756900000000);
      expect(jsonMap['deleted_at'], isNull);

      final fromJson = FolderChangeDto.fromJson(jsonMap);
      expect(fromJson.id, change.id);
      expect(fromJson.name, change.name);
      expect(fromJson.parentId, change.parentId);
      expect(fromJson.updatedAt, change.updatedAt);
      expect(fromJson.deletedAt, change.deletedAt);
    });

    test('FolderChangeDto round-trips a non-null parentId and deletedAt (tombstone)', () {
      const change = FolderChangeDto(
        id: 'folder-2',
        name: 'Sottocartella',
        parentId: 'folder-1',
        updatedAt: 1756900000000,
        deletedAt: 1756999999000,
      );

      final jsonMap = change.toJson();
      expect(jsonMap['parent_id'], 'folder-1');
      expect(jsonMap['deleted_at'], 1756999999000);

      final fromJson = FolderChangeDto.fromJson(jsonMap);
      expect(fromJson.parentId, 'folder-1');
      expect(fromJson.deletedAt, 1756999999000);
    });

    test('NoteChangeDto serializes and deserializes properly, content included', () {
      const change = NoteChangeDto(
        id: 'note-1',
        title: 'Titolo',
        content: '# Titolo\nContenuto',
        folderId: 'folder-1',
        updatedAt: 1756900000000,
        deletedAt: null,
      );

      final jsonMap = change.toJson();
      expect(jsonMap['id'], 'note-1');
      expect(jsonMap['title'], 'Titolo');
      expect(jsonMap['content'], '# Titolo\nContenuto');
      expect(jsonMap['folder_id'], 'folder-1');
      expect(jsonMap['updated_at'], 1756900000000);
      expect(jsonMap['deleted_at'], isNull);

      final fromJson = NoteChangeDto.fromJson(jsonMap);
      expect(fromJson.id, change.id);
      expect(fromJson.title, change.title);
      expect(fromJson.content, change.content);
      expect(fromJson.folderId, change.folderId);
      expect(fromJson.updatedAt, change.updatedAt);
    });

    test('SyncRequest carries the cursor plus dirty folders and notes', () {
      const request = SyncRequest(
        lastSyncedAt: 1000,
        folders: [
          FolderChangeDto(id: 'f1', name: 'F1', parentId: null, updatedAt: 1200, deletedAt: null),
        ],
        notes: [
          NoteChangeDto(id: 'n1', title: 'N1', content: 'c', folderId: 'f1', updatedAt: 1300, deletedAt: null),
        ],
      );

      final jsonMap = request.toJson();
      expect(jsonMap['last_synced_at'], 1000);
      expect((jsonMap['folders'] as List).length, 1);
      expect((jsonMap['notes'] as List).length, 1);
    });

    test('SyncResponse parses server_time, folders and notes correctly', () {
      final jsonMap = {
        'server_time': 2000,
        'folders': [
          {
            'id': 'folder-remote',
            'name': 'Dal server',
            'parent_id': null,
            'updated_at': 1500,
            'deleted_at': null,
          }
        ],
        'notes': [
          {
            'id': 'note-remote',
            'title': 'Dal server',
            'content': '# Contenuto Server',
            'folder_id': 'folder-remote',
            'updated_at': 1756950000000,
            'deleted_at': null,
          }
        ],
      };

      final response = SyncResponse.fromJson(jsonMap);
      expect(response.serverTime, 2000);
      expect(response.folders.length, 1);
      expect(response.folders.first.name, 'Dal server');
      expect(response.notes.length, 1);
      expect(response.notes.first.content, '# Contenuto Server');
      expect(response.notes.first.updatedAt, 1756950000000);
    });

    test('SyncResponse defaults to empty lists when fields are absent', () {
      final response = SyncResponse.fromJson({'server_time': 42});
      expect(response.serverTime, 42);
      expect(response.folders, isEmpty);
      expect(response.notes, isEmpty);
    });

    test('UserSettingsDto serializes matching backend schema', () {
      const settings = UserSettingsDto(
        theme: 'dark',
        colorScheme: 'dark_teal',
        language: 'it',
        fontFamily: 'Inter',
        fontSize: 16,
        lineSpacing: 1.6,
        layout: 'split',
        updatedAt: 1756950000000,
      );

      final map = settings.toJson();
      expect(map['theme'], 'dark');
      expect(map['color_scheme'], 'dark_teal');
      expect(map['language'], 'it');
      expect(map['font_family'], 'Inter');
      expect(map['font_size'], 16);
      expect(map['line_spacing'], 1.6);
      expect(map['layout'], 'split');
      expect(map['updated_at'], 1756950000000);

      final parsed = UserSettingsDto.fromJson(map);
      expect(parsed.theme, 'dark');
      expect(parsed.colorScheme, 'dark_teal');
      expect(parsed.fontSize, 16);
      expect(parsed.lineSpacing, 1.6);
    });

    test('LoginResponseDto parses authentication payload', () {
      final jsonMap = {
        'token': 'jwt.token.here',
        'expires_at': 1767225600,
        'user_id': 'usr_123',
        'username': 'mario.rossi'
      };

      final dto = LoginResponseDto.fromJson(jsonMap);
      expect(dto.token, 'jwt.token.here');
      expect(dto.expiresAt, 1767225600);
      expect(dto.userId, 'usr_123');
      expect(dto.username, 'mario.rossi');
    });
  });
}
