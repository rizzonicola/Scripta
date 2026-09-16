import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/widgets.dart' show SelectedContent, TextSelection;

import '../models/markdown_ast_nodes.dart';
import 'markdown_ast_parser.dart';

/// FASE 3 — Motore di selezione logica basato su AST.
///
/// `SelectableRegion` (usato da `MarkdownRenderedView`) seleziona e copia
/// il testo così come viene VISUALMENTE renderizzato: grassetti, corsivi,
/// link e codice inline sono già stati "smontati" dalla sintassi
/// Markdown originale (`**`, `_`, `[...](...)`, ``` ` ```) dal motore di
/// rendering (`flutter_markdown_plus`), quindi il testo copiato di
/// default è FORMATTATO, non il sorgente Markdown.
///
/// Questo file colma quel divario senza mai perdere la mappatura O(1)
/// con l'AST: per ciascun blocco di primo livello viene ricostruita, UNA
/// SOLA VOLTA per parsing del documento (mai durante lo scroll), sia la
/// versione "renderizzata" del suo testo (equivalente a ciò che l'utente
/// vede e quindi seleziona) sia una mappatura carattere-per-carattere
/// verso l'offset esatto nel sorgente Markdown originale. Alla copia, il
/// testo selezionato (visuale) viene individuato all'interno del
/// documento renderizzato ricostruito e tradotto, tramite questa
/// mappatura, nell'intervallo di sorgente corrispondente, che viene
/// infine estratto con `MarkdownAstDocument.extractSourceText` — MAI
/// ricodificato, MAI passato per un formato intermedio (vedi il vincolo
/// "NATIVE MARKDOWN FIRST").
///
/// ISOLAMENTO SYNC: questo file non importa né conosce DAO, database o
/// `sync_provider.dart` — opera esclusivamente sulla stringa sorgente e
/// sull'AST già parsato.
///
/// LIMITI NOTI (documentati volutamente, non nascosti):
/// - Il layer inline supportato copre grassetto (`**`/`__`), corsivo
///   (`*`/`_`), barrato (`~~`), codice inline (`` ` ``), link
///   (`[testo](url)`) e immagini (`![alt](url)`, non selezionabili come
///   testo, quindi non contribuiscono ad alcun carattere renderizzato).
///   Sintassi non riconosciuta viene passata come testo letterale: non
///   corrompe mai la mappatura, al più la rende meno precisa in quel
///   punto.
/// - Tabelle (e, in generale, un nodo il cui testo non è stato
///   individuabile nel sorgente) sono trattate come blocchi ATOMICI: se
///   la selezione tocca anche solo parzialmente un blocco atomico, in
///   copia viene restituito l'INTERO blocco, mai un frammento di
///   sintassi Markdown troncato e quindi non valido. Lo stesso vale, per
///   ora, per i blocchi atomici annidati dentro liste/blockquote più di
///   un livello: vengono comunque copiati per intero se toccati, ma la
///   protezione "espandi al blocco atomico" opera oggi solo sui nodi di
///   PRIMO LIVELLO (estensione naturale, se necessario, in una fase
///   successiva).
/// - La corrispondenza fra il testo effettivamente selezionato da
///   `SelectableRegion` (`SelectedContent.plainText`) e il documento
///   renderizzato ricostruito qui è cercata prima in modo ESATTO, poi —
///   se fallisce — con una ricerca tollerante agli spazi/interruzioni di
///   riga. Se anche questa fallisce, il chiamante (`MarkdownRenderedView`)
///   ricade sul testo renderizzato così com'è, così la funzione di copia
///   non si rompe MAI, anche nel caso peggiore.

/// Risultato dell'estrazione: il testo Markdown sorgente esatto, più
/// l'intervallo `[srcStart, srcEnd)` nel documento completo da cui è
/// stato estratto (la "selezione logica" richiesta dai criteri di
/// accettazione, espressa come `TextSelection(baseOffset, extentOffset)`
/// sul testo SORGENTE, non su quello renderizzato).
@immutable
class SourceExtractionResult {
  final String text;
  final int srcStart;
  final int srcEnd;

  /// `true` se la selezione renderizzata è stata trovata con un
  /// confronto esatto; `false` se si è dovuto ricorrere alla ricerca
  /// tollerante agli spazi bianchi (vedi limiti noti sopra).
  final bool exactMatch;

