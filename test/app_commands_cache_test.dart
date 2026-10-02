import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/utils/app_commands.dart';

void main() {
  group('activatorsFor (cache)', () {
    test('restituisce sempre la stessa lista e mai una vuota', () {
      for (final command in AppCommand.values) {
        expect(activatorsFor(command), isNotEmpty, reason: '$command');
        expect(
          identical(activatorsFor(command), activatorsFor(command)),
          isTrue,
          reason: '$command',
        );
      }
    });

    test('la lista in cache non è modificabile dall\'esterno', () {
      final shared = activatorsFor(AppCommand.values.first);
      expect(
        () => shared.add(activatorsFor(AppCommand.values.last).first),
        throwsUnsupportedError,
      );
    });
  });
}
