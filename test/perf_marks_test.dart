import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/utils/perf_marks.dart';

// I marker servono solo a misurare: non devono mai cambiare il risultato né
// l'errore di ciò che avvolgono, e `_init`/il DB/le note li usano senza `await`
// dedicati, quindi un wrapper che inghiottisse errori o alterasse valori
// romperebbe l'app in modo invisibile.

void main() {
  group('PerfMarks', () {
    test('instant non lancia', () {
      expect(() => PerfMarks.instant('scripta.test.instant'), returnsNormally);
    });

    test('timeAsync restituisce il valore della callback', () async {
      final value = await PerfMarks.timeAsync('scripta.test.valore', () async => 42);
      expect(value, 42);
    });

    test('timeAsync attende davvero la callback', () async {
      final gate = Completer<String>();
      var done = false;

      final result = PerfMarks.timeAsync('scripta.test.attesa', () => gate.future)
          .then((v) {
        done = true;
        return v;
      });

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(done, isFalse, reason: 'la callback non è ancora finita');

      gate.complete('fatto');
      expect(await result, 'fatto');
      expect(done, isTrue);
    });

    test('timeAsync rilancia lo STESSO errore della callback', () async {
      final error = StateError('errore di prova');
      await expectLater(
        PerfMarks.timeAsync<int>('scripta.test.errore', () async => throw error),
        throwsA(same(error)),
      );
    });

    test('timeAsync rilancia anche l\'errore di una callback sincrona', () async {
      final error = StateError('errore sincrono');
      await expectLater(
        PerfMarks.timeAsync<int>('scripta.test.errore_sync', () => throw error),
        throwsA(same(error)),
      );
    });

    test('più intervalli concorrenti con lo stesso nome non si disturbano', () async {
      final results = await Future.wait([
        PerfMarks.timeAsync('scripta.test.concorrente', () async => 1),
        PerfMarks.timeAsync('scripta.test.concorrente', () async => 2),
      ]);
      expect(results, [1, 2]);
    });
  });
}
