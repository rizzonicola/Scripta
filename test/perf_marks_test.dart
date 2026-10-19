import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/utils/perf_marks.dart';

// A-02 — i marker di prestazione devono essere TRASPARENTI: stesso valore,
// stesso errore, stessa esecuzione (una volta sola, subito) di ciò che
// avvolgono. Il database, le note e `_init` li usano senza `await` dedicati,
// quindi un wrapper che inghiottisse errori o alterasse valori romperebbe
// l'app in modo invisibile. L'emissione degli eventi in DevTools non è
// testabile in-process: si verifica a mano (vedi CHECKLIST_PROVA_MANUALE.md).

void main() {
  group('PerfMarks', () {
    test('mark non lancia', () {
      expect(() => PerfMarks.mark('test.istante'), returnsNormally);
    });

    test('timeAsync restituisce il valore della funzione avvolta', () async {
      final value = await PerfMarks.timeAsync('test.valore', () async => 42);
      expect(value, 42);
    });

    test('timeAsync esegue la funzione una sola volta e subito (in modo sincrono)', () async {
      var calls = 0;
      final future = PerfMarks.timeAsync('test.una_volta', () async {
        calls++;
        return 'ok';
      });
      // Il caricamento iniziale delle note parte nel costruttore del notifier:
      // l'avvolgimento non deve spostare l'inizio del lavoro in un microtask.
      expect(calls, 1);
      expect(await future, 'ok');
      expect(calls, 1);
    });

    test('timeAsync attende davvero la funzione avvolta', () async {
      final gate = Completer<String>();
      var done = false;

      final result = PerfMarks.timeAsync('test.attesa', () => gate.future).then((v) {
        done = true;
        return v;
      });

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(done, isFalse, reason: 'la funzione avvolta non è ancora finita');

      gate.complete('fatto');
      expect(await result, 'fatto');
      expect(done, isTrue);
    });

    test('timeAsync rilancia lo stesso errore, senza mascherarlo', () async {
      final error = StateError('errore di prova');
      await expectLater(
        PerfMarks.timeAsync<int>('test.errore', () async => throw error),
        throwsA(same(error)),
      );
    });

    test('timeAsync rilancia anche l\'errore di una funzione sincrona', () async {
      final error = StateError('errore sincrono');
      await expectLater(
        PerfMarks.timeAsync<int>('test.errore_sync', () => throw error),
        throwsA(same(error)),
      );
    });

    test('timeAsync può essere ripetuto con lo stesso nome', () async {
      // Più fasi con lo stesso nome (es. ogni apertura del database) non si
      // devono disturbare a vicenda.
      final results = await Future.wait([
        PerfMarks.timeAsync('test.ripetuto', () async => 1),
        PerfMarks.timeAsync('test.ripetuto', () async => 2),
      ]);
      expect(results, [1, 2]);
    });
  });
}
