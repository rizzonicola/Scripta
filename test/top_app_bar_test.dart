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
import 'package:scripta/core/theme/app_theme.dart';
import 'package:scripta/features/notes/models/note_model.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';
import 'package:scripta/shell/top_app_bar.dart';

import 'support/wait_until.dart';

const String _noteId = 'top-app-bar-note';

Widget _app({required bool isEditorVisible}) {
  return MaterialApp(
    theme: AppTheme.darkTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      appBar: TopAppBar(
        isEditorVisible: isEditorVisible,
        showBackButton: isEditorVisible,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppConstants.prefOnboardingCompleted: true,
    });
    AppDatabase.ensureFactoryInitialized();
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = p.join(
      Directory.systemTemp.path,
      'scripta_top_bar_${DateTime.now().microsecondsSinceEpoch}.db',
    );
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = null;
  });

  testWidgets(
    'senza nota la sync resta a sinistra delle impostazioni, in fondo a destra',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final now = DateTime.now();
        await NotesDao().upsert(
          NoteModel(
            id: _noteId,
            title: 'Nota',
            content: 'Contenuto',
            createdAt: now,
            updatedAt: now,
          ).toRow(),
        );
        final notes = container.read(notesProvider.notifier);
        await waitUntil(() async => notes.initialLoadComplete);
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _app(isEditorVisible: false),
        ),
      );
      await tester.pumpAndSettle();

      // Nessuna azione dell'editor quando non c'è una nota aperta.
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      expect(find.byIcon(Icons.fullscreen_rounded), findsNothing);

      final settings = find.byTooltip('Settings');
      expect(settings, findsOneWidget);

      // La sync è l'ultimo controllo prima delle impostazioni: l'ingranaggio
      // resta all'estrema destra.
      expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
      expect(
        tester.getCenter(find.byIcon(Icons.cloud_off_outlined)).dx,
        lessThan(tester.getCenter(settings).dx),
      );

      // Con la nota aperta tornano le azioni dell'editor e la scorciatoia
      // Impostazioni lascia il posto alla modalità/focus.
      container.read(notesProvider.notifier).selectNote(_noteId);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _app(isEditorVisible: true),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Settings'), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
    },
  );
}