  const SourceExtractionResult({
    required this.text,
    required this.srcStart,
    required this.srcEnd,
    required this.exactMatch,
  });

  TextSelection get sourceSelection =>
      TextSelection(baseOffset: srcStart, extentOffset: srcEnd);
}

/// Mappa un frammento di testo inline Markdown (il contenuto grezzo di un
/// paragrafo o di un titolo) sia nella sua forma "renderizzata" (quella
/// che l'utente vede e seleziona) sia in una mappatura carattere per
/// carattere verso l'offset assoluto nel sorgente.
///
/// Implementazione a scansione lineare, ricorsiva sui delimitatori di
/// enfasi (per supportare i casi comuni di annidamento, es.
/// `**grassetto *e corsivo* insieme**`), pensata per essere O(n) nella
/// lunghezza del testo e non degradare mai in loop o eccezioni anche su
/// sintassi malformata (in quel caso il testo viene semplicemente
/// riportato letteralmente).
class MarkdownInlineTextMapper {
  const MarkdownInlineTextMapper();

  /// [baseOffset] è l'offset assoluto, nel sorgente completo del
  /// documento, del primo carattere di [text].
  InlineRenderResult map(String text, int baseOffset) {
    final buffer = StringBuffer();
    final offsets = <int>[];
    final spans = <FormattingSpan>[];
    _scan(text, 0, text.length, baseOffset, buffer, offsets, spans);
    offsets.add(baseOffset + text.length);
    return InlineRenderResult(buffer.toString(), offsets, spans);
  }

  void _emit(StringBuffer buffer, List<int> offsets, String s, int srcOffsetOfFirstChar) {
    for (var k = 0; k < s.length; k++) {
      offsets.add(srcOffsetOfFirstChar + k);
    }
    buffer.write(s);
  }

  void _scan(
    String text,
    int from,
    int to,
    int baseOffset,
    StringBuffer buffer,
    List<int> offsets,
    List<FormattingSpan> spans,
  ) {
    var i = from;
    while (i < to) {
      final ch = text[i];
      final abs = baseOffset + i;

      // Escape (`\*`, `\_`, ...): il carattere seguente è letterale.
      if (ch == '\\' && i + 1 < to) {
        _emit(buffer, offsets, text[i + 1], baseOffset + i + 1);
        i += 2;
        continue;
      }

      // Codice inline `...`: contenuto letterale, MAI riparsato come
      // Markdown (coerente con CommonMark). I backtick sono un
      // delimitatore a "larghezza zero" nel testo renderizzato: si
      // registra uno [FormattingSpan] così che, se la selezione coincide
      // esattamente con l'inizio del contenuto, l'estrazione possa
      // "riespandersi" per includerli (vedi `resolveSourceTextForSelection`).
      if (ch == '`') {
        final close = text.indexOf('`', i + 1);
        if (close != -1 && close < to) {
          final inner = text.substring(i + 1, close);
          final innerStart = buffer.length;
          _emit(buffer, offsets, inner, baseOffset + i + 1);
          final innerEnd = buffer.length;
          if (innerEnd > innerStart) {
            spans.add(FormattingSpan(innerStart, innerEnd, abs, baseOffset + close + 1));
          }
          i = close + 1;
          continue;
        }
      }

      // Immagine `![alt](url)`: non produce testo selezionabile a
      // schermo (viene renderizzata un'immagine, non testo) — si
      // consuma la sintassi senza emettere alcun carattere.
      if (ch == '!' && i + 1 < to && text[i + 1] == '[') {
        final consumedTo = _consumeLinkSyntax(text, i + 1, to);
        if (consumedTo != null) {
          i = consumedTo;
          continue;
        }
      }

      // Link `[testo](url)`: emette solo il testo visibile del link
      // (che può a sua volta contenere enfasi, quindi si ri-scandisce).
      if (ch == '[') {
        final closeBracket = _matchBracket(text, i, to);
        if (closeBracket != null &&
            closeBracket + 1 < to &&
            text[closeBracket + 1] == '(') {
          final closeParen = text.indexOf(')', closeBracket + 2);
          if (closeParen != -1 && closeParen < to) {
            final innerStart = buffer.length;
            _scan(text, i + 1, closeBracket, baseOffset, buffer, offsets, spans);
            final innerEnd = buffer.length;
            if (innerEnd > innerStart) {
              spans.add(FormattingSpan(innerStart, innerEnd, abs, baseOffset + closeParen + 1));
            }
            i = closeParen + 1;
            continue;
          }
        }
      }

      // Grassetto `**...**` / `__...__`.
      if ((ch == '*' || ch == '_') && i + 1 < to && text[i + 1] == ch) {
        final delimiter = text.substring(i, i + 2);
        final close = _indexOfWithin(text, delimiter, i + 2, to);
        if (close != null && close > i + 2) {
          final innerStart = buffer.length;
          _scan(text, i + 2, close, baseOffset, buffer, offsets, spans);
          final innerEnd = buffer.length;
          if (innerEnd > innerStart) {
            spans.add(FormattingSpan(innerStart, innerEnd, abs, baseOffset + close + 2));
          }
          i = close + 2;
          continue;
        }
      }

      // Barrato `~~...~~`.
      if (ch == '~' && i + 1 < to && text[i + 1] == '~') {
        final close = _indexOfWithin(text, '~~', i + 2, to);
        if (close != null && close > i + 2) {
          final innerStart = buffer.length;
          _scan(text, i + 2, close, baseOffset, buffer, offsets, spans);
          final innerEnd = buffer.length;
          if (innerEnd > innerStart) {
            spans.add(FormattingSpan(innerStart, innerEnd, abs, baseOffset + close + 2));
          }
          i = close + 2;
          continue;
        }
      }

      // Corsivo `*...*` / `_..._`.
      if (ch == '*' || ch == '_') {
        final close = _indexOfWithin(text, ch, i + 1, to);
        if (close != null && close > i + 1) {
          final innerStart = buffer.length;
          _scan(text, i + 1, close, baseOffset, buffer, offsets, spans);
          final innerEnd = buffer.length;
          if (innerEnd > innerStart) {
            spans.add(FormattingSpan(innerStart, innerEnd, abs, baseOffset + close + 1));
          }
          i = close + 1;
          continue;
        }
      }

      // Carattere letterale (o delimitatore senza chiusura valida, che
      // per robustezza viene riportato così com'è).
      _emit(buffer, offsets, ch, abs);
      i += 1;
    }
  }

