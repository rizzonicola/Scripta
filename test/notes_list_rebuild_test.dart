import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/database/app_database.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/core/theme/app_theme.dart';
import 'package:scripta/features/folders/providers/folder_provider.dart';
import 'package:scripta/features/notes/presentation/note_card.dart';
import 'package:scripta/features/notes/presentation/notes_list_view.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _waitUntil(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  Duration interval = const Duration(milliseconds: 25),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(interval);
  }
}

NoteCard _card(WidgetTester tester, String id) => tester
    .widgetList<NoteCard>(find.byType(NoteCard))
    .firstWhere((card) => card.note.id == id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppDatabase.ensureFactoryInitialized();
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = p.join(
      Directory.systemTemp.path,
      'scripta_list_rebuild_${DateTime.now().microsecondsSinceEpoch}.db',
    );
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = null;
  });

  test('aggiornare il contenuto non notifica la lista degli id', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notes = container.read(notesProvider.notifier);
    final folders = container.read(folderProvider.notifier);
    await _waitUntil(
      () async => notes.initialLoadComplete && folders.initialLoadComplete,
    );

    final first = notes.createNote();
    notes.createNote();
    await notes.flushPendingSaves();

    final notifications = <FilteredNoteIds>[];
    container.listen(
      filteredNoteIdsProvider,
      (_, next) => notifications.add(next),
      fireImmediately: true,
    );
    notifications.clear();

    notes.updateNote(first.id, content: 'contenuto aggiornato');

    expect(notifications, isEmpty);
    expect(
      container.read(notesByIdProvider)[first.id]!.content,
      'contenuto aggiornato',
    );
  });

  testWidgets('solo la card della nota modificata viene ricostruita', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notes = container.read(notesProvider.notifier);
    final folders = container.read(folderProvider.notifier);
    await tester.runAsync(
      () => _waitUntil(
        () async => notes.initialLoadComplete && folders.initialLoadComplete,
      ),
    );

    final first = notes.createNote();
    final second = notes.createNote();
    await tester.runAsync(notes.flushPendingSaves);
    addTearDown(notes.flushPendingSaves);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.lightTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SizedBox(width: 380, child: NotesListView()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final firstBefore = _card(tester, first.id);
    final secondBefore = _card(tester, second.id);

    notes.updateNote(first.id, content: 'contenuto aggiornato');
    await tester.pump();

    final firstAfter = _card(tester, first.id);
    final secondAfter = _card(tester, second.id);

    expect(identical(firstBefore, firstAfter), isFalse);
    expect(identical(secondBefore, secondAfter), isTrue);
    expect(firstAfter.note.content, 'contenuto aggiornato');

    await tester.runAsync(notes.flushPendingSaves);
  });
}
