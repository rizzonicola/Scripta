import 'dart:ui' show TextRange;

import '../../../core/utils/text_search.dart';

/// Un blocco della vista di lettura già reso in testo semplice, nella stessa
/// forma usata dalla selezione di `flutter_md`
/// (`markdownBlockRenderedText`).
class ReadingSearchBlock {
  const ReadingSearchBlock({required this.documentId, required this.text});

  /// Identificativo stabile del blocco nel modello di selezione: è l'ancora
  /// usata per portare a schermo un risultato, non la sua posizione nella
  /// lista (che cambia quando blocchi vengono costruiti o scartati).
  final String documentId;

  /// Testo reso del blocco (senza marker Markdown).
  final String text;
}

/// Occorrenza di ricerca dentro un blocco reso.
class ReadingSearchHit {
  const ReadingSearchHit({required this.documentId, required this.range});

  final String documentId;

  /// Offset nel testo RESO del blocco: è lo stesso spazio in cui la selezione
  /// ancorata al modello lavora, quindi può essere selezionato direttamente.
  final TextRange range;
}

/// Cerca [query] nel testo reso dei blocchi, senza distinzione tra maiuscole
/// e minuscole e senza occorrenze sovrapposte. Usa lo stesso motore e lo
/// stesso limite della ricerca sull'editor.
List<ReadingSearchHit> findReadingSearchHits(
  Iterable<ReadingSearchBlock> blocks,
  String query, {
  int maxHits = maxTextSearchMatches,
}) {
  final hits = <ReadingSearchHit>[];
  for (final block in blocks) {
    if (hits.length >= maxHits) break;
    final ranges = findTextMatchesInLowercase(
      block.text.toLowerCase(),
      query,
      maxMatches: maxHits - hits.length,
    );
    for (final range in ranges) {
      hits.add(ReadingSearchHit(documentId: block.documentId, range: range));
    }
  }
  return hits;
}
