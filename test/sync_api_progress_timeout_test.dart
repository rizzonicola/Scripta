// Y-05: il timeout della sync conta il PROGRESSO, non la durata.
//
// Prima: un solo `timeout(30 s)` sull'intera richiesta, quindi un upload lento
// ma vivo veniva interrotto e ripartiva da zero. Ora scatta solo se per un
// certo tempo non si muove nessun byte (in su o in giù), o allo scadere del
// tetto assoluto. I tempi del test sono volutamente minuscoli.

import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scripta/core/services/sync_api_service.dart';
import 'package:scripta/features/sync/models/sync_models.dart';

const _okBody = '{"server_time":7,"full_resync":false,"folders":[],"notes":[]}';
const _headers = {'content-type': 'application/json'};

/// ~100 KB di testo: più blocchi da 16 KiB nell'upload.
NoteChangeDto _bigNote() => NoteChangeDto(
      id: 'n1',
      title: 't',
      content: 'a' * 100000,
      folderId: null,
      isFavorite: false,
      isPinned: false,
      orderIndex: 0,
      updatedAt: 1,
      deletedAt: null,
    );

Future<SyncResponse> _call(SyncApiService s, {bool big = false}) => s.sync(
      baseUrl: 'http://localhost:8080',
      token: 't',
      lastSyncedAt: 0,
      folders: const [],
      notes: big ? [_bigNote()] : const [],
    );

http.StreamedResponse _ok() =>
    http.StreamedResponse(Stream.value(utf8.encode(_okBody)), 200, headers: _headers);

Stream<List<int>> _slowBody(Duration gap, {int pieces = 6}) async* {
  final bytes = utf8.encode(_okBody);
  final step = (bytes.length / pieces).ceil();
  for (var i = 0; i < bytes.length; i += step) {
    await Future<void>.delayed(gap);
    yield bytes.sublist(i, min(i + step, bytes.length));
  }
}

