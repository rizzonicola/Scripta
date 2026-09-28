import 'package:sqflite/sqflite.dart';

import 'app_database.dart';

/// Riga grezza della tabella `folders`, senza alcuna logica di business:
/// la conversione verso il modello di dominio [FolderNode] (che aggiunge la
/// struttura ad albero con i figli) avviene nel provider, non qui.
class FolderRow {
  final String id;
  final String name;
  final String? parentId;
  final bool isExpanded;
  final int updatedAt;
  final int? deletedAt;

  const FolderRow({
    required this.id,
    required this.name,
    required this.parentId,
    required this.isExpanded,
    required this.updatedAt,
    required this.deletedAt,
  });

  bool get isDeleted => deletedAt != null;

  factory FolderRow.fromMap(Map<String, Object?> m) => FolderRow(
        id: m['id'] as String,
        name: m['name'] as String,
        parentId: m['parent_id'] as String?,
        isExpanded: (m['is_expanded'] as int) != 0,
        updatedAt: m['updated_at'] as int,
        deletedAt: m['deleted_at'] as int?,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'parent_id': parentId,
        'is_expanded': isExpanded ? 1 : 0,
        'updated_at': updatedAt,
        'deleted_at': deletedAt,
      };

  FolderRow copyWith({
    String? name,
    Object? parentId = _unset,
    bool? isExpanded,
    int? updatedAt,
    Object? deletedAt = _unset,
  }) {
    return FolderRow(
      id: id,
      name: name ?? this.name,
      parentId: identical(parentId, _unset) ? this.parentId : parentId as String?,
      isExpanded: isExpanded ?? this.isExpanded,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: identical(deletedAt, _unset) ? this.deletedAt : deletedAt as int?,
    );
  }
}

const Object _unset = Object();

/// Data Access Object per le cartelle. Ogni mutazione locale imposta
/// `updated_at` (LWW) e `dirty = 1` (cosa inviare al server); le righe
/// applicate dalla pull sono scritte con `dirty = 0`.
class FoldersDao {
  Future<Database> get _db => AppDatabase.instance.db;

