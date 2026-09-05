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

    test('syncNotes sends payload and parses accepted and server_wins', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/api/v1/sync') {
          final body = json.decode(request.body) as Map<String, dynamic>;
          final notes = body['notes'] as List<dynamic>;

          return http.Response(
            json.encode({
              'accepted': [
                {
                  'relative_path': notes.first['relative_path'],
                  'updated_at': notes.first['updated_at'],
                  'deleted': false,
                }
              ],
              'server_wins': [
                {
                  'relative_path': 'lavoro/conflitto.md',
                  'content': '# Versione server più recente',
                  'updated_at': 1756999999000,
                  'deleted': false,
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
      final syncResp = await service.syncNotes(
        baseUrl: 'http://localhost:8080',
        token: 'valid_token',
        notes: [
          const NoteChange(
            relativePath: 'personale/nota1.md',
            content: '# Mia nota',
            updatedAt: 1756900000000,
          ),
        ],
      );

      expect(syncResp.accepted.length, 1);
      expect(syncResp.accepted.first.relativePath, 'personale/nota1.md');
      expect(syncResp.serverWins.length, 1);
      expect(syncResp.serverWins.first.content, '# Versione server più recente');
    });

    test('downloadNote fetches raw markdown file properly', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/api/v1/notes/download') {
          final path = request.url.queryParameters['path'];
          if (path == 'lavoro/nota.md') {
            return http.Response('# Contenuto remoto', 200, headers: {
              'content-type': 'text/markdown; charset=utf-8',
            });
          }
          return http.Response('file non trovato', 404);
        }
        return http.Response('error', 500);
      });

      final service = SyncApiService(client);
      final content = await service.downloadNote(
        baseUrl: 'http://localhost:8080',
        token: 'valid_token',
        relativePath: 'lavoro/nota.md',
      );
      expect(content, '# Contenuto remoto');

      expect(
        () => service.downloadNote(
          baseUrl: 'http://localhost:8080',
          token: 'valid_token',
          relativePath: 'non_esiste.md',
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
        () => service.syncNotes(baseUrl: 'http://localhost:8080', token: 'expired', notes: []),
        throwsA(predicate((e) => e is SyncApiException && e.statusCode == 401)),
      );

      expect(
        () => service.downloadNote(baseUrl: 'http://localhost:8080', token: 'expired', relativePath: 'test.md'),
        throwsA(predicate((e) => e is SyncApiException && e.statusCode == 401)),
      );
    });
  });
}
