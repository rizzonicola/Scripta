import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';

/// Fake in-memory di [NotesDao]: evita di aprire un vero database SQLite nei
/// test unitari (che richiederebbe sqflite_common_ffi), pur esercitando
/// esattamente la stessa interfaccia usata da [NotesNotifier].
class FakeNotesDao implements NotesDao {
  final Map<String, NoteRow> _rows = {};

  @override
  Future<List<NoteRow>> getActive() async =>
      _rows.values.where((r) => !r.isDeleted).toList();

  @override
  Future<NoteRow?> getById(String id) async => _rows[id];

  @override
  Future<void> upsert(NoteRow row) async => _rows[row.id] = row;

  @override
  Future<void> applyRemoteLWW(NoteRow remote) async {
    final local = _rows[remote.id];
    if (local == null || remote.updatedAt >= local.updatedAt) {
      _rows[remote.id] = remote;
    }
  }

  @override
  Future<List<NoteRow>> listDirtySince(int sinceMillis) async =>
      _rows.values.where((r) => r.updatedAt > sinceMillis).toList();

  @override
  Future<void> softDeleteByFolder(String folderId, int now) async {
    for (final id in _rows.keys.toList()) {
      final r = _rows[id]!;
      if (r.folderId == folderId && !r.isDeleted) {
        _rows[id] = r.copyWith(updatedAt: now, deletedAt: now);
      }
    }
  }

  @override
  Future<void> hardDeleteIds(List<String> ids) async {
    for (final id in ids) {
      _rows.remove(id);
    }
  }

  @override
  Future<void> hardDeleteAll() async => _rows.clear();
}

void main() {
  group('NotesNotifier.moveNote', () {
    test('updates folderId and bumps updatedAt on move', () async {
      final notifier = NotesNotifier(dao: FakeNotesDao());
      // Nessuna nota preesistente: il DB locale è vuoto al primo avvio
      // (zero seeding), quindi non serve attendere alcun caricamento.
      await Future<void>.delayed(Duration.zero);

      final note = notifier.createNote(folderId: 'personal-folder-id');
      final beforeMove = notifier.state.notes.firstWhere((n) => n.id == note.id);
      expect(beforeMove.folderId, 'personal-folder-id');

      notifier.moveNote(note.id, 'work-folder-id');

      final afterMove = notifier.state.notes.firstWhere((n) => n.id == note.id);
      expect(afterMove.folderId, 'work-folder-id');
      expect(afterMove.updatedAt.isAfter(beforeMove.updatedAt) || afterMove.updatedAt.isAtSameMomentAs(beforeMove.updatedAt), isTrue);
    });

    test('moving to null (root) clears the folder', () async {
      final notifier = NotesNotifier(dao: FakeNotesDao());
      await Future<void>.delayed(Duration.zero);

      final note = notifier.createNote(folderId: 'folder-a');
      notifier.moveNote(note.id, null);

      final updated = notifier.state.notes.firstWhere((n) => n.id == note.id);
      expect(updated.folderId, isNull);
    });

    test('moving to the same folder is a no-op', () async {
      final notifier = NotesNotifier(dao: FakeNotesDao());
      await Future<void>.delayed(Duration.zero);

      final note = notifier.createNote(folderId: 'folder-a');
      final before = notifier.state.notes.firstWhere((n) => n.id == note.id);

      notifier.moveNote(note.id, 'folder-a');

      final after = notifier.state.notes.firstWhere((n) => n.id == note.id);
      expect(after.updatedAt, before.updatedAt);
      expect(after.folderId, 'folder-a');
    });

    test('deleteNote removes it from the active list and persists a tombstone', () async {
      final dao = FakeNotesDao();
      final notifier = NotesNotifier(dao: dao);
      await Future<void>.delayed(Duration.zero);

      final note = notifier.createNote();
      notifier.deleteNote(note.id);

      expect(notifier.state.notes.any((n) => n.id == note.id), isFalse);

      final stored = await dao.getById(note.id);
      expect(stored, isNotNull);
      expect(stored!.isDeleted, isTrue);
    });
  });
}
