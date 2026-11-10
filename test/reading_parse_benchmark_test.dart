// Benchmark diagnostico (nessuna asserzione di soglia): misura il costo del
// parsing Markdown della vista di lettura su note di 10, 100 e 500 KB.
// Si esegue con `flutter test test/reading_parse_benchmark_test.dart` e
// stampa i tempi; non fa parte dei test di regressione funzionale.
// ignore_for_file: avoid_print
import 'package:flutter_md/flutter_md.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/utils/markdown_math.dart';

String _note(int approximateBytes) {
  final buffer = StringBuffer();
  var i = 0;
  while (buffer.length < approximateBytes) {
    i++;
    buffer
      ..writeln('## Sezione $i')
      ..writeln()
      ..writeln(
        'Paragrafo $i con **grassetto**, *corsivo*, `codice` e un '
        '[link](https://example.com) per misurare il parsing reale.',
      )
      ..writeln()
      ..writeln('- primo elemento')
      ..writeln('- secondo elemento')
      ..writeln();
  }
  return buffer.toString();
}

void main() {
  test('parsing della vista di lettura: 10/100/500 KB', () {
    for (final kb in <int>[10, 100, 500]) {
      final content = _note(kb * 1024);
      final stopwatch = Stopwatch()..start();
      final blocks = Markdown.fromString(
        normalizeInlineMath(content),
        inlineMath: true,
      ).blocks;
      stopwatch.stop();
      print(
        'reading.parse ${kb.toString().padLeft(3)} KB: '
        '${stopwatch.elapsedMilliseconds.toString().padLeft(5)} ms, '
        '${blocks.length} blocchi',
      );
      expect(blocks, isNotEmpty);
    }
  });
}
