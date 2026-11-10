import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/database/app_database.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/core/models/editor_mode.dart';
import 'package:scripta/core/theme/app_theme.dart';
import 'package:scripta/features/editor/presentation/note_editor_pane.dart';
import 'package:scripta/features/editor/providers/editor_provider.dart';
import 'package:scripta/features/notes/models/note_model.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/wait_until.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppDatabase.ensureFactoryInitialized();
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = p.join(
      Directory.systemTemp.path,
      'scripta_focus_outline_${DateTime.now().microsecondsSinceEpoch}.db',
    );
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = null;
  });

  testWidgets('il focus mode nasconde il pulsante dell\'indice', (
    tester,
  ) async {
    // Pannello largo: l'indice sarebbe visibile senza il focus mode, così il
    // test misura davvero il flag e non la soglia responsive.
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final now = DateTime.now();
      await NotesDao().upsert(
        NoteModel(
          id: 'focus-outline-note',
          title: 'Nota con indice',
          content:
              '## Prima sezione\n\nTesto introduttivo.\n\n'
              '## Seconda sezione\n\nAltro testo.',
          createdAt: now,
          updatedAt: now,
        ).toRow(),
      );
      final notes = container.read(notesProvider.notifier);
      await waitUntil(() async => notes.initialLoadComplete);
      container.read(editorProvider.notifier).setMode(EditorMode.readOnly);
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.darkTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: NoteEditorPane()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.toc_rounded), findsOneWidget);

    container.read(editorProvider.notifier).toggleFocusMode();
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.toc_rounded), findsNothing);

    container.read(editorProvider.notifier).toggleFocusMode();
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.toc_rounded), findsOneWidget);
  });
}
