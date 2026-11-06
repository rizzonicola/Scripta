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
  Future<List<NoteRow>> getByIds(Iterable<String> ids) async => [
    for (final id in ids)
      if (rows[id] != null) rows[id]!,
  ];

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
  Future<List<NoteRow>> getByIds(Iterable<String> ids) async => const [];

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

  test('le mutazioni fuori editor notificano solo dopo la scrittura', () async {
    final dao = _FlakyNotesDao();
    var mutations = 0;
    final notifier = NotesNotifier(
      dao: dao,
      // Lungo abbastanza da non far scattare il retry automatico mentre il
      // test forza il fallimento e poi richiede esplicitamente il retry.
      writeRetryBase: const Duration(seconds: 5),
      onMutationCommitted: () => mutations++,
    );
    addTearDown(notifier.dispose);
    await _waitUntil(() async => notifier.initialLoadComplete);

    final note = notifier.createNote();
    await _waitUntil(() async => dao.rows.containsKey(note.id));
    expect(mutations, 0, reason: 'la creazione non passa dal canale');

    dao.failAlways = true;
    await notifier.togglePin(note.id);
    expect(mutations, 0, reason: 'una scrittura fallita non deve notificare');

    dao.failAlways = false;
    await notifier.retryFailedWrites(resetRetries: true);
    expect(dao.rows[note.id]!.isPinned, isTrue);
    expect(mutations, 1, reason: 'il retry riuscito notifica la mutazione');

    await notifier.toggleFavorite(note.id);
    expect(mutations, 2);

    await notifier.updateMetadata(note.id, isFavorite: false);
    expect(mutations, 3);

    notifier.duplicateNote(note.id);
    expect(mutations, 4);

    await notifier.deleteNote(note.id);
    expect(mutations, 5);
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

  test('pin fallito espone il banner e viene ritentato', () async {
    final dao = _FlakyNotesDao();
    final notifier = NotesNotifier(
      dao: dao,
      writeRetryBase: const Duration(milliseconds: 10),
    );
    addTearDown(notifier.dispose);
    await _waitUntil(() async => notifier.initialLoadComplete);

    final note = notifier.createNote();
    await _waitUntil(() async => dao.rows.containsKey(note.id));

    dao.failAlways = true;
    await notifier.togglePin(note.id);
    expect(notifier.state.hasPendingWriteError, isTrue);
    expect(dao.rows[note.id]!.isPinned, isFalse);

    dao.failAlways = false;
    await notifier.retryFailedWrites(resetRetries: true);

    expect(dao.rows[note.id]!.isPinned, isTrue);
    expect(notifier.state.hasPendingWriteError, isFalse);
  });

  test('metadati falliti espongono il banner e vengono ritentati', () async {
    final dao = _FlakyNotesDao();
    final notifier = NotesNotifier(
      dao: dao,
      writeRetryBase: const Duration(milliseconds: 10),
    );
    addTearDown(notifier.dispose);
    await _waitUntil(() async => notifier.initialLoadComplete);

    final note = notifier.createNote();
    await _waitUntil(() async => dao.rows.containsKey(note.id));

    dao.failAlways = true;
    await notifier.updateMetadata(note.id, isFavorite: true);
    expect(notifier.state.hasPendingWriteError, isTrue);
    expect(dao.rows[note.id]!.isFavorite, isFalse);

    dao.failAlways = false;
    await notifier.retryFailedWrites(resetRetries: true);

    expect(dao.rows[note.id]!.isFavorite, isTrue);
    expect(notifier.state.hasPendingWriteError, isFalse);
  });

  test('il retry automatico si ferma al limite e riparte su comando', () async {
    final dao = _FlakyNotesDao()..failAlways = true;
    final notifier = NotesNotifier(
      dao: dao,
      writeRetryBase: const Duration(milliseconds: 50),
      maxWriteRetries: 2,
    );
    addTearDown(notifier.dispose);
    await _waitUntil(() async => notifier.initialLoadComplete);

    final note = notifier.createNote();
    final attemptsAtCreation = dao.upsertAttempts;
    await _waitUntil(() async => notifier.state.hasPendingWriteError);

    // Primo tentativo + esattamente maxWriteRetries tentativi automatici.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final attemptsAfterRetries = dao.upsertAttempts;
    expect(
      attemptsAfterRetries - attemptsAtCreation,
      2,
      reason: 'dopo il primo tentativo partono maxWriteRetries retry',
    );

    // Oltre il limite non deve più riprogrammare da solo.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(dao.upsertAttempts, attemptsAfterRetries);
    expect(notifier.state.hasPendingWriteError, isTrue);

    dao.failAlways = false;
    await notifier.retryFailedWrites(resetRetries: true);
    expect(dao.rows.containsKey(note.id), isTrue);
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

  test(
    'un successo su un\'altra cartella non cancella il fallimento pendente',
    () async {
      final foldersDao = _FlakyFoldersDao();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final folders = FolderNotifier(
        container.read(_refProvider),
        foldersDao: foldersDao,
        notesDao: _EmptyNotesDao(),
        writeRetryBase: const Duration(milliseconds: 5),
        maxWriteRetries: 1,
      );
      addTearDown(folders.dispose);
      await _waitUntil(() async => folders.initialLoadComplete);

      foldersDao.failAlways = true;
      final first = folders.addFolder('Prima');
      await _waitUntil(() async => folders.state.hasPendingWriteError);
      expect(foldersDao.rows, isEmpty);

      // Una scrittura diversa riesce: il fallimento della prima cartella non
      // è affatto recuperato e il banner deve restare.
      foldersDao.failAlways = false;
      final second = folders.addFolder('Seconda');
      await _waitUntil(() async => foldersDao.rows.containsKey(second.id));
      expect(folders.state.hasPendingWriteError, isTrue);
      expect(foldersDao.rows.containsKey(first.id), isFalse);

      await folders.retryPendingWrites();

      expect(foldersDao.rows.containsKey(first.id), isTrue);
      expect(folders.state.hasPendingWriteError, isFalse);
    },
  );

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
