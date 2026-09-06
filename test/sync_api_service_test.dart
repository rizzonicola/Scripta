import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scripta/core/services/sync_api_service.dart';
import 'package:scripta/features/sync/models/sync_models.dart';

void main() {
  group('SyncApiService Unit Tests', () {
    test('checkHealth returns true on 200 and false on error', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/healthz') {
          return http.Response('ok', 200);
        }
        return http.Response('not found', 404);
      });

      final service = SyncApiService(client);
      final isOnline = await service.checkHealth('http://localhost:8080');
      expect(isOnline, isTrue);

      final isOffline = await service.checkHealth('http://localhost:8080/nonexistent');
      expect(isOffline, isFalse);
    });

    test('login succeeds and parses LoginResponseDto', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/api/v1/auth/login') {
          final body = json.decode(request.body) as Map<String, dynamic>;
          if (body['username'] == 'mario.rossi' && body['password'] == 'segreta') {
            return http.Response(
              json.encode({
                'token': 'mock.jwt.token',
                'expires_at': 1767225600,
                'user_id': 'u1',
                'username': 'mario.rossi',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(json.encode({'error': 'credenziali non valide'}), 401);
        }
        return http.Response('error', 500);
      });

      final service = SyncApiService(client);
      final resp = await service.login(
        baseUrl: 'http://localhost:8080',
        username: 'mario.rossi',
        password: 'segreta',
      );

      expect(resp.token, 'mock.jwt.token');
      expect(resp.username, 'mario.rossi');

      expect(
        () => service.login(
          baseUrl: 'http://localhost:8080',
          username: 'wrong',
          password: 'pwd',
        ),
        throwsA(isA<SyncApiException>()),
      );
    });

    test('getUserSettings and updateUserSettings work properly', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/api/v1/user/settings') {
          if (request.headers['authorization'] != 'Bearer token123') {
            return http.Response('unauthorized', 401);
          }
          if (request.method == 'GET') {
            return http.Response(
              json.encode({
                'theme': 'dark',
                'color_scheme': 'oled',
                'language': 'it',
                'font_family': 'Inter',
                'font_size': 16,
                'line_spacing': 1.6,
                'layout': 'split',
                'updated_at': 1756950000000,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          } else if (request.method == 'PUT') {
            final body = json.decode(request.body) as Map<String, dynamic>;
            body['updated_at'] = 1756960000000;
            return http.Response(
              json.encode(body),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
        }
        return http.Response('not found', 404);
      });

      final service = SyncApiService(client);

      final settings = await service.getUserSettings(
        baseUrl: 'http://localhost:8080',
        token: 'token123',
      );
      expect(settings.theme, 'dark');
      expect(settings.colorScheme, 'oled');

      final updated = await service.updateUserSettings(
        baseUrl: 'http://localhost:8080',
        token: 'token123',
        settings: const UserSettingsDto(
          theme: 'light',
          colorScheme: 'clean_light',
          language: 'en',
          fontFamily: 'Roboto',
          fontSize: 18,
          lineSpacing: 1.5,
        ),
      );
      expect(updated.theme, 'light');
      expect(updated.colorScheme, 'clean_light');
      expect(updated.fontSize, 18);
    });

    test('sync sends last_synced_at + folders/notes and parses the pull response', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/api/v1/sync') {
          final body = json.decode(request.body) as Map<String, dynamic>;
          expect(body['last_synced_at'], 1000);
          final notes = body['notes'] as List<dynamic>;
          expect(notes.first['id'], 'note-1');
          expect(notes.first['folder_id'], 'folder-1');

          return http.Response(
            json.encode({
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
                  'id': 'note-conflict',
                  'title': 'Versione server più recente',
                  'content': '# Vince il server',
                  'folder_id': null,
                  'updated_at': 1800,
                  'deleted_at': null,
                }
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('error', 500);
      });

      final service = SyncApiService(client);
      final syncResp = await service.sync(
        baseUrl: 'http://localhost:8080',
        token: 'valid_token',
        lastSyncedAt: 1000,
        folders: const [],
        notes: const [
          NoteChangeDto(
            id: 'note-1',
            title: 'Mia nota',
            content: '# Mia nota',
            folderId: 'folder-1',
            updatedAt: 1200,
            deletedAt: null,
          ),
        ],
      );

      expect(syncResp.serverTime, 2000);
      expect(syncResp.folders.length, 1);
      expect(syncResp.folders.first.name, 'Dal server');
      expect(syncResp.notes.length, 1);
      expect(syncResp.notes.first.content, '# Vince il server');
    });

    test('downloadNoteMarkdown fetches raw markdown by id', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/api/v1/notes/download') {
          final id = request.url.queryParameters['id'];
          if (id == 'note-123') {
            return http.Response('# Contenuto remoto', 200, headers: {
              'content-type': 'text/markdown; charset=utf-8',
            });
          }
          return http.Response('file non trovato', 404);
        }
        return http.Response('error', 500);
      });

      final service = SyncApiService(client);
      final content = await service.downloadNoteMarkdown(
        baseUrl: 'http://localhost:8080',
        token: 'valid_token',
        noteId: 'note-123',
      );
      expect(content, '# Contenuto remoto');

      expect(
        () => service.downloadNoteMarkdown(
          baseUrl: 'http://localhost:8080',
          token: 'valid_token',
          noteId: 'non-esiste',
        ),
        throwsA(isA<SyncApiException>()),
      );
    });

    test('handles 401 token expiration across all endpoints', () async {
      final client = MockClient((request) async {
        return http.Response(json.encode({'error': 'token scaduto'}), 401);
      });

      final service = SyncApiService(client);

      expect(
        () => service.getUserSettings(baseUrl: 'http://localhost:8080', token: 'expired'),
        throwsA(predicate((e) => e is SyncApiException && e.statusCode == 401)),
      );

      expect(
        () => service.updateUserSettings(
          baseUrl: 'http://localhost:8080',
          token: 'expired',
          settings: const UserSettingsDto(),
        ),
        throwsA(predicate((e) => e is SyncApiException && e.statusCode == 401)),
      );

      expect(
        () => service.sync(baseUrl: 'http://localhost:8080', token: 'expired', lastSyncedAt: 0, folders: const [], notes: const []),
        throwsA(predicate((e) => e is SyncApiException && e.statusCode == 401)),
      );

      expect(
        () => service.downloadNoteMarkdown(baseUrl: 'http://localhost:8080', token: 'expired', noteId: 'x'),
        throwsA(predicate((e) => e is SyncApiException && e.statusCode == 401)),
      );
    });

    test('handles 503 (server busy) as a SyncApiException with statusCode 503', () async {
      final client = MockClient((request) async {
        return http.Response(json.encode({'error': 'database temporaneamente occupato, riprovare'}), 503);
      });

      final service = SyncApiService(client);

      expect(
        () => service.sync(baseUrl: 'http://localhost:8080', token: 't', lastSyncedAt: 0, folders: const [], notes: const []),
        throwsA(predicate((e) => e is SyncApiException && e.statusCode == 503)),
      );
    });
  });
}