  int? _indexOfWithin(String text, String needle, int from, int to) {
    final idx = text.indexOf(needle, from);
    if (idx == -1 || idx >= to) return null;
    return idx;
  }

  /// Individua la `]` di chiusura per un `[` in posizione [openIndex].
  /// Nessun supporto per parentesi quadre annidate (caso raro in un
  /// testo di link/immagine).
  int? _matchBracket(String text, int openIndex, int to) {
    final close = text.indexOf(']', openIndex + 1);
    if (close == -1 || close >= to) return null;
    return close;
  }

  /// Consuma un `[...](...)`, restituendo l'indice subito dopo la `)`
  /// di chiusura, senza emettere alcun carattere (uso per le immagini).
  int? _consumeLinkSyntax(String text, int bracketStart, int to) {
    final closeBracket = _matchBracket(text, bracketStart, to);
    if (closeBracket == null) return null;
    if (closeBracket + 1 >= to || text[closeBracket + 1] != '(') return null;
    final closeParen = text.indexOf(')', closeBracket + 2);
    if (closeParen == -1 || closeParen >= to) return null;
    return closeParen + 1;
  }
}

/// Un delimitatore di formattazione "a larghezza zero" nel testo
/// renderizzato (grassetto, corsivo, barrato, codice inline, link):
/// [innerRStart]/[innerREnd] sono le posizioni, nel testo renderizzato
/// LOCALE al blocco/frammento in cui è stato individuato, del contenuto
/// visibile racchiuso dal delimitatore; [outerSrcStart]/[outerSrcEnd]
/// sono gli offset assoluti, nel sorgente completo del documento,
/// dell'INTERO span (delimitatori inclusi).
///
/// Usato da `MarkdownSelectionSourceMapper.resolveSourceTextForSelection`
/// per "riespandere" l'estrazione quando la selezione visuale coincide
/// esattamente con l'inizio del contenuto formattato: i delimitatori,
/// non avendo alcun carattere renderizzato corrispondente, andrebbero
/// altrimenti persi (il testo copiato sarebbe `gatto` invece di
/// `**gatto**`).
@immutable
class FormattingSpan {
  final int innerRStart;
  final int innerREnd;
  final int outerSrcStart;
  final int outerSrcEnd;

