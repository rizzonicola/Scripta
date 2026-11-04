import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/services/backup_manifest.dart';

Map<String, Object?> _manifest({
  List<Object?>? folders,
  List<Object?>? notes,
}) => {
  'format': backupManifestFormat,
  'version': backupManifestVersion,
  'folders': folders ?? const <Object?>[],
  'notes': notes ?? const <Object?>[],
};

String _encode(Map<String, Object?> manifest) => jsonEncode(manifest);

void main() {
  test('rifiuta più di maxItems cartelle prima di costruire gli oggetti', () {
    final folders = List<Object?>.generate(
      BackupManifest.maxItems + 1,
      (i) => <String, Object?>{'path': 'f$i', 'name': 'f$i'},
    );

    expect(
      () => BackupManifest.decode(_encode(_manifest(folders: folders))),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('troppi elementi'),
        ),
      ),
    );
  });

  test('rifiuta più di maxItems note', () {
    final notes = List<Object?>.generate(
      BackupManifest.maxItems + 1,
      (i) => <String, Object?>{'path': 'n$i.md'},
    );

    expect(
      () => BackupManifest.decode(_encode(_manifest(notes: notes))),
      throwsFormatException,
    );
  });

  test('rifiuta elementi non-oggetto invece di scartarli in silenzio', () {
    expect(
      () => BackupManifest.decode(
        _encode(_manifest(folders: ['non-un-oggetto'])),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('elemento non valido'),
        ),
      ),
    );
    expect(
      () => BackupManifest.decode(_encode(_manifest(notes: [42]))),
      throwsFormatException,
    );
  });

  test('un manifest minimo valido continua a essere accettato', () {
    final manifest = BackupManifest.decode(_encode(_manifest()));

    expect(manifest.folders, isEmpty);
    expect(manifest.notes, isEmpty);
  });
}
