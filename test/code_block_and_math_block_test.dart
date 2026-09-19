import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/features/editor/presentation/code_block_with_copy.dart';
import 'package:scripta/features/editor/presentation/display_math_block.dart';
import 'package:scripta/features/editor/presentation/markdown_rendered_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Verifica Modifiche Precedenti (CodeBlockWithCopy & DisplayMathBlock)', () {
    testWidgets('1. CodeBlockWithCopy: click copia il codice negli appunti e mostra feedback visivo', (tester) async {
      String? copiedText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            copiedText = (methodCall.arguments as Map)['text'] as String?;
            return null;
          }
          return null;
        },
      );

      const testCode = 'void main() {\n  print("Scripta");\n}';

      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: CodeBlockWithCopy(
              code: testCode,
              language: 'dart',
              surfaceColor: Color(0xFF1E1E1E),
              child: Text(testCode),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verifica presenza etichetta linguaggio
      expect(find.text('dart'), findsOneWidget);

      // Verifica presenza icona copia
      final copyButtonFinder = find.byType(IconButton);
      expect(copyButtonFinder, findsOneWidget);

      // Clicchiamo sul pulsante copia
      await tester.tap(copyButtonFinder);
      await tester.pump();

      // Verifichiamo che il testo copiato sia ESATTAMENTE il codice e non altro
      expect(copiedText, testCode);

      // Verifichiamo che appaia l'icona di check e l'etichetta "Copiato!"
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('2. CodeBlockWithCopy dentro MarkdownRenderedView: il tap sul pulsante non viene intercettato dalla selezione', (tester) async {
      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            clipboardText = (methodCall.arguments as Map)['text'] as String?;
            return null;
          }
          return null;
        },
      );

      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const note = '# Nota con codice\n\n```python\nx = 42\n```\n\nFine.';

      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ProviderScope(
              child: MarkdownRenderedView(
                title: 'Test Codice',
                content: note,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final copyBtn = find.byIcon(Icons.content_copy_rounded);
      expect(copyBtn, findsOneWidget);

      await tester.ensureVisible(copyBtn);
      await tester.pumpAndSettle();

      // Tap su IconButton con puntatore mouse
      final iconBtnFinder = find.byType(IconButton);
      expect(iconBtnFinder, findsOneWidget);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(iconBtnFinder));
      await mouse.down(tester.getCenter(iconBtnFinder));
      await mouse.up();
      await tester.pumpAndSettle();

      expect(clipboardText, 'x = 42');
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('3. DisplayMathBlock: rendering di TeX valido e fallback su TeX invalido', (tester) async {
      // Test formula TeX valida
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DisplayMathBlock(
              tex: r'\frac{-b \pm \sqrt{b^2 - 4ac}}{2a}',
              textStyle: TextStyle(fontSize: 18),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DisplayMathBlock), findsOneWidget);

      // Test formula TeX invalida (sintassi rotta)
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DisplayMathBlock(
              tex: r'\frac{incompleta',
              textStyle: TextStyle(fontSize: 18),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Deve mostrare il fallback di testo invece di lanciare eccezione
      expect(find.text(r'\frac{incompleta'), findsOneWidget);
    });

    testWidgets('4. MarkdownRenderedView integra DisplayMathBlock con AST pre-parsato ed errore cachato', (tester) async {
      const note = '''
# Note con Display Math
Prima riga di testo.

\$\$
\\frac{1}{2} + \\sqrt{3}
\$\$

\$\$
\\frac{incompleta
\$\$

Testo finale.
''';

      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ProviderScope(
              child: MarkdownRenderedView(
                title: 'Math Note',
                content: note,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Devono esserci 2 DisplayMathBlock
      expect(find.byType(DisplayMathBlock), findsNWidgets(2));
      // La formula incompleta deve mostrare il fallback
      expect(find.text(r'\frac{incompleta'), findsOneWidget);
    });
  });
}
