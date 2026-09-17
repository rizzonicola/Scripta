/// Modelli di dominio per la selezione del testo nell'editor Markdown.
///
/// Libreria di puro Dart (nessuna dipendenza da Flutter): gli offset sono
/// assoluti sul documento piatto e tutta la logica è unit-testabile senza
/// ambiente UI.
library;

import 'dart:math' as math;

/// Una selezione del documento, espressa come offset assoluti (0-based)
/// sul testo piatto.
///
/// Gli estremi possono essere disordinati (selezione "all'indietro"):
/// usare [min] e [max] per gli estremi ordinati. Una selezione con
/// `start == end` è detta _collapsed_ e rappresenta il semplice caret.
///
/// Modello immutabile: ogni trasformazione produce una nuova istanza
/// tramite [copyWith]; l'uguaglianza è per valore.
class MarkdownSelectionRange {
  /// Offset di inizio della selezione (può essere maggiore di [end] se
  /// l'utente sta selezionando all'indietro).
  final int start;

  /// Offset di fine della selezione (può essere minore di [start] se
  /// l'utente sta selezionando all'indietro).
  final int end;

  /// `true` mentre l'utente sta trascinando la selezione.
  ///
  /// È stato del gesto, non degli estremi: partecipa comunque a
  /// [operator ==] e [hashCode] perché distingue stati logici diversi
  /// (dragging attivo vs selezione confermata).
  final bool isSelecting;

  /// Costruisce un intervallo di selezione.
  ///
  /// [start] ed [end] possono essere in qualsiasi ordine reciproco; per
  /// il caret usare [MarkdownSelectionRange.collapsed].
  const MarkdownSelectionRange({
    required this.start,
    required this.end,
    this.isSelecting = false,
  });

  /// Costruisce un intervallo _collapsed_ (caret) in [offset]:
  /// `start == end == offset`, nessun trascinamento attivo. Per un drag
  /// appena iniziato usare `copyWith(isSelecting: true)`.
  const MarkdownSelectionRange.collapsed(int offset)
      : start = offset,
        end = offset,
        isSelecting = false;

  /// Estremo inferiore dell'intervallo, qualunque sia la direzione.
  int get min => start < end ? start : end;

  /// Estremo superiore dell'intervallo, qualunque sia la direzione.
  int get max => start < end ? end : start;

  /// `true` se la selezione è vuota (`start == end`), cioè un caret.
  bool get isCollapsed => start == end;

  /// `true` se entrambi gli estremi sono offset validi (non negativi).
  bool get isValid => start >= 0 && end >= 0;

  /// Restituisce una copia con i campi forniti sovrascritti.
  MarkdownSelectionRange copyWith({int? start, int? end, bool? isSelecting}) {
    return MarkdownSelectionRange(
      start: start ?? this.start,
      end: end ?? this.end,
      isSelecting: isSelecting ?? this.isSelecting,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MarkdownSelectionRange &&
        other.start == start &&
        other.end == end &&
        other.isSelecting == isSelecting;
  }

  @override
  int get hashCode => Object.hash(start, end, isSelecting);

  @override
  String toString() =>
      'MarkdownSelectionRange(start: $start, end: $end, '
      'isSelecting: $isSelecting)';
}

/// Come una selezione del documento si sovrappone a un singolo blocco.
enum SelectionType {
  /// Nessuna sovrapposizione: il blocco non deve evidenziare nulla.
  none,

  /// Il blocco è interamente contenuto nella selezione.
  full,

  /// Solo una parte del blocco è selezionata: l'intervallo locale è
  /// descritto da [BlockSelectionIntersection.localStart] e
  /// [BlockSelectionIntersection.localEnd].
  partial,
}

/// Intersezione tra la selezione del documento e un singolo blocco,
/// con offset **relativi all'inizio del blocco** (0-based, fine esclusiva).
///
/// I valori locali sono pronti per il layer di presentazione, es.
/// `TextRange(start: intersection.localStart, end: intersection.localEnd)`,
/// senza conversioni aggiuntive.
class BlockSelectionIntersection {
  /// Classificazione della sovrapposizione.
  final SelectionType type;

  /// Offset di inizio della parte selezionata, relativo all'inizio del
  /// blocco (0-based). Sempre `0` per [SelectionType.none] e
  /// [SelectionType.full].
  final int localStart;

  /// Offset di fine (esclusivo) della parte selezionata, relativo
  /// all'inizio del blocco. È `0` per [SelectionType.none]; per
  /// [SelectionType.full] coincide con la lunghezza del blocco.
  final int localEnd;

