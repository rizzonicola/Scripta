import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/services/import_service.dart';

// Regressioni sulla preflight del central directory ZIP: `archive` 4.5.2
// ignora il conteggio EOCD e scorre tutti i record presenti in `cdSize`,
// quindi la preflight deve fare lo stesso e pretendere che il conteggio
// dichiarato coincida. Altrimenti una voce nascosta (per esempio un symlink,
// che il decoder decompressa subito) sfugge ai limiti.

Uint8List _zipOf(List<String> names) {
  final archive = Archive();
  for (final name in names) {
    archive.addFile(ArchiveFile.bytes(name, utf8.encode(name)));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

int _u16(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _u32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

void _setU16(Uint8List bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
}

void _setU32(Uint8List bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
  bytes[offset + 2] = (value >> 16) & 0xff;
  bytes[offset + 3] = (value >> 24) & 0xff;
}

int _eocdOffset(Uint8List bytes) {
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (_u32(bytes, i) == 0x06054b50) return i;
  }
  throw StateError('EOCD non trovato');
}

/// Offset del secondo record del central directory.
int _secondCentralRecord(Uint8List bytes, int first) =>
    first +
    46 +
    _u16(bytes, first + 28) +
    _u16(bytes, first + 30) +
    _u16(bytes, first + 32);

void main() {
  test('un record nascosto oltre il conteggio EOCD viene ispezionato', () {
    final bytes = _zipOf(['a.md', 'b.md']);
    final eocd = _eocdOffset(bytes);
    final cdOffset = _u32(bytes, eocd + 16);
    final second = _secondCentralRecord(bytes, cdOffset);

    // Il secondo record diventa un symlink Unix, ma l'EOCD dichiara una sola
    // voce. La vecchia preflight si fermava al conteggio e non lo vedeva.
    _setU16(bytes, second + 4, (3 << 8) | 20);
    _setU32(bytes, second + 38, 0xa1ff << 16);
    _setU16(bytes, eocd + 8, 1);
    _setU16(bytes, eocd + 10, 1);

    expect(
      () => ImportService.decodeZipEntries(bytes),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('collegamento simbolico'),
        ),
      ),
    );
  });

  test('un conteggio EOCD inferiore ai record reali viene rifiutato', () {
    final bytes = _zipOf(['a.md', 'b.md']);
    final eocd = _eocdOffset(bytes);
    _setU16(bytes, eocd + 8, 1);
    _setU16(bytes, eocd + 10, 1);

    expect(
      () => ImportService.decodeZipEntries(bytes),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('numero di voci incoerente'),
        ),
      ),
    );
  });

  test('un conteggio EOCD superiore ai record reali viene rifiutato', () {
    final bytes = _zipOf(['a.md']);
    final eocd = _eocdOffset(bytes);
    _setU16(bytes, eocd + 8, 2);
    _setU16(bytes, eocd + 10, 2);

    expect(
      () => ImportService.decodeZipEntries(bytes),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('numero di voci incoerente'),
        ),
      ),
    );
  });

  test('byte estranei dentro cdSize rendono la directory non allineata', () {
    final bytes = _zipOf(['a.md']);
    final eocd = _eocdOffset(bytes);
    final cdSize = _u32(bytes, eocd + 12);

    // Inserisce un byte subito dopo l'ultimo record e allarga cdSize: la
    // preflight non deve fermarsi prima della fine dichiarata.
    final padded = Uint8List(bytes.length + 1)
      ..setRange(0, eocd, bytes)
      ..[eocd] = 0
      ..setRange(eocd + 1, bytes.length + 1, bytes.sublist(eocd));
    _setU32(padded, eocd + 1 + 12, cdSize + 1);

    expect(() => ImportService.decodeZipEntries(padded), throwsFormatException);
  });

  test('un locator ZIP64 prima dell\'EOCD viene rifiutato anche senza sentinelle', () {
    final bytes = _zipOf(['a.md']);
    final eocd = _eocdOffset(bytes);

    // Inserisce 20 byte prima dell'EOCD e mette la firma del locator ZIP64
    // esattamente a eocd-20. I campi EOCD restano validi e non sentinella:
    // archive seguirebbe comunque il locator, quindi la preflight deve
    // rifiutarlo prima del decode.
    final withLocator = Uint8List(bytes.length + 20)
      ..setRange(0, eocd, bytes)
      ..setRange(eocd + 20, bytes.length + 20, bytes.sublist(eocd));
    _setU32(withLocator, eocd, 0x07064b50);

    expect(
      () => ImportService.decodeZipEntries(withLocator),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('ZIP64'),
        ),
      ),
    );
  });

  test('un EOCD-esca con commento oltre EOF non nasconde quello valido', () {
    final bytes = _zipOf(['a.md']);

    // Aggiunge un secondo EOCD alla fine, con commentLength 0xffff e campi
    // plausibili. archive seleziona la firma più vicina alla fine; la
    // preflight deve fare lo stesso e rifiutare l'allineamento, invece di
    // saltare l'esca e convalidare l'EOCD precedente.
    final decoy = Uint8List(bytes.length + 22);
    decoy.setRange(0, bytes.length, bytes);
    final decoyOffset = bytes.length;
    _setU32(decoy, decoyOffset, 0x06054b50);
    _setU16(decoy, decoyOffset + 20, 0xffff);

    expect(
      () => ImportService.decodeZipEntries(decoy),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('EOCD non allineato'),
        ),
      ),
    );
  });

  test('un commento EOCD che termina esattamente a EOF è accettato', () {
    final bytes = _zipOf(['a.md']);
    final eocd = _eocdOffset(bytes);
    final comment = utf8.encode('backup');

    final withComment = Uint8List(bytes.length + comment.length)
      ..setRange(0, bytes.length, bytes)
      ..setRange(bytes.length, bytes.length + comment.length, comment);
    _setU16(withComment, eocd + 20, comment.length);

    expect(ImportService.decodeZipEntries(withComment), hasLength(1));
  });
}
