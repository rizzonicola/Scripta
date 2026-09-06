import 'package:sqflite/sqflite.dart';

import 'app_database.dart';

/// Persiste il cursore di sincronizzazione (`last_synced_at`, unix millis
/// tempo SERVER) nella tabella locale `sync_meta`. È il valore che
/// [SyncNotifier] invia ad ogni richiesta di sync e aggiorna con
/// `SyncResponse.serverTime` alla fine di ogni round riuscito: determina sia
/// cosa il client considera "da inviare" (righe locali con `updated_at` >
/// cursore) sia cosa il server considera "da restituire" nella pull.
class SyncMetaDao {
  static const _cursorKey = 'last_synced_at';

  Future<Database> get _db => AppDatabase.instance.db;

  Future<int> getSyncCursor() async {
    final db = await _db;
    final rows = await db.query('sync_meta', where: 'key = ?', whereArgs: [_cursorKey], limit: 1);
    if (rows.isEmpty) return 0;
    return int.tryParse(rows.first['value'] as String) ?? 0;
  }

  Future<void> setSyncCursor(int millis) async {
    final db = await _db;
    await db.insert(
      'sync_meta',
      {'key': _cursorKey, 'value': millis.toString()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
