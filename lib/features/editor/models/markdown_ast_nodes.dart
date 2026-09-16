import 'package:flutter/foundation.dart' show immutable;

/// Tipi di nodo supportati dall'AST Markdown interno.
///
/// Copre il sottoinsieme di blocchi richiesto dal nuovo motore di
/// rendering: titoli, paragrafi, code block, elenchi, tabelle e blocchi
/// matematici, oltre a blockquote e separatori orizzontali necessari per
/// una struttura ad albero coerente.
enum MarkdownNodeType {
  heading,
  paragraph,
  codeBlock,
  thematicBreak,
  blockquote,
  listBlock,
  listItem,
  tableBlock,
  tableRow,
  mathBlock,
}

/// Allineamento di una colonna in una tabella GFM (`:---`, `:---:`, `---:`).
enum TableColumnAlignment { none, left, center, right }

/// Nodo base, immutabile, dell'Abstract Syntax Tree Markdown.
///
/// Ogni nodo mantiene una mappatura ESATTA con la porzione di testo
/// sorgente Markdown da cui è stato generato tramite [startOffset] ed
/// [endOffset]: entrambi sono indici di carattere (UTF-16, gli stessi
/// usati da [String.substring]) nel testo sorgente COMPLETO del
/// documento — mai nel testo del blocco padre, nemmeno per i nodi
/// innestati (item di lista, righe di tabella, blocchi dentro una
/// blockquote, ...). Questo è ciò che rende possibile una mappatura O(1)
/// (per singolo nodo) / O(log N) (per ricerca nell'albero) tra un punto
/// del testo sorgente e il nodo visivo corrispondente, senza dover
/// ricalcolare offset relativi a runtime.
///
/// Convenzione sugli offset:
/// - [startOffset] è l'indice del primo carattere del nodo (inclusivo).
/// - [endOffset] è l'indice subito dopo l'ultimo carattere del nodo
///   (esclusivo), SENZA includere l'eventuale "a capo" (`\n`) che separa
///   il blocco dal successivo. Questo garantisce che
///   `source.substring(node.startOffset, node.endOffset)` restituisca
///   sempre e soltanto il testo sorgente esatto del nodo (round-trip),
///   proprietà su cui si basa `MarkdownAstDocument.extractSourceText`.
@immutable
abstract class MarkdownNode {
  /// Indice (inclusivo) del primo carattere del nodo nel testo sorgente.
  final int startOffset;

  /// Indice (esclusivo) subito dopo l'ultimo carattere del nodo nel testo
  /// sorgente.
  final int endOffset;

  /// Sotto-nodi innestati (es. gli item di una lista, le righe di una
  /// tabella, i blocchi contenuti in una blockquote). Lista vuota se il
  /// nodo non ha figli.
  final List<MarkdownNode> children;

  /// Metadati specifici del tipo di nodo (es. `level` per gli heading,
  /// `language` per i code block). Le chiavi garantite per ciascun tipo
  /// sono documentate sulla relativa sottoclasse concreta, che espone
  /// getter tipizzati per un accesso sicuro senza cast manuali.
  final Map<String, dynamic> attributes;

  const MarkdownNode({
    required this.startOffset,
    required this.endOffset,
    this.children = const [],
    this.attributes = const {},
  })  : assert(startOffset >= 0, 'startOffset non può essere negativo'),
        assert(
          endOffset >= startOffset,
          'endOffset deve essere maggiore o uguale a startOffset',
        );

  /// Il tipo discriminante del nodo.
  MarkdownNodeType get type;

  /// Lunghezza, in caratteri, del testo sorgente coperto dal nodo.
  int get length => endOffset - startOffset;

