import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/database/folders_dao.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/features/folders/presentation/folder_tree_view.dart';
import 'package:scripta/features/folders/providers/folder_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryFoldersDao implements FoldersDao {
  final Map<String, FolderRow> rows = {};

  @override
  Future<List<FolderRow>> getActive() async =>
      rows.values.where((r) => !r.isDeleted).toList();

  @override
  Future<void> upsert(FolderRow row) async => rows[row.id] = row;

  @override
  Future<void> setOrderIndexes(Map<String, int> indexes) async {
    for (final entry in indexes.entries) {
      final row = rows[entry.key];
      if (row != null) rows[entry.key] = row.copyWith(orderIndex: entry.value);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _MemoryNotesDao implements NotesDao {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

Future<void> _pumpTree(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: Locale('it'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: SizedBox(width: 320, height: 600, child: FolderTreeView()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('long-press trascina una cartella prima di un’altra', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        folderProvider.overrideWith(
          (ref) => FolderNotifier(
            ref,
            foldersDao: _MemoryFoldersDao(),
            notesDao: _MemoryNotesDao(),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final folders = container.read(folderProvider.notifier);

    await _pumpTree(tester, container);
    folders.addFolder('Alpha');
    folders.addFolder('Beta');
    await tester.pumpAndSettle();

    expect(folders.state.rootFolders.map((n) => n.name), ['Alpha', 'Beta']);

    final start = tester.getCenter(find.text('Beta'));
    final target = tester.getCenter(find.text('Alpha'));

    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 500));
    // Zona superiore della riga "Alpha" -> inserimento prima.
    await gesture.moveTo(Offset(target.dx, target.dy - 16));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(folders.state.rootFolders.map((n) => n.name), ['Beta', 'Alpha']);
  });

  testWidgets('long-press al centro sposta la cartella dentro l’altra', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        folderProvider.overrideWith(
          (ref) => FolderNotifier(
            ref,
            foldersDao: _MemoryFoldersDao(),
            notesDao: _MemoryNotesDao(),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final folders = container.read(folderProvider.notifier);

    await _pumpTree(tester, container);
    folders.addFolder('Alpha');
    folders.addFolder('Beta');
    await tester.pumpAndSettle();

    final start = tester.getCenter(find.text('Beta'));
    final target = tester.getCenter(find.text('Alpha'));

    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final alpha = folders.state.rootFolders.single;
    expect(alpha.name, 'Alpha');
    expect(alpha.children.map((n) => n.name), ['Beta']);
  });
}
