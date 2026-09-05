import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('NotesNotifier.moveNote', () {
    test('clears relativePath and captures pendingOldRelativePath on move', () async {
      final notifier = NotesNotifier();
      // Wait for the async _loadFromPrefs() to seed the sample note.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final note = notifier.createNote();
      notifier.updateNoteRelativePath(note.id, 'personale/${note.id}.md');

      final beforeMove = notifier.state.notes.firstWhere((n) => n.id == note.id);
      expect(beforeMove.relativePath, 'personale/${note.id}.md');
      expect(beforeMove.pendingOldRelativePath, isNull);

      notifier.moveNote(note.id, 'work-folder-id');

      final afterMove = notifier.state.notes.firstWhere((n) => n.id == note.id);
      expect(afterMove.folderId, 'work-folder-id');
      // The relative path must be invalidated so the next sync recomputes it
      // based on the new folder instead of silently keeping the old path.
      expect(afterMove.relativePath, isNull);
      // The previous path must be preserved so it can be sent as
      // old_relative_path in the next sync payload.
      expect(afterMove.pendingOldRelativePath, 'personale/${note.id}.md');
    });

    test('updateNoteRelativePath clears the pending move flag once synced', () async {
      final notifier = NotesNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final note = notifier.createNote();
      notifier.updateNoteRelativePath(note.id, 'personale/${note.id}.md');
      notifier.moveNote(note.id, 'work-folder-id');

      // Simulate what sync_provider does after resolving the new path.
      notifier.updateNoteRelativePath(
        note.id,
        'lavoro/${note.id}.md',
        clearPendingMove: true,
      );

      final updated = notifier.state.notes.firstWhere((n) => n.id == note.id);
      expect(updated.relativePath, 'lavoro/${note.id}.md');
      expect(updated.pendingOldRelativePath, isNull);
    });

    test('moving to the same folder is a no-op', () async {
      final notifier = NotesNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final note = notifier.createNote(folderId: 'folder-a');
      notifier.updateNoteRelativePath(note.id, 'a/${note.id}.md');

      notifier.moveNote(note.id, 'folder-a');

      final unchanged = notifier.state.notes.firstWhere((n) => n.id == note.id);
      expect(unchanged.relativePath, 'a/${note.id}.md');
      expect(unchanged.pendingOldRelativePath, isNull);
    });
  });
}
