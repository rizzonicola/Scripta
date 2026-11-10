import 'dart:ui' show TextRange;

/// Un blocco della vista di lettura già reso in testo semplice, nella stessa
/// forma usata dalla selezione di `flutter_md`
/// (`markdownBlockRenderedText`).
class ReadingSearchBlock {
  const ReadingSearchBlock({
    required this.itemIndex,
    required this.documentId,
    required this.text,
  });

  /// Indice dell'elemento nella lista virtualizzata della vista.
  final int itemIndex;

  /// Identificativo del documento registrato nel controller di selezione.
  final String documentId;

  /// Testo reso del blocco (senza marker Markdown).
  final String text;
}

/// Occorrenza di ricerca dentro un blocco reso.
class ReadingSearchHit {
  const ReadingSearchHit({
    required this.itemIndex,
    required this.documentId,
    required this.range,
  });

  final int itemIndex;
  final String documentId;

  /// Offset nel testo RESO del blocco: è lo stesso spazio in cui la selezione
  /// ancorata al modello lavora, quindi può essere selezionato direttamente.
  final TextRange range;
}

/// Cerca [query] nel testo reso dei blocchi, senza distinzione tra maiuscole
/// e minuscole e senza occorrenze sovrapposte. Il limite difensivo è lo
/// stesso della ricerca sull'editor: una query di un solo carattere su una
/// nota enorme non deve produrre decine di migliaia di risultati.
List<ReadingSearchHit> findReadingSearchHits(
  Iterable<ReadingSearchBlock> blocks,
  String query, {
  int maxHits = 2000,
}) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const [];
  final lowerQuery = trimmed.toLowerCase();

  final hits = <ReadingSearchHit>[];
  for (final block in blocks) {
    if (hits.length >= maxHits) break;
    final lowerText = block.text.toLowerCase();
    if (lowerText.isEmpty) continue;
    var searchStart = 0;
    while (hits.length < maxHits) {
      final index = lowerText.indexOf(lowerQuery, searchStart);
      if (index < 0) break;
      final end = index + lowerQuery.length;
      hits.add(
        ReadingSearchHit(
          itemIndex: block.itemIndex,
          documentId: block.documentId,
          range: TextRange(start: index, end: end),
        ),
      );
      searchStart = end;
    }
  }
  return hits;
}
