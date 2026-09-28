import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/services/import_service.dart';

void main() {
  test('i limiti di import sono definiti e ragionevoli', () {
    expect(ImportService.maxZipBytes, greaterThan(0));
    expect(ImportService.maxEntryBytes, lessThan(ImportService.maxTotalUncompressedBytes));
    expect(ImportService.maxImportedFiles, lessThanOrEqualTo(ImportService.maxZipEntries));
  });
}
