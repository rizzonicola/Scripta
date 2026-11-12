import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scripta/core/constants/app_constants.dart';
import 'package:scripta/core/database/app_database.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/core/models/editor_mode.dart';
import 'package:scripta/core/theme/app_theme.dart';
import 'package:scripta/features/editor/presentation/markdown_editor_field.dart';
import 'package:scripta/features/editor/presentation/note_editor_pane.dart';
import 'package:scripta/features/editor/presentation/note_scroll_memory.dart';
import 'package:scripta/features/editor/providers/editor_provider.dart';
import 'package:scripta/features/folders/providers/folder_provider.dart';
import 'package:scripta/features/notes/models/note_model.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';
import 'package:scripta/shell/adaptive_app_shell.dart';
import 'package:scripta/shell/top_app_bar.dart';

import 'support/wait_until.dart';

const String _noteId = 'scroll-position-note';
const ValueKey<String> _readingListKey = ValueKey<String>(
  'markdown-formatted-listview',
);

String _longNoteContent() {
  final buffer = StringBuffer('# Posizione\n\n');
  for (var i = 0; i < 120; i++) {
    buffer.writeln(
      'Paragrafo numero $i con abbastanza testo per creare altezza '
      'e rendere verificabile lo scorrimento.',
    );
    buffer.writeln();
  }
  return buffer.toString();
}

Future<void> _seedNote() async {
  final now = DateTime.now();
  await NotesDao().upsert(
    NoteModel(
      id: _noteId,
      title: 'Nota lunga',
      content: _longNoteContent(),
      createdAt: now,
      updatedAt: now,
    ).toRow(),
  );
}

ScrollableState _readingScrollable(WidgetTester tester) => tester.state(
  find
      .descendant(
        of: find.byKey(_readingListKey),
        matching: find.byType(Scrollable),
      )
      .first,
);

ScrollController _editorScrollController(WidgetTester tester) {
  final scrollView = tester.widget<SingleChildScrollView>(
    find
        .descendant(
          of: find.byType(MarkdownEditorField),
          matching: find.byType(SingleChildScrollView),
        )
        .first,
  );
  return scrollView.controller!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppConstants.prefOnboardingCompleted: true,
    });
    NoteScrollMemory.clear();
    AppDatabase.ensureFactoryInitialized();
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = p.join(
      Directory.systemTemp.path,
      'scripta_scroll_${DateTime.now().microsecondsSinceEpoch}.db',
    );
  });

  tearDown(() async {
    NoteScrollMemory.clear();
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = null;
  });

  testWidgets(
    'la posizione passa da sola lettura a modifica e poi di nuovo a lettura',
    (tester) async {
      tester.view.physicalSize = const Size(900, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        await _seedNote();
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

      final readPixelsBefore = _readingScrollable(tester).position.pixels;
      await tester.drag(find.byKey(_readingListKey), const Offset(0, -700));
      await tester.pumpAndSettle();

      final readPixels = _readingScrollable(tester).position.pixels;
      final readAnchor = NoteScrollMemory.sourceOffsetFor(_noteId);
      expect(readPixels, greaterThan(readPixelsBefore));
      expect(readAnchor, isNotNull);
      expect(readAnchor, greaterThan(0));

      container.read(editorProvider.notifier).setMode(EditorMode.edit);
      await tester.pumpAndSettle();

      final editorController = _editorScrollController(tester);
      expect(editorController.offset, greaterThan(0));

      // Scorri ancora nell'editor: la nuova ancora deve superare quella
      // lasciata dalla lettura, così il ritorno verifica un cambio reale.
      editorController.jumpTo(
        (editorController.offset + 500).clamp(
          0.0,
          editorController.position.maxScrollExtent,
        ),
      );
      await tester.pumpAndSettle();

      final editorAnchor = NoteScrollMemory.sourceOffsetFor(_noteId);
      expect(editorAnchor, isNotNull);
      expect(editorAnchor, greaterThan(readAnchor!));

      container.read(editorProvider.notifier).setMode(EditorMode.readOnly);
      await tester.pumpAndSettle();

      final readPixelsAfterReturn = _readingScrollable(tester).position.pixels;
      expect(readPixelsAfterReturn, greaterThan(0));
      expect(readPixelsAfterReturn, greaterThan(readPixels));
    },
  );

  testWidgets('il focus mode non rimonta NoteEditorPane', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      await _seedNote();
      final notes = container.read(notesProvider.notifier);
      final folders = container.read(folderProvider.notifier);
      await waitUntil(
        () async => notes.initialLoadComplete && folders.initialLoadComplete,
      );
      container.read(editorProvider.notifier).setMode(EditorMode.readOnly);
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.darkTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const AdaptiveAppShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final paneState = tester.state(find.byType(NoteEditorPane));
    expect(find.byType(TopAppBar), findsOneWidget);

    await tester.drag(find.byKey(_readingListKey), const Offset(0, -500));
    await tester.pumpAndSettle();
    final readPixelsBeforeFocus = _readingScrollable(tester).position.pixels;
    expect(readPixelsBeforeFocus, greaterThan(0));

    container.read(editorProvider.notifier).toggleFocusMode();
    await tester.pumpAndSettle();

    expect(tester.state(find.byType(NoteEditorPane)), same(paneState));
    expect(find.byType(TopAppBar), findsNothing);
    expect(
      _readingScrollable(tester).position.pixels,
      closeTo(readPixelsBeforeFocus, 1),
    );

    container.read(editorProvider.notifier).toggleFocusMode();
    await tester.pumpAndSettle();

    expect(tester.state(find.byType(NoteEditorPane)), same(paneState));
    expect(find.byType(TopAppBar), findsOneWidget);
    expect(
      _readingScrollable(tester).position.pixels,
      closeTo(readPixelsBeforeFocus, 1),
    );
  });
}
