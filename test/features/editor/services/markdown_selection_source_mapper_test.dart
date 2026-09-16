import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/features/editor/services/markdown_ast_parser.dart';
import 'package:scripta/features/editor/services/markdown_selection_source_mapper.dart';

void main() {
  const parser = MarkdownAstParser();

  MarkdownSelectionSourceMapper mapperFor(String source) {
    final document = parser.parseDocument(source);
    return MarkdownSelectionSourceMapper(document);
  }

  group('MarkdownInlineTextMapper', () {
    const inline = MarkdownInlineTextMapper();

    test('testo semplice senza sintassi resta invariato', () {
      final r = inline.map('ciao mondo', 0);
      expect(r.text, 'ciao mondo');
      expect(r.offsets, List<int>.generate(11, (i) => i));
    });

    test('grassetto: il testo renderizzato non contiene gli asterischi', () {
      final r = inline.map('un **grassetto** qui', 0);
      expect(r.text, 'un grassetto qui');
    });

    test('corsivo e grassetto annidati', () {
      final r = inline.map('**bold *and italic* end**', 0);
      expect(r.text, 'bold and italic end');
    });

    test('codice inline: contenuto letterale', () {
      final r = inline.map('usa `print(x)` qui', 0);
      expect(r.text, 'usa print(x) qui');
    });

    test('link: solo il testo visibile viene emesso', () {
      final r = inline.map('vedi [Scripta](https://example.com) qui', 0);
      expect(r.text, 'vedi Scripta qui');
    });

    test('immagine: nessun testo selezionabile prodotto', () {
      final r = inline.map('foto: ![alt](img.png) fine', 0);
      expect(r.text, 'foto:  fine');
    });
  });

  group('MarkdownSelectionSourceMapper — round trip esatto', () {
    test('selezione di un intero paragrafo semplice', () {
      const source = 'Questo è un paragrafo di prova.';
      final mapper = mapperFor(source);

      final result = mapper.resolveSourceTextForSelection(source);

      expect(result, isNotNull);
      expect(result!.text, source);
      expect(result.exactMatch, isTrue);
    });

    test('selezione parziale di un paragrafo con grassetto preserva la sintassi', () {
      const source = 'Il **gatto** dorme sul tappeto.';
      final mapper = mapperFor(source);

      // L'utente vede/seleziona "gatto" (senza asterischi).
      final result = mapper.resolveSourceTextForSelection('gatto');

      expect(result, isNotNull);
      expect(result!.text, '**gatto**');
    });

    test('code block: il testo copiato è verbatim, identico al sorgente', () {
      const source = '```dart\nvoid main() {\n  print(1);\n}\n```';
      final mapper = mapperFor(source);
      final document = parser.parseDocument(source);
      final code = (document.blocks.single as CodeBlockNode).code;

      final result = mapper.resolveSourceTextForSelection(code);

      expect(result, isNotNull);
      expect(result!.text, code);
    });

    test('titolo con formattazione inline: sintassi preservata alla copia', () {
      const source = '# Titolo con **enfasi**';
      final mapper = mapperFor(source);

      final result = mapper.resolveSourceTextForSelection('Titolo con enfasi');

      expect(result, isNotNull);
      expect(result!.text, 'Titolo con **enfasi**');
    });

    test('selezione multi-blocco: paragrafo + titolo successivo per intero', () {
      const source = 'Primo paragrafo.\n\n## Secondo blocco';
      final mapper = mapperFor(source);

      final rendered = 'Primo paragrafo.\nSecondo blocco';
      final result = mapper.resolveSourceTextForSelection(rendered);

      expect(result, isNotNull);
      expect(result!.text, source);
    });

    test('tabella: qualunque selezione al suo interno restituisce l\'intero blocco', () {
      const source = '| A | B |\n| --- | --- |\n| 1 | 2 |';
      final mapper = mapperFor(source);

      final result = mapper.resolveSourceTextForSelection('1 | 2');

      expect(result, isNotNull);
      expect(result!.text, source);
    });

    test('testo non trovato restituisce null (nessuna corrispondenza affidabile)', () {
      const source = 'Testo qualunque.';
      final mapper = mapperFor(source);

      final result = mapper.resolveSourceTextForSelection('frase mai apparsa nel documento');

      expect(result, isNull);
    });

    test('link: preserva la sintassi completa se la selezione coincide con il testo del link', () {
      const source = 'Vedi [Scripta](https://example.com) per saperne di più.';
      final mapper = mapperFor(source);

      final result = mapper.resolveSourceTextForSelection('Scripta');

      expect(result, isNotNull);
      expect(result!.text, '[Scripta](https://example.com)');
    });

    test('selezione interna a un grassetto (non ai bordi) resta senza asterischi', () {
      const source = 'Il **gattone** dorme.';
      final mapper = mapperFor(source);

      // "att" è strettamente interno a "gattone": non tocca i bordi del
      // grassetto, quindi non deve "risucchiare" i delimitatori.
      final result = mapper.resolveSourceTextForSelection('att');

      expect(result, isNotNull);
      expect(result!.text, 'att');
    });
  });

  group('MarkdownSelectionSourceMapper — liste e blockquote', () {
    test('un item di lista non include il marcatore nel testo copiato', () {
      const source = '- Primo elemento\n- Secondo elemento';
      final mapper = mapperFor(source);

      final result = mapper.resolveSourceTextForSelection('Primo elemento');

      expect(result, isNotNull);
      expect(result!.text, 'Primo elemento');
      expect(result.text.contains('-'), isFalse);
    });

    test('blockquote: il paragrafo interno mantiene la formattazione', () {
      const source = '> Una citazione con **enfasi**.';
      final mapper = mapperFor(source);

      final result = mapper.resolveSourceTextForSelection('enfasi');

      expect(result, isNotNull);
      expect(result!.text, '**enfasi**');
    });
  });

  group('MarkdownSelectionController', () {
    test('seleziona tutto: fullSourceText restituisce il documento intero', () {
      const source = '# Titolo\n\nUn **paragrafo**.';
      final controller = MarkdownSelectionController();
      controller.updateDocument(parser.parseDocument(source));

      expect(controller.fullSourceText, source);
    });

    test('nessuna selezione attiva: resolveClipboardText è null', () {
      final controller = MarkdownSelectionController();
      controller.updateDocument(parser.parseDocument('testo'));

      expect(controller.resolveClipboardText(), isNull);
      expect(controller.hasSelection, isFalse);
    });
  });
}
