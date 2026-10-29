// Y-14 (app): `caps` è opzionale e additivo.

import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/features/sync/models/sync_models.dart';

void main() {
  group('ServerCaps', () {
    test('senza `caps` la risposta resta valida (server 2.1.0)', () {
      final r = SyncResponse.fromJson({
        'server_time': 5,
        'full_resync': false,
        'folders': [],
        'notes': [],
      });
      expect(r.caps, isNull);
      expect(r.serverTime, 5);
    });

    test('con `caps` si legge la versione del contratto', () {
      final r = SyncResponse.fromJson({
        'server_time': 5,
        'folders': [],
        'notes': [],
        'caps': {'proto': 2},
      });
      expect(r.caps, isNotNull);
      expect(r.caps!.proto, 2);
      expect(r.caps!.has('page'), isFalse);
    });

    test(
      'una chiave assente vale «non supportato», una sconosciuta si ignora',
      () {
        final caps = ServerCaps.fromJson({
          'proto': 3,
          'req_gzip': true,
          'page': false,
          'futura': 'boh',
          'n': 4,
        });
        expect(caps.proto, 3);
        expect(caps.has('req_gzip'), isTrue);
        expect(caps.has('page'), isFalse);
        expect(caps.has('assente'), isFalse);
        expect(
          caps.has('futura'),
          isFalse,
          reason: 'solo i booleani sono capability',
        );
      },
    );

    test('senza `proto` il contratto è la versione 1', () {
      expect(ServerCaps.fromJson({}).proto, 1);
    });

    test('un valore di `caps` che non è un oggetto viene ignorato', () {
      final r = SyncResponse.fromJson({
        'server_time': 1,
        'folders': [],
        'notes': [],
        'caps': 'sì',
      });
      expect(r.caps, isNull);
    });
  });
}