  const FormattingSpan(
    this.innerRStart,
    this.innerREnd,
    this.outerSrcStart,
    this.outerSrcEnd,
  );

  FormattingSpan shifted(int rDelta) =>
      FormattingSpan(innerRStart + rDelta, innerREnd + rDelta, outerSrcStart, outerSrcEnd);
}

/// Testo "renderizzato" (ciò che l'utente vede/seleziona) di un
/// frammento, più la mappatura carattere-per-carattere verso l'offset
/// assoluto nel sorgente. `offsets.length == text.length + 1`:
/// `offsets[k]` è l'offset sorgente del carattere renderizzato in
/// posizione `k` (o, per `k == text.length`, l'offset subito dopo la
/// fine del frammento sorgente).
@immutable
class InlineRenderResult {
  final String text;
  final List<int> offsets;
  final List<FormattingSpan> spans;

  const InlineRenderResult(this.text, this.offsets, this.spans);
}

/// Rendering "logico" di UN SOLO blocco di primo livello (o di un nodo
/// annidato, es. un item di lista): testo renderizzato, mappatura verso
/// il sorgente, e se il blocco va trattato come un'unità ATOMICA in fase
/// di estrazione (vedi limiti noti in cima al file).
@immutable
class BlockRenderInfo {
  final MarkdownBlockNode node;
  final String renderedText;
  final List<int> offsets;
  final List<FormattingSpan> spans;
  final bool atomic;

  const BlockRenderInfo({
    required this.node,
    required this.renderedText,
    required this.offsets,
    required this.atomic,
    this.spans = const [],
  });
}

class _BlockSpan {
  final int rStart;
  final int rEnd;
  final BlockRenderInfo info;

  _BlockSpan(this.rStart, this.rEnd, this.info);

  MarkdownBlockNode get node => info.node;
}

/// Costruisce, a partire da un [MarkdownAstDocument] già parsato, la
/// rappresentazione "documento renderizzato" completa (equivalente a
/// tutto ciò che l'utente vedrebbe/selezionerebbe se l'intero documento
/// fosse realizzato a schermo — inclusi i blocchi virtualizzati fuori
/// viewport, dato che si lavora sull'AST e non sui widget effettivamente
/// montati) e la usa per tradurre una selezione "visuale"
/// (`SelectedContent.plainText`) nell'intervallo di sorgente Markdown
/// esatto corrispondente.
///
/// Costo di costruzione: O(n) nella lunghezza del documento, pagato UNA
/// SOLA VOLTA per parsing (stesso ciclo di vita della cache dell'AST in
/// `MarkdownRenderedView`), mai durante lo scroll — coerente con il
/// vincolo di performance della Fase 3.
class MarkdownSelectionSourceMapper {
  final MarkdownAstDocument document;

  static const MarkdownInlineTextMapper _inline = MarkdownInlineTextMapper();

  late final String _renderedDocument;
  late final List<int> _documentOffsets; // length == _renderedDocument.length + 1
  late final List<_BlockSpan> _topLevelSpans;
  late final List<FormattingSpan> _formattingSpans;

  late final String _normalizedRendered;
  late final List<int> _normalizedToOriginal; // length == _normalizedRendered.length

  MarkdownSelectionSourceMapper(this.document) {
    _build();
    _buildNormalized();
  }

  /// L'intero testo Markdown sorgente, invariato: usato da "Seleziona
  /// Tutto" (nessuna approssimazione necessaria in quel caso).
  String get fullSourceText => document.source;

