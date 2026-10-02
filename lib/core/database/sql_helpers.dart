import 'package:sqflite/sqflite.dart';

/// Numero massimo di variabili (`?`) per singolo statement: SQLite ne ammette
/// al più 999 nelle build più vecchie (Android < 11), quindi si resta ben
/// sotto il limite anche aggiungendo qualche parametro fisso alla query.
const int sqlVariableChunkSize = 500;

/// Suddivide [items] in blocchi di al massimo [size] elementi, nello stesso
/// ordine. Usato per le clausole `IN (...)` su liste potenzialmente grandi
/// (id di note/cartelle ricevuti da una sync completa).
Iterable<List<T>> chunked<T>(List<T> items, [int size = sqlVariableChunkSize]) sync* {
  for (var start = 0; start < items.length; start += size) {
    final end = start + size;
    yield items.sublist(start, end > items.length ? items.length : end);
  }
}

/// Segnaposto `?,?,?` per una clausola `IN (...)` di [count] elementi.
String sqlPlaceholders(int count) => List.filled(count, '?').join(',');

/// Elimina da [table] le righe il cui `id` è in [ids], a blocchi ma dentro
/// UNA SOLA transazione: o spariscono tutte o nessuna, e si paga un solo
/// commit/fsync invece di uno per blocco.
///
/// Con [onlyClean] la DELETE ripete la condizione `dirty = 0` nello stesso
/// statement: una riga che l'utente ha modificato DOPO che la lista [ids] è
/// stata calcolata (quindi nel frattempo è diventata `dirty = 1`) non viene
/// più cancellata. Senza questa guardia una modifica locale concorrente a una
/// sync poteva essere persa.
Future<void> deleteByIds(
  Database db,
  String table,
  List<String> ids, {
  bool onlyClean = false,
}) async {
  if (ids.isEmpty) return;
  await db.transaction((txn) async {
    for (final chunk in chunked(ids)) {
      final inClause = 'id IN (${sqlPlaceholders(chunk.length)})';
      await txn.delete(
        table,
        where: onlyClean ? '$inClause AND dirty = 0' : inClause,
        whereArgs: chunk,
      );
    }
  });
}
