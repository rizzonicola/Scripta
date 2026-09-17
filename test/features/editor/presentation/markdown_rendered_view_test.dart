import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/features/editor/presentation/markdown_rendered_view.dart';
import 'package:scripta/features/editor/presentation/providers/markdown_selection_provider.dart';

void main() {
  testWidgets('Long press selects word and displays AdaptiveTextSelectionToolbar without handles', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const content = 'Questo e un test del testo di Scripta.';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(
            textTheme: const TextTheme(
              bodyMedium: TextStyle(fontSize: 16),
            ),
          ),
          home: const Scaffold(
            body: MarkdownRenderedView(
              title: 'Nota di test',
              content: content,
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify initial state has no selection and no toolbar
    expect(container.read(markdownSelectionProvider).isValid, isFalse);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);

    // Long press on the text
    final textFinder = find.text('Questo e un test del testo di Scripta.');
    expect(textFinder, findsOneWidget);

    await tester.longPress(textFinder);
    await tester.pumpAndSettle();

    // Verify selection is now valid and non-collapsed
    final selection = container.read(markdownSelectionProvider);
    expect(selection.isValid, isTrue);
    expect(selection.isCollapsed, isFalse);

    // Verify the native AdaptiveTextSelectionToolbar is displayed
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

    // Verify that NO selection handles exist (CustomPaint handles are removed)
    // There should be no GestureDetector with handle drag callbacks
    expect(find.byKey(const ValueKey('start_handle')), findsNothing);
    expect(find.byKey(const ValueKey('end_handle')), findsNothing);

    // TAP BREVE: A quick tap on the selected text MUST deselect immediately
    await tester.tap(textFinder);
    await tester.pumpAndSettle();

    // Verify selection is cleared and toolbar is dismissed
    final afterTapSelection = container.read(markdownSelectionProvider);
    expect(afterTapSelection.isValid, isFalse);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);

    // Drain any remaining haptics debounce timers
    await tester.pump(const Duration(milliseconds: 300));
  });
}
