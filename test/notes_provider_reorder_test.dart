import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scripta/core/constants/app_constants.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:scripta/features/notes/models/note_model.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';

/// Fake in-memory di [NotesDao] con una latenza configurabile su
/// [getActive], per riprodurre la race "lettura DB avviata prima di una
/// scrittura locale" (vedi NotesNotifier.refreshFromDb).
class _FakeDao implements NotesDao {
  final Map<String, NoteRow> rows = {};
  Duration getActiveDelay = Duration.zero;

  @override
  Future<List<NoteRow>> getActive() async {
    final snapshot = rows.values.where((r) => !r.isDeleted).toList();
    if (getActiveDelay > Duration.zero) {
      await Future<void>.delayed(getActiveDelay);
    }
    return snapshot;
  }

  @override
  Future<NoteRow?> getById(String id) async => rows[id];

  @override
  Future<void> upsert(NoteRow row) async => rows[row.id] = row;

  @override
  Future<void> upsertBatch(List<NoteRow> list) async {
    for (final r in list) {
      rows[r.id] = r;
    }
  }

  @override
  Future<void> applyRemoteLWW(NoteRow remote) async => rows[remote.id] = remote;

  @override
  Future<void> applyRemoteLWWBatch(List<NoteRow> remotes) async {
    for (final r in remotes) {
      rows[r.id] = r;
    }
  }

  @override
  Future<List<NoteRow>> listDirtySince(int sinceMillis) async =>
      rows.values.where((r) => r.updatedAt > sinceMillis).toList();

  @override
  Future<void> softDeleteByFolder(String folderId, int now) async {}

  @override
  Future<void> hardDeleteIds(List<String> ids) async {
    for (final id in ids) {
      rows.remove(id);
    }
  }

  @override
  Future<void> hardDeleteAll() async => rows.clear();
}

NoteRow _row(String id, int order, {String? folder}) => NoteRow(
      id: id,
      title: id,
      content: '',
      folderId: folder,
      isFavorite: false,
      isPinned: false,
      orderIndex: order,
      createdAt: 1000,
      updatedAt: 1000,
      deletedAt: null,
    );

List<String> _ids(NotesNotifier n) => n.state.notes.map((e) => e.id).toList();

