import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/database/folders_dao.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:scripta/features/folders/providers/folder_provider.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _waitUntil(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 15),
  Duration interval = const Duration(milliseconds: 25),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(interval);
  }
  fail('condizione non raggiunta entro $timeout');
}

class _FlakyNotesDao implements NotesDao {
  final Map<String, NoteRow> rows = {};
  int failuresRemaining = 0;
  bool failAlways = false;
  int upsertAttempts = 0;

  @override
  Future<List<NoteRow>> getActive() async =>
      rows.values.where((r) => !r.isDeleted).toList();

  @override
  Future<void> upsert(NoteRow row) async {
    upsertAttempts++;
    if (failAlways || failuresRemaining > 0) {
      if (failuresRemaining > 0) failuresRemaining--;
      throw Exception('disco pieno');
    }
    rows[row.id] = row;
  }

  @override
  Future<void> upsertBatch(List<NoteRow> list) async {
    for (final row in list) {
      await upsert(row);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _FlakyFoldersDao implements FoldersDao {
  final Map<String, FolderRow> rows = {};
  int failuresRemaining = 0;
  bool failAlways = false;
  int upsertAttempts = 0;

  @override
  Future<List<FolderRow>> getActive() async =>
      rows.values.where((r) => !r.isDeleted).toList();

  @override
  Future<void> upsert(FolderRow row) async {
    upsertAttempts++;
    if (failAlways || failuresRemaining > 0) {
      if (failuresRemaining > 0) failuresRemaining--;
      throw Exception('disco pieno');
    }
    rows[row.id] = row;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _EmptyNotesDao implements NotesDao {
  @override
  Future<List<NoteRow>> getActive() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

final Provider<Ref> _refProvider = Provider<Ref>((ref) => ref);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('autosave fallito resta in memoria e viene ritentato', () async {
    final dao = _FlakyNotesDao();
    final notifier = NotesNotifier(dao: dao);
    addTearDown(notifier.dispose);
    await _waitUntil(() async => notifier.initialLoadComplete);

    final note = notifier.createNote();
    expect(notifier.state.hasPendingWriteError, isFalse);

    dao.failuresRemaining = 1;
    notifier.updateNote(note.id, content: 'contenuto nuovo');
    await _waitUntil(() async => notifier.state.hasPendingWriteError);

    await _waitUntil(
      () async => dao.rows[note.id]?.content == 'contenuto nuovo',
    );
    expect(notifier.state.hasPendingWriteError, isFalse);
    expect(dao.upsertAttempts, greaterThanOrEqualTo(3));
  });

  test('creazione nota fallita viene ritentata su richiesta', () async {
    final dao = _FlakyNotesDao()..failAlways = true;
    final notifier = NotesNotifier(dao: dao);
    addTearDown(notifier.dispose);
    await _waitUntil(() async => notifier.initialLoadComplete);

    final note = notifier.createNote();
    await _waitUntil(() async => notifier.state.hasPendingWriteError);
    expect(dao.rows, isEmpty);

    dao.failAlways = false;
    await notifier.retryFailedWrites();

    expect(dao.rows[note.id]?.content, '');
    expect(notifier.state.hasPendingWriteError, isFalse);
  });

  test('flush fallito propaga l\'errore e recupera al retry', () async {
    final dao = _FlakyNotesDao();
    final notifier = NotesNotifier(dao: dao);
    addTearDown(notifier.dispose);
    await _waitUntil(() async => notifier.initialLoadComplete);

    final note = notifier.createNote();
    dao.failAlways = true;
    notifier.updateNote(note.id, content: 'testo da salvare');

    await expectLater(notifier.flushPendingSaves(), throwsException);
    expect(notifier.state.hasPendingWriteError, isTrue);

    dao.failAlways = false;
    await notifier.retryFailedWrites();
    expect(dao.rows[note.id]?.content, 'testo da salvare');
    expect(notifier.state.hasPendingWriteError, isFalse);
  });

  test('scrittura cartella fallita viene ritentata con backoff', () async {
    final foldersDao = _FlakyFoldersDao()..failuresRemaining = 1;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final folders = FolderNotifier(
      container.read(_refProvider),
      foldersDao: foldersDao,
      notesDao: _EmptyNotesDao(),
    );
    addTearDown(folders.dispose);
    await _waitUntil(() async => folders.initialLoadComplete);

    final folder = folders.addFolder('Progetti');
    await _waitUntil(() async => foldersDao.rows.containsKey(folder.id));

    expect(folders.state.hasPendingWriteError, isFalse);
    expect(foldersDao.upsertAttempts, greaterThanOrEqualTo(2));
  });

  test('errore cartella persistente espone il banner e si recupera', () async {
    final foldersDao = _FlakyFoldersDao()..failAlways = true;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final folders = FolderNotifier(
      container.read(_refProvider),
      foldersDao: foldersDao,
      notesDao: _EmptyNotesDao(),
    );
    addTearDown(folders.dispose);
    await _waitUntil(() async => folders.initialLoadComplete);

    final folder = folders.addFolder('Archivio');
    await _waitUntil(() async => folders.state.hasPendingWriteError);
    expect(foldersDao.rows, isEmpty);

    foldersDao.failAlways = false;
    await folders.retryPendingWrites();

    expect(foldersDao.rows.containsKey(folder.id), isTrue);
    expect(folders.state.hasPendingWriteError, isFalse);
  });
}
