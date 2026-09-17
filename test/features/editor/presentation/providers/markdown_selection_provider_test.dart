import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/features/editor/presentation/providers/markdown_selection_provider.dart';

void main() {
  group('MarkdownSelectionNotifier Unit Tests', () {
    late ProviderContainer container;
    late MarkdownSelectionNotifier notifier;

    setUp(() {
      container = ProviderContainer();
      notifier = container.read(markdownSelectionProvider.notifier);
    });

    tearDown(() {
      container.dispose();
    });

    test('Initial state is unselected and valid collapsed at zero', () {
      final state = container.read(markdownSelectionProvider);
      expect(state.isValid, isFalse);
      expect(state.isCollapsed, isTrue);
    });

    test('startSelection initializes selection range properly', () {
      notifier.startSelection(10);
      final state = container.read(markdownSelectionProvider);
      expect(state.start, equals(10));
      expect(state.end, equals(10));
      expect(state.isSelecting, isTrue);
      expect(state.isValid, isTrue);
    });

    test('updateSelection expands range and clamps to min/max', () {
      notifier.startSelection(10);
      notifier.updateSelection(25);
      var state = container.read(markdownSelectionProvider);
      expect(state.start, equals(10));
      expect(state.end, equals(25));
      expect(state.min, equals(10));
      expect(state.max, equals(25));
      expect(state.isCollapsed, isFalse);

      notifier.updateSelection(5);
      state = container.read(markdownSelectionProvider);
      expect(state.start, equals(10));
      expect(state.end, equals(5));
      expect(state.min, equals(5));
      expect(state.max, equals(10));
    });

    test('endSelection finalizes selection drag', () {
      notifier.startSelection(10);
      notifier.updateSelection(20);
      notifier.endSelection();
      final state = container.read(markdownSelectionProvider);
      expect(state.isSelecting, isFalse);
      expect(state.min, equals(10));
      expect(state.max, equals(20));
    });

    test('clearSelection resets selection to unselected state', () {
      notifier.startSelection(10);
      notifier.updateSelection(20);
      notifier.endSelection();
      expect(container.read(markdownSelectionProvider).isValid, isTrue);

      notifier.clearSelection();
      final state = container.read(markdownSelectionProvider);
      expect(state.isValid, isFalse);
      expect(state.isCollapsed, isTrue);
      expect(state.start, equals(-1));
      expect(state.end, equals(-1));
    });

    test('selectAll selects entire content length safely', () {
      notifier.selectAll(100);
      var state = container.read(markdownSelectionProvider);
      expect(state.start, equals(0));
      expect(state.end, equals(100));
      expect(state.isValid, isTrue);
      expect(state.isCollapsed, isFalse);

      notifier.selectAll(0);
      state = container.read(markdownSelectionProvider);
      expect(state.isValid, isTrue);
      expect(state.isCollapsed, isTrue);
    });

    test('selectWordAt snaps to word boundaries correctly', () {
      const String content = 'Hello world Markdown!';
      // 'world' is from index 6 to 11
      notifier.selectWordAt(8, content);
      final state = container.read(markdownSelectionProvider);
      expect(state.start, equals(6));
      expect(state.end, equals(11));
      expect(state.isValid, isTrue);
      expect(state.isCollapsed, isFalse);
    });

    test('copySelectedText handles out of bounds without throwing RangeError', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const String content = 'Short text';
      // Set selection out of bounds: -5 to 50
      notifier.startSelection(-5);
      notifier.updateSelection(50);
      notifier.endSelection();

      // Should safely clamp to 0..content.length without throw
      await expectLater(
        notifier.copySelectedText(content),
        completes,
      );
    });
  });
}
