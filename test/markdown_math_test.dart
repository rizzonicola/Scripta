import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/utils/markdown_math.dart';

void main() {
  group('splitNoteChunks', () {
    test('senza formule restituisce un solo tratto Markdown', () {
      final chunks = splitNoteChunks('# Titolo\n\ntesto');
      expect(chunks, hasLength(1));
      expect(chunks.single, isA<MarkdownChunk>());
    });

    test('estrae una formula a blocco su una riga', () {
      final chunks = splitNoteChunks('prima\n\$\$ E = mc^2 \$\$\ndopo');
      expect(chunks, hasLength(3));
      expect((chunks[1] as DisplayMathChunk).tex, 'E = mc^2');
    });

    test('estrae una formula a blocco multi-riga', () {
      final chunks = splitNoteChunks(
        'a\n\$\$\n\\frac{a}{b}\n+ c\n\$\$\nb',
      );
      expect(chunks, hasLength(3));
      expect((chunks[1] as DisplayMathChunk).tex, '\\frac{a}{b}\n+ c');
    });

    test('ignora \$\$ dentro i code fence', () {
      const src = '```\n\$\$\nx\n\$\$\n```';
      final chunks = splitNoteChunks(src);
      expect(chunks, hasLength(1));
      expect(chunks.single, isA<MarkdownChunk>());
    });

    test('un \$\$ non chiuso resta testo normale', () {
      final chunks = splitNoteChunks('\$\$\nx\n\ntesto dopo senza chiusura');
      expect(chunks.whereType<DisplayMathChunk>(), isEmpty);
    });

    test('tollera righe vuote interne se la chiusura arriva entro 30 righe', () {
      const src = '\$\$\nx = 1\n\ny = 2\n\$\$';
      final chunks = splitNoteChunks(src);
      expect(chunks.whereType<DisplayMathChunk>(), hasLength(1));
      expect(chunks.whereType<DisplayMathChunk>().first.tex, 'x = 1\n\ny = 2');
    });

    test('un \$\$ che non si chiude entro 30 righe viene rifiutato come blocco', () {
      final longText = [
        '\$\$',
        for (var i = 0; i < 35; i++) 'riga $i',
        '\$\$',
      ].join('\n');
      final chunks = splitNoteChunks(longText);
      // Non deve essere accoppiato perché supera le 30 righe
      expect(chunks.whereType<DisplayMathChunk>(), isEmpty);
    });

    test('un \$\$ orfano seguito da intestazione Markdown non inghiotte la formula successiva', () {
      const src = '''
\$\$
questa era una formula mai chiusa

# Titolo della sezione
Testo descrittivo normale

\$\$
x = 42
\$\$
''';
      final chunks = splitNoteChunks(src);
      // Solo la vera formula deve essere estratta
      final mathChunks = chunks.whereType<DisplayMathChunk>().toList();
      expect(mathChunks, hasLength(1));
      expect(mathChunks.single.tex, 'x = 42');
    });

    test('due righe vuote consecutive dentro un \$\$ aperto ne determinano l\'abbandono', () {
      const src = '''
\$\$
passo 1


passo 2
\$\$
''';
      final chunks = splitNoteChunks(src);
      expect(chunks.whereType<DisplayMathChunk>(), isEmpty);
    });

    test('formula multi-riga con sottrazione a inizio riga (- c) resta valida', () {
      const src = '''
\$\$
a = b
- c
\$\$
''';
      final chunks = splitNoteChunks(src);
      expect(chunks.whereType<DisplayMathChunk>(), hasLength(1));
      expect(chunks.whereType<DisplayMathChunk>().first.tex, 'a = b\n- c');
    });

    test('\$\$x\$\$ seguito da testo sulla stessa riga non è un blocco', () {
      final chunks = splitNoteChunks('\$\$x\$\$ e altro');
      expect(chunks.whereType<DisplayMathChunk>(), isEmpty);
    });
  });

  group('normalizeInlineMath', () {
    test(r'\text{CO}_2 diventa CO_2', () {
      expect(normalizeInlineMath(r'aria: $\text{CO}_2$'), r'aria: $CO_2$');
    });

    test('non tocca valute', () {
      const src = r'costa $5 e $10';
      expect(normalizeInlineMath(src), src);
    });

    test('non tocca code span né code fence', () {
      const inline = r'usa `echo $HOME e $PATH` qui';
      expect(normalizeInlineMath(inline), inline);
      const fenced = '```\n\$\\text{a}\$\n```';
      expect(normalizeInlineMath(fenced), fenced);
    });

    test(r'\$ è un dollaro letterale', () {
      const src = r'\$\alpha\$';
      expect(normalizeInlineMath(src), src);
    });

    test('solo testo: toglie i \$ (es. formula chimica senza pedici)', () {
      expect(normalizeInlineMath(r'Ossido ($\text{BaO}$) +'), r'Ossido (BaO) +');
    });

    test('con pedici/apici mantiene i \$ per il parser di flutter_md', () {
      expect(normalizeInlineMath(r'$\text{H}_2\text{O}$'), r'$H_2O$');
      expect(normalizeInlineMath(r'$E = mc^2$'), r'$E = mc^2$');
    });

    test('frazioni e radici semplici diventano testo lineare', () {
      expect(normalizeInlineMath(r'$\frac{1}{2}$'), '1/2');
      expect(normalizeInlineMath(r'$\frac{a+b}{c}$'), '(a+b)/c');
      expect(normalizeInlineMath(r'$\sqrt{x+1}$'), '√(x+1)');
    });
  });
}
