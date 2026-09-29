import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scripta/core/constants/app_constants.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:scripta/features/notes/models/note_model.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';

class _FakeDao implements NotesDao {
  final Map<String, NoteRow> rows = {};

  @override
  Future<List<NoteRow>> getActive() async => rows.values.where((r) => !r.isDeleted).toList();
  @override
  Future<void> upsert(NoteRow row) async => rows[row.id] = row;
  @override
  Future<void> upsertBatch(List<NoteRow> list) async {
    for (final r in list) {
      rows[r.id] = r;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

NoteRow _row(String id, {required int created, required int updated}) => NoteRow(
      id: id,
      title: id,
      content: 'c',
      folderId: null,
      isFavorite: false,
      isPinned: false,
      orderIndex: 0,
      createdAt: created,
      updatedAt: updated,
      deletedAt: null,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('all\'avvio la nota attiva è la prima con l\'ordinamento salvato', () async {
    SharedPreferences.setMockInitialValues({AppConstants.prefSortMode: NoteSortOrder.createdAsc.name});
    final dao = _FakeDao()
      ..rows['a'] = _row('a', created: 100, updated: 900) // più recente per modifica
      ..rows['b'] = _row('b', created: 50, updated: 100); // più vecchia per creazione
    final n = NotesNotifier(dao: dao);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(n.state.sortOrder, NoteSortOrder.createdAsc);
    expect(n.state.notes.first.id, 'b');
    expect(n.state.activeNoteId, 'b');
    n.dispose();
  });

  test('ordinamento per creazione: spareggio deterministico su date uguali', () async {
    SharedPreferences.setMockInitialValues({AppConstants.prefSortMode: NoteSortOrder.createdDesc.name});
    final dao = _FakeDao()
      ..rows['z'] = _row('z', created: 100, updated: 300)
      ..rows['a'] = _row('a', created: 100, updated: 500);
    final n = NotesNotifier(dao: dao);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(n.state.notes.map((e) => e.id).toList(), ['a', 'z']);
    n.dispose();
  });

  test('updateNote senza modifiche reali non cambia updatedAt', () async {
    SharedPreferences.setMockInitialValues({});
    final dao = _FakeDao()..rows['a'] = _row('a', created: 1, updated: 1000);
    final n = NotesNotifier(dao: dao);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    n.updateNote('a', title: 'a', content: 'c');
    expect(n.state.notes.single.updatedAt.toUtc().millisecondsSinceEpoch, 1000);
    n.updateNote('a', content: 'nuovo');
    expect(n.state.notes.single.updatedAt.toUtc().millisecondsSinceEpoch, greaterThan(1000));
    await n.flushPendingSaves();
    n.dispose();
  });

  test('importNotesBulk: date distinte e ordine di import stabile', () async {
    SharedPreferences.setMockInitialValues({AppConstants.prefSortMode: NoteSortOrder.createdAsc.name});
    final dao = _FakeDao();
    final n = NotesNotifier(dao: dao);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await n.importNotesBulk([
      (title: 'uno', content: '1', folderId: null),
      (title: 'due', content: '2', folderId: null),
      (title: 'tre', content: '3', folderId: null),
    ]);
    expect(n.state.notes.map((e) => e.title).toList(), ['uno', 'due', 'tre']);
    expect(n.state.notes.map((e) => e.createdAt).toSet().length, 3);
    n.dispose();
  });

  group('ordinamento per vista (Tutte le note / cartella)', () {
    _FakeDao threeNotes() => _FakeDao()
      ..rows['a'] = _row('a', created: 1, updated: 300)
      ..rows['b'] = _row('b', created: 2, updated: 200)
      ..rows['c'] = _row('c', created: 3, updated: 100);

    test('ogni cartella ha il proprio criterio, senza toccare le altre viste', () async {
      SharedPreferences.setMockInitialValues({});
      final n = NotesNotifier(dao: threeNotes());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      n.setScope('f1');
      await n.setSortOrder(NoteSortOrder.titleDesc);
      expect(n.state.notes.map((e) => e.id).toList(), ['c', 'b', 'a']);

      n.setScope(null); // "Tutte le note" non eredita l'ordine della cartella
      expect(n.state.sortOrder, NoteSortOrder.updatedDesc);
      expect(n.state.notes.map((e) => e.id).toList(), ['a', 'b', 'c']);

      n.setScope('f2'); // altra cartella: nessuna impostazione propria
      expect(n.state.sortOrder, NoteSortOrder.updatedDesc);

      n.setScope('f1'); // f1 ricorda il proprio
      expect(n.state.sortOrder, NoteSortOrder.titleDesc);
      n.dispose();
    });

    test('ordine manuale di una cartella: nessuna scrittura su DB, altre viste intatte', () async {
      SharedPreferences.setMockInitialValues({});
      final dao = threeNotes();
      final n = NotesNotifier(dao: dao);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final before = Map<String, NoteRow>.of(dao.rows);

      n.setScope('f1');
      await n.setSortOrder(NoteSortOrder.custom);
      n.reorderNotes(0, 3, visibleIds: ['a', 'b', 'c']); // a in fondo
      expect(n.state.notes.map((e) => e.id).toList(), ['b', 'c', 'a']);
      await n.flushPendingSaves();
      for (final id in ['a', 'b', 'c']) {
        expect(identical(dao.rows[id], before[id]), isTrue, reason: 'riga $id riscritta');
      }

      n.setScope(null);
      expect(n.state.notes.map((e) => e.id).toList(), ['a', 'b', 'c']);
      n.dispose();
    });

    test('impostazioni per vista e ordine manuale sopravvivono al riavvio', () async {
      SharedPreferences.setMockInitialValues({});
      final dao = threeNotes();
      final n = NotesNotifier(dao: dao);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      n.setScope('f1');
      await n.setSortOrder(NoteSortOrder.custom);
      n.reorderNotes(0, 3, visibleIds: ['a', 'b', 'c']);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      n.dispose();

      final n2 = NotesNotifier(dao: dao);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(n2.state.sortOrder, NoteSortOrder.updatedDesc); // "Tutte le note"
      n2.setScope('f1');
      expect(n2.state.sortOrder, NoteSortOrder.custom);
      expect(n2.state.notes.map((e) => e.id).toList(), ['b', 'c', 'a']);
      n2.dispose();
    });

    test('nota nuova in una cartella con ordine manuale compare in cima', () async {
      SharedPreferences.setMockInitialValues({});
      final n = NotesNotifier(dao: threeNotes());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      n.setScope('f1');
      await n.setSortOrder(NoteSortOrder.custom);
      final created = n.createNote(folderId: 'f1');
      expect(n.state.notes.first.id, created.id);
      n.dispose();
    });
  });
}
