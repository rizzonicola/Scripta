/// Supporto alla sintassi matematica (LaTeX) per la vista di lettura.
///
/// Dart puro, senza dipendenze da Flutter né da `flutter_md`, così da poter
/// essere testato in isolamento (vedi `test/markdown_math_test.dart`).
///
/// Il rendering è a due livelli, perché `flutter_md` disegna ogni blocco su
/// canvas e NON può ospitare widget dentro un paragrafo:
///
///  * **Formule inline `$...$`** — restano dentro il paragrafo e sono rese
///    dal parser di `flutter_md` (`inlineMath: true`), che converte comandi
///    LaTeX e apici/pedici in Unicode (es. `$\text{CO}_2$` → CO₂).
///    [normalizeInlineMath] prepara il sorgente per quel parser, gestendo
///    alcuni costrutti comuni che il pacchetto non copre (`\text{..}`,
///    spaziature, `\frac`/`\sqrt` semplici).
///  * **Formule a blocco `$$...$$`** — vengono estratte da
///    [splitNoteChunks] come [DisplayMathChunk] e renderizzate come widget
///    a sé (layout 2D reale, vedi `display_math_block.dart`).
library;

/// Un tratto contiguo del sorgente di una nota.
sealed class NoteChunk {
  const NoteChunk();
}

/// Markdown "normale" (può contenere formule inline `$...$`).
final class MarkdownChunk extends NoteChunk {
  const MarkdownChunk(this.source);
  final String source;
}

/// Formula a blocco `$$...$$`; [tex] è il contenuto senza i delimitatori.
final class DisplayMathChunk extends NoteChunk {
  const DisplayMathChunk(this.tex);
  final String tex;
}

final RegExp _fenceOpen = RegExp(r'^(`{3,}|~{3,})');

int _indentOf(String line) {
  var n = 0;
  for (final unit in line.codeUnits) {
    if (unit == 0x20) {
      n++;
    } else if (unit == 0x09) {
      n += 4;
    } else {
      break;
    }
  }
  return n;
}

bool _closesFence(String trimmed, String fence) {
  if (trimmed.length < fence.length) return false;
  final ch = fence[0];
  for (var i = 0; i < trimmed.length; i++) {
    if (trimmed[i] != ch) return false;
  }
  return true;
}

/// Divide il sorgente in tratti Markdown e formule a blocco `$$...$$`.
///
/// I delimitatori dentro i code fence (``` / ~~~) e i blocchi di codice
/// indentati (≥ 4 spazi) sono ignorati. Un `$$` non chiuso, o che incontra
/// una riga vuota prima della chiusura, NON viene trattato come formula e
/// resta testo normale (così un `$$` isolato non inghiotte il resto della
/// nota).
List<NoteChunk> splitNoteChunks(String source) {
  final lines = source.split('\n');
  final chunks = <NoteChunk>[];
  final buffer = <String>[];
  String? fence;

  void flush() {
    if (buffer.isEmpty) return;
    chunks.add(MarkdownChunk(buffer.join('\n')));
    buffer.clear();
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trim();
    final indent = _indentOf(line);

    if (fence != null) {
      buffer.add(line);
      if (_closesFence(trimmed, fence)) fence = null;
      i++;
      continue;
    }

    if (indent < 4) {
      final open = _fenceOpen.firstMatch(trimmed);
      if (open != null) {
        fence = open.group(1);
        buffer.add(line);
        i++;
        continue;
      }
      if (trimmed.startsWith(r'$$')) {
        final math = _readDisplayMath(lines, i);
        if (math != null) {
          flush();
          chunks.add(DisplayMathChunk(math.tex));
          i = math.next;
          continue;
        }
      }
    }

    buffer.add(line);
    i++;
  }
  flush();
  return chunks;
}

