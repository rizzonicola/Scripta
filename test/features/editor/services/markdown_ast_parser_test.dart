import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/features/editor/models/markdown_ast_nodes.dart';
import 'package:scripta/features/editor/services/markdown_ast_parser.dart';

/// Verifica ricorsivamente, per ogni nodo dell'albero, l'invariante di
/// round-trip fondamentale su cui si basa l'intera mappatura O(1)/O(log N)
/// tra offset e nodo: `source.substring(start, end)` deve corrispondere
/// esattamente al testo che il nodo dichiara di coprire, gli offset dei
/// figli devono ricadere entro quelli del genitore, e la lista di
/// fratelli deve essere ordinata e non sovrapposta (precondizione delle
/// ricerche binarie del lookup engine).
void expectValidTree(String source, List<MarkdownNode> nodes, {MarkdownNode? parent}) {
  var previousEnd = parent?.startOffset ?? 0;
  for (final node in nodes) {
    expect(node.startOffset, greaterThanOrEqualTo(0));
    expect(node.endOffset, greaterThanOrEqualTo(node.startOffset));
    expect(node.endOffset, lessThanOrEqualTo(source.length));
    expect(
      node.startOffset,
      greaterThanOrEqualTo(previousEnd),
      reason: 'I nodi fratelli devono essere ordinati e non sovrapposti',
    );
    if (parent != null) {
      expect(node.startOffset, greaterThanOrEqualTo(parent.startOffset));
      expect(node.endOffset, lessThanOrEqualTo(parent.endOffset));
    }
    previousEnd = node.endOffset;
    if (node.children.isNotEmpty) {
      expectValidTree(source, node.children, parent: node);
    }
  }
}