  /// Aggiorna SOLO il flag di espansione (stato UI locale, mai inviato al
  /// server): a differenza di [upsert], NON tocca `updated_at`, per non far
  /// rientrare la cartella nel prossimo batch di push solo per un
  /// espandi/comprimi dell'albero in UI.
  Future<void> setExpanded(String id, bool isExpanded) async {
    final db = await _db;
    await db.update(
      'folders',
      {'is_expanded': isExpanded ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<FolderRow>> getActive() async {
    final db = await _db;
    final rows = await db.query('folders', where: 'deleted_at IS NULL', orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(FolderRow.fromMap).toList();
  }

  Future<FolderRow?> getById(String id) async {
    final db = await _db;
    final rows = await db.query('folders', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return FolderRow.fromMap(rows.first);
  }

  /// Inserisce o sovrascrive integralmente una riga (usato sia per le
  /// mutazioni locali sia per applicare le entità ricevute dal server).
  /// Scrittura LOCALE: marca la riga `dirty = 1` (da inviare al server).
  Future<void> upsert(FolderRow row) async {
    final db = await _db;
    await db.insert('folders', {...row.toMap(), 'dirty': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Applica una riga ricevuta dal server (vedi [applyRemoteLWWBatch]).
  Future<void> applyRemoteLWW(FolderRow remote) => applyRemoteLWWBatch([remote]);

  /// Applica righe remote in un'unica transazione. Stessa regola di
  /// `NotesDao.applyRemoteLWWBatch`: la copia remota vince se la riga locale
  /// non esiste, è pulita (`dirty = 0`) o è meno recente; una modifica locale
  /// sporca e più recente non viene mai sovrascritta. Le righe applicate
  /// diventano pulite. `isExpanded` è solo locale e viene sempre preservato.
  Future<void> applyRemoteLWWBatch(List<FolderRow> remotes) async {
    if (remotes.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      for (final remote in remotes) {
        final rows = await txn.query('folders', where: 'id = ?', whereArgs: [remote.id], limit: 1);
        if (rows.isEmpty) {
          await txn.insert('folders', {...remote.toMap(), 'dirty': 0}, conflictAlgorithm: ConflictAlgorithm.replace);
          continue;
        }
        final local = FolderRow.fromMap(rows.first);
        final localIsDirty = (rows.first['dirty'] as int? ?? 1) != 0;
        if (!localIsDirty || remote.updatedAt >= local.updatedAt) {
          final merged = remote.copyWith(isExpanded: local.isExpanded);
          await txn.insert('folders', {...merged.toMap(), 'dirty': 0}, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
  }

  /// Righe con modifiche locali non ancora confermate dal server.
  Future<List<FolderRow>> listDirty() async {
    final db = await _db;
    final rows = await db.query('folders', where: 'dirty = 1');
    return rows.map(FolderRow.fromMap).toList();
  }

  /// Vedi `NotesDao.markSynced`.
  Future<void> markSynced(Map<String, int> idToPushedUpdatedAt) async {
    if (idToPushedUpdatedAt.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      for (final e in idToPushedUpdatedAt.entries) {
        await txn.update('folders', {'dirty': 0}, where: 'id = ? AND updated_at = ?', whereArgs: [e.key, e.value]);
      }
    });
  }

  /// Elimina i tombstone già confermati dal server (`dirty = 0`).
  Future<void> purgeCleanTombstones() async {
    final db = await _db;
    await db.delete('folders', where: 'deleted_at IS NOT NULL AND dirty = 0');
  }

  /// Dopo un `full_resync`: elimina le righe pulite sconosciute al server.
  Future<void> deleteCleanNotIn(Set<String> serverIds) async {
    final db = await _db;
    final rows = await db.query('folders', columns: ['id'], where: 'dirty = 0');
    final stale = [for (final r in rows) r['id'] as String]..removeWhere(serverIds.contains);
    await hardDeleteIds(stale);
  }

  Future<List<String>> listActiveChildIds(String parentId) async {
    final db = await _db;
    final rows = await db.query(
      'folders',
      columns: ['id'],
      where: 'parent_id = ? AND deleted_at IS NULL',
      whereArgs: [parentId],
    );
    return rows.map((r) => r['id'] as String).toList();
  }

  /// Propaga ricorsivamente (in ampiezza) la cancellazione di una cartella a
  /// tutte le sottocartelle e note ancora attive al suo interno, usando lo
  /// stesso timestamp per l'intero sottoalbero. Speculare alla cascade
  /// server-side in `internal/handlers/api_sync.go`, così che anche in
  /// assenza di connettività l'utente veda immediatamente sparire l'intero
  /// sottoalbero, senza dover attendere la prossima sync.
  Future<void> cascadeSoftDelete(String rootFolderId, int now, {required Future<void> Function(String folderId, int now) deleteNotesInFolder}) async {
    final db = await _db;

    // La radice stessa deve essere marcata cancellata: il ciclo qui sotto si
    // occupa SOLO di propagare ai discendenti (li scopre interrogando i figli
    // di "current", mai il nodo stesso). Senza questo UPDATE la riga della
    // cartella radice resterebbe con deleted_at = NULL nel DB locale: non
    // verrebbe mai inclusa in listDirtySince (updated_at non è cambiato) e
    // quindi non verrebbe mai inviata al server, e al successivo
    // refreshFromDb() post-sync (getActive() = WHERE deleted_at IS NULL)
    // ricomparirebbe nell'albero — vuota, perché figli e note nel frattempo
    // sono stati correttamente cancellati.
    await db.update(
      'folders',
      {'updated_at': now, 'deleted_at': now, 'dirty': 1},
      where: 'id = ?',
      whereArgs: [rootFolderId],
    );

    final queue = <String>[rootFolderId];

    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);

      await deleteNotesInFolder(current, now);

      final childIds = await listActiveChildIds(current);
      if (childIds.isNotEmpty) {
        final batch = db.batch();
        for (final id in childIds) {
          batch.update(
            'folders',
            {'updated_at': now, 'deleted_at': now, 'dirty': 1},
            where: 'id = ?',
            whereArgs: [id],
          );
        }
        await batch.commit(noResult: true);
        queue.addAll(childIds);
      }
    }
  }

  Future<void> hardDeleteIds(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await _db;
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      final placeholders = List.filled(chunk.length, '?').join(',');
      await db.delete('folders', where: 'id IN ($placeholders)', whereArgs: chunk);
    }
  }

  Future<void> hardDeleteAll() async {
    final db = await _db;
    await db.delete('folders');
  }
}