({String tex, int next})? _readDisplayMath(List<String> lines, int start) {
  final afterOpen = lines[start].trim().substring(2);

  // Caso su una sola riga: `$$ ... $$`.
  if (afterOpen.endsWith(r'$$') && !afterOpen.endsWith(r'\$$')) {
    final inner = afterOpen.substring(0, afterOpen.length - 2);
    if (inner.contains(r'$$')) return null;
    final tex = inner.trim();
    return tex.isEmpty ? null : (tex: tex, next: start + 1);
  }

  // `$$x$$ testo` (formula seguita da altro sulla stessa riga): non è un
  // blocco, lasciamo la riga al parser inline.
  if (afterOpen.contains(r'$$')) return null;

  // Caso multi-riga.
  final parts = <String>[];
  if (afterOpen.trim().isNotEmpty) parts.add(afterOpen.trim());
  for (var j = start + 1; j < lines.length; j++) {
    final t = lines[j].trim();
    if (t.isEmpty) return null; // niente righe vuote: `$$` non chiuso.
    if (t.endsWith(r'$$')) {
      final before = t.substring(0, t.length - 2).trim();
      if (before.contains(r'$$')) return null;
      if (before.isNotEmpty) parts.add(before);
      final tex = parts.join('\n').trim();
      return tex.isEmpty ? null : (tex: tex, next: j + 1);
    }
    if (t.contains(r'$$')) return null;
    parts.add(t);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Formule inline
// ---------------------------------------------------------------------------

// `$...$` con le regole "alla pandoc" per non confondere le valute:
// dopo l'apertura non c'è spazio, prima della chiusura non c'è spazio e dopo
// la chiusura non c'è una cifra ("costa $5 e $10" NON è una formula).
// `\$` è un dollaro letterale.
final RegExp _inlineMath = RegExp(
  r'(?<![\\$])\$(?![\s$])((?:[^$\n\\]|\\.)*?[^\s$\\])\$(?![\d$])',
);

final RegExp _codeSpan = RegExp(r'(`+).+?\1');

final RegExp _textLikeCommand = RegExp(
  r'\\(?:text|textrm|textbf|textit|textsf|texttt|mathrm|mathbf|mathit|mathsf|'
  r'mathtt|mathbb|mathcal|operatorname|mbox)\s*\{([^{}]*)\}',
);
final RegExp _fracCommand = RegExp(r'\\[dt]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}');
final RegExp _sqrtCommand = RegExp(r'\\sqrt\s*\{([^{}]*)\}');
final RegExp _leftRight = RegExp(r'\\(?:left|right)(?![a-zA-Z])');
final RegExp _thinSpaces = RegExp(r'\\[,;:]');
final RegExp _simpleOperand = RegExp(r'^[\w.]+$', unicode: true);

String _paren(String s) {
  final t = s.trim();
  return _simpleOperand.hasMatch(t) ? t : '($t)';
}

/// Riduce alcuni costrutti LaTeX comuni a una forma che il convertitore
/// inline di `flutter_md` sa rendere. Opera SOLO sul contenuto di una
/// formula (senza i `$`).
String normalizeTexForInline(String tex) {
  var out = tex;
  // Il contenuto di \text{..}/\mathrm{..} è testo: si toglie il comando e
  // si tiene il contenuto (`\text{CO}_2` → `CO_2` → CO₂). Più passate per
  // gestire annidamenti semplici.
  for (var i = 0; i < 3 && _textLikeCommand.hasMatch(out); i++) {
    out = out.replaceAllMapped(_textLikeCommand, (m) => m.group(1)!);
  }
  out = out.replaceAllMapped(
    _fracCommand,
    (m) => '${_paren(m.group(1)!)}/${_paren(m.group(2)!)}',
  );
  out = out.replaceAllMapped(
    _sqrtCommand,
    (m) => '√${_paren(m.group(1)!)}',
  );
  out = out.replaceAll(_leftRight, '');
  out = out.replaceAll(_thinSpaces, ' ');
  out = out.replaceAll(r'\!', '');
  return out;
}

String _normalizeInlineSegment(String segment) {
  if (!segment.contains(r'$')) return segment;
  return segment.replaceAllMapped(
    _inlineMath,
    (m) => '\$${normalizeTexForInline(m.group(1)!)}\$',
  );
}

String _normalizeInlineLine(String line) {
  if (!line.contains(r'$')) return line;
  final out = StringBuffer();
  var last = 0;
  for (final m in _codeSpan.allMatches(line)) {
    out.write(_normalizeInlineSegment(line.substring(last, m.start)));
    out.write(m.group(0));
    last = m.end;
  }
  out.write(_normalizeInlineSegment(line.substring(last)));
  return out.toString();
}

/// Prepara un tratto Markdown per il parser con `inlineMath: true`.
///
/// Non tocca code fence, blocchi indentati né code span inline.
String normalizeInlineMath(String markdown) {
  if (!markdown.contains(r'$')) return markdown;
  final lines = markdown.split('\n');
  String? fence;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();
    if (fence != null) {
      if (_closesFence(trimmed, fence)) fence = null;
      continue;
    }
    final indent = _indentOf(line);
    if (indent >= 4) continue;
    final open = _fenceOpen.firstMatch(trimmed);
    if (open != null) {
      fence = open.group(1);
      continue;
    }
    lines[i] = _normalizeInlineLine(line);
  }
  return lines.join('\n');
}
