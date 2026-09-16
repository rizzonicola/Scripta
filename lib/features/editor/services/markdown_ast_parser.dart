import 'dart:isolate';

import 'package:flutter/foundation.dart' show immutable;

import '../models/markdown_ast_nodes.dart';

/// Servizio che converte una stringa Markdown sorgente in un albero di
/// [MarkdownBlockNode] con mappatura esatta degli offset (vedi
/// `markdown_ast_nodes.dart`).
///
/// ISOLAMENTO: questo file opera esclusivamente su stringhe Dart in
/// memoria. Non importa né tocca in alcun modo DAO, database o servizi
/// di sincronizzazione: non ha alcuna conoscenza della persistenza delle
/// note, per costruzione.
///
/// NATIVE MARKDOWN FIRST: l'unica fonte di verità è la stringa Markdown
/// sorgente. Il parser non produce né richiede alcuna serializzazione
/// intermedia (JSON o altro): l'AST è una vista derivata, ricalcolabile
/// in qualunque momento dalla stessa stringa.
///
/// Il parsing dei blocchi è implementato "a mano", con una singola
/// scansione lineare del testo riga per riga: il pacchetto base
/// `package:markdown` non espone in modo affidabile gli offset di
/// carattere dei blocchi nel testo sorgente (traccia solo la struttura
/// ad albero del documento HTML risultante), mentre qui la mappatura
/// esatta start/end è un requisito di prodotto, non un dettaglio
/// implementativo. La scansione è O(n) nel numero di caratteri del
/// documento.
class MarkdownAstParser {
  const MarkdownAstParser();

  /// Sotto questa soglia (numero di caratteri) il parsing avviene in
  /// modo sincrono, sull'isolate corrente: per documenti di dimensioni
  /// tipiche di una nota (poche migliaia di parole) l'overhead di avvio
  /// di un isolate dedicato (spawn + trasferimento del messaggio di
  /// ritorno) supera il tempo di parsing stesso. Oltre la soglia, il
  /// lavoro viene spostato su un isolate dedicato per non bloccare mai
  /// l'UI thread, a costo di qualche millisecondo di overhead fisso.
  static const int isolateSizeThreshold = 20000;

  /// Esegue il parsing in modo sincrono, sull'isolate corrente.
  ///
  /// Per un documento di circa 50.000 parole la scansione lineare
  /// completa in un tempo dell'ordine di pochi millisecondi su hardware
  /// desktop/mobile moderno (vedi il benchmark in
  /// `test/features/editor/services/markdown_ast_parser_test.dart`).
  /// Per garantire di non bloccare mai l'UI thread indipendentemente
  /// dall'hardware, preferire [parseAsync].
  List<MarkdownBlockNode> parse(String source) => _parseBlocksFromScratch(source);

  /// Esegue il parsing spostando il lavoro su un isolate dedicato quando
  /// [source] supera [isolateSizeThreshold] caratteri, così da non
  /// bloccare mai l'UI thread per documenti di grandi dimensioni.
  Future<List<MarkdownBlockNode>> parseAsync(String source) async {
    if (source.length < isolateSizeThreshold) {
      return parse(source);
    }
    // `_parseBlocksFromScratch` è una funzione top-level pura (nessuna
    // chiusura su stato mutabile esterno), quindi eseguibile in un
    // isolate dedicato tramite `Isolate.run`: Dart copia `source` nel
    // nuovo isolate, esegue il parsing e restituisce l'albero risultante
    // al chiamante senza mai toccare l'UI thread nel frattempo.
    return Isolate.run(() => _parseBlocksFromScratch(source));
  }

  /// Come [parse], ma restituisce un [MarkdownAstDocument] che espone
  /// anche il testo sorgente e il motore di lookup per offset.
  MarkdownAstDocument parseDocument(String source) =>
      MarkdownAstDocument(source: source, blocks: parse(source));

  /// Come [parseAsync], ma restituisce un [MarkdownAstDocument].
  Future<MarkdownAstDocument> parseDocumentAsync(String source) async {
    final blocks = await parseAsync(source);
    return MarkdownAstDocument(source: source, blocks: blocks);
  }
}

