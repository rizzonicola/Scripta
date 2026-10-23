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
  static const _accountIdentityKey = 'account_identity';

  Future<Database> get _db => AppDatabase.instance.db;

  Future<int> getSyncCursor() async {
    final db = await _db;
    final rows = await db.query('sync_meta',
        where: 'key = ?', whereArgs: [_cursorKey], limit: 1);
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

  /// Identità dell'ultimo account autenticato su questo dispositivo
  /// (`serverUrl|userId`). Resta in `sync_meta` anche dopo logout e 401:
  /// serve a riconoscere un cambio account e a NON applicare i dati di
  /// un'utenza sull'altra.
  Future<String?> getAccountIdentity() async {
    final db = await _db;
    final rows = await db.query(
      'sync_meta',
      where: 'key = ?',
      whereArgs: [_accountIdentityKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> setAccountIdentity(String identity) async {
    final db = await _db;
    await db.insert(
      'sync_meta',
      {'key': _accountIdentityKey, 'value': identity},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Azzera cursore e metadati di sync, conservando l'identità del NUOVO
  /// account (altrimenti il prossimo login non potrebbe più distinguerlo).
  Future<void> clearSyncState({required String accountIdentity}) async {
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete('sync_meta');
      await txn.insert('sync_meta', {
        'key': _accountIdentityKey,
        'value': accountIdentity,
      });
    });
  }
}
