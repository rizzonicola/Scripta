import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/features/editor/presentation/note_search_highlighted_view.dart';
import 'package:scripta/features/editor/providers/note_search_provider.dart';
import 'package:scripta/features/notes/models/note_model.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

NoteModel _note(String content) => NoteModel(
  id: 'n1',
  title: 'Titolo',
  content: content,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

List<InlineSpan> _spans(WidgetTester tester) {
  final selectable = tester.widget<SelectableText>(find.byType(SelectableText));
  return selectable.textSpan!.children!.toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'cambiare occorrenza riusa gli span non attivi e ricrea solo i due coinvolti',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const content = 'alfa beta alfa gamma alfa';
      final container = ProviderContainer(
        overrides: [activeNoteProvider.overrideWithValue(_note(content))],
      );
      addTearDown(container.dispose);
      container.read(noteSearchProvider.notifier).open(initialQuery: 'alfa');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: NoteSearchHighlightedView(
                title: 'Titolo',
                content: content,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final before = _spans(tester);
      expect(before, hasLength(5));

      container.read(noteSearchProvider.notifier).nextMatch(3);
      await tester.pump();

      final after = _spans(tester);
      expect(after, hasLength(before.length));
      expect(identical(before[1], after[1]), isTrue);
      expect(identical(before[3], after[3]), isTrue);
      expect(identical(before[4], after[4]), isTrue);
      expect(identical(before[0], after[0]), isFalse);
      expect(identical(before[2], after[2]), isFalse);
    },
  );
}