/// Un AST Markdown già risolto, abbinato al testo sorgente da cui è
/// stato generato: fornisce i metodi di interrogazione per offset usati
/// dal motore di rendering per sapere, dato un punto nel testo (es. la
/// posizione del cursore nell'editor), quale nodo visivo gli corrisponde.
@immutable
class MarkdownAstDocument {
  /// Il testo Markdown sorgente completo, invariato.
  final String source;

  /// I nodi di primo livello dell'albero, in ordine di apparizione nel
  /// testo sorgente (invariante su cui si basano tutte le ricerche
  /// binarie sottostanti).
  final List<MarkdownBlockNode> blocks;

  const MarkdownAstDocument({required this.source, required this.blocks});

  /// Restituisce il nodo più profondo (foglia) che contiene [offset], o
  /// `null` se [offset] non ricade in alcun blocco (es. testo vuoto).
  ///
  /// Complessità: O(log N) per livello di annidamento attraversato
  /// (ricerca binaria tra fratelli, che sono sempre ordinati e non
  /// sovrapposti per costruzione), quindi O(log N) nel caso comune di
  /// documenti poco annidati.
  MarkdownNode? getNodeAtOffset(int offset) => _findNodeAtOffset(blocks, offset);

  /// Restituisce, in ordine di apparizione, tutti i nodi (a qualunque
  /// livello di annidamento) il cui range `[startOffset, endOffset)` si
  /// sovrappone all'intervallo semi-aperto `[start, end)` richiesto.
  ///
  /// Complessità: O(log N + K), dove K è il numero di nodi restituiti.
  List<MarkdownNode> getNodesInOffsetRange(int start, int end) {
    if (end <= start) return const [];
    return _findNodesInRange(blocks, start, end);
  }

  /// Estrae il testo sorgente esatto nell'intervallo semi-aperto
  /// `[start, end)`, tipicamente usato con gli offset di un nodo per
  /// ottenerne il testo grezzo originale (`extractSourceText(node
  /// .startOffset, node.endOffset)`). Gli estremi fuori range vengono
  /// troncati (clamp) invece di lanciare un'eccezione.
  String extractSourceText(int start, int end) {
    final safeStart = start.clamp(0, source.length);
    final safeEnd = end.clamp(safeStart, source.length);
    return source.substring(safeStart, safeEnd);
  }
}

// ============================================================================
// Lookup engine (ricerca binaria su liste di fratelli ordinate e non
// sovrapposte per costruzione).
// ============================================================================

MarkdownNode? _findNodeAtOffset(List<MarkdownNode> nodes, int offset) {
  var lo = 0;
  var hi = nodes.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final node = nodes[mid];
    if (offset < node.startOffset) {
      hi = mid - 1;
    } else if (offset > node.endOffset) {
      lo = mid + 1;
    } else {
      // offset è coperto (in modo inclusivo, vedi `containsOffset`) da
      // `node`: se ha figli, il nodo più specifico potrebbe essere tra
      // loro; altrimenti `node` stesso è la risposta.
      if (node.children.isEmpty) return node;
      return _findNodeAtOffset(node.children, offset) ?? node;
    }
  }
  return null;
}

List<MarkdownNode> _findNodesInRange(List<MarkdownNode> nodes, int start, int end) {
  if (nodes.isEmpty) return const [];
  // Lower bound: primo indice il cui nodo NON finisce prima di `start`
  // (cioè il primo che può potenzialmente sovrapporsi al range).
  var lo = 0;
  var hi = nodes.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (nodes[mid].endOffset <= start) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  final result = <MarkdownNode>[];
  for (var i = lo; i < nodes.length && nodes[i].startOffset < end; i++) {
    result.add(nodes[i]);
    if (nodes[i].children.isNotEmpty) {
      result.addAll(_findNodesInRange(nodes[i].children, start, end));
    }
  }
  return result;
}

// ============================================================================
// Indicizzazione delle righe: unica fonte di verità per la conversione
// tra indice di riga e offset di carattere assoluto nel testo sorgente
// passato a `_parseBlocksFromScratch` (che sia il documento originale o
// un sotto-testo dedentato ricostruito per il parsing ricorsivo di
// blockquote/list item).
// ============================================================================