  /// Vero se [offset] ricade nel range coperto dal nodo.
  ///
  /// NOTA: il test è volutamente INCLUSIVO su entrambi gli estremi
  /// (`offset >= startOffset && offset <= endOffset`), a differenza della
  /// semantica esclusiva di [endOffset] usata per l'estrazione di testo
  /// (vedi `MarkdownAstDocument.extractSourceText`). La motivazione è
  /// ergonomica: un cursore posizionato esattamente alla fine di un
  /// blocco (es. subito dopo l'ultima lettera di un paragrafo, prima
  /// dell'a-capo che lo separa dal successivo) deve poter essere
  /// attribuito a quel blocco. Poiché due blocchi consecutivi generati
  /// dal parser sono sempre separati da almeno un carattere (l'a-capo
  /// stesso), questa scelta non introduce mai ambiguità tra nodi
  /// fratelli: il range inclusivo di un nodo non si sovrappone mai a
  /// quello del nodo successivo. Vedi `MarkdownAstDocument.getNodeAtOffset`.
  bool containsOffset(int offset) =>
      offset >= startOffset && offset <= endOffset;

  @override
  String toString() => '$runtimeType(start: $startOffset, end: $endOffset, '
      'children: ${children.length}, attrs: $attributes)';
}

/// Nodo di livello "blocco": è il tipo effettivamente restituito da
/// `MarkdownAstParser`, sia a livello di documento (lista radice) sia
/// come figlio innestato (item di lista, riga di tabella, blocco dentro
/// una blockquote, ...). Il layer inline (bold/italic/link/...) non è
/// nello scope di questa struttura dati: i nodi foglia espongono il
/// proprio testo grezzo tramite gli attributi (`text`, `code`,
/// `expression`, ...), lasciando l'eventuale parsing inline a un layer
/// successivo, dedicato al rendering.
@immutable
abstract class MarkdownBlockNode extends MarkdownNode {
  const MarkdownBlockNode({
    required super.startOffset,
    required super.endOffset,
    super.children,
    super.attributes,
  });

  /// Crea una copia del nodo con [startOffset], [endOffset] e/o
  /// [children] sostituiti (gli [attributes] restano invariati). Le
  /// sottoclassi la implementano per permettere a [remapOffsets] di
  /// ricostruire l'albero preservando il tipo concreto di ciascun nodo.
  MarkdownBlockNode copyWith({
    int? startOffset,
    int? endOffset,
    List<MarkdownBlockNode>? children,
  });

  /// Ricostruisce ricorsivamente questo nodo (e tutti i suoi discendenti)
  /// applicando [mapper] a ogni offset.
  ///
  /// Il parser lo usa per convertire gli offset "locali" calcolati
  /// durante il parsing ricorsivo di un sotto-testo (es. il contenuto
  /// dedentato di una blockquote o di un item di lista, estratto in una
  /// stringa temporanea e riparsato da capo) negli offset assoluti del
  /// testo sorgente originale del documento.
  MarkdownBlockNode remapOffsets(int Function(int localOffset) mapper) {
    final remappedChildren = children
        .map((child) => (child as MarkdownBlockNode).remapOffsets(mapper))
        .toList(growable: false);
    return copyWith(
      startOffset: mapper(startOffset),
      endOffset: mapper(endOffset),
      children: remappedChildren,
    );
  }
}

/// Titolo (`# ...` .. `###### ...`, stile ATX).
///
/// Attributi garantiti: `level` (`int`, 1-6), `text` (`String`, il testo
/// del titolo senza i cancelletti iniziali/finali e senza spazi ai
/// bordi).
class HeadingNode extends MarkdownBlockNode {
  const HeadingNode({
    required super.startOffset,
    required super.endOffset,
    required super.attributes,
  });

  int get level => attributes['level'] as int;
  String get text => attributes['text'] as String;

  @override
  MarkdownNodeType get type => MarkdownNodeType.heading;

  @override
  HeadingNode copyWith({
    int? startOffset,
    int? endOffset,
    List<MarkdownBlockNode>? children,
  }) =>
      HeadingNode(
        startOffset: startOffset ?? this.startOffset,
        endOffset: endOffset ?? this.endOffset,
        attributes: attributes,
      );
}

/// Paragrafo di testo semplice.
///
/// Attributi garantiti: `text` (`String`, il testo grezzo del paragrafo,
/// eventualmente su più righe separate da `\n`).
class ParagraphNode extends MarkdownBlockNode {
  const ParagraphNode({
    required super.startOffset,
    required super.endOffset,
    required super.attributes,
  });

