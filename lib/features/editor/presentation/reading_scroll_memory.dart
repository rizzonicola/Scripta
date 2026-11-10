import 'package:flutter/foundation.dart' show visibleForTesting;

/// Memoria in-process della posizione di lettura per nota.
///
/// PERCHÉ in memoria e non su disco: il caso d'uso è tornare alla stessa nota
/// dopo aver cambiato nota o modalità nella stessa sessione; persistere sul
/// disco aggiungerebbe I/O e una chiave da ripulire senza un beneficio
/// richiesto. Il limite LRU evita che una lunga sessione su centinaia di note
/// trattenga tutte le posizioni.
class ReadingScrollMemory {
  const ReadingScrollMemory._();

  static const int maxEntries = 20;
  static final Map<String, double> _offsets = <String, double>{};

  static double? offsetFor(String noteId) {
    final offset = _offsets.remove(noteId);
    if (offset == null) return null;
    _offsets[noteId] = offset; // touch: diventa la più recente
    return offset;
  }

  static void save(String noteId, double offset) {
    if (offset <= 0) {
      _offsets.remove(noteId);
      return;
    }
    _offsets.remove(noteId);
    _offsets[noteId] = offset;
    while (_offsets.length > maxEntries) {
      _offsets.remove(_offsets.keys.first);
    }
  }

  @visibleForTesting
  static void clear() => _offsets.clear();
}