  void _build() {
    final buffer = StringBuffer();
    final offsets = <int>[];
    final spans = <_BlockSpan>[];
    final formattingSpans = <FormattingSpan>[];

    for (var b = 0; b < document.blocks.length; b++) {
      if (b > 0) {
        // Separatore fra blocchi di primo livello: nella UI corrisponde
        // allo spazio verticale fra due widget di blocco consecutivi.
        // Non esiste un singolo carattere sorgente "giusto" da
        // assegnargli: si usa la fine del blocco precedente, che non
        // altera mai la correttezza dell'estrazione (l'offset di un
        // separatore non viene mai usato come estremo di taglio preciso
        // a meno che la selezione dell'utente finisca esattamente lì,
        // caso in cui coincide comunque con un confine di blocco valido).
        offsets.add(document.blocks[b - 1].endOffset);
        buffer.write('\n');
      }
      final rStart = buffer.length;
      final info = _renderBlock(document.blocks[b]);
      buffer.write(info.renderedText);
      offsets.addAll(info.offsets.sublist(0, info.offsets.length - 1));
      formattingSpans.addAll(info.spans.map((s) => s.shifted(rStart)));
      spans.add(_BlockSpan(rStart, buffer.length, info));
    }
    offsets.add(document.source.length);

    _renderedDocument = buffer.toString();
    _documentOffsets = offsets;
    _topLevelSpans = spans;
    _formattingSpans = formattingSpans;
  }

  void _buildNormalized() {
    final buf = StringBuffer();
    final map = <int>[];
    var i = 0;
    final src = _renderedDocument;
    while (i < src.length) {
      if (_isWhitespace(src[i])) {
        map.add(i);
        buf.write('\n');
        while (i < src.length && _isWhitespace(src[i])) {
          i++;
        }
      } else {
        map.add(i);
        buf.write(src[i]);
        i++;
      }
    }
    _normalizedRendered = buf.toString();
    _normalizedToOriginal = map;
  }

  static bool _isWhitespace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

  BlockRenderInfo _renderBlock(MarkdownBlockNode node) {
    switch (node.type) {
      case MarkdownNodeType.heading:
        return _renderInlineLeaf(node, (node as HeadingNode).text);
      case MarkdownNodeType.paragraph:
        return _renderInlineLeaf(node, (node as ParagraphNode).text);
      case MarkdownNodeType.codeBlock:
        return _renderVerbatimLeaf(node, (node as CodeBlockNode).code);
      case MarkdownNodeType.mathBlock:
        return _renderVerbatimLeaf(node, (node as MathBlockNode).expression);
      case MarkdownNodeType.thematicBreak:
        return BlockRenderInfo(
          node: node,
          renderedText: '',
          offsets: [node.startOffset],
          atomic: false,
        );
      case MarkdownNodeType.blockquote:
      case MarkdownNodeType.listBlock:
      case MarkdownNodeType.listItem:
        return _renderContainer(node);
      case MarkdownNodeType.tableBlock:
        return _renderTableAtomic(node as TableBlockNode);
      case MarkdownNodeType.tableRow:
        return _atomicFallback(node);
    }
  }

  BlockRenderInfo _renderInlineLeaf(MarkdownBlockNode node, String text) {
    final off = _locate(text, node.startOffset, node.endOffset);
    if (off == null) return _atomicFallback(node);
    final r = _inline.map(text, off);
    return BlockRenderInfo(
      node: node,
      renderedText: r.text,
      offsets: r.offsets,
      spans: r.spans,
      atomic: false,
    );
  }

  BlockRenderInfo _renderVerbatimLeaf(MarkdownBlockNode node, String text) {
    if (text.isEmpty) return _atomicFallback(node);
    final off = _locate(text, node.startOffset, node.endOffset);
    if (off == null) return _atomicFallback(node);
    final offsets = List<int>.generate(text.length + 1, (k) => off + k);
    return BlockRenderInfo(node: node, renderedText: text, offsets: offsets, atomic: false);
  }