  String get text => attributes['text'] as String;

  @override
  MarkdownNodeType get type => MarkdownNodeType.paragraph;

  @override
  ParagraphNode copyWith({
    int? startOffset,
    int? endOffset,
    List<MarkdownBlockNode>? children,
  }) =>
      ParagraphNode(
        startOffset: startOffset ?? this.startOffset,
        endOffset: endOffset ?? this.endOffset,
        attributes: attributes,
      );
}

/// Blocco di codice, delimitato da fence ``` (backtick) o `~~~` (tilde).
///
/// Attributi garantiti: `language` (`String?`, `null` se non
/// specificato nell'info-string della fence), `code` (`String`, il
/// contenuto del blocco, righe di fence escluse).
class CodeBlockNode extends MarkdownBlockNode {
  const CodeBlockNode({
    required super.startOffset,
    required super.endOffset,
    required super.attributes,
  });

  String? get language => attributes['language'] as String?;
  String get code => attributes['code'] as String;

  @override
  MarkdownNodeType get type => MarkdownNodeType.codeBlock;

  @override
  CodeBlockNode copyWith({
    int? startOffset,
    int? endOffset,
    List<MarkdownBlockNode>? children,
  }) =>
      CodeBlockNode(
        startOffset: startOffset ?? this.startOffset,
        endOffset: endOffset ?? this.endOffset,
        attributes: attributes,
      );
}

/// Linea di separazione orizzontale (`---`, `***`, `___`, 3+ caratteri).
class ThematicBreakNode extends MarkdownBlockNode {
  const ThematicBreakNode({
    required super.startOffset,
    required super.endOffset,
  });

  @override
  MarkdownNodeType get type => MarkdownNodeType.thematicBreak;

  @override
  ThematicBreakNode copyWith({
    int? startOffset,
    int? endOffset,
    List<MarkdownBlockNode>? children,
  }) =>
      ThematicBreakNode(
        startOffset: startOffset ?? this.startOffset,
        endOffset: endOffset ?? this.endOffset,
      );
}

/// Blockquote (`> ...`). Il contenuto è ri-parsato ricorsivamente e
/// disponibile in [children] (tipicamente paragrafi, ma può contenere
/// qualsiasi altro blocco, incluse blockquote annidate).
class BlockquoteNode extends MarkdownBlockNode {
  const BlockquoteNode({
    required super.startOffset,
    required super.endOffset,
    required super.children,
  });

  @override
  MarkdownNodeType get type => MarkdownNodeType.blockquote;

  @override
  BlockquoteNode copyWith({
    int? startOffset,
    int? endOffset,
    List<MarkdownBlockNode>? children,
  }) =>
      BlockquoteNode(
        startOffset: startOffset ?? this.startOffset,
        endOffset: endOffset ?? this.endOffset,
        children: children ?? this.children.cast<MarkdownBlockNode>(),
      );
}

/// Un elenco, puntato o numerato. Gli item sono in [children] come
/// [ListItemNode] (vedi [items] per l'accesso tipizzato).
///
/// Attributi garantiti: `ordered` (`bool`), `start` (`int?`, presente
/// solo per liste numerate quando il primo marcatore non è `1`).
class ListBlockNode extends MarkdownBlockNode {
  const ListBlockNode({
    required super.startOffset,
    required super.endOffset,
    required super.children,
    required super.attributes,
  });

  bool get ordered => attributes['ordered'] as bool;
  int? get start => attributes['start'] as int?;
  List<ListItemNode> get items => children.cast<ListItemNode>();

  @override
  MarkdownNodeType get type => MarkdownNodeType.listBlock;

  @override
  ListBlockNode copyWith({
    int? startOffset,
    int? endOffset,
    List<MarkdownBlockNode>? children,
  }) =>
      ListBlockNode(
        startOffset: startOffset ?? this.startOffset,
        endOffset: endOffset ?? this.endOffset,
        children: children ?? this.children.cast<MarkdownBlockNode>(),
        attributes: attributes,
      );
}

