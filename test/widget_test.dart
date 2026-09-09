import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show inMemoryDatabasePath;
import 'package:scripta/app.dart';
import 'package:scripta/core/database/app_database.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/core/utils/markdown_toolbar_actions.dart';
import 'package:scripta/core/utils/syntax_highlighter.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';
import 'package:scripta/features/folders/providers/folder_provider.dart';
import 'package:flutter/material.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// [NotesNotifier] e [FolderNotifier] scrivono su SQLite in modo
  /// "fire-and-forget" per design (`unawaited(_dao.upsert(...))` in
  /// `createNote`/`moveNote`/`addFolder`/`deleteFolder`/ecc.: vedi il
  /// commento di classe in `folder_provider.dart` — "aggiornamenti dello
  /// stato in-memory SEMPRE sincroni, persistenza su SQLite in background".
  /// È una scelta architetturale intenzionale, che qui NON modifichiamo.
  ///
  /// Nei test, però, il corpo di un `test()` può terminare (e quindi far
  /// scattare `addTearDown(container.dispose)` seguito dal `tearDown`
  /// globale sotto, che chiude il database) PRIMA che una di queste
  /// scritture fire-and-forget abbia effettivamente raggiunto SQLite.
  /// Quando poi quella scrittura in ritardo riprende, trova un
  /// [AppDatabase] già chiuso → `SqfliteFfiException: This database has
  /// already been closed`.
  ///
  /// Un ciclo di `Future.delayed(Duration.zero)` pompa solo la coda dei
  /// microtask del proprio isolate: non garantisce di aver atteso una
  /// risposta che deve ancora arrivare dall'isolate/worker FFI di
  /// `sqflite_common_ffi` se quella risposta richiede un tempo reale (anche
  /// minimo) per completarsi. Un'attesa basata su una durata reale
  /// (`Duration(milliseconds: ...)`, non zero) lascia invece effettivamente
  /// passare quel tempo, dando a QUALSIASI scrittura fire-and-forget ancora
  /// in volo l'occasione di completarsi prima che il `tearDown` chiuda il
  /// database.
  Future<void> flushPendingDbWrites() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});

    // sqflite_common_ffi funziona nell'ambiente `flutter test` puro (usa
    // sqlite3 nativo via FFI, non un platform channel), a differenza di
    // `path_provider`.
    //
    // Database IN-MEMORY (`:memory:`) invece di un file temporaneo su
    // `/tmp/`: ogni apertura di `inMemoryDatabasePath` crea un'istanza
    // SQLite indipendente e isolata (stessa garanzia di isolamento fra un
    // test e l'altro che si aveva con un file temp per-test), ma senza
    // alcun file reale su disco — quindi nessuna possibile contesa di I/O o
    // lock di file, e nessun rischio di "apertura in ritardo che punta a
    // una directory già cancellata dal tearDown" (vedi AppDatabase.close(),
    // che comunque resta protetto anche per l'uso su file reali in altri
    // contesti).
    AppDatabase.ensureFactoryInitialized();
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = inMemoryDatabasePath;
  });

  tearDown(() async {
    // Lasciamo assestare qualunque scrittura DAO fire-and-forget avviata
    // dal test appena concluso PRIMA di chiudere il database: altrimenti
    // quella scrittura, riprendendo in ritardo, troverebbe una connessione
    // già chiusa (vedi commento su [flushPendingDbWrites] sopra).
    await flushPendingDbWrites();
    await AppDatabase.instance.close();
  });

  test('MarkdownToolbarActions wraps selection with tags properly', () {
    final controller = TextEditingController(text: 'Hello World');
    controller.selection = const TextSelection(baseOffset: 6, extentOffset: 11);

    MarkdownToolbarActions.wrapSelection(controller, '**', '**');
    expect(controller.text, 'Hello **World**');
  });

  test('MarkdownToolbarActions prepends line properly', () {
    final controller = TextEditingController(text: 'First Line\nSecond Line');
    controller.selection = const TextSelection.collapsed(offset: 14);

    MarkdownToolbarActions.prependLine(controller, '# ');
    expect(controller.text, 'First Line\n# Second Line');
  });

  test('AppLocalizations loads translations for it, en, fr', () async {
    final enL10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(enL10n.appName, 'Scripta');
    expect(enL10n.modeReadOnly, 'Read-Only Mode');

    final itL10n = await AppLocalizations.delegate.load(const Locale('it'));
    expect(itL10n.appName, 'Scripta');
    expect(itL10n.modeReadOnly, 'Modalità Sola Lettura');

    final frL10n = await AppLocalizations.delegate.load(const Locale('fr'));
    expect(frL10n.appName, 'Scripta');
    expect(frL10n.modeReadOnly, 'Mode Lecture Seule');
  });

  testWidgets('Scripta app initial widget pump test — no fake welcome note/folders', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: ScriptaApp(),
      ),
    );
    await tester.pumpAndSettle();
    // Ulteriore margine per qualunque scrittura fire-and-forget dei
    // notifier (_loadFromDb dei provider creati dall'albero widget) che
    // pumpAndSettle, non essendo legata a frame/animazioni, potrebbe non
    // attendere.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Scripta title should be present
    expect(find.text('Scripta'), findsWidgets);
  });

  test('ScriptaCodeHighlighter highlights Dart code into styled tokens', () {
    const code = 'void main() {\n  final app = ScriptaApp();\n}';
    final span = ScriptaCodeHighlighter.highlight(
      code: code,
      language: 'dart',
      isDark: true,
      baseStyle: const TextStyle(fontSize: 14),
    );

    expect(span.children, isNotEmpty);
    final texts = span.children!.map((s) => (s as TextSpan).text).join();
    expect(texts, code);
  });

  test('ScriptaCodeHighlighter highlights JSON keys and strings', () {
    const jsonCode = '{\n  "name": "Scripta",\n  "active": true\n}';
    final span = ScriptaCodeHighlighter.highlight(
      code: jsonCode,
      language: 'json',
      isDark: true,
      baseStyle: const TextStyle(fontSize: 14),
    );

    expect(span.children, isNotEmpty);
    final texts = span.children!.map((s) => (s as TextSpan).text).join();
    expect(texts, jsonCode);
  });

  test('moveNote updates folderId and moves note between folders and root', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notesNotifier = container.read(notesProvider.notifier);
    final note = notesNotifier.createNote(folderId: 'folder_a');
    expect(note.folderId, 'folder_a');

    notesNotifier.moveNote(note.id, 'folder_b');
    final movedNote = container.read(notesProvider).notes.firstWhere((n) => n.id == note.id);
    expect(movedNote.folderId, 'folder_b');

    notesNotifier.moveNote(note.id, null);
    final rootNote = container.read(notesProvider).notes.firstWhere((n) => n.id == note.id);
    expect(rootNote.folderId, isNull);

    // Lasciamo evadere le scritture fire-and-forget (createNote/moveNote
    // x2) prima che il test termini e il tearDown chiuda il database.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test('moveFolder moves folder and prevents cyclic moves', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final folderNotifier = container.read(folderProvider.notifier);
    folderNotifier.addFolder('ParentFolder');
    final parent = container.read(folderProvider).rootFolders.firstWhere((f) => f.name == 'ParentFolder');

    folderNotifier.addFolder('ChildFolder', parentId: parent.id);
    final updatedParent = container.read(folderProvider).rootFolders.firstWhere((f) => f.id == parent.id);
    expect(updatedParent.children.length, 1);
    final child = updatedParent.children.first;

    // Moving parent into its child must fail (prevent cycle)
    final invalidMove = folderNotifier.moveFolder(parent.id, child.id);
    expect(invalidMove, isFalse);

    // Moving child to root must succeed
    final validMove = folderNotifier.moveFolder(child.id, null);
    expect(validMove, isTrue);

    final roots = container.read(folderProvider).rootFolders;
    expect(roots.any((f) => f.id == child.id), isTrue);

    // Lasciamo evadere le scritture fire-and-forget (addFolder x2 +
    // moveFolder) prima che il test termini e il tearDown chiuda il database.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test('deleteFolder cascades to subfolders and notes inside them', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final folderNotifier = container.read(folderProvider.notifier);
    final notesNotifier = container.read(notesProvider.notifier);

    final parent = folderNotifier.addFolder('Progetti');
    final child = folderNotifier.addFolder('Sotto-progetto', parentId: parent.id);
    final noteInParent = notesNotifier.createNote(folderId: parent.id);
    final noteInChild = notesNotifier.createNote(folderId: child.id);

    folderNotifier.deleteFolder(parent.id);

    final roots = container.read(folderProvider).rootFolders;
    expect(roots.any((f) => f.id == parent.id), isFalse);
    expect(roots.any((f) => f.id == child.id), isFalse);

    // Attendiamo il completamento della cascade asincrona sul DB locale e il
    // conseguente refresh di notesProvider (vedi FolderNotifier.deleteFolder).
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final activeNoteIds = container.read(notesProvider).notes.map((n) => n.id).toSet();
    expect(activeNoteIds.contains(noteInParent.id), isFalse);
    expect(activeNoteIds.contains(noteInChild.id), isFalse);
  });
}