void main() {
  group('Y-05: timeout a progressi', () {
    test('una risposta lenta ma viva non scade (durata totale > idle)', () async {
      final client = MockClient.streaming((request, body) async {
        await body.drain<void>();
        return http.StreamedResponse(_slowBody(const Duration(milliseconds: 60)), 200, headers: _headers);
      });
      final service = SyncApiService(
        client,
        const SyncTimeouts(
          connect: Duration(seconds: 2),
          idle: Duration(milliseconds: 250),
          serverWait: Duration(seconds: 2),
          total: Duration(seconds: 10),
        ),
      );
      final resp = await _call(service);
      expect(resp.serverTime, 7);
    });

    test('una risposta che si ferma a metà scade per inattività', () async {
      // Resta volutamente aperto: la lettura viene annullata dal timeout.
      final controller = StreamController<List<int>>();
      final client = MockClient.streaming((request, body) async {
        await body.drain<void>();
        controller.add(utf8.encode(_okBody.substring(0, 10)));
        return http.StreamedResponse(controller.stream, 200, headers: _headers);
      });
      final service = SyncApiService(
        client,
        const SyncTimeouts(
          connect: Duration(seconds: 2),
          idle: Duration(milliseconds: 150),
          serverWait: Duration(seconds: 2),
          total: Duration(seconds: 10),
        ),
      );
      await expectLater(_call(service), throwsA(isA<TimeoutException>()));
    });

    test('un upload lento ma vivo non scade', () async {
      final client = MockClient.streaming((request, body) async {
        // Il server legge un blocco ogni 60 ms: ~7 blocchi, ~420 ms in tutto.
        await for (final _ in body) {
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
        return _ok();
      });
      final service = SyncApiService(
        client,
        const SyncTimeouts(
          connect: Duration(seconds: 2),
          idle: Duration(milliseconds: 250),
          serverWait: Duration(seconds: 2),
          total: Duration(seconds: 10),
        ),
      );
      final resp = await _call(service, big: true);
      expect(resp.serverTime, 7);
    });

    test('un upload che si blocca dopo il primo blocco scade', () async {
      final client = MockClient.streaming((request, body) async {
        final it = StreamIterator<List<int>>(body);
        await it.moveNext(); // legge un blocco e poi non legge più nulla
        return Completer<http.StreamedResponse>().future; // non risponde mai
      });
      final service = SyncApiService(
        client,
        const SyncTimeouts(
          connect: Duration(seconds: 2),
          idle: Duration(milliseconds: 150),
          serverWait: Duration(seconds: 2),
          total: Duration(seconds: 10),
        ),
      );
      await expectLater(_call(service, big: true), throwsA(isA<TimeoutException>()));
    });

    test('se la connessione non parte mai scade il timeout di connessione', () async {
      final client = MockClient.streaming((request, body) async {
        return Completer<http.StreamedResponse>().future; // non legge il corpo, non risponde
      });
      final service = SyncApiService(
        client,
        const SyncTimeouts(
          connect: Duration(milliseconds: 150),
          idle: Duration(seconds: 5),
          serverWait: Duration(seconds: 5),
          total: Duration(seconds: 10),
        ),
      );
      await expectLater(_call(service), throwsA(isA<TimeoutException>()));
    });

    test('l\'attesa del server dopo l\'invio ha il suo limite, più largo dell\'idle', () async {
      Future<http.StreamedResponse> slowServer(http.BaseRequest request, http.ByteStream body) async {
        await body.drain<void>();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return _ok();
      }

      final patient = SyncApiService(
        MockClient.streaming(slowServer),
        const SyncTimeouts(
          connect: Duration(seconds: 2),
          idle: Duration(milliseconds: 100),
          serverWait: Duration(seconds: 2),
          total: Duration(seconds: 10),
        ),
      );
      expect((await _call(patient)).serverTime, 7);

      final impatient = SyncApiService(
        MockClient.streaming(slowServer),
        const SyncTimeouts(
          connect: Duration(seconds: 2),
          idle: Duration(milliseconds: 100),
          serverWait: Duration(milliseconds: 100),
          total: Duration(seconds: 10),
        ),
      );
      await expectLater(_call(impatient), throwsA(isA<TimeoutException>()));
    });

    test('il tetto assoluto ferma anche una risposta che non finisce mai', () async {
      final client = MockClient.streaming((request, body) async {
        await body.drain<void>();
        Stream<List<int>> endless() async* {
          while (true) {
            await Future<void>.delayed(const Duration(milliseconds: 40));
            yield utf8.encode(' ');
          }
        }

        return http.StreamedResponse(endless(), 200, headers: _headers);
      });
      final service = SyncApiService(
        client,
        const SyncTimeouts(
          connect: Duration(seconds: 2),
          idle: Duration(seconds: 5),
          serverWait: Duration(seconds: 5),
          total: Duration(milliseconds: 400),
        ),
      );
      await expectLater(_call(service), throwsA(isA<TimeoutException>()));
    });

    test('gli errori HTTP restano quelli di prima (401, 422)', () async {
      final unauthorized = SyncApiService(MockClient((r) async => http.Response('{"error":"x"}', 401)));
      await expectLater(
        _call(unauthorized),
        throwsA(predicate((e) => e is SyncApiException && e.statusCode == 401)),
      );

      final rejected = SyncApiService(MockClient((r) async => http.Response(
            json.encode({
              'error': 'rifiutati',
              'rejected': [
                {'kind': 'note', 'id': 'n1', 'reason': 'invalid_folder_id'},
              ],
            }),
            422,
            headers: _headers,
          )));
      await expectLater(
        _call(rejected),
        throwsA(predicate((e) =>
            e is SyncApiException && e.statusCode == 422 && e.rejected.length == 1 && e.rejected.single.id == 'n1')),
      );
    });
  });
}