Future<NotesNotifier> _customNotifier(_FakeDao dao) async {
  SharedPreferences.setMockInitialValues({
    AppConstants.prefSortMode: NoteSortOrder.custom.name,
  });
  final notifier = NotesNotifier(dao: dao);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return notifier;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NotesNotifier.reorderNotes', () {
    test('con una cartella selezionata sposta la nota trascinata, non un\'altra', () async {
      final dao = _FakeDao()
        ..rows.addAll({
          'P1': _row('P1', 0),
          'W1': _row('W1', 1, folder: 'w'),
          'P2': _row('P2', 2),
          'W2': _row('W2', 3, folder: 'w'),
          'W3': _row('W3', 4, folder: 'w'),
        });
      final notifier = await _customNotifier(dao);
      expect(_ids(notifier), ['P1', 'W1', 'P2', 'W2', 'W3']);

      // Vista cartella "w": [W1, W2, W3]. Si trascina W3 in cima.
      notifier.reorderNotes(2, 0, visibleIds: ['W1', 'W2', 'W3']);

      // W3 sale nel primo slot occupato dalle note della cartella; le note
      // fuori cartella (P1, P2) restano ferme dove sono.
      expect(_ids(notifier), ['P1', 'W3', 'P2', 'W1', 'W2']);
      expect(notifier.state.notes.map((n) => n.orderIndex), [0, 1, 2, 3, 4]);
    });

    test('senza visibleIds riordina l\'intera lista (comportamento classico)', () async {
      final dao = _FakeDao()
        ..rows.addAll({
          'A': _row('A', 0),
          'B': _row('B', 1),
          'C': _row('C', 2),
        });
      final notifier = await _customNotifier(dao);

      // Convenzione ReorderableListView: newIndex è pre-rimozione.
      notifier.reorderNotes(0, 3);
      expect(_ids(notifier), ['B', 'C', 'A']);
    });

    test('persiste solo le note il cui order_index è cambiato', () async {
      final dao = _FakeDao()
        ..rows.addAll({
          'A': _row('A', 0),
          'B': _row('B', 1),
          'C': _row('C', 2),
          'D': _row('D', 3),
        });
      final notifier = await _customNotifier(dao);

      notifier.reorderNotes(1, 3); // B dopo C: cambiano solo B e C
      await notifier.flushPendingSaves();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(dao.rows['A']!.updatedAt, 1000);
      expect(dao.rows['D']!.updatedAt, 1000);
      expect(dao.rows['B']!.updatedAt, greaterThan(1000));
      expect(dao.rows['C']!.updatedAt, greaterThan(1000));
      expect(dao.rows['C']!.orderIndex, 1);
      expect(dao.rows['B']!.orderIndex, 2);
    });

    test('una lista visibile obsoleta viene ignorata senza spostare altro', () async {
      final dao = _FakeDao()
        ..rows.addAll({'A': _row('A', 0), 'B': _row('B', 1)});
      final notifier = await _customNotifier(dao);

      notifier.reorderNotes(0, 2, visibleIds: ['A', 'B', 'ghost']);
      expect(_ids(notifier), ['A', 'B']);
    });

    test('il nuovo ordine sopravvive a un riavvio (ricarica dal DB)', () async {
      final dao = _FakeDao()
        ..rows.addAll({
          'A': _row('A', 0),
          'B': _row('B', 1),
          'C': _row('C', 2),
        });
      final notifier = await _customNotifier(dao);
      notifier.reorderNotes(2, 0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final expected = _ids(notifier);

      final reloaded = await _customNotifier(dao);
      expect(_ids(reloaded), expected);
    });
  });

  group('NotesNotifier - coerenza order_index', () {
    test('createNote non crea duplicati e mette la nota in cima', () async {
      final dao = _FakeDao()
        ..rows.addAll({'A': _row('A', 0), 'B': _row('B', 1)});
      final notifier = await _customNotifier(dao);

      final n1 = notifier.createNote();
      final n2 = notifier.createNote();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(_ids(notifier).take(2), [n2.id, n1.id]);
      final indexes = notifier.state.notes.map((n) => n.orderIndex).toList();
      expect(indexes.toSet().length, indexes.length);
      // Ciò che è in memoria coincide con ciò che è su disco.
      for (final n in notifier.state.notes) {
        expect(dao.rows[n.id]!.orderIndex, n.orderIndex);
      }
    });

    test('passando a "manuale" si parte dall\'ordine visibile', () async {
      SharedPreferences.setMockInitialValues({});
      final dao = _FakeDao()
        ..rows.addAll({
          'A': _row('A', 0),
          'B': _row('B', 0),
          'C': _row('C', 0),
        });
      final notifier = NotesNotifier(dao: dao);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await notifier.setSortOrder(NoteSortOrder.titleDesc);
      final visible = _ids(notifier); // C, B, A

      await notifier.setSortOrder(NoteSortOrder.custom);
      expect(_ids(notifier), visible);
      expect(notifier.state.notes.map((n) => n.orderIndex), [0, 1, 2]);
    });
  });

  group('NotesNotifier.refreshFromDb', () {
    test('non annulla un riordino fatto mentre la lettura DB è in corso', () async {
      final dao = _FakeDao()
        ..rows.addAll({
          'A': _row('A', 0),
          'B': _row('B', 1),
          'C': _row('C', 2),
        });
      final notifier = await _customNotifier(dao);

      dao.getActiveDelay = const Duration(milliseconds: 60);
      final refresh = notifier.refreshFromDb(); // legge lo snapshot VECCHIO
      await Future<void>.delayed(const Duration(milliseconds: 10));
      notifier.reorderNotes(2, 0); // riordino durante la lettura
      final afterReorder = _ids(notifier);
      await refresh;

      expect(_ids(notifier), afterReorder);
    });

    test('preserva il testo in debounce durante il refresh', () async {
      final dao = _FakeDao()..rows.addAll({'A': _row('A', 0)});
      final notifier = await _customNotifier(dao);

      notifier.updateNote('A', content: 'testo appena digitato');
      await notifier.refreshFromDb();

      expect(notifier.state.notes.single.content, 'testo appena digitato');
      await notifier.flushPendingSaves();
    });
  });

  group('NotesNotifier - scritture in debounce vs metadati', () {
    test('spostare una nota subito dopo aver digitato non la riporta indietro', () async {
      final dao = _FakeDao()
        ..rows.addAll({'A': _row('A', 0, folder: 'origine')});
      final notifier = await _customNotifier(dao);

      notifier.updateNote('A', content: 'testo digitato'); // debounce 500ms
      notifier.moveNote('A', 'destinazione'); // entro i 500ms

      // Lascia scattare il timer di autosave e tutte le scritture.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await notifier.flushPendingSaves();

      expect(dao.rows['A']!.folderId, 'destinazione');
      expect(dao.rows['A']!.content, 'testo digitato');
    });

    test('cancellare una nota subito dopo aver digitato non la fa risorgere', () async {
      final dao = _FakeDao()..rows.addAll({'A': _row('A', 0)});
      final notifier = await _customNotifier(dao);

      notifier.updateNote('A', content: 'testo digitato');
      notifier.deleteNote('A');

      await Future<void>.delayed(const Duration(milliseconds: 700));
      await notifier.flushPendingSaves();

      expect(dao.rows['A']!.isDeleted, isTrue);
    });
  });
}