/// Calcola, per ciascuna riga di [source], l'offset assoluto del suo
/// primo carattere. `starts[i]` è l'inizio della riga `i`;
/// `starts.length` è il numero totale di righe (un documento che
/// termina con `\n` ha quindi un'ultima riga vuota, coerentemente con la
/// convenzione comune negli editor di testo).
List<int> _computeLineStarts(String source) {
  final starts = <int>[0];
  for (var i = 0; i < source.length; i++) {
    if (source[i] == '\n') starts.add(i + 1);
  }
  return starts;
}

/// Il contenuto della riga [i] (senza l'eventuale `\n` finale).
String _lineText(String source, List<int> lineStarts, int i) {
  final start = lineStarts[i];
  final end = _lineEndOffsetExclusiveOfNewline(source, lineStarts, i);
  return source.substring(start, end);
}

/// L'offset (esclusivo) subito dopo l'ultimo carattere della riga [i],
/// SENZA includere l'a-capo che la separa dalla riga successiva (o la
/// fine stringa se [i] è l'ultima riga).
int _lineEndOffsetExclusiveOfNewline(String source, List<int> lineStarts, int i) {
  if (i + 1 < lineStarts.length) return lineStarts[i + 1] - 1;
  return source.length;
}

int _leadingSpaces(String s) {
  var n = 0;
  while (n < s.length && s[n] == ' ') n++;
  return n;
}

// ============================================================================
// Testo "mappato": usato per il parsing ricorsivo di sotto-blocchi
// (blockquote, item di lista) il cui contenuto viene estratto e
// "dedentato" (prefisso rimosso) in una stringa temporanea indipendente,
// poi riparsata da capo. `mapOffset` converte un offset nella stringa
// temporanea nell'offset assoluto corrispondente nel testo passato a
// `_buildMappedText` (che a sua volta può essere il documento originale
// o, per l'annidamento multiplo, una stringa già mappata di un livello
// superiore: la composizione di più `remapOffsets` applicati in
// sequenza, dal livello più interno a quello più esterno, converge
// correttamente all'offset assoluto nel documento originale).
// ============================================================================

class _MappedText {
  final String text;
  final List<int> _offsetMap; // lunghezza == text.length + 1

  const _MappedText(this.text, this._offsetMap);

  int mapOffset(int localOffset) {
    if (_offsetMap.isEmpty) return 0;
    if (localOffset <= 0) return _offsetMap.first;
    if (localOffset >= _offsetMap.length) return _offsetMap.last;
    return _offsetMap[localOffset];
  }
}

/// Costruisce il testo dedentato per le righe `[startLine,
/// endLineExclusive)` di [source], rimuovendo da ciascuna riga i primi
/// `stripCount(lineIndex, lineText)` caratteri (clampato alla lunghezza
/// della riga, per gestire correttamente le righe vuote), e l'offset map
/// che permette di risalire dagli indici del testo risultante agli
/// offset assoluti originali.
_MappedText _buildMappedText(
  String source,
  List<int> lineStarts,
  int startLine,
  int endLineExclusive,
  int Function(int lineIndex, String lineText) stripCount,
) {
  final buffer = StringBuffer();
  final offsetMap = <int>[];
  for (var li = startLine; li < endLineExclusive; li++) {
    final lineText = _lineText(source, lineStarts, li);
    final absoluteLineStart = lineStarts[li];
    final strip = stripCount(li, lineText).clamp(0, lineText.length);
    final kept = lineText.substring(strip);
    for (var k = 0; k < kept.length; k++) {
      offsetMap.add(absoluteLineStart + strip + k);
    }
    buffer.write(kept);
    if (li < endLineExclusive - 1) {
      buffer.write('\n');
      offsetMap.add(absoluteLineStart + strip + kept.length);
    }
  }
  final lastLine = endLineExclusive - 1;
  offsetMap.add(_lineEndOffsetExclusiveOfNewline(source, lineStarts, lastLine));
  return _MappedText(buffer.toString(), offsetMap);
}

// ============================================================================
// Pattern di riconoscimento dei blocchi. Compilati una sola volta a
// livello di libreria.
// ============================================================================

