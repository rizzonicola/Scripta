import 'dart:collection';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Memoria in-process della posizione di scorrimento per nota.
///
/// La posizione è un offset nel SORGENTE Markdown, non un offset in pixel:
/// così resta valida quando cambiano modalità (lettura formattata / modifica),
/// larghezza del pannello o altezza della viewport (focus mode). Le due viste
/// traducono l'offset nella propria geometria quando salvano e ripristinano.
///
/// PERCHÉ in memoria e non su disco: il caso d'uso è tornare alla stessa nota
/// dopo aver cambiato nota o modalità nella stessa sessione; persistere sul
/// disco aggiungerebbe I/O e una chiave da ripulire senza un beneficio
/// richiesto. Il limite LRU evita che una lunga sessione su centinaia di note
/// trattenga tutte le posizioni.
class NoteScrollMemory {
  const NoteScrollMemory._();

  static const int maxEntries = 20;

  // LinkedHashMap mantiene l'ordine di inserimento: la prima chiave è la meno
  // recente e viene rimossa per prima quando si supera [maxEntries].
  static final LinkedHashMap<String, int> _sourceOffsets =
      LinkedHashMap<String, int>();

  /// Offset nel sorgente per [noteId], o `null` se la nota non è mai stata
  /// scorsa. Il valore `0` è valido (l'utente è tornato in cima) e va
  /// distinto dall'assenza di una posizione salvata.
  static int? sourceOffsetFor(String noteId) {
    final offset = _sourceOffsets.remove(noteId);
    if (offset == null) return null;
    _sourceOffsets[noteId] = offset; // touch: diventa la più recente
    return offset;
  }

  /// Salva (o aggiorna) la posizione di [noteId]. Accetta anche `0`: una nota
  /// riportata in cima deve riaprirsi in cima, non all'ultima posizione
  /// precedente.
  static void save(String noteId, int sourceOffset) {
    final clamped = sourceOffset < 0 ? 0 : sourceOffset;
    _sourceOffsets.remove(noteId);
    _sourceOffsets[noteId] = clamped;
    while (_sourceOffsets.length > maxEntries) {
      _sourceOffsets.remove(_sourceOffsets.keys.first);
    }
  }

  @visibleForTesting
  static void clear() => _sourceOffsets.clear();
}