  /// Istanza canonicalizzata per il caso "nessuna intersezione".
  ///
  /// [calculateBlockIntersection] restituisce esattamente questo oggetto
  /// quando il blocco non è toccato dalla selezione: essendo `const`,
  /// Dart la canonicalizza e il caso più frequente non esegue alcuna
  /// allocazione a caldo. I chiamanti possono quindi usare
  /// `identical(result, BlockSelectionIntersection.none)` come fast path.
  static const BlockSelectionIntersection none = BlockSelectionIntersection(
    type: SelectionType.none,
    localStart: 0,
    localEnd: 0,
  );

  /// Costruisce un'intersezione; per il caso vuoto preferire [none].
  const BlockSelectionIntersection({
    required this.type,
    required this.localStart,
    required this.localEnd,
  });

  /// Numero di caratteri del blocco coperti dalla selezione.
  int get length => localEnd - localStart;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BlockSelectionIntersection &&
        other.type == type &&
        other.localStart == localStart &&
        other.localEnd == localEnd;
  }

  @override
  int get hashCode => Object.hash(type, localStart, localEnd);

  @override
  String toString() =>
      'BlockSelectionIntersection(type: $type, localStart: $localStart, '
      'localEnd: $localEnd)';
}

/// Calcola come [selection] interseca il blocco che occupa l'intervallo
/// `[blockStartOffset, blockEndOffset)` del documento piatto.
///
/// Funzione pura: deterministica, senza effetti collaterali né stato
/// condiviso. Pensata per essere invocata per ogni blocco a ogni frame
/// durante un trascinamento (O(blocchi)), quindi il caso negativo deve
/// costare il meno possibile.
///
/// Convenzione degli intervalli (allineata a `TextSelection` di Flutter):
/// gli offset di fine sono **esclusivi**. Ne segue che una selezione che
/// termina esattamente dove inizia il blocco (o che inizia esattamente
/// dove il blocco finisce) non lo interseca: mai evidenziazioni vuote.
///
/// - Selezione _collapsed_ (caret) o blocco fuori dalla selezione →
///   [BlockSelectionIntersection.none] (istanza preallocata: zero
///   allocazioni a caldo).
/// - Blocco interamente contenuto in `[selection.min, selection.max]` →
///   [SelectionType.full] con `localStart == 0` e `localEnd` pari alla
///   lunghezza del blocco.
/// - Qualunque altra sovrapposizione → [SelectionType.partial] con
///   estremi clampati ai bordi del blocco; vale sempre l'invariante
///   `0 <= localStart < localEnd <= blockEndOffset - blockStartOffset`.
BlockSelectionIntersection calculateBlockIntersection({
  required int blockStartOffset,
  required int blockEndOffset,
  required MarkdownSelectionRange selection,
}) {
  // Precondizioni solo in debug: in release la funzione resta pura e
  // priva di branch difensivi.
  assert(blockStartOffset >= 0, 'blockStartOffset deve essere non negativo.');
  assert(
    blockEndOffset >= blockStartOffset,
    'blockEndOffset deve essere >= blockStartOffset.',
  );

  // Fast path 1 — caret: nessun blocco da evidenziare (il caso più
  // comune durante la digitazione). Zero allocazioni.
  if (selection.isCollapsed) {
    return BlockSelectionIntersection.none;
  }

  final int selectionMin = selection.min;
  final int selectionMax = selection.max;

  // Fast path 2 — nessuna sovrapposizione tra [selectionMin, selectionMax)
  // e [blockStartOffset, blockEndOffset). Zero allocazioni.
  if (selectionMax <= blockStartOffset || selectionMin >= blockEndOffset) {
    return BlockSelectionIntersection.none;
  }

  final int blockLength = blockEndOffset - blockStartOffset;

  // Il blocco è interamente coperto dalla selezione.
  if (selectionMin <= blockStartOffset && selectionMax >= blockEndOffset) {
    return BlockSelectionIntersection(
      type: SelectionType.full,
      localStart: 0,
      localEnd: blockLength,
    );
  }

  // Sovrapposizione parziale: estremi clampati ai bordi del blocco,
  // direttamente utilizzabili come TextRange locale.
  return BlockSelectionIntersection(
    type: SelectionType.partial,
    localStart: math.max(0, selectionMin - blockStartOffset),
    localEnd: math.min(blockLength, selectionMax - blockStartOffset),
  );
}