void main() {
  const parser = MarkdownAstParser();

  group('Heading', () {
    test('offset e livello di un titolo ATX semplice', () {
      const source = '# Titolo principale';
      final blocks = parser.parse(source);

      expect(blocks, hasLength(1));
      final heading = blocks.single as HeadingNode;
      expect(heading.type, MarkdownNodeType.heading);
      expect(heading.level, 1);
      expect(heading.text, 'Titolo principale');
      expect(heading.startOffset, 0);
      expect(heading.endOffset, source.length);
      expect(source.substring(heading.startOffset, heading.endOffset), source);
    });

    test('livelli multipli e hash di chiusura opzionali', () {
      const source = '## Secondo livello ##\n\n### Terzo livello';
      final blocks = parser.parse(source);

      expect(blocks, hasLength(2));
      final h2 = blocks[0] as HeadingNode;
      final h3 = blocks[1] as HeadingNode;
      expect(h2.level, 2);
      expect(h2.text, 'Secondo livello');
      expect(h3.level, 3);
      expect(h3.text, 'Terzo livello');
      expectValidTree(source, blocks);
    });

    test('un cancelletto senza spazio non è un titolo', () {
      const source = '#nonèunTitolo';
      final blocks = parser.parse(source);
      expect(blocks.single, isA<ParagraphNode>());
    });
  });

  group('Paragraph', () {
    test('paragrafo singolo con offset esatti', () {
      const source = 'Questo è un paragrafo di prova.';
      final blocks = parser.parse(source);

      final paragraph = blocks.single as ParagraphNode;
      expect(paragraph.startOffset, 0);
      expect(paragraph.endOffset, source.length);
      expect(paragraph.text, source);
    });

    test('due paragrafi separati da riga vuota', () {
      const source = 'Primo paragrafo.\n\nSecondo paragrafo su\ndue righe.';
      final blocks = parser.parse(source);

      expect(blocks, hasLength(2));
      final p1 = blocks[0] as ParagraphNode;
      final p2 = blocks[1] as ParagraphNode;
      expect(source.substring(p1.startOffset, p1.endOffset), 'Primo paragrafo.');
      expect(
        source.substring(p2.startOffset, p2.endOffset),
        'Secondo paragrafo su\ndue righe.',
      );
      expectValidTree(source, blocks);
    });
  });

  group('CodeBlock', () {
    test('blocco di codice con linguaggio', () {
      const source = '```dart\nfinal x = 1;\nprint(x);\n```';
      final blocks = parser.parse(source);

      final code = blocks.single as CodeBlockNode;
      expect(code.language, 'dart');
      expect(code.code, 'final x = 1;\nprint(x);');
      expect(source.substring(code.startOffset, code.endOffset), source);
    });

    test('blocco di codice senza linguaggio e senza fence di chiusura', () {
      const source = '```\ncontenuto non terminato';
      final blocks = parser.parse(source);

      final code = blocks.single as CodeBlockNode;
      expect(code.language, isNull);
      expect(code.code, 'contenuto non terminato');
      expect(source.substring(code.startOffset, code.endOffset), source);
    });

    test('un blocco di codice interrompe un paragrafo circostante', () {
      const source = 'Prima del codice\n```\nx = 1\n```\nDopo il codice';
      final blocks = parser.parse(source);

      expect(blocks, hasLength(3));
      expect(blocks[0], isA<ParagraphNode>());
      expect(blocks[1], isA<CodeBlockNode>());
      expect(blocks[2], isA<ParagraphNode>());
      expectValidTree(source, blocks);
    });
  });

  group('MathBlock', () {
    test('formula su una sola riga', () {
      const source = r'$$E = mc^2$$';
      final blocks = parser.parse(source);

      final math = blocks.single as MathBlockNode;
      expect(math.expression, 'E = mc^2');
      expect(source.substring(math.startOffset, math.endOffset), source);
    });

    test('formula multilinea', () {
      const source = '\$\$\nx = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}\n\$\$';
      final blocks = parser.parse(source);

      final math = blocks.single as MathBlockNode;
      expect(math.expression, r'x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}');
      expect(source.substring(math.startOffset, math.endOffset), source);
    });
  });

  group('ListBlock', () {
    test('lista puntata semplice con offset esatti per ogni item', () {
      const source = '- item one\n- item two\n- item three';
      final blocks = parser.parse(source);

      final list = blocks.single as ListBlockNode;
      expect(list.ordered, isFalse);
      expect(list.items, hasLength(3));
      expect(source.substring(list.startOffset, list.endOffset), source);

      final expectedItems = ['- item one', '- item two', '- item three'];
      for (var i = 0; i < list.items.length; i++) {
        final item = list.items[i];
        expect(source.substring(item.startOffset, item.endOffset), expectedItems[i]);
      }
      expectValidTree(source, blocks);
    });

    test('lista numerata con numero di partenza personalizzato', () {
      const source = '3. terzo\n4. quarto';
      final blocks = parser.parse(source);

      final list = blocks.single as ListBlockNode;
      expect(list.ordered, isTrue);
      expect(list.start, 3);
      expect(list.items, hasLength(2));
    });

    test('lista annidata: gli item padre hanno una ListBlockNode figlia', () {
      const source = '- padre\n  - figlio uno\n  - figlio due\n- secondo padre';
      final blocks = parser.parse(source);

      final list = blocks.single as ListBlockNode;
      expect(list.items, hasLength(2));

      final firstItem = list.items[0];
      final nestedList = firstItem.children.whereType<ListBlockNode>().single;
      expect(nestedList.items, hasLength(2));
      expect(
        source.substring(nestedList.items[0].startOffset, nestedList.items[0].endOffset),
        '- figlio uno',
      );
      expect(
        source.substring(nestedList.items[1].startOffset, nestedList.items[1].endOffset),
        '- figlio due',
      );
      expectValidTree(source, blocks);
    });

    test('item con paragrafo su più righe (continuazione indentata)', () {
      const source = '- prima riga\n  continuazione della stessa riga\n- secondo item';
      final blocks = parser.parse(source);

      final list = blocks.single as ListBlockNode;
      final firstItemParagraph = list.items[0].children.single as ParagraphNode;
      expect(firstItemParagraph.text, 'prima riga\ncontinuazione della stessa riga');
    });
  });

  group('TableBlock', () {
    test('tabella con intestazione, allineamenti e righe dati', () {
      const source = '| Nome | Età |\n| :--- | ---: |\n| Ada | 32 |\n| Grace | 40 |';
      final blocks = parser.parse(source);

      final table = blocks.single as TableBlockNode;
      expect(table.headers, ['Nome', 'Età']);
      expect(table.alignments, [TableColumnAlignment.left, TableColumnAlignment.right]);
      expect(table.dataRows, [
        ['Ada', '32'],
        ['Grace', '40'],
      ]);
      expect(table.columnCount, 2);
      // header + 2 righe dati = 3 TableRowNode figlie
      expect(table.rows, hasLength(3));
      expect(table.rows.first.isHeader, isTrue);
      expect(source.substring(table.startOffset, table.endOffset), source);
      expectValidTree(source, blocks);
    });

    test('una tabella può interrompere un paragrafo senza riga vuota', () {
      const source = 'Vedi la tabella:\n| A | B |\n|---|---|\n| 1 | 2 |';
      final blocks = parser.parse(source);

      expect(blocks, hasLength(2));
      expect(blocks[0], isA<ParagraphNode>());
      expect(blocks[1], isA<TableBlockNode>());
    });
  });

  group('Blockquote', () {
    test('blockquote con paragrafo interno, offset del figlio corretti', () {
      const source = '> Citazione importante\n> su due righe';
      final blocks = parser.parse(source);

      final quote = blocks.single as BlockquoteNode;
      final inner = quote.children.single as ParagraphNode;
      expect(inner.text, 'Citazione importante\nsu due righe');
      expect(source.substring(quote.startOffset, quote.endOffset), source);
      expectValidTree(source, blocks);
    });

    test('blockquote annidata', () {
      const source = '> esterna\n> > interna';
      final blocks = parser.parse(source);

      final outer = blocks.single as BlockquoteNode;
      final inner = outer.children.whereType<BlockquoteNode>().single;
      final innerParagraph = inner.children.single as ParagraphNode;
      expect(innerParagraph.text, 'interna');
      expect(
        source.substring(innerParagraph.startOffset, innerParagraph.endOffset),
        'interna',
      );
    });
  });

  group('ThematicBreak', () {
    test('separatore orizzontale distinto da un item di lista', () {
      const source = 'Sopra\n\n---\n\nSotto';
      final blocks = parser.parse(source);

      expect(blocks, hasLength(3));
      expect(blocks[1], isA<ThematicBreakNode>());
    });
  });

  group('Documento composito', () {
    const composite = '''
# Nota di esempio

Un paragrafo introduttivo con del testo.

## Elenco puntti chiave

- primo punto
- secondo punto
  - punto annidato
- terzo punto

```dart
void main() => print('ciao');
```

| Colonna A | Colonna B |
| --- | --- |
| 1 | 2 |

> Una citazione finale.
''';

    test("l'albero risultante è interamente valido (round-trip + ordinamento)", () {
      final blocks = parser.parse(composite);
      expect(blocks, isNotEmpty);
      expectValidTree(composite, blocks);
    });

    test('getNodeAtOffset risolve il nodo più specifico per una posizione', () {
      final document = parser.parseDocument(composite);
      final headingOffset = composite.indexOf('# Nota di esempio') + 2;
      final node = document.getNodeAtOffset(headingOffset);
      expect(node, isA<HeadingNode>());
      expect((node as HeadingNode).text, 'Nota di esempio');
    });

    test('getNodeAtOffset scende fino al paragrafo dentro un item di lista', () {
      final document = parser.parseDocument(composite);
      final offset = composite.indexOf('punto annidato') + 3;
      final node = document.getNodeAtOffset(offset);
      expect(node, isA<ParagraphNode>());
      expect((node as ParagraphNode).text, contains('punto annidato'));
    });

    test('getNodeAtOffset restituisce null fuori dai limiti del documento', () {
      final document = parser.parseDocument(composite);
      expect(document.getNodeAtOffset(-1), isNull);
      expect(document.getNodeAtOffset(composite.length + 1000), isNull);
    });

    test('getNodesInOffsetRange restituisce tutti i nodi che intersecano il range', () {
      final document = parser.parseDocument(composite);
      final start = composite.indexOf('- primo punto');
      final end = composite.indexOf('```dart');
      final nodes = document.getNodesInOffsetRange(start, end);

      expect(nodes, isNotEmpty);
      expect(nodes.any((n) => n is ListBlockNode), isTrue);
      for (final node in nodes) {
        expect(node.startOffset < end && node.endOffset > start, isTrue);
      }
    });

    test('extractSourceText restituisce esattamente il testo di un nodo', () {
      final document = parser.parseDocument(composite);
      final table = document.blocks.whereType<TableBlockNode>().single;
      final extracted = document.extractSourceText(table.startOffset, table.endOffset);
      expect(extracted, composite.substring(table.startOffset, table.endOffset));
      expect(extracted, startsWith('| Colonna A'));
    });

    test('extractSourceText troncala (clamp) invece di lanciare eccezioni fuori range', () {
      final document = parser.parseDocument(composite);
      expect(() => document.extractSourceText(-10, 5), returnsNormally);
      expect(() => document.extractSourceText(0, composite.length + 500), returnsNormally);
    });
  });

  group('MarkdownAstParser.parseAsync', () {
    test('per un documento piccolo restituisce lo stesso risultato di parse', () async {
      const source = '# Titolo\n\nUn paragrafo.';
      final sync = parser.parse(source);
      final async = await parser.parseAsync(source);

      expect(async, hasLength(sync.length));
      expect(async.first.runtimeType, sync.first.runtimeType);
    });

    test('per un documento grande (isolate dedicato) produce un albero valido', () async {
      final large = List.generate(
        30,
        (i) => '## Sezione $i\n\nContenuto della sezione numero $i con qualche parola in più.',
      ).join('\n\n');
      // Forziamo il ramo isolate abbassando artificialmente la soglia non è
      // possibile da qui (è una costante), quindi verifichiamo invece che,
      // qualunque sia il percorso scelto, il risultato sia identico e
      // valido: è la proprietà osservabile che conta per il chiamante.
      final blocks = await parser.parseAsync(large);
      expectValidTree(large, blocks);
      expect(blocks.whereType<HeadingNode>().length, 30);
    });
  });

  group('Performance', () {
    test('un documento di circa 50.000 parole viene parsato rapidamente', () {
      final buffer = StringBuffer();
      for (var i = 0; i < 2000; i++) {
        buffer.writeln('## Sezione $i');
        buffer.writeln();
        buffer.writeln(
          'Questa è una frase di prova ripetuta più volte per simulare un paragrafo '
          'realistico di appunti con diverse parole e una lunghezza ragionevole così '
          'da raggiungere circa cinquantamila parole nel documento complessivo.',
        );
        buffer.writeln();
        buffer.writeln('- primo punto della sezione $i');
        buffer.writeln('- secondo punto della sezione $i');
        buffer.writeln();
      }
      final source = buffer.toString();
      final wordCount = source.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      expect(wordCount, greaterThan(45000));

      final stopwatch = Stopwatch()..start();
      final blocks = parser.parse(source);
      stopwatch.stop();

      // Obiettivo di prodotto: < 16ms su hardware desktop/mobile moderno
      // (vedi dartdoc di `MarkdownAstParser.parse`). La soglia qui è
      // volutamente più permissiva per assorbire la varianza delle
      // macchine CI, che possono essere sensibilmente più lente di un
      // dispositivo target; l'obiettivo stretto resta comunque verificato
      // "a occhio" tramite il valore stampato in console.
      // ignore: avoid_print
      print('Parsing di ${source.length} caratteri (~$wordCount parole) in '
          '${stopwatch.elapsedMilliseconds}ms');
      expect(stopwatch.elapsedMilliseconds, lessThan(500));
      expect(blocks, isNotEmpty);
    });
  });
}