/// Un singolo elemento di una lista. Il contenuto (testo, liste
/// annidate, code block, ...) è ri-parsato ricorsivamente dal testo
/// "dedentato" dell'item e disponibile in [children].
class ListItemNode extends MarkdownBlockNode {
  const ListItemNode({
    required super.startOffset,
    required super.endOffset,
    required super.children,
  });

  @override
  MarkdownNodeType get type => MarkdownNodeType.listItem;

  @override
  ListItemNode copyWith({
    int? startOffset,
    int? endOffset,
    List<MarkdownBlockNode>? children,
  }) =>
      ListItemNode(
        startOffset: startOffset ?? this.startOffset,
        endOffset: endOffset ?? this.endOffset,
        children: children ?? this.children.cast<MarkdownBlockNode>(),
      );
}

/// Una tabella GFM (riga di intestazione + riga di delimitazione,
/// consumata ma non materializzata come nodo + righe dati). Le righe
/// sono in [children] come [TableRowNode] (la prima è sempre
/// l'intestazione: vedi [rows]).
///
/// Attributi garantiti: `headers` (`List<String>`), `alignments`
/// (`List<TableColumnAlignment>`, una per colonna), `rows`
/// (`List<List<String>>`, solo le righe dati, senza l'intestazione),
/// `columnCount` (`int`).
class TableBlockNode extends MarkdownBlockNode {
  const TableBlockNode({
    required super.startOffset,
    required super.endOffset,
    required super.children,
    required super.attributes,
  });

  List<String> get headers => attributes['headers'] as List<String>;

  List<TableColumnAlignment> get alignments =>
      attributes['alignments'] as List<TableColumnAlignment>;

  List<List<String>> get dataRows => attributes['rows'] as List<List<String>>;

  int get columnCount => attributes['columnCount'] as int;

  List<TableRowNode> get rows => children.cast<TableRowNode>();

  @override
  MarkdownNodeType get type => MarkdownNodeType.tableBlock;

  @override
  TableBlockNode copyWith({
    int? startOffset,
    int? endOffset,
    List<MarkdownBlockNode>? children,
  }) =>
      TableBlockNode(
        startOffset: startOffset ?? this.startOffset,
        endOffset: endOffset ?? this.endOffset,
        children: children ?? this.children.cast<MarkdownBlockNode>(),
        attributes: attributes,
      );
}

/// Una singola riga di una [TableBlockNode] (intestazione o dati).
///
/// Attributi garantiti: `cells` (`List<String>`), `isHeader` (`bool`).
class TableRowNode extends MarkdownBlockNode {
  const TableRowNode({
    required super.startOffset,
    required super.endOffset,
    required super.attributes,
  });

  List<String> get cells => attributes['cells'] as List<String>;
  bool get isHeader => attributes['isHeader'] as bool;

  @override
  MarkdownNodeType get type => MarkdownNodeType.tableRow;

  @override
  TableRowNode copyWith({
    int? startOffset,
    int? endOffset,
    List<MarkdownBlockNode>? children,
  }) =>
      TableRowNode(
        startOffset: startOffset ?? this.startOffset,
        endOffset: endOffset ?? this.endOffset,
        attributes: attributes,
      );
}

/// Blocco di formula matematica (`$$ ... $$`), su una o più righe.
///
/// Attributi garantiti: `expression` (`String`, il contenuto tra i
/// delimitatori `$$`, senza spazi ai bordi).
class MathBlockNode extends MarkdownBlockNode {
  const MathBlockNode({
    required super.startOffset,
    required super.endOffset,
    required super.attributes,
  });

  String get expression => attributes['expression'] as String;

  @override
  MarkdownNodeType get type => MarkdownNodeType.mathBlock;

  @override
  MathBlockNode copyWith({
    int? startOffset,
    int? endOffset,
    List<MarkdownBlockNode>? children,
  }) =>
      MathBlockNode(
        startOffset: startOffset ?? this.startOffset,
        endOffset: endOffset ?? this.endOffset,
        attributes: attributes,
      );
}