final RegExp _fenceOpenRegex = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');
final RegExp _closingBacktickFenceRegex = RegExp(r'^ {0,3}`{3,}[ \t]*$');
final RegExp _closingTildeFenceRegex = RegExp(r'^ {0,3}~{3,}[ \t]*$');

final RegExp _mathOpenRegex = RegExp(r'^ {0,3}\$\$');
final RegExp _mathSingleLineRegex = RegExp(r'^ {0,3}\$\$(.+)\$\$\s*$');
final RegExp _mathCloseRegex = RegExp(r'^ {0,3}\$\$\s*$');

final RegExp _atxHeadingRegex = RegExp(r'^ {0,3}(#{1,6})(?:\s+(.*?))?\s*#*\s*$');

final RegExp _blockquoteMarkerRegex = RegExp(r'^ {0,3}> ?');

final RegExp _listMarkerRegex = RegExp(r'^( *)([-*+]|\d{1,9}[.)]) (.*)$');

bool _isThematicBreak(String lineText) {
  final t = lineText.trim();
  if (t.length < 3) return false;
  final c = t[0];
  if (c != '-' && c != '*' && c != '_') return false;
  final compact = t.replaceAll(' ', '').replaceAll('\t', '');
  if (compact.length < 3) return false;
  for (var i = 0; i < compact.length; i++) {
    if (compact[i] != c) return false;
  }
  return true;
}

bool _looksLikeTableRow(String lineText) =>
    lineText.contains('|') && lineText.trim().isNotEmpty;

List<String> _splitTableRow(String lineText) {
  var t = lineText.trim();
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|') && !t.endsWith(r'\|')) t = t.substring(0, t.length - 1);
  final cells = <String>[];
  final buffer = StringBuffer();
  for (var i = 0; i < t.length; i++) {
    final ch = t[i];
    if (ch == r'\' && i + 1 < t.length && t[i + 1] == '|') {
      buffer.write('|');
      i++;
      continue;
    }
    if (ch == '|') {
      cells.add(buffer.toString().trim());
      buffer.clear();
    } else {
      buffer.write(ch);
    }
  }
  cells.add(buffer.toString().trim());
  return cells;
}

bool _isTableDelimiterRow(String lineText) {
  if (!lineText.contains('-')) return false;
  final cells = _splitTableRow(lineText);
  if (cells.isEmpty) return false;
  final delimCellRegex = RegExp(r'^:?-+:?$');
  return cells.every((c) => delimCellRegex.hasMatch(c.trim()));
}

TableColumnAlignment _parseAlignment(String cell) {
  final c = cell.trim();
  final left = c.startsWith(':');
  final right = c.endsWith(':');
  if (left && right) return TableColumnAlignment.center;
  if (right) return TableColumnAlignment.right;
  if (left) return TableColumnAlignment.left;
  return TableColumnAlignment.none;
}

/// Vero se la riga [lineIndex] apre (o è di per sé) un nuovo blocco, o è
/// una riga vuota: usato per decidere dove termina un paragrafo o un
/// item di lista senza duplicare l'ordine di priorità dei riconoscitori
/// usato dal ciclo principale di [_parseBlocksFromScratch].
bool _isBlockBoundaryLine(
  String source,
  List<int> lineStarts,
  int lineCount,
  int lineIndex,
) {
  final lt = _lineText(source, lineStarts, lineIndex);
  if (lt.trim().isEmpty) return true;
  if (_fenceOpenRegex.hasMatch(lt)) return true;
  if (_mathOpenRegex.hasMatch(lt)) return true;
  if (_atxHeadingRegex.hasMatch(lt)) return true;
  if (_isThematicBreak(lt)) return true;
  if (_blockquoteMarkerRegex.hasMatch(lt)) return true;
  if (_listMarkerRegex.hasMatch(lt)) return true;
  if (lineIndex + 1 < lineCount &&
      _looksLikeTableRow(lt) &&
      _isTableDelimiterRow(_lineText(source, lineStarts, lineIndex + 1))) {
    return true;
  }
  return false;
}

// ============================================================================
// Parsing dei singoli tipi di blocco.
// ============================================================================

