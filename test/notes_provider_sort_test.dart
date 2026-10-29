import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scripta/core/constants/app_constants.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:scripta/features/notes/models/note_model.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';

class _FakeDao implements NotesDao {
  final Map<String, NoteRow> rows = {};

  @override
  Future<List<NoteRow>> getActive() async =>
      rows.values.where((r) => !r.isDeleted).toList();
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

NoteRow _row(
  String id, {
  required int created,
  required int updated,
  String? title,
}) =>
    NoteRow(
      id: id,
      title: title ?? id,
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

  test('all\'avvio la nota attiva è la prima con l\'ordinamento salvato',
      () async {
    SharedPreferences.setMockInitialValues(
        {AppConstants.prefSortMode: NoteSortOrder.createdAsc.name});
    final dao = _FakeDao()
      ..rows['a'] =
          _row('a', created: 100, updated: 900) // più recente per modifica
      ..rows['b'] =
          _row('b', created: 50, updated: 100); // più vecchia per creazione
    final n = NotesNotifier(dao: dao);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(n.state.sortOrder, NoteSortOrder.createdAsc);
    expect(n.state.notes.first.id, 'b');
    expect(n.state.activeNoteId, 'b');
    n.dispose();
  });

  test('ordinamento per creazione: spareggio deterministico su date uguali',
      () async {
    SharedPreferences.setMockInitialValues(
        {AppConstants.prefSortMode: NoteSortOrder.createdDesc.name});
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
    expect(n.state.notes.single.updatedAt.toUtc().millisecondsSinceEpoch,
        greaterThan(1000));
    await n.flushPendingSaves();
    n.dispose();
  });

  test('updateMetadata sincronizza createdAt e bumpa updatedAt', () async {
    SharedPreferences.setMockInitialValues({});
    final dao = _FakeDao()..rows['a'] = _row('a', created: 1000, updated: 2000);
    final n = NotesNotifier(dao: dao);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await n.updateMetadata(
      'a',
      createdAt: DateTime.fromMillisecondsSinceEpoch(500),
    );

    final note = n.state.notes.single;
    expect(note.createdAt.toUtc().millisecondsSinceEpoch, 500);
    expect(
      note.updatedAt.toUtc().millisecondsSinceEpoch,
      greaterThanOrEqualTo(2000),
    );
    expect(dao.rows['a']!.createdAt, 500);
    expect(
      dao.rows['a']!.updatedAt,
      note.updatedAt.toUtc().millisecondsSinceEpoch,
    );
    n.dispose();
  });

  test('updateMetadata non porta createdAt nel futuro', () async {
    SharedPreferences.setMockInitialValues({});
    final dao = _FakeDao()..rows['a'] = _row('a', created: 1000, updated: 2000);
    final n = NotesNotifier(dao: dao);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await n.updateMetadata(
      'a',
      createdAt: DateTime.now().add(const Duration(days: 2)),
    );

    final note = n.state.notes.single;
    expect(note.createdAt.isAfter(note.updatedAt), isFalse);
    expect(note.createdAt.isAfter(DateTime.now()), isFalse);
    n.dispose();
  });

  test(
      'importNotesBulkDetailed converte UTC in locale e mantiene l\'invariante',
      () async {
    SharedPreferences.setMockInitialValues({});
    final dao = _FakeDao();
    final n = NotesNotifier(dao: dao);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final created = DateTime.utc(2024, 1, 1, 10);
    final updated = DateTime.utc(2024, 1, 2, 11);
    await n.importNotesBulkDetailed([
      ImportedNote(
        title: 'con date',
        content: '',
        folderId: null,
        createdAt: created,
        updatedAt: updated,
      ),
      ImportedNote(
        title: 'senza creazione',
        content: '',
        folderId: null,
        updatedAt: updated,
      ),
      ImportedNote(
        title: 'date invertite',
        content: '',
        folderId: null,
        createdAt: updated,
        updatedAt: created,
      ),
    ]);

    final notes = n.state.notes;
    final conDate = notes.singleWhere((e) => e.title == 'con date');
    expect(conDate.createdAt.isUtc, isFalse);
    expect(conDate.updatedAt.isUtc, isFalse);
    expect(conDate.createdAt.toUtc(), created);
    expect(conDate.updatedAt.toUtc(), updated);

    final senzaCreazione =
        notes.singleWhere((e) => e.title == 'senza creazione');
    expect(senzaCreazione.createdAt, senzaCreazione.updatedAt);

    final invertite = notes.singleWhere((e) => e.title == 'date invertite');
    expect(invertite.createdAt, invertite.updatedAt);
    expect(invertite.createdAt.toUtc(), created);
    n.dispose();
  });

  test('importNotesBulk: date distinte e ordine di import stabile', () async {
    SharedPreferences.setMockInitialValues(
        {AppConstants.prefSortMode: NoteSortOrder.createdAsc.name});
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

    test('ogni cartella ha il proprio criterio, senza toccare le altre viste',
        () async {
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

    test(
        'ordine manuale di una cartella: nessuna scrittura su DB, altre viste intatte',
        () async {
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
        expect(identical(dao.rows[id], before[id]), isTrue,
            reason: 'riga $id riscritta');
      }

      n.setScope(null);
      expect(n.state.notes.map((e) => e.id).toList(), ['a', 'b', 'c']);
      n.dispose();
    });

    test('impostazioni per vista e ordine manuale sopravvivono al riavvio',
        () async {
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

    test('nota nuova in una cartella con ordine manuale compare in cima',
        () async {
      SharedPreferences.setMockInitialValues({});
      final n = NotesNotifier(dao: threeNotes());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      n.setScope('f1');
      await n.setSortOrder(NoteSortOrder.custom);
      final created = n.createNote(folderId: 'f1');
      expect(n.state.notes.first.id, created.id);
      n.dispose();
    });

    test('titoli con numeri seguono l\'ordine naturale in entrambi i versi',
        () async {
      SharedPreferences.setMockInitialValues({});
      final dao = _FakeDao()
        ..rows['a'] = _row('a', title: 'Nota 10', created: 1, updated: 100)
        ..rows['b'] = _row('b', title: 'nota 2', created: 2, updated: 90)
        ..rows['c'] = _row('c', title: 'Nota 1', created: 3, updated: 80)
        ..rows['d'] = _row('d', title: 'Nota 03', created: 4, updated: 70);
      final n = NotesNotifier(dao: dao);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await n.setSortOrder(NoteSortOrder.titleAsc);
      expect(
        n.state.notes.map((e) => e.title).toList(),
        ['Nota 1', 'nota 2', 'Nota 03', 'Nota 10'],
      );

      await n.setSortOrder(NoteSortOrder.titleDesc);
      expect(
        n.state.notes.map((e) => e.title).toList(),
        ['Nota 10', 'Nota 03', 'nota 2', 'Nota 1'],
      );
      n.dispose();
    });
  });
}
