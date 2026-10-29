// Y-02 (app): il corpo delle risposte si decodifica SEMPRE come UTF-8, anche
// quando il Content-Type non dichiara il charset.
//
// Il pacchetto http, senza `charset`, decodifica `response.body` con Latin-1:
// "è → 😀" diventerebbe mojibake. Il server ora dichiara `charset=utf-8`
// (Y-02 lato server), ma un'app deve reggere anche i server precedenti.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scripta/core/services/sync_api_service.dart';
import 'package:scripta/features/sync/models/sync_models.dart';

const _title = 'è → 😀';
const _content = 'Perché «ciao» 😀\nriga 2 — fine';

String _syncBody({String title = _title}) => json.encode({
      'server_time': 5,
      'full_resync': false,
      'folders': <Object>[],
      'notes': [
        {
          'id': 'n1',
          'title': title,
          'content': _content,
          'folder_id': null,
          'is_favorite': false,
          'is_pinned': false,
          'order_index': 0,
          'updated_at': 1,
          'deleted_at': null,
        },
      ],
    });

Future<SyncResponse> _sync(SyncApiService s) => s.sync(
      baseUrl: 'http://localhost:8080',
      token: 't',
      lastSyncedAt: 0,
      folders: const [],
      notes: const [],
    );

void main() {
  group('Y-02: risposte in UTF-8', () {
    test(
        'senza charset nel Content-Type accenti, frecce ed emoji arrivano intatti',
        () async {
      final client = MockClient((request) async => http.Response.bytes(
            utf8.encode(_syncBody()),
            200,
            headers: {'content-type': 'application/json'},
          ));
      final resp = await _sync(SyncApiService(client));
      expect(resp.notes.single.title, _title);
      expect(resp.notes.single.content, _content);
    });

    test('con charset=utf-8 dichiarato il risultato è lo stesso', () async {
      final client = MockClient((request) async => http.Response.bytes(
            utf8.encode(_syncBody()),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
      final resp = await _sync(SyncApiService(client));
      expect(resp.notes.single.title, _title);
    });

    test(
        'un corpo non UTF-8 (vecchio comportamento Latin-1) non fa fallire la sync',
        () async {
      // http.Response(String) senza charset codifica in Latin-1: byte non
      // validi in UTF-8. Si ripiega sulla decodifica di prima invece di lanciare.
      final client = MockClient((request) async => http.Response(
            _syncBody(title: 'più'),
            200,
            headers: {'content-type': 'application/json'},
          ));
      final resp = await _sync(SyncApiService(client));
      expect(resp.notes.single.title, 'più');
    });

    test('il messaggio d\'errore del server mantiene i caratteri non ASCII',
        () async {
      final client = MockClient((request) async => http.Response.bytes(
            utf8.encode(json.encode({'error': 'password troppo corta è'})),
            400,
            headers: {'content-type': 'application/json'},
          ));
      await expectLater(
        SyncApiService(client).login(
            baseUrl: 'http://localhost:8080', username: 'u', password: 'p'),
        throwsA(predicate((e) =>
            e is SyncApiException && e.message == 'password troppo corta è')),
      );
    });

    test('la richiesta parte in UTF-8, con charset e identificativo dell\'app',
        () async {
      late final List<int> sentBytes;
      late final Map<String, String> sentHeaders;
      final client = MockClient((request) async {
        sentBytes = request.bodyBytes;
        sentHeaders = request.headers;
        return http.Response.bytes(utf8.encode(_syncBody()), 200,
            headers: {'content-type': 'application/json'});
      });
      await SyncApiService(client).sync(
        baseUrl: 'http://localhost:8080',
        token: 't',
        lastSyncedAt: 0,
        folders: const [],
        notes: const [
          NoteChangeDto(
            id: 'n1',
            title: _title,
            content: _content,
            folderId: null,
            isFavorite: false,
            isPinned: false,
            orderIndex: 0,
            createdAt: 1,
            updatedAt: 1,
            deletedAt: null,
          ),
        ],
      );
      final sent = json.decode(utf8.decode(sentBytes)) as Map<String, dynamic>;
      expect((sent['notes'] as List).single['title'], _title);
      expect(sentHeaders['Content-Type'], contains('charset=utf-8'));
      expect(sentHeaders['Authorization'], 'Bearer t');
      expect(sentHeaders['X-Scripta-Client'], SyncApiService.clientHeaderValue);
    });
  });

  group('Retry-After', () {
    test('un 503 porta con sé l\'attesa indicata dal server', () async {
      final client = MockClient((request) async => http.Response(
            json.encode(
                {'error': 'database temporaneamente occupato, riprovare'}),
            503,
            headers: {'content-type': 'application/json', 'retry-after': '3'},
          ));
      await expectLater(
        _sync(SyncApiService(client)),
        throwsA(predicate((e) =>
            e is SyncApiException &&
            e.statusCode == 503 &&
            e.retryAfter == const Duration(seconds: 3))),
      );
    });

    test('senza Retry-After l\'attesa non è indicata', () async {
      final client = MockClient((request) async => http.Response('', 503));
      await expectLater(
        _sync(SyncApiService(client)),
        throwsA(predicate((e) =>
            e is SyncApiException &&
            e.statusCode == 503 &&
            e.retryAfter == null)),
      );
    });

    test('parseRetryAfter accetta solo secondi non negativi', () {
      expect(SyncApiService.parseRetryAfter('2'), const Duration(seconds: 2));
      expect(SyncApiService.parseRetryAfter(' 5 '), const Duration(seconds: 5));
      expect(SyncApiService.parseRetryAfter('0'), Duration.zero);
      expect(SyncApiService.parseRetryAfter('abc'), isNull);
      expect(SyncApiService.parseRetryAfter('-1'), isNull);
      expect(SyncApiService.parseRetryAfter('Wed, 21 Oct 2026 07:28:00 GMT'),
          isNull);
      expect(SyncApiService.parseRetryAfter(null), isNull);
    });
  });
}