({CodeBlockNode node, int nextLine}) _parseFencedCode(
  String source,
  List<int> lineStarts,
  int lineCount,
  int startLine,
  RegExpMatch openMatch,
) {
  final fenceChars = openMatch.group(1)!;
  final isBacktick = fenceChars.startsWith('`');
  final info = (openMatch.group(2) ?? '').trim();
  final language = info.isEmpty ? null : info.split(RegExp(r'\s+')).first;

  int? closeLine;
  var end = startLine + 1;
  while (end < lineCount) {
    final lt = _lineText(source, lineStarts, end);
    final closingRegex = isBacktick ? _closingBacktickFenceRegex : _closingTildeFenceRegex;
    if (closingRegex.hasMatch(lt)) {
      final fenceRun = lt.trim();
      if (fenceRun.length >= fenceChars.length) {
        closeLine = end;
        break;
      }
    }
    end++;
  }

  final codeEndExclusive = closeLine ?? lineCount;
  final codeLines = <String>[
    for (var li = startLine + 1; li < codeEndExclusive; li++) _lineText(source, lineStarts, li),
  ];
  final finalLine = closeLine ?? (lineCount - 1);

  final node = CodeBlockNode(
    startOffset: lineStarts[startLine],
    endOffset: _lineEndOffsetExclusiveOfNewline(source, lineStarts, finalLine),
    attributes: {'language': language, 'code': codeLines.join('\n')},
  );
  return (node: node, nextLine: closeLine != null ? closeLine + 1 : lineCount);
}

({MathBlockNode node, int nextLine}) _parseMathBlock(
  String source,
  List<int> lineStarts,
  int lineCount,
  int startLine,
) {
  final lt = _lineText(source, lineStarts, startLine);
  final singleLine = _mathSingleLineRegex.firstMatch(lt);
  if (singleLine != null) {
    final node = MathBlockNode(
      startOffset: lineStarts[startLine],
      endOffset: _lineEndOffsetExclusiveOfNewline(source, lineStarts, startLine),
      attributes: {'expression': singleLine.group(1)!.trim()},
    );
    return (node: node, nextLine: startLine + 1);
  }

  int? closeLine;
  var end = startLine + 1;
  while (end < lineCount) {
    if (_mathCloseRegex.hasMatch(_lineText(source, lineStarts, end))) {
      closeLine = end;
      break;
    }
    end++;
  }

  final contentEndExclusive = closeLine ?? lineCount;
  final exprLines = <String>[
    for (var li = startLine + 1; li < contentEndExclusive; li++) _lineText(source, lineStarts, li),
  ];
  final finalLine = closeLine ?? (lineCount - 1);

  final node = MathBlockNode(
    startOffset: lineStarts[startLine],
    endOffset: _lineEndOffsetExclusiveOfNewline(source, lineStarts, finalLine),
    attributes: {'expression': exprLines.join('\n').trim()},
  );
  return (node: node, nextLine: closeLine != null ? closeLine + 1 : lineCount);
}

({BlockquoteNode node, int nextLine}) _parseBlockquote(
  String source,
  List<int> lineStarts,
  int lineCount,
  int startLine,
) {
  var end = startLine;
  while (end < lineCount) {
    final lt = _lineText(source, lineStarts, end);
    if (lt.trim().isEmpty) {
      final next = end + 1;
      if (next < lineCount && _blockquoteMarkerRegex.hasMatch(_lineText(source, lineStarts, next))) {
        end++;
        continue;
      }
      break;
    }
    if (_blockquoteMarkerRegex.hasMatch(lt)) {
      end++;
      continue;
    }
    break;
  }

  var trimmedEnd = end;
  while (trimmedEnd > startLine && _lineText(source, lineStarts, trimmedEnd - 1).trim().isEmpty) {
    trimmedEnd--;
  }

  final startOffset = lineStarts[startLine];
  final endOffset = _lineEndOffsetExclusiveOfNewline(source, lineStarts, trimmedEnd - 1);

  final mapped = _buildMappedText(source, lineStarts, startLine, trimmedEnd, (li, lt) {
    final m = _blockquoteMarkerRegex.firstMatch(lt);
    return m?.end ?? 0;
  });
  final childBlocks = _parseBlocksFromScratch(mapped.text);
  final remapped = childBlocks.map((b) => b.remapOffsets(mapped.mapOffset)).toList(growable: false);

  final node = BlockquoteNode(startOffset: startOffset, endOffset: endOffset, children: remapped);
  return (node: node, nextLine: trimmedEnd);
}

