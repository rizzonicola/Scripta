import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/services/export_service.dart';

void main() {
  group('ExportService fallback', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('scripta_export_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('non sovrascrive un export già presente', () async {
      await File('${dir.path}/Nota.md').writeAsString('primo');

      final second = await ExportService.uniqueFallbackFile(dir, 'Nota.md');
      await second.writeAsString('secondo');
      final third = await ExportService.uniqueFallbackFile(dir, 'Nota.md');

      expect(second.path, '${dir.path}/Nota-2.md');
      expect(third.path, '${dir.path}/Nota-3.md');
      expect(await File('${dir.path}/Nota.md').readAsString(), 'primo');
      expect(await second.readAsString(), 'secondo');
    });

    test('gestisce nomi senza estensione', () async {
      await File('${dir.path}/Backup').writeAsString('primo');

      final second = await ExportService.uniqueFallbackFile(dir, 'Backup');

      expect(second.path, '${dir.path}/Backup-2');
    });
  });
}