  BlockRenderInfo _renderContainer(MarkdownBlockNode node) {
    final children = node.children.cast<MarkdownBlockNode>();
    if (children.isEmpty) {
      return BlockRenderInfo(
        node: node,
        renderedText: '',
        offsets: [node.startOffset],
        atomic: false,
      );
    }

    final buffer = StringBuffer();
    final offsets = <int>[];
    final spans = <FormattingSpan>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        offsets.add(children[i - 1].endOffset);
        buffer.write('\n');
      }
      final childStart = buffer.length;
      final info = _renderBlock(children[i]);
      buffer.write(info.renderedText);
      offsets.addAll(info.offsets.sublist(0, info.offsets.length - 1));
      spans.addAll(info.spans.map((s) => s.shifted(childStart)));
    }
    offsets.add(node.endOffset);

    return BlockRenderInfo(
      node: node,
      renderedText: buffer.toString(),
      offsets: offsets,
      spans: spans,
      // Il contenitore in sé non è atomico: eventuali figli atomici
      // (es. una tabella dentro una blockquote) restano protetti dalla
      // propria estrazione verbatim del blocco, vedi limiti noti.
      atomic: false,
    );
  }

  BlockRenderInfo _renderTableAtomic(TableBlockNode node) {
    final buffer = StringBuffer()..writeln(node.headers.join(' | '));
    for (final row in node.dataRows) {
      buffer.writeln(row.join(' | '));
    }
    final text = buffer.toString().trimRight();
    return BlockRenderInfo(
      node: node,
      // Le tabelle sono atomiche: questi offset non vengono mai usati
      // per un taglio preciso (vedi `_expandAtomicOverlaps`), servono
      // solo a mantenere un testo plausibile nel documento renderizzato
      // complessivo, utile alla ricerca della selezione.
      renderedText: text,
      offsets: List<int>.generate(text.length + 1, (_) => node.startOffset),
      atomic: true,
    );
  }

  BlockRenderInfo _atomicFallback(MarkdownBlockNode node) {
    final raw = document.extractSourceText(node.startOffset, node.endOffset);
    return BlockRenderInfo(
      node: node,
      renderedText: raw,
      offsets: List<int>.generate(
        raw.length + 1,
        (k) => (node.startOffset + k).clamp(0, document.source.length),
      ),
      atomic: true,
    );
  }

  int? _locate(String needle, int hintStart, int hintEnd) {
    if (needle.isEmpty) return hintStart;
    final src = document.source;
    final safeHintStart = hintStart.clamp(0, src.length);
    final idx = src.indexOf(needle, safeHintStart);
    if (idx == -1 || idx > hintEnd) return null;
    return idx;
  }

  /// Traduce [renderedSelection] (tipicamente `SelectedContent.plainText`
  /// riportato da `SelectableRegion.onSelectionChanged`) nel testo
  /// Markdown sorgente esatto corrispondente, oppure `null` se non è
  /// stato possibile individuare in modo affidabile la corrispondenza
  /// (in quel caso il chiamante deve ricadere sul testo renderizzato
  /// così com'è, per non rompere mai la copia).
  SourceExtractionResult? resolveSourceTextForSelection(String renderedSelection) {
    if (renderedSelection.isEmpty || _renderedDocument.isEmpty) return null;

    var start = _renderedDocument.indexOf(renderedSelection);
    var exact = true;
    int end;

    if (start != -1) {
      end = start + renderedSelection.length;
    } else {
      final tolerant = _tolerantSearch(renderedSelection);
      if (tolerant == null) return null;
      start = tolerant.$1;
      end = tolerant.$2;
      exact = false;
    }

    start = start.clamp(0, _renderedDocument.length);
    end = end.clamp(start, _renderedDocument.length);

    var srcStart = _documentOffsets[start];
    var srcEnd = _documentOffsets[end];

    // Riespande ai delimitatori di formattazione (grassetto/corsivo/
    // codice inline/link) quando la selezione visuale coincide
    // esattamente con l'inizio (o la fine) del contenuto racchiuso: i
    // delimitatori sono "a larghezza zero" nel testo renderizzato e
    // andrebbero altrimenti persi (vedi `FormattingSpan`). Si considerano
    // TUTTI gli span corrispondenti (anche annidati) cosi da ottenere
    // sempre il più esterno, il comportamento corretto quando l'utente
    // seleziona un'intera frase formattata.
    for (final span in _formattingSpans) {
      if (span.innerRStart == start) {
        srcStart = math.min(srcStart, span.outerSrcStart);
      }
      if (span.innerREnd == end) {
        srcEnd = math.max(srcEnd, span.outerSrcEnd);
      }
    }

    // Espande l'estrazione per includere per intero ogni blocco di primo
    // livello ATOMICO toccato anche solo parzialmente dalla selezione
    // (vedi limiti noti in cima al file).
    for (final span in _topLevelSpans) {
      if (!span.info.atomic) continue;
      final overlaps = span.rStart < end && span.rEnd > start;
      if (!overlaps) continue;
      srcStart = math.min(srcStart, span.node.startOffset);
      srcEnd = math.max(srcEnd, span.node.endOffset);
    }

    srcStart = srcStart.clamp(0, document.source.length);
    srcEnd = srcEnd.clamp(srcStart, document.source.length);

    return SourceExtractionResult(
      text: document.extractSourceText(srcStart, srcEnd),
      srcStart: srcStart,
      srcEnd: srcEnd,
      exactMatch: exact,
    );
  }

  (int, int)? _tolerantSearch(String needle) {
    final normalizedNeedle = _normalize(needle);
    if (normalizedNeedle.isEmpty) return null;
    final idx = _normalizedRendered.indexOf(normalizedNeedle);
    if (idx == -1) return null;

    final origStart = _normalizedToOriginal[idx];
    final normEnd = idx + normalizedNeedle.length;
    final origEnd = normEnd < _normalizedToOriginal.length
        ? _normalizedToOriginal[normEnd]
        : _renderedDocument.length;
    return (origStart, origEnd);
  }

  static String _normalize(String s) {
    final buf = StringBuffer();
    var i = 0;
    while (i < s.length) {
      if (_isWhitespace(s[i])) {
        buf.write('\n');
        while (i < s.length && _isWhitespace(s[i])) {
          i++;
        }
      } else {
        buf.write(s[i]);
        i++;
      }
    }
    return buf.toString();
  }
}