({ListItemNode node, int nextLine}) _parseListItem(
  String source,
  List<int> lineStarts,
  int lineCount,
  int startLine,
  RegExpMatch markerMatch,
) {
  final contentStartCol =
      markerMatch.group(1)!.length + markerMatch.group(2)!.length + 1;

  var end = startLine + 1;
  while (end < lineCount) {
    final lt = _lineText(source, lineStarts, end);
    if (lt.trim().isEmpty) {
      end++;
      continue;
    }
    final indent = _leadingSpaces(lt);
    if (indent >= contentStartCol) {
      end++;
      continue;
    }
    break;
  }

  var trimmedEnd = end;
  while (trimmedEnd > startLine + 1 && _lineText(source, lineStarts, trimmedEnd - 1).trim().isEmpty) {
    trimmedEnd--;
  }

  final itemStartOffset = lineStarts[startLine];
  final itemEndOffset = _lineEndOffsetExclusiveOfNewline(source, lineStarts, trimmedEnd - 1);

  final mapped = _buildMappedText(source, lineStarts, startLine, trimmedEnd, (li, lt) => contentStartCol);
  final childBlocks = _parseBlocksFromScratch(mapped.text);
  final remapped = childBlocks.map((b) => b.remapOffsets(mapped.mapOffset)).toList(growable: false);

  final node = ListItemNode(startOffset: itemStartOffset, endOffset: itemEndOffset, children: remapped);
  return (node: node, nextLine: trimmedEnd);
}

({ListBlockNode node, int nextLine}) _parseListBlock(
  String source,
  List<int> lineStarts,
  int lineCount,
  int startLine,
  RegExpMatch firstMatch,
) {
  final baseIndent = firstMatch.group(1)!.length;
  final firstMarker = firstMatch.group(2)!;
  final ordered = RegExp(r'^\d').hasMatch(firstMarker);
  final bulletChar = ordered ? null : firstMarker;
  final startNumber = ordered ? int.tryParse(RegExp(r'\d+').firstMatch(firstMarker)!.group(0)!) : null;

  final items = <ListItemNode>[];
  var line = startLine;
  while (line < lineCount) {
    final lt = _lineText(source, lineStarts, line);
    final m = _listMarkerRegex.firstMatch(lt);
    if (m == null) break;
    final indent = _leadingSpaces(lt);
    if (indent != baseIndent) break;
    final marker = m.group(2)!;
    final markerOrdered = RegExp(r'^\d').hasMatch(marker);
    if (markerOrdered != ordered) break;
    if (!ordered && marker != bulletChar) break;

    final result = _parseListItem(source, lineStarts, lineCount, line, m);
    items.add(result.node);
    line = result.nextLine;
  }

  final node = ListBlockNode(
    startOffset: lineStarts[startLine],
    endOffset: items.last.endOffset,
    children: items,
    attributes: {
      'ordered': ordered,
      if (startNumber != null) 'start': startNumber,
    },
  );
  return (node: node, nextLine: line);
}

({TableBlockNode node, int nextLine}) _parseTable(
  String source,
  List<int> lineStarts,
  int lineCount,
  int startLine,
) {
  final headerLineText = _lineText(source, lineStarts, startLine);
  final headers = _splitTableRow(headerLineText);
  final delimLineText = _lineText(source, lineStarts, startLine + 1);
  final alignments = _splitTableRow(delimLineText).map(_parseAlignment).toList(growable: false);

  final rowNodes = <TableRowNode>[
    TableRowNode(
      startOffset: lineStarts[startLine],
      endOffset: _lineEndOffsetExclusiveOfNewline(source, lineStarts, startLine),
      attributes: {'cells': headers, 'isHeader': true},
    ),
  ];

  final dataRows = <List<String>>[];
  var end = startLine + 2;
  while (end < lineCount) {
    final lt = _lineText(source, lineStarts, end);
    if (!_looksLikeTableRow(lt)) break;
    final cells = _splitTableRow(lt);
    dataRows.add(cells);
    rowNodes.add(TableRowNode(
      startOffset: lineStarts[end],
      endOffset: _lineEndOffsetExclusiveOfNewline(source, lineStarts, end),
      attributes: {'cells': cells, 'isHeader': false},
    ));
    end++;
  }

  final node = TableBlockNode(
    startOffset: lineStarts[startLine],
    endOffset: _lineEndOffsetExclusiveOfNewline(source, lineStarts, end - 1),
    children: rowNodes,
    attributes: {
      'headers': headers,
      'alignments': alignments,
      'rows': dataRows,
      'columnCount': headers.length,
    },
  );
  return (node: node, nextLine: end);
}

