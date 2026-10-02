import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/features/notes/models/note_model.dart';

NoteModel _note(String content) => NoteModel(
      id: 'n',
      title: 'T',
      content: content,
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );

void main() {
  group('NoteModel.wordCount', () {
    test('testo vuoto o fatto di soli spazi vale zero', () {
      expect(_note('').wordCount, 0);
      expect(_note('   \n\t  ').wordCount, 0);
    });

    test('conta sequenze di caratteri non-spazio', () {
      expect(_note('uno').wordCount, 1);
      expect(_note('uno due  tre\nquattro\tcinque').wordCount, 5);
      expect(_note('  spazi ai bordi  ').wordCount, 3);
    });

    test('riconosce gli stessi spazi di \\s (spazio non separabile incluso)', () {
      expect(_note('a\u00a0b').wordCount, 2);
      expect(_note('a\u2003b\u3000c').wordCount, 3);
    });

    test('è coerente con la definizione originale split(RegExp(r"\\s+"))', () {
      const samples = [
        'Ciao mondo',
        '# Titolo\n\n- elemento uno\n- elemento due\n',
        'una   riga   con   spazi   multipli',
        '\n\nsolo a capo e una parola\n\n',
      ];
      for (final text in samples) {
        final expected = text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;
        expect(_note(text).wordCount, expected, reason: text);
      }
    });
  });

  group('NoteModel.readingTimeMinutes', () {
    test('vale almeno un minuto', () {
      expect(_note('').readingTimeMinutes, 1);
      expect(_note('poche parole').readingTimeMinutes, 1);
    });

    test('arrotonda per eccesso a 200 parole al minuto', () {
      expect(_note(List.filled(200, 'w').join(' ')).readingTimeMinutes, 1);
      expect(_note(List.filled(201, 'w').join(' ')).readingTimeMinutes, 2);
    });
  });

  group('NoteModel.previewSnippet', () {
    test('contenuto vuoto → testo segnaposto', () {
      expect(_note('').previewSnippet, 'Nessun testo aggiuntivo');
      expect(_note('   ').previewSnippet, 'Nessun testo aggiuntivo');
    });

    test('rimuove i simboli di formattazione Markdown', () {
      expect(
        _note('# Titolo\n**grassetto** e `codice`').previewSnippet,
        'Titolo\ngrassetto e codice',
      );
    });

    test('di un link mostra il testo, non il letterale "\$1"', () {
      expect(
        _note('Vedi [la guida](https://example.com) ora').previewSnippet,
        'Vedi la guida ora',
      );
    });

    test('rimuove i marcatori delle checklist', () {
      final snippet = _note('- [ ] da fare\n- [x] fatto').previewSnippet;
      expect(snippet, contains('da fare'));
      expect(snippet, contains('fatto'));
      expect(snippet, isNot(contains('[')));
    });

    test('tronca a 120 caratteri aggiungendo i puntini', () {
      expect(_note('a' * 500).previewSnippet, '${'a' * 120}...');
      expect(_note('a' * 120).previewSnippet, 'a' * 120);
    });

    test('su una nota molto lunga basta il prefisso del testo', () {
      expect(_note('x' * 100000).previewSnippet, '${'x' * 120}...');
    });

    test('se l\'inizio è quasi tutto markup ripulisce l\'intero contenuto', () {
      final content = '${'#' * 5000} testo finale visibile';
      expect(_note(content).previewSnippet, 'testo finale visibile');
    });

    test('è calcolato una volta sola per istanza', () {
      final note = _note('contenuto');
      expect(identical(note.previewSnippet, note.previewSnippet), isTrue);
    });
  });
}
