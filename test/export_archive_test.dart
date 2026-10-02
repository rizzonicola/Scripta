import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/services/export_archive.dart';
import 'package:scripta/features/folders/models/folder_node.dart';

ExportNote _note(
  String id,
  String title, {
  String content = 'testo',
  String? folderId,
}) =>
    (id: id, title: title, content: content, folderId: folderId);

ExportFolder _folder(String id, String name, {String? parentId}) =>
    (id: id, name: name, parentId: parentId);

/// Elenco dei file contenuti nello ZIP (percorso → testo).
Map<String, String> _entries(ZipResult result) {
  final archive = ZipDecoder().decodeBytes(result.bytes);
  return {
    for (final file in archive.files)
      if (file.isFile) file.name: utf8.decode(file.content as List<int>),
  };
}

void main() {
  group('buildNotesZip', () {
    test('due note con lo stesso titolo nella stessa cartella non si sovrascrivono', () {
      final result = buildNotesZip((
        folders: [_folder('f', 'Lavoro')],
        notes: [
          _note('id-1', 'Riunione', content: 'uno', folderId: 'f'),
          _note('id-2', 'Riunione', content: 'due', folderId: 'f'),
          // Su Windows e macOS "riunione.md" e "Riunione.md" sono lo stesso file.
          _note('id-3', 'riunione', content: 'tre', folderId: 'f'),
        ],
      ));

      final entries = _entries(result);
      expect(result.noteCount, 3);
      expect(
        entries.keys,
        unorderedEquals([
          'Lavoro/Riunione.md',
          'Lavoro/Riunione (2).md',
          'Lavoro/riunione (3).md',
        ]),
      );
      // Nessun contenuto è andato perso.
      final allText = entries.values.join('\n');
      expect(allText, contains('uno'));
      expect(allText, contains('due'));
      expect(allText, contains('tre'));
    });

    test('un id più corto di 6 caratteri non fa fallire l\'esportazione', () {
      final result = buildNotesZip((
        folders: const <ExportFolder>[],
        notes: [_note('ab', '')],
      ));

      expect(_entries(result).keys, ['$uncatalogedFolderName/Nota_ab.md']);
    });

    test('titolo vuoto → nome ricavato dai primi 6 caratteri dell\'id', () {
      final result = buildNotesZip((
        folders: const <ExportFolder>[],
        notes: [_note('abcdef123456', '   ')],
      ));

      expect(_entries(result).keys, ['$uncatalogedFolderName/Nota_abcdef.md']);
    });

    test('note senza cartella o con cartella sconosciuta finiscono in Non_Catalogate', () {
      final result = buildNotesZip((
        folders: [_folder('f', 'Reale')],
        notes: [
          _note('1111111', 'A'),
          _note('2222222', 'B', folderId: 'inesistente'),
          _note('3333333', 'C', folderId: 'f'),
        ],
      ));

      expect(
        _entries(result).keys,
        unorderedEquals([
          '$uncatalogedFolderName/A.md',
          '$uncatalogedFolderName/B.md',
          'Reale/C.md',
        ]),
      );
    });

    test('le cartelle annidate producono percorsi annidati', () {
      final result = buildNotesZip((
        folders: [
          _folder('a', 'A'),
          _folder('b', 'B', parentId: 'a'),
          _folder('c', 'C', parentId: 'b'),
        ],
        notes: [_note('1111111', 'Nota', folderId: 'c')],
      ));

      expect(_entries(result).keys, ['A/B/C/Nota.md']);
    });

    test('i nomi di cartella pericolosi vengono sanitizzati (niente path traversal)', () {
      final result = buildNotesZip((
        folders: [
          _folder('p', '..'),
          _folder('c', 'a/b', parentId: 'p'),
        ],
        notes: [_note('1111111', 'x', folderId: 'c')],
      ));

      final names = _entries(result).keys.toList();
      expect(names, ['_/a_b/x.md']);
      for (final name in names) {
        expect(name.split('/'), isNot(contains('..')));
        expect(name, isNot(startsWith('/')));
      }
    });

    test('una gerarchia ciclica (dati corrotti) non manda in loop', () {
      final result = buildNotesZip((
        folders: [
          _folder('a', 'A', parentId: 'b'),
          _folder('b', 'B', parentId: 'a'),
        ],
        notes: [_note('1111111', 'N', folderId: 'a')],
      ));

      expect(result.noteCount, 1);
      expect(_entries(result).keys.single, endsWith('/N.md'));
    });

    test('antepone il titolo solo se il testo non inizia già con un titolo', () {
      final result = buildNotesZip((
        folders: const <ExportFolder>[],
        notes: [
          _note('1111111', 'Senza', content: 'corpo'),
          _note('2222222', 'Con', content: '# Già presente\n\ncorpo'),
        ],
      ));

      final entries = _entries(result);
      expect(entries['$uncatalogedFolderName/Senza.md'], '# Senza\n\ncorpo');
      expect(entries['$uncatalogedFolderName/Con.md'], '# Già presente\n\ncorpo');
    });

    test('un archivio vuoto è comunque uno ZIP valido', () {
      final result = buildNotesZip((
        folders: const <ExportFolder>[],
        notes: const <ExportNote>[],
      ));

      expect(result.noteCount, 0);
      expect(_entries(result), isEmpty);
    });
  });

  group('sanitizzazione', () {
    test('sanitizeFileName sostituisce i caratteri non ammessi', () {
      expect(sanitizeFileName('a/b:c*d?e"f<g>h|i\\j'), 'a_b_c_d_e_f_g_h_i_j');
      expect(sanitizeFileName('riga\u0000con\u001Fcontrollo'), 'riga_con_controllo');
      expect(sanitizeFileName('  spazi  '), 'spazi');
    });

    test('sanitizeFileName non restituisce mai una stringa vuota', () {
      expect(sanitizeFileName(''), 'untitled');
      expect(sanitizeFileName('   '), 'untitled');
    });

    test('sanitizeFolderName neutralizza "." e ".."', () {
      expect(sanitizeFolderName('.'), '_');
      expect(sanitizeFolderName('..'), '_');
      expect(sanitizeFolderName('...'), '_');
      expect(sanitizeFolderName('v1.2'), 'v1.2');
      expect(sanitizeFolderName('.nascosta'), '.nascosta');
    });
  });

  group('noteMarkdownContent', () {
    test('antepone il titolo quando manca un titolo di primo livello', () {
      expect(noteMarkdownContent('Titolo', 'corpo'), '# Titolo\n\ncorpo');
    });

    test('lascia invariato un testo che inizia già con un titolo', () {
      expect(noteMarkdownContent('Altro', '# Mio\n\ncorpo'), '# Mio\n\ncorpo');
    });

    test('lascia invariato il testo se il titolo è vuoto', () {
      expect(noteMarkdownContent('  ', 'corpo'), 'corpo');
    });
  });

  group('flattenFolderTree', () {
    test('appiattisce in pre-ordine assegnando il genitore dall\'albero', () {
      final flat = flattenFolderTree(const [
        FolderNode(
          id: 'a',
          name: 'A',
          children: [FolderNode(id: 'b', name: 'B', parentId: 'a')],
        ),
        FolderNode(id: 'c', name: 'C'),
      ]);

      expect(flat, [
        (id: 'a', name: 'A', parentId: null),
        (id: 'b', name: 'B', parentId: 'a'),
        (id: 'c', name: 'C', parentId: null),
      ]);
    });

    test('la radice dell\'esportazione ha sempre parentId nullo', () {
      final flat = flattenFolderTree(const [
        FolderNode(id: 'x', name: 'X', parentId: 'altrove'),
      ]);

      expect(flat.single.parentId, isNull);
    });
  });
}
