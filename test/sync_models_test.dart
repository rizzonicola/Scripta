import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/features/sync/models/sync_models.dart';

void main() {
  group('SyncModels Unit Tests', () {
    test('NoteChange serializes and deserializes properly', () {
      const change = NoteChange(
        relativePath: 'lavoro/progetto.md',
        content: '# Titolo\nContenuto',
        updatedAt: 1756900000000,
        deleted: false,
      );

      final jsonMap = change.toJson();
      expect(jsonMap['relative_path'], 'lavoro/progetto.md');
      expect(jsonMap['content'], '# Titolo\nContenuto');
      expect(jsonMap['updated_at'], 1756900000000);
      expect(jsonMap['deleted'], false);

      final fromJson = NoteChange.fromJson(jsonMap);
      expect(fromJson.relativePath, change.relativePath);
      expect(fromJson.content, change.content);
      expect(fromJson.updatedAt, change.updatedAt);
      expect(fromJson.deleted, change.deleted);
    });

    test('NoteChange includes old_relative_path when a note was moved', () {
      const change = NoteChange(
        relativePath: 'lavoro/progetto.md',
        content: '# Titolo',
        updatedAt: 1756900000000,
        oldRelativePath: 'personale/progetto.md',
      );

      final jsonMap = change.toJson();
      expect(jsonMap['old_relative_path'], 'personale/progetto.md');
      expect(jsonMap['is_folder'], false);

      final fromJson = NoteChange.fromJson(jsonMap);
      expect(fromJson.oldRelativePath, 'personale/progetto.md');
      expect(fromJson.isFolder, false);
    });

    test('NoteChange omits old_relative_path when not moving', () {
      const change = NoteChange(
        relativePath: 'nota.md',
        content: 'contenuto',
        updatedAt: 1756900000000,
      );

      final jsonMap = change.toJson();
      expect(jsonMap.containsKey('old_relative_path'), isFalse);
    });

    test('NoteChange serializes empty folder markers with is_folder true', () {
      const change = NoteChange(
        relativePath: 'lavoro/archivio',
        content: '',
        updatedAt: 1756900000000,
        isFolder: true,
      );

      final jsonMap = change.toJson();
      expect(jsonMap['is_folder'], true);

      final fromJson = NoteChange.fromJson(jsonMap);
      expect(fromJson.isFolder, true);
      expect(fromJson.relativePath, 'lavoro/archivio');
    });

    test('SyncResponse parses accepted and server_wins correctly', () {
      final jsonMap = {
        'accepted': [
          {
            'relative_path': 'nota1.md',
            'updated_at': 1756900000000,
            'deleted': false,
          }
        ],
        'server_wins': [
          {
            'relative_path': 'nota2.md',
            'content': '# Contenuto Server',
            'updated_at': 1756950000000,
            'deleted': false,
          }
        ]
      };

      final response = SyncResponse.fromJson(jsonMap);
      expect(response.accepted.length, 1);
      expect(response.accepted.first.relativePath, 'nota1.md');
      expect(response.serverWins.length, 1);
      expect(response.serverWins.first.relativePath, 'nota2.md');
      expect(response.serverWins.first.content, '# Contenuto Server');
      expect(response.serverWins.first.updatedAt, 1756950000000);
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
