import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/database/app_database.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/core/theme/app_theme.dart';
import 'package:scripta/features/folders/providers/folder_provider.dart';
import 'package:scripta/features/notes/models/note_model.dart';
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

List<String> _ids(ProviderContainer container) =>
    container.read(notesProvider).notes.map((note) => note.id).toList();

Future<void> _longPressDrag(
  WidgetTester tester,
  Offset start, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  final gesture = await tester.startGesture(start, kind: kind);
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  // Più move: il primo frame avvia il drag proxy, i successivi spostano
  // l'elemento oltre il punto di scambio.
  for (var i = 0; i < 6; i++) {
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppDatabase.ensureFactoryInitialized();
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = p.join(
      Directory.systemTemp.path,
      'scripta_reorder_gesture_${DateTime.now().microsecondsSinceEpoch}.db',
    );
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = null;
  });

  testWidgets(
    'custom: niente maniglia, tap breve apre, long-press e long-click trascinano',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notes = container.read(notesProvider.notifier);
      final folders = container.read(folderProvider.notifier);
      await tester.runAsync(
        () => _waitUntil(
          () async => notes.initialLoadComplete && folders.initialLoadComplete,
        ),
      );

      notes.createNote();
      notes.createNote();
      await notes.setSortOrder(NoteSortOrder.custom);
      await tester.runAsync(notes.flushPendingSaves);

      NoteModel? opened;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.lightTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SizedBox(
                width: 380,
                child: NotesListView(onNoteSelected: (note) => opened = note),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.byType(ReorderableDelayedDragStartListener),
        findsNWidgets(2),
      );
      expect(
        find.ancestor(
          of: find.byType(NoteCard).first,
          matching: find.byType(ReorderableDelayedDragStartListener),
        ),
        findsOneWidget,
        reason: 'il drag deve partire dall’intera card, non da una maniglia',
      );
      expect(find.byIcon(Icons.drag_indicator_rounded), findsNothing);

      final before = _ids(container);
      final firstCard = tester.widget<NoteCard>(find.byType(NoteCard).first);
      await tester.tap(find.byType(NoteCard).first);
      await tester.pump();

      expect(opened?.id, firstCard.note.id);
      expect(_ids(container), before, reason: 'il tap breve non riordina');

      final draggedId = firstCard.note.id;
      final draggedIndex = before.indexOf(draggedId);
      opened = null;
      await _longPressDrag(
        tester,
        tester.getCenter(find.byType(NoteCard).at(0)),
      );

      expect(opened, isNull, reason: 'il drag non deve aprire la nota');
      expect(
        _ids(container).indexOf(draggedId),
        isNot(draggedIndex),
        reason: 'il long-press seguito da trascinamento deve riordinare',
      );

      final mouseDraggedId = _ids(container).first;
      opened = null;
      await _longPressDrag(
        tester,
        tester.getCenter(find.byType(NoteCard).first),
        kind: PointerDeviceKind.mouse,
      );

      expect(opened, isNull, reason: 'il long-click non deve aprire la nota');
      expect(
        _ids(container).indexOf(mouseDraggedId),
        isNot(0),
        reason: 'il long-click con mouse deve avviare lo stesso riordino',
      );

      final clickCard = tester.widget<NoteCard>(find.byType(NoteCard).first);
      final beforeClick = _ids(container);
      await tester.tap(
        find.byType(NoteCard).first,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(opened?.id, clickCard.note.id);
      expect(
        _ids(container),
        beforeClick,
        reason: 'il click breve deve aprire la nota senza riordinarla',
      );

      // Il riordino persiste le note con una scrittura fire-and-forget:
      // refreshFromDb attende le scritture in volo prima di rileggere.
      final persistedIds = _ids(container);
      await tester.runAsync(notes.refreshFromDb);
      expect(
        _ids(container),
        persistedIds,
        reason: 'l’ordine trascinato deve essere persistito su SQLite',
      );
    },
  );

  testWidgets(
    'custom: la rotella scorre la lista e aggiorna l’indice durante il drag',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notes = container.read(notesProvider.notifier);
      final folders = container.read(folderProvider.notifier);
      await tester.runAsync(
        () => _waitUntil(
          () async => notes.initialLoadComplete && folders.initialLoadComplete,
        ),
      );

      for (var i = 0; i < 20; i++) {
        notes.createNote();
      }
      await notes.setSortOrder(NoteSortOrder.custom);
      await tester.runAsync(notes.flushPendingSaves);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.lightTheme(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: SizedBox(width: 380, height: 500, child: NotesListView()),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ReorderableListView),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        scrollable.position.maxScrollExtent,
        greaterThan(0),
        reason: 'servono abbastanza note perché la lista possa scorrere',
      );

      final before = _ids(container);
      final draggedId = before.first;
      final start = tester.getCenter(find.byType(NoteCard).first);

      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 8));
      await tester.pump();

      expect(scrollable.position.pixels, 0);

      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: start,
          scrollDelta: const Offset(0, 300),
          kind: PointerDeviceKind.mouse,
        ),
      );
      // Primo frame: la Scrollable applica la rotella e il post-frame
      // programma il move sintetico. Secondo frame: il move aggiorna
      // l'indice di inserimento sulle nuove geometrie.
      await tester.pump();
      await tester.pump();

      expect(
        scrollable.position.pixels,
        greaterThan(0),
        reason: 'la rotella deve scorrere la lista durante il trascinamento',
      );

      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        _ids(container).indexOf(draggedId),
        greaterThan(0),
        reason:
            'dopo lo scroll la nota trascinata deve essere rilasciata più in basso',
      );

      // Il riordino persiste con scritture fire-and-forget: lasciarle
      // completare prima che il test smonti l'albero (altrimenti restano
      // timer sqflite pendenti nel fake async).
      await tester.runAsync(() async {
        await notes.flushPendingSaves();
        await notes.refreshFromDb();
      });
    },
  );
}
