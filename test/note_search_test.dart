import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/features/editor/providers/note_search_provider.dart';
import 'package:scripta/features/notes/models/note_model.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';

NoteModel _note(String content) => NoteModel(
  id: 'n1',
  title: 'Titolo',
  content: content,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

ProviderContainer _container(String content) {
  final container = ProviderContainer(
    overrides: [activeNoteProvider.overrideWithValue(_note(content))],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('le occorrenze sono case-insensitive e non sovrapposte', () {
    final container = _container('Foo foo FOOD foo');
    container.read(noteSearchProvider.notifier).setQuery('foo');

    final matches = container.read(noteSearchMatchesProvider);
    expect(matches, hasLength(4));
    expect(matches.map((m) => (m.start, m.end)), [
      (0, 3),
      (4, 7),
      (8, 11),
      (13, 16),
    ]);

    final overlapping = _container('aaaa');
    overlapping.read(noteSearchProvider.notifier).setQuery('aa');
    expect(overlapping.read(noteSearchMatchesProvider), hasLength(2));
  });

  test('query vuota o con soli spazi non produce occorrenze', () {
    final container = _container('testo con testo');
    final notifier = container.read(noteSearchProvider.notifier);

    notifier.setQuery('');
    expect(container.read(noteSearchMatchesProvider), isEmpty);
    notifier.setQuery('   ');
    expect(container.read(noteSearchMatchesProvider), isEmpty);
  });

  test('next/previous scorrono con wraparound e indice clampato', () {
    final container = _container('x x x');
    final notifier = container.read(noteSearchProvider.notifier);
    notifier.open(initialQuery: 'x');

    int activeIndex() => container.read(noteSearchActiveMatchIndexProvider);
    expect(activeIndex(), 0);

    notifier.nextMatch(3);
    expect(activeIndex(), 1);
    notifier.nextMatch(3);
    expect(activeIndex(), 2);
    notifier.nextMatch(3);
    expect(activeIndex(), 0);
    notifier.previousMatch(3);
    expect(activeIndex(), 2);

    notifier.setQuery('assente');
    expect(container.read(noteSearchMatchesProvider), isEmpty);
    expect(activeIndex(), -1);
    expect(container.read(activeNoteSearchMatchProvider), isNull);
  });

  test('cambiare query riparte dalla prima occorrenza', () {
    final container = _container('alfa beta alfa beta');
    final notifier = container.read(noteSearchProvider.notifier);
    notifier.open(initialQuery: 'alfa');
    notifier.nextMatch(2);
    expect(container.read(noteSearchActiveMatchIndexProvider), 1);

    notifier.setQuery('beta');
    final matches = container.read(noteSearchMatchesProvider);
    expect(matches, hasLength(2));
    expect(container.read(noteSearchActiveMatchIndexProvider), 0);
    expect(container.read(activeNoteSearchMatchProvider), matches.first);
  });

  test('open senza query preserva il termine, close lo azzera', () {
    final container = _container('termine');
    final notifier = container.read(noteSearchProvider.notifier);

    notifier.open(initialQuery: 'termine');
    notifier.close();
    expect(container.read(noteSearchProvider).query, isEmpty);

    notifier.setQuery('termine');
    notifier.open();
    expect(container.read(noteSearchProvider).query, 'termine');
  });
}
