import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scripta/core/services/sync_api_service.dart';
import 'package:scripta/features/sync/models/sync_models.dart';

const _jsonHeaders = {'content-type': 'application/json'};

Map<String, dynamic> _noteJson(int i, String content) => {
      'id': 'n$i',
      'title': 'titolo $i',
      'content': content,
      'folder_id': null,
      'is_favorite': false,
      'is_pinned': false,
      'order_index': i,
      'updated_at': 1000 + i,
      'deleted_at': null,
    };

NoteChangeDto _noteDto(int i, String content) => NoteChangeDto(
      id: 'n$i',
      title: 'titolo $i',
      content: content,
      folderId: null,
      isFavorite: false,
      isPinned: false,
      orderIndex: i,
      updatedAt: 1000 + i,
      deletedAt: null,
    );

Future<SyncResponse> _sync(
  SyncApiService service, {
  int lastSyncedAt = 0,
  List<NoteChangeDto> notes = const [],
}) =>
    service.sync(
      baseUrl: 'http://localhost:8080',
      token: 'token',
      lastSyncedAt: lastSyncedAt,
      folders: const [],
      notes: notes,
    );

void main() {
  group('SyncApiService con payload voluminosi (isolate)', () {
    test('una risposta oltre soglia viene decodificata con lo stesso risultato', () async {
      final content = 'x' * 1000;
      final body = json.encode({
        'server_time': 12345,
        'full_resync': true,
        'folders': <Object>[],
        'notes': [for (var i = 0; i < 400; i++) _noteJson(i, content)],
      });
      expect(body.length, greaterThan(SyncApiService.isolateJsonThreshold));

      final service = SyncApiService(
        MockClient((request) async => http.Response(body, 200, headers: _jsonHeaders)),
      );
      final response = await _sync(service);

      expect(response.serverTime, 12345);
      expect(response.fullResync, isTrue);
      expect(response.notes.length, 400);
      expect(response.notes.first.content, content);
      expect(response.notes.last.id, 'n399');
    });

    test('una richiesta con contenuto voluminoso viene serializzata correttamente', () async {
      final content = 'y' * 1000;
      Map<String, dynamic>? sent;
      final service = SyncApiService(
        MockClient((request) async {
          sent = json.decode(request.body) as Map<String, dynamic>;
          return http.Response(
            json.encode({'server_time': 1, 'folders': <Object>[], 'notes': <Object>[]}),
            200,
            headers: _jsonHeaders,
          );
        }),
      );

      final notes = [for (var i = 0; i < 300; i++) _noteDto(i, content)];
      expect(notes.length * content.length, greaterThan(SyncApiService.isolateJsonThreshold));

      final response = await _sync(service, lastSyncedAt: 777, notes: notes);

      expect(response.serverTime, 1);
      expect(sent!['last_synced_at'], 777);
      final sentNotes = sent!['notes'] as List<dynamic>;
      expect(sentNotes.length, 300);
      expect((sentNotes.last as Map<String, dynamic>)['id'], 'n299');
      expect((sentNotes.first as Map<String, dynamic>)['content'], content);
    });

    test('un corpo voluminoso non valido produce un errore, senza restare in attesa', () async {
      final invalid = '{"notes": [${'x' * (SyncApiService.isolateJsonThreshold + 1)}';
      final service = SyncApiService(
        MockClient((request) async => http.Response(invalid, 200, headers: _jsonHeaders)),
      );

      await expectLater(_sync(service), throwsA(anything));
    });

    test('i payload piccoli continuano a essere elaborati senza isolate', () async {
      final body = json.encode({
        'server_time': 5,
        'folders': <Object>[],
        'notes': [_noteJson(1, 'breve')],
      });
      final service = SyncApiService(
        MockClient((request) async => http.Response(body, 200, headers: _jsonHeaders)),
      );

      final response = await _sync(service, notes: [_noteDto(1, 'breve')]);

      expect(response.serverTime, 5);
      expect(response.notes.single.content, 'breve');
    });
  });
}
