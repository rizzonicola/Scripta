import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/utils/link_safety.dart';

void main() {
  group('safeExternalUri', () {
    test('accetta http, https e mailto', () {
      expect(safeExternalUri('https://example.com/a?b=1'), isNotNull);
      expect(safeExternalUri('http://example.com'), isNotNull);
      expect(safeExternalUri('  HTTPS://Example.com  '), isNotNull);
      expect(safeExternalUri('mailto:mario@example.com'), isNotNull);
    });

    test('rifiuta schemi pericolosi o non ammessi', () {
      for (final bad in [
        'javascript:alert(1)',
        'file:///etc/passwd',
        'intent://scan/#Intent;scheme=zxing;end',
        'content://com.android.contacts/contacts',
        'data:text/html;base64,PHNjcmlwdD4=',
        'ftp://example.com/file',
        'tel:+390000000',
        'myapp://do-something',
      ]) {
        expect(safeExternalUri(bad), isNull, reason: bad);
      }
    });

    test('rifiuta input vuoti, senza host o con caratteri di controllo', () {
      expect(safeExternalUri(''), isNull);
      expect(safeExternalUri('   '), isNull);
      expect(safeExternalUri('https://'), isNull);
      expect(safeExternalUri('mailto:'), isNull);
      expect(safeExternalUri('java\nscript:alert(1)'), isNull);
      expect(safeExternalUri('/relativo/senza/schema'), isNull);
    });
  });
}
