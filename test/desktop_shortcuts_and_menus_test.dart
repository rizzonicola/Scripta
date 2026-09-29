import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/utils/app_commands.dart';
import 'package:scripta/core/widgets/context_menu.dart';

void main() {
  group('AppCommand shortcuts', () {
    test('every command has at least one activator and no duplicates', () {
      final seen = <String>{};
      for (final command in AppCommand.values) {
        final activators = activatorsFor(command);
        expect(activators, isNotEmpty, reason: command.name);
        for (final a in activators) {
          final id = '${a.trigger.keyId}-${a.control}-${a.meta}-${a.alt}-${a.shift}';
          expect(seen.add(id), isTrue, reason: 'duplicate activator: ${command.name}');
        }
      }
    });

    test('editor shortcuts do not collide with global shortcuts', () {
      final global = <String>{
        for (final c in AppCommand.values)
          for (final a in activatorsFor(c))
            '${a.trigger.keyId}-${a.control}-${a.meta}-${a.alt}-${a.shift}',
      };
      for (final c in EditorCommand.values) {
        final a = editorActivatorFor(c);
        final id = '${a.trigger.keyId}-${a.control}-${a.meta}-${a.alt}-${a.shift}';
        expect(global.contains(id), isFalse, reason: c.name);
      }
    });

    test('labels are non-empty', () {
      for (final c in AppCommand.values) {
        expect(commandShortcutLabel(c), isNotEmpty);
      }
    });
  });

  group('ContextMenuRegion', () {
    testWidgets('right click opens menu and runs the selected action', (tester) async {
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ContextMenuRegion(
                behavior: HitTestBehavior.opaque,
                entriesBuilder: (_) => [
                  ContextMenuEntry(label: 'Pin', onSelected: () => selected++),
                  const ContextMenuEntry.divider(),
                  const ContextMenuEntry(label: 'Disabled'),
                ],
                child: const SizedBox(width: 200, height: 100, child: Text('target')),
              ),
            ),
          ),
        ),
      );

      // Il tasto sinistro non deve aprire nulla.
      await tester.tap(find.text('target'));
      await tester.pumpAndSettle();
      expect(find.text('Pin'), findsNothing);

      await tester.tap(find.text('target'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('Pin'), findsOneWidget);

      await tester.tap(find.text('Pin'));
      await tester.pumpAndSettle();
      expect(selected, 1);
      expect(find.text('Pin'), findsNothing);
    });

    testWidgets('innermost region wins over the outer one', (tester) async {
      var inner = 0;
      var outer = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContextMenuRegion(
              behavior: HitTestBehavior.opaque,
              entriesBuilder: (_) => [
                ContextMenuEntry(label: 'Outer', onSelected: () => outer++),
              ],
              child: Center(
                child: ContextMenuRegion(
                  behavior: HitTestBehavior.opaque,
                  entriesBuilder: (_) => [
                    ContextMenuEntry(label: 'Inner', onSelected: () => inner++),
                  ],
                  child: const SizedBox(width: 100, height: 50, child: Text('card')),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('card'), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('Inner'), findsOneWidget);
      expect(find.text('Outer'), findsNothing);
      await tester.tap(find.text('Inner'));
      await tester.pumpAndSettle();
      expect(inner, 1);
      expect(outer, 0);
    });
  });
}