/// Handler/controller di selezione dedicato (Fase 3): tiene traccia
/// dell'ultima selezione visuale riportata da `SelectableRegion` e la
/// traduce, su richiesta, in testo Markdown sorgente pronto per la
/// clipboard — senza che `MarkdownRenderedView` debba conoscere i
/// dettagli della mappatura AST-sorgente.
///
/// Il documento (e quindi il [MarkdownSelectionSourceMapper] sottostante)
/// va aggiornato tramite [updateDocument] ogni volta — e SOLO ogni volta
/// — che il testo sorgente della nota cambia davvero, esattamente come
/// la cache dell'AST in `MarkdownRenderedView`.
class MarkdownSelectionController {
  MarkdownSelectionSourceMapper? _mapper;
  SelectedContent? _lastSelection;
  SourceExtractionResult? _lastResolution;

  void updateDocument(MarkdownAstDocument document) {
    _mapper = MarkdownSelectionSourceMapper(document);
    _lastResolution = null;
  }

  /// Da chiamare da `SelectableRegion.onSelectionChanged`.
  void updateSelection(SelectedContent? content) {
    _lastSelection = content;
    _lastResolution = null;
  }

  bool get hasSelection =>
      _lastSelection != null && _lastSelection!.plainText.isNotEmpty;

  /// La selezione logica corrente, come intervallo di caratteri nel
  /// testo sorgente (`TextSelection(baseOffset, extentOffset)`), come
  /// richiesto dai criteri di accettazione — `null` se non risolvibile
  /// (nessuna selezione attiva, o mappatura fallita).
  TextSelection? get logicalSourceSelection => _resolve()?.sourceSelection;

  /// Il testo Markdown sorgente esatto pronto per la clipboard, per la
  /// selezione corrente. Non fallisce mai: se la mappatura logica non
  /// trova una corrispondenza affidabile, ricade sul testo renderizzato
  /// (formattato) così com'è, cosi la copia resta sempre funzionante.
  String? resolveClipboardText() {
    final rendered = _lastSelection?.plainText;
    if (rendered == null || rendered.isEmpty) return null;
    return _resolve()?.text ?? rendered;
  }

  /// L'intero documento Markdown sorgente: usato da "Seleziona Tutto",
  /// che per definizione non necessita di alcuna mappatura parziale.
  String? get fullSourceText => _mapper?.fullSourceText;

  SourceExtractionResult? _resolve() {
    final cached = _lastResolution;
    if (cached != null) return cached;
    final rendered = _lastSelection?.plainText;
    if (rendered == null || rendered.isEmpty) return null;
    final resolved = _mapper?.resolveSourceTextForSelection(rendered);
    _lastResolution = resolved;
    return resolved;
  }
}