({MarkdownBlockNode node, int nextLine}) _parseParagraph(
  String source,
  List<int> lineStarts,
  int lineCount,
  int startLine,
) {
  var end = startLine + 1;
  while (end < lineCount && !_isBlockBoundaryLine(source, lineStarts, lineCount, end)) {
    end++;
  }
  final startOffset = lineStarts[startLine];
  final endOffset = _lineEndOffsetExclusiveOfNewline(source, lineStarts, end - 1);
  final node = ParagraphNode(
    startOffset: startOffset,
    endOffset: endOffset,
    attributes: {'text': source.substring(startOffset, endOffset)},
  );
  return (node: node, nextLine: end);
}

// ============================================================================
// Entry point del parsing: usata sia per il documento completo sia,
// ricorsivamente, per il contenuto dedentato di blockquote e item di
// lista. È una funzione TOP-LEVEL pura (nessuna chiusura su stato
// esterno) apposta, così da poter essere eseguita anche dentro
// `Isolate.run` in `MarkdownAstParser.parseAsync`.
// ============================================================================

List<MarkdownBlockNode> _parseBlocksFromScratch(String source) {
  final lineStarts = _computeLineStarts(source);
  final lineCount = lineStarts.length;
  final blocks = <MarkdownBlockNode>[];

  var i = 0;
  while (i < lineCount) {
    final lt = _lineText(source, lineStarts, i);

    if (lt.trim().isEmpty) {
      i++;
      continue;
    }

    final fenceMatch = _fenceOpenRegex.firstMatch(lt);
    if (fenceMatch != null) {
      final r = _parseFencedCode(source, lineStarts, lineCount, i, fenceMatch);
      blocks.add(r.node);
      i = r.nextLine;
      continue;
    }

    if (_mathOpenRegex.hasMatch(lt)) {
      final r = _parseMathBlock(source, lineStarts, lineCount, i);
      blocks.add(r.node);
      i = r.nextLine;
      continue;
    }

    final headingMatch = _atxHeadingRegex.firstMatch(lt);
    if (headingMatch != null) {
      blocks.add(HeadingNode(
        startOffset: lineStarts[i],
        endOffset: _lineEndOffsetExclusiveOfNewline(source, lineStarts, i),
        attributes: {
          'level': headingMatch.group(1)!.length,
          'text': (headingMatch.group(2) ?? '').trim(),
        },
      ));
      i++;
      continue;
    }

    if (_isThematicBreak(lt)) {
      blocks.add(ThematicBreakNode(
        startOffset: lineStarts[i],
        endOffset: _lineEndOffsetExclusiveOfNewline(source, lineStarts, i),
      ));
      i++;
      continue;
    }

    if (_blockquoteMarkerRegex.hasMatch(lt)) {
      final r = _parseBlockquote(source, lineStarts, lineCount, i);
      blocks.add(r.node);
      i = r.nextLine;
      continue;
    }

    final listMatch = _listMarkerRegex.firstMatch(lt);
    if (listMatch != null) {
      final r = _parseListBlock(source, lineStarts, lineCount, i, listMatch);
      blocks.add(r.node);
      i = r.nextLine;
      continue;
    }

    if (i + 1 < lineCount &&
        _looksLikeTableRow(lt) &&
        _isTableDelimiterRow(_lineText(source, lineStarts, i + 1))) {
      final r = _parseTable(source, lineStarts, lineCount, i);
      blocks.add(r.node);
      i = r.nextLine;
      continue;
    }

    final r = _parseParagraph(source, lineStarts, lineCount, i);
    blocks.add(r.node);
    i = r.nextLine;
  }

  return blocks;
}
