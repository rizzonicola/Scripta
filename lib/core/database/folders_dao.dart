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

/// Data Access Object per le cartelle. Tutte le scritture aggiornano sempre
/// `updated_at`: è quello il segnale che la sync userà per capire cosa
/// inviare al server (vedi SyncNotifier._collectDirtyFolders), quindi ogni
/// singolo metodo di mutazione qui sotto lo imposta esplicitamente, non c'è
/// bisogno di una coda/outbox separata.
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
  Future<void> upsert(FolderRow row) async {
    final db = await _db;
    await db.insert('folders', row.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Applica una riga ricevuta dal server con la stessa semantica
  /// Last-Write-Wins del backend: sovrascrive la copia locale solo se
  /// l'updated_at remoto è >= di quello locale (il server, per come è
  /// costruito il protocollo di sync, ha già risolto i conflitti: qui è solo
  /// una difesa in profondità contro modifiche locali fatte durante il
  /// round-trip di rete della sync stessa).
  ///
  /// `isExpanded` è puramente locale (il server non lo conosce: il suo
  /// FolderDTO non ha questo campo, vedi sync_models.dart), quindi viene
  /// sempre preservato dalla copia locale invece di essere perso
  /// nell'overwrite (altrimenti ogni cartella arrivata da un altro
  /// dispositivo ricomparirebbe forzatamente espansa).
  Future<void> applyRemoteLWW(FolderRow remote) async {
    final local = await getById(remote.id);
    if (local == null) {
      await upsert(remote);
      return;
    }
    if (remote.updatedAt >= local.updatedAt) {
      await upsert(remote.copyWith(isExpanded: local.isExpanded));
    }
  }

  Future<List<FolderRow>> listDirtySince(int sinceMillis) async {
    final db = await _db;
    final rows = await db.query('folders', where: 'updated_at > ?', whereArgs: [sinceMillis]);
    return rows.map(FolderRow.fromMap).toList();
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
    final queue = <String>[rootFolderId];
    final db = await _db;

    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);

      await deleteNotesInFolder(current, now);

      final childIds = await listActiveChildIds(current);
      if (childIds.isNotEmpty) {
        final batch = db.batch();
        for (final id in childIds) {
          batch.update(
            'folders',
            {'updated_at': now, 'deleted_at': now},
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
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete('folders', where: 'id IN ($placeholders)', whereArgs: ids);
  }

  Future<void> hardDeleteAll() async {
    final db = await _db;
    await db.delete('folders');
  }
}
