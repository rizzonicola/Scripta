// ignore_for_file: avoid_print, deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_math_fork/tex.dart'
    show SyntaxTree, TexParser, TexParserSettings;
import 'package:flutter_md/flutter_md.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/core/utils/markdown_math.dart';
import 'package:scripta/features/editor/presentation/display_math_block.dart';
import 'package:scripta/features/editor/presentation/markdown_rendered_view.dart';

void main() {
  final benchmarkMarkdown = StringBuffer()
    ..writeln('# Benchmark Document con Formule Matematiche e Markdown Complesso\n')
    ..writeln('Questo documento serve a profilare le prestazioni di rendering di Scripta.\n')
    ..writeln('## Sezione 1: Formule Inline Chimiche e Fisiche')
    ..writeln(
      r'La reazione fondamentale di combustione del glucosio e '
      r'$\text{C}_6\text{H}_{12}\text{O}_6 + 6\text{O}_2 \rightarrow 6\text{CO}_2 + 6\text{H}_2\text{O}$, '
      r'con una variazione di entalpia pari a $\Delta H^\circ = -2803\text{ kJ/mol}$. '
      r'In condizioni standard la temperatura e $T = 298.15\text{ K}$ e la pressione $P = 1\text{ atm}$.',
    )
    ..writeln(
      r"Nella meccanica quantistica, l'energia di un fotone e data da "
      r"$E = h\nu = \hbar\omega$, "
      r"mentre la lunghezza d'onda di De Broglie e $\lambda = \frac{h}{p}$. "
      r"La relazione relativistica tra energia e momento e $E^2 = (pc)^2 + (m_0 c^2)^2$.",
    )
    ..writeln('\n## Sezione 2: Formule a Blocco Complesse\n')
    ..writeln(r'$$')
    ..writeln(r'f(x) = \frac{1}{\sigma \sqrt{2\pi}} \exp\left( -\frac{1}{2}\left(\frac{x-\mu}{\sigma}\right)^2 \right)')
    ..writeln(r'$$')
    ..writeln('\nUn\'altra formula a blocco di calcolo integrale:\n')
    ..writeln(r'$$')
    ..writeln(r'\int_{-\infty}^{\infty} e^{-x^2} \, dx = \sqrt{\pi}')
    ..writeln(r'$$')
    ..writeln('\n## Sezione 3: Tabella dei Parametri Fisici\n')
    ..writeln('| Costante | Simbolo | Valore Approssimato | Unita di Misura |')
    ..writeln('| :--- | :---: | :--- | :--- |')
    ..writeln(r'| Velocita della luce | $c$ | $2.998 \times 10^8$ | m/s |')
    ..writeln(r'| Costante di Planck | $h$ | $6.626 \times 10^{-34}$ | J*s |')
    ..writeln(r'| Costante gravitazionale | $G$ | $6.674 \times 10^{-11}$ | N*m2/kg2 |')
    ..writeln(r'| Costante di Boltzmann | $k_B$ | $1.381 \times 10^{-23}$ | J/K |')
    ..writeln('\n## Sezione 4: Blocchi di Codice\n')
    ..writeln('```dart\nvoid main() {\n  final double h = 6.626e-34;\n  final double c = 3.0e8;\n  print(h * c);\n}\n```')
    ..writeln('```python\ndef gaussian(x, mu, sigma):\n    return (1.0 / (sigma * (2 * 3.14159)**0.5)) * math.exp(-0.5 * ((x - mu)/sigma)**2)\n```');

  for (var i = 1; i <= 25; i++) {
    benchmarkMarkdown.writeln('\n### Paragrafo $i di approfondimento');
    benchmarkMarkdown.writeln(
      'Consideriamo il caso $i: la densita di probabilita soddisfa '
      r'$\sum_{k=1}^n P(X = k) = 1$ e la varianza e calcolata come '
      r'$\sigma^2 = \text{Var}(X) = E[X^2] - (E[X])^2$. '
      r'Questo garantisce stabilita numerica per qualsiasi $N > 1000$. '
      'Testo descrittivo aggiuntivo con parole chiave in **grassetto**, '
      '*corsivo* e un [link di documentazione](https://scripta.app) per validare la ricchezza visiva.',
    );
    if (i % 5 == 0) {
      benchmarkMarkdown.writeln(r'$$');
      benchmarkMarkdown.writeln('S_{$i} = \\sum_{j=1}^{$i} \\frac{j^2 + 1}{\\sqrt{j + 3}}');
      benchmarkMarkdown.writeln(r'$$');
    }
  }

  final testNoteContent = benchmarkMarkdown.toString();

  group('Performance Baseline & Math Rendering Benchmarks', () {
    test('1. Baseline Timing: splitNoteChunks + normalizeInlineMath + Markdown.fromString', () {
      final stopwatch = Stopwatch()..start();
      const iterations = 50;
      for (var iter = 0; iter < iterations; iter++) {
        final chunks = splitNoteChunks(testNoteContent);
        for (final chunk in chunks) {
          if (chunk is MarkdownChunk) {
            final normalized = normalizeInlineMath(chunk.source);
            if (normalized.trim().isNotEmpty) {
              final md = Markdown.fromString(normalized, inlineMath: true);
              expect(md.blocks, isNotEmpty);
            }
          } else if (chunk is DisplayMathChunk) {
            expect(chunk.tex, isNotEmpty);
          }
        }
      }
      stopwatch.stop();
      final avgMs = stopwatch.elapsedMilliseconds / iterations;
      print('--> [BASELINE] Tempo medio parsing completo nota (${testNoteContent.length} char, 50 iterazioni): ${avgMs.toStringAsFixed(2)} ms');
      expect(avgMs, lessThan(30.0));
    });

    testWidgets('2. Baseline UI Lifecycle: apertura nota, initial build & layout', (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final stopwatch = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ProviderScope(
              child: MarkdownRenderedView(
                title: 'Nota Benchmark Prestazioni',
                content: testNoteContent,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      stopwatch.stop();
      final initialFrameMs = stopwatch.elapsedMilliseconds;
      print('--> [BASELINE] Tempo apertura nota (pumpWidget + layout iniziale): $initialFrameMs ms');

      final scrollWatch = Stopwatch()..start();
      final scrollController = find.byType(ListView);
      expect(scrollController, findsOneWidget);

      final frameTimes = <double>[];
      for (var s = 0; s < 20; s++) {
        final fWatch = Stopwatch()..start();
        await tester.drag(scrollController, const Offset(0, -300));
        await tester.pump();
        fWatch.stop();
        frameTimes.add(fWatch.elapsedMicroseconds / 1000.0);
      }
      scrollWatch.stop();

      frameTimes.sort();
      final p50 = frameTimes[(frameTimes.length * 0.50).toInt()];
      final p99 = frameTimes[frameTimes.length - 1];
      final avgFrame = frameTimes.reduce((a, b) => a + b) / frameTimes.length;

      print('--> [BASELINE] Scroll frame build times (ListView virtualizzata): Media=${avgFrame.toStringAsFixed(2)} ms, p50=${p50.toStringAsFixed(2)} ms, p99=${p99.toStringAsFixed(2)} ms');
      expect(avgFrame, lessThan(20.0));
      await tester.pumpAndSettle();
    });

    testWidgets('3. Confronto Diretto: flutter_md nativo vs WidgetSpan(Math.tex) inline', (tester) async {
      // Misuriamo il costo di renderizzare 20 paragrafi con formule inline complesse:
      // Caso A: flutter_md (Canvas / TextPainter con Unicode convertito)
      // Caso B: RichText con WidgetSpan(Math.tex) per ogni formula

      const paragraphWithMath =
        'Paragrafo con formula a frazione \$x = \\frac{a+b}{c+d}\$, radice \$\\sqrt{x^2+1}\$, '
        'sommatoria \$\\sum_{i=0}^n i^2\$ ed energia \$E = mc^2\$. '
        'Testo continuo per misurare il layout multi-riga.';

      // Caso A: flutter_md nativo
      final mdWatch = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: List.generate(20, (i) {
                  final normalized = normalizeInlineMath(paragraphWithMath);
                  final md = Markdown.fromString(normalized, inlineMath: true);
                  return MarkdownWidget(
                    markdown: md,
                    documentId: 'p-$i',
                  );
                }),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      mdWatch.stop();
      final mdMs = mdWatch.elapsedMicroseconds / 1000.0;

      // Contiamo i RenderObject creati nel Caso A
      var countRenderObjectsA = 0;
      tester.binding.renderView.visitChildren((child) {
        void visit(RenderObject obj) {
          countRenderObjectsA++;
          obj.visitChildren(visit);
        }
        visit(child);
      });

      // Caso B: RichText con WidgetSpan(Math.tex)
      final spanWatch = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: List.generate(20, (i) {
                  return Text.rich(
                    TextSpan(
                      text: 'Paragrafo con formula a frazione ',
                      style: const TextStyle(fontSize: 16, color: Colors.black),
                      children: [
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Math.tex(r'x = \frac{a+b}{c+d}', mathStyle: MathStyle.text),
                        ),
                        const TextSpan(text: ', radice '),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Math.tex(r'\sqrt{x^2+1}', mathStyle: MathStyle.text),
                        ),
                        const TextSpan(text: ', sommatoria '),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Math.tex(r'\sum_{i=0}^n i^2', mathStyle: MathStyle.text),
                        ),
                        const TextSpan(text: ' ed energia '),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Math.tex(r'E = mc^2', mathStyle: MathStyle.text),
                        ),
                        const TextSpan(text: '. Testo continuo per misurare il layout multi-riga.'),
                      ],
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      spanWatch.stop();
      final spanMs = spanWatch.elapsedMicroseconds / 1000.0;

      var countRenderObjectsB = 0;
      tester.binding.renderView.visitChildren((child) {
        void visit(RenderObject obj) {
          countRenderObjectsB++;
          obj.visitChildren(visit);
        }
        visit(child);
      });

      print('--> [CONFRONTO RENDERING INLINE (20 paragrafi x 4 formule = 80 formule)]');
      print('    - flutter_md Nativo (Canvas/Unicode): Tempo = ${mdMs.toStringAsFixed(2)} ms, RenderObjects = $countRenderObjectsA');
      print('    - Ibrido WidgetSpan(Math.tex):        Tempo = ${spanMs.toStringAsFixed(2)} ms, RenderObjects = $countRenderObjectsB');
      print('    - Overhead temporale: +${((spanMs - mdMs) / mdMs * 100).toStringAsFixed(1)}%');
      print('    - Overhead RenderObjects: +${((countRenderObjectsB - countRenderObjectsA) / countRenderObjectsA * 100).toStringAsFixed(1)}% (+${countRenderObjectsB - countRenderObjectsA} nodi nel render tree)');
    });

    testWidgets('4. Model-Anchored Selection Integrity Check', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ProviderScope(
              child: MarkdownRenderedView(
                title: 'Verifica Selezione',
                content: 'Paragrafo uno con formula \$E = mc^2\$.\n\nParagrafo due con \$H_2O\$.',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final selectionScopeFinder = find.byType(MarkdownSelectionScope);
      expect(selectionScopeFinder, findsOneWidget);
      final selectionScope = tester.state<MarkdownSelectionScopeState>(selectionScopeFinder);

      selectionScope.selectAll();
      await tester.pumpAndSettle();

      final selection = selectionScope.controller.selection;
      expect(selection, isNotNull);
      expect(selection!.isCollapsed, isFalse);

      final selectedText = selectionScope.controller.getText();
      print('--> [SELECTION CHECK] Testo selezionato con SelectAll:\n"$selectedText"');
      expect(selectedText, contains('Paragrafo uno con formula'));
      expect(selectedText, contains('Paragrafo due con'));
    });

    testWidgets('5. Benchmark Comparativo: Rebuild Scroll SENZA cache vs CON cache memoized', (tester) async {
      // 10 formule complesse realistiche
      final complexTexList = [
        r'f(x) = \frac{1}{\sigma \sqrt{2\pi}} \exp\left( -\frac{1}{2}\left(\frac{x-\mu}{\sigma}\right)^2 \right)',
        r'\int_{-\infty}^{\infty} e^{-x^2} \, dx = \sqrt{\pi}',
        r'S_n = \sum_{k=1}^n \frac{k^2 + 1}{\sqrt{k + 3}}',
        r'x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}',
        r'\nabla \times \mathbf{B} = \mu_0 \mathbf{J} + \mu_0 \epsilon_0 \frac{\partial \mathbf{E}}{\partial t}',
        r'\oint_{\partial \Sigma} \mathbf{E} \cdot d\boldsymbol{\ell} = -\frac{d}{dt} \iint_{\Sigma} \mathbf{B} \cdot d\mathbf{S}',
        r'\sum_{n=1}^\infty \frac{1}{n^s} = \prod_{p \text{ primo}} \frac{1}{1 - p^{-s}}',
        r'\mathcal{L}\{f(t)\} = \int_0^\infty e^{-st} f(t) \, dt',
        r'\lim_{x \to 0} \frac{\sin(x)}{x} = 1',
        r'\begin{matrix} a & b \\ c & d \end{matrix}',
      ];

      const iterations = 50;

      // 1) SENZA CACHE (come nella vecchia implementazione: Math.tex rieseguito a ogni frame)
      final withoutCacheTimes = <double>[];
      for (var iter = 0; iter < iterations; iter++) {
        final w = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: complexTexList.map((tex) {
                  return DisplayMathBlock(
                    tex: tex,
                    textStyle: const TextStyle(fontSize: 16),
                  );
                }).toList(),
              ),
            ),
          ),
        );
        w.stop();
        withoutCacheTimes.add(w.elapsedMicroseconds / 1000.0);
      }

      // 2) CON CACHE MEMOIZED (_MathItem: pre-parsato e riutilizzato)
      // Simuliamo gli elementi _MathItem che mantengono il getter memoized
      final mathItems = complexTexList.map((tex) {
        // Simuliamo l'interfaccia di _MathItem (lazy memoized)
        SyntaxTree? ast;
        try {
          ast = SyntaxTree(greenRoot: TexParser(tex, const TexParserSettings()).parse());
        } catch (_) {}
        return (tex: tex, ast: ast);
      }).toList();

      final withCacheTimes = <double>[];
      for (var iter = 0; iter < iterations; iter++) {
        final w = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: mathItems.map((item) {
                  return DisplayMathBlock(
                    tex: item.tex,
                    textStyle: const TextStyle(fontSize: 16),
                    ast: item.ast,
                  );
                }).toList(),
              ),
            ),
          ),
        );
        w.stop();
        withCacheTimes.add(w.elapsedMicroseconds / 1000.0);
      }

      withoutCacheTimes.sort();
      withCacheTimes.sort();

      final avgWithout = withoutCacheTimes.reduce((a, b) => a + b) / withoutCacheTimes.length;
      final p50Without = withoutCacheTimes[(withoutCacheTimes.length * 0.5).toInt()];
      final p99Without = withoutCacheTimes.last;

      final avgWith = withCacheTimes.reduce((a, b) => a + b) / withCacheTimes.length;
      final p50With = withCacheTimes[(withCacheTimes.length * 0.5).toInt()];
      final p99With = withCacheTimes.last;

      final deltaMs = avgWithout - avgWith;
      final percentSaved = (deltaMs / avgWithout) * 100;

      print('--> [BENCHMARK CACHE TEX: 10 formule complesse x 50 cicli di rebuild/scroll]');
      print('    - SENZA CACHE (Math.tex rieseguito):   Media = ${avgWithout.toStringAsFixed(2)} ms, p50 = ${p50Without.toStringAsFixed(2)} ms, p99 = ${p99Without.toStringAsFixed(2)} ms');
      print('    - CON CACHE MEMOIZED (SyntaxTree):      Media = ${avgWith.toStringAsFixed(2)} ms, p50 = ${p50With.toStringAsFixed(2)} ms, p99 = ${p99With.toStringAsFixed(2)} ms');
      print('    - Risparmio CPU per frame di scroll:    -${deltaMs.toStringAsFixed(2)} ms (-${percentSaved.toStringAsFixed(1)}% di tempo di build/layout!)');
    });
  });
}
