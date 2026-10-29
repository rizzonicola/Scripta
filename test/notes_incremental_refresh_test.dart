import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/database/notes_dao.dart';
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

class _FakeDao implements NotesDao {
  final Map<String, NoteRow> rows = {};
  int activeReads = 0;

  @override
  Future<List<NoteRow>> getActive() async {
    activeReads++;
    return rows.values.where((r) => !r.isDeleted).toList();
  }

  @override
  Future<NoteRow?> getById(String id) async => rows[id];

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

NoteRow _row(
  String id, {
  String? content,
  required int updatedAt,
  int? deletedAt,
}) => NoteRow(
  id: id,
  title: id,
  content: content ?? id,
  folderId: null,
  isFavorite: false,
  isPinned: false,
  orderIndex: 0,
  createdAt: 1,
  updatedAt: updatedAt,
  deletedAt: deletedAt,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'applica solo gli id cambiati senza rileggere l\'intero archivio',
    () async {
      final dao = _FakeDao()
        ..rows['a'] = _row('a', updatedAt: 10)
        ..rows['b'] = _row('b', updatedAt: 20)
        ..rows['c'] = _row('c', updatedAt: 30);
      final notes = NotesNotifier(dao: dao);
      await _waitUntil(() async => notes.initialLoadComplete);
      await _waitUntil(() async => notes.state.notes.length == 3);

      dao.activeReads = 0;
      dao.rows['b'] = _row('b', content: 'aggiornata', updatedAt: 40);
      dao.rows['c'] = _row('c', updatedAt: 50, deletedAt: 50);
      dao.rows['d'] = _row('d', updatedAt: 60);

      await notes.applyRemoteChanges(['b', 'c', 'd']);

      final byId = {for (final n in notes.state.notes) n.id: n};
      expect(dao.activeReads, 0);
      expect(byId.keys, unorderedEquals(['a', 'b', 'd']));
      expect(byId['b']!.content, 'aggiornata');
      expect(notes.state.activeNoteId, isNot('c'));
      notes.dispose();
    },
  );

  test('preserva una modifica ancora in attesa di autosave', () async {
    final dao = _FakeDao()..rows['a'] = _row('a', updatedAt: 10);
    final notes = NotesNotifier(dao: dao);
    await _waitUntil(() async => notes.initialLoadComplete);
    await _waitUntil(() async => notes.state.notes.isNotEmpty);

    notes.updateNote('a', content: 'testo appena digitato');
    dao.rows['a'] = _row('a', content: 'versione vecchia', updatedAt: 20);

    await notes.applyRemoteChanges(['a']);

    expect(notes.state.notes.single.content, 'testo appena digitato');
    await notes.flushPendingSaves();
    notes.dispose();
  });
}
