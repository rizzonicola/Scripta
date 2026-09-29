import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';

import 'notes_provider_move_test.dart' show FakeNotesDao;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('NotesNotifier.duplicateNote', () {
    test('copies content and folder, appends suffix, activates the copy', () async {
      final notifier = NotesNotifier(dao: FakeNotesDao());
      await Future<void>.delayed(Duration.zero);

      final original = notifier.createNote(folderId: 'folder-a');
      notifier.updateNote(original.id, title: 'Idee', content: '# Hello');

      final copy = notifier.duplicateNote(original.id, copySuffix: ' (copia)');

      expect(copy, isNotNull);
      expect(copy!.id, isNot(original.id));
      expect(copy.title, 'Idee (copia)');
      expect(copy.content, '# Hello');
      expect(copy.folderId, 'folder-a');
      expect(notifier.state.activeNoteId, copy.id);
      expect(notifier.state.notes.length, 2);
    });

    test('untitled note stays untitled', () async {
      final notifier = NotesNotifier(dao: FakeNotesDao());
      await Future<void>.delayed(Duration.zero);

      final original = notifier.createNote();
      notifier.updateNote(original.id, content: 'body');

      final copy = notifier.duplicateNote(original.id);
      expect(copy!.title, isEmpty);
      expect(copy.content, 'body');
    });

    test('unknown id returns null and changes nothing', () async {
      final notifier = NotesNotifier(dao: FakeNotesDao());
      await Future<void>.delayed(Duration.zero);

      expect(notifier.duplicateNote('missing'), isNull);
      expect(notifier.state.notes, isEmpty);
    });
  });
}
