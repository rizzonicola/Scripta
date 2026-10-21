// Y-15 (app): le fixture JSON condivise con il server (test/fixtures/contract,
// copiate da testdata/contract del server). Se un lato cambia un campo, questi
// test falliscono. Sono ricavate dal codice del server, non da una spec.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scripta/core/services/sync_api_service.dart';
import 'package:scripta/features/sync/models/sync_models.dart';

List<int> _bytes(String name) => File('test/fixtures/contract/$name').readAsBytesSync();

Map<String, dynamic> _json(String name) => json.decode(utf8.decode(_bytes(name))) as Map<String, dynamic>;

Future<SyncResponse> _syncAgainst(MockClient client) => SyncApiService(client).sync(
      baseUrl: 'http://localhost:8080',
      token: 't',
      lastSyncedAt: 0,
      folders: const [],
      notes: const [],
    );

void main() {
  test('la richiesta di fixture: i DTO dell\'app la riproducono campo per campo', () {
    final fixture = _json('sync_request.json');
    final folders = (fixture['folders'] as List).map((e) => FolderChangeDto.fromJson(e as Map<String, dynamic>)).toList();
    final notes = (fixture['notes'] as List).map((e) => NoteChangeDto.fromJson(e as Map<String, dynamic>)).toList();
    final rebuilt = SyncRequest(lastSyncedAt: fixture['last_synced_at'] as int, folders: folders, notes: notes).toJson();

    // Stesse chiavi, stessi valori: l'app produce ciò che il server si aspetta.
    expect(json.decode(json.encode(rebuilt)), fixture);
  });

  test('la risposta 200 di fixture si legge, testo UTF-8 compreso, anche senza charset', () async {
    final client = MockClient((r) async => http.Response.bytes(
          _bytes('sync_response_200.json'),
          200,
          headers: {'content-type': 'application/json'},
        ));
    final resp = await _syncAgainst(client);

    expect(resp.fullResync, isFalse);
    expect(resp.caps?.proto, 2);
    expect(resp.folders.map((f) => f.id), ['f-figlia', 'f-radice']);
    expect(resp.folders.firstWhere((f) => f.id == 'f-figlia').parentId, 'f-radice');
    expect(resp.folders.firstWhere((f) => f.id == 'f-radice').name, 'Lavoro è → 😀');
    expect(resp.notes.single.title, 'Perché → già 😀');
    expect(resp.notes.single.content, '# Titolo\n\nTesto con «accenti» e 😀\n');
    expect(resp.notes.single.isFavorite, isTrue);
    expect(resp.notes.single.orderIndex, 3);
  });

  test('la risposta full_resync di fixture è riconosciuta', () async {
    final client = MockClient((r) async => http.Response.bytes(
          _bytes('sync_response_full_resync.json'),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ));
    final resp = await _syncAgainst(client);
    expect(resp.fullResync, isTrue);
    expect(resp.notes, hasLength(1));
  });

  test('il 422 di fixture porta i due elementi rifiutati e non un cursore', () async {
    final client = MockClient((r) async => http.Response.bytes(
          _bytes('sync_response_422.json'),
          422,
          headers: {'content-type': 'application/json'},
        ));
    await expectLater(
      _syncAgainst(client),
      throwsA(predicate((e) {
        if (e is! SyncApiException || e.statusCode != 422) return false;
        final byId = {for (final r in e.rejected) r.id: r};
        return e.rejected.length == 2 &&
            byId['f-orfana']!.kind == 'folder' &&
            byId['f-orfana']!.reason == 'invalid_parent_id' &&
            byId['n-orfana']!.kind == 'note' &&
            byId['n-orfana']!.reason == 'invalid_folder_id';
      })),
    );
  });

  test('il 503 di fixture, con il suo Retry-After, diventa un\'attesa', () async {
    final headers = {
      'content-type': 'application/json',
      ...(_json('sync_response_503.headers.json').map((k, v) => MapEntry(k.toLowerCase(), v.toString()))),
    };
    final client = MockClient((r) async => http.Response.bytes(_bytes('sync_response_503.json'), 503, headers: headers));
    await expectLater(
      _syncAgainst(client),
      throwsA(predicate((e) => e is SyncApiException && e.statusCode == 503 && e.retryAfter == const Duration(seconds: 1))),
    );
  });
}
