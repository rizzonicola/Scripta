import 'package:sqflite/sqflite.dart';

import 'app_database.dart';
import 'sql_helpers.dart';

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

/// Metadati minimi di una riga locale per la risoluzione LWW in
/// [FoldersDao.applyRemoteLWWBatch] (`isExpanded` è solo locale e va sempre
/// preservato).
typedef _LocalFolderMeta = ({bool isExpanded, int updatedAt, bool dirty});

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
  /// Stesso schema di costo: letture raggruppate per blocco di id + un solo
  /// batch di scritture.
  Future<void> applyRemoteLWWBatch(List<FolderRow> remotes) async {
    if (remotes.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      final local = <String, _LocalFolderMeta>{};
      for (final ids in chunked([for (final r in remotes) r.id])) {
        final rows = await txn.rawQuery(
          'SELECT id, is_expanded, updated_at, dirty FROM folders WHERE id IN (${sqlPlaceholders(ids.length)})',
          ids,
        );
        for (final row in rows) {
          local[row['id'] as String] = (
            isExpanded: (row['is_expanded'] as int) != 0,
            updatedAt: row['updated_at'] as int,
            dirty: (row['dirty'] as int? ?? 1) != 0,
          );
        }
      }

      final batch = txn.batch();
      for (final remote in remotes) {
        final existing = local[remote.id];
        final bool isExpanded;
        if (existing == null) {
          isExpanded = remote.isExpanded;
        } else if (existing.dirty && remote.updatedAt < existing.updatedAt) {
          continue; // modifica locale non ancora inviata e più recente: resta
        } else {
          isExpanded = existing.isExpanded;
        }
        batch.insert(
          'folders',
          {...remote.copyWith(isExpanded: isExpanded).toMap(), 'dirty': 0},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        local[remote.id] = (isExpanded: isExpanded, updatedAt: remote.updatedAt, dirty: false);
      }
      await batch.commit(noResult: true);
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
    final batch = db.batch();
    for (final e in idToPushedUpdatedAt.entries) {
      batch.update('folders', {'dirty': 0}, where: 'id = ? AND updated_at = ?', whereArgs: [e.key, e.value]);
    }
    await batch.commit(noResult: true);
  }

  /// Elimina i tombstone già confermati dal server (`dirty = 0`). Stessa
  /// forma a sotto-query di `NotesDao.purgeCleanTombstones` (usa l'indice
  /// parziale `idx_folders_tombstones`).
  Future<void> purgeCleanTombstones() async {
    final db = await _db;
    await db.rawDelete(
      'DELETE FROM folders WHERE dirty = 0 AND id IN '
      '(SELECT id FROM folders WHERE deleted_at IS NOT NULL)',
    );
  }

  /// Dopo un `full_resync`: elimina le righe pulite sconosciute al server
  /// (la DELETE ripete `dirty = 0`, vedi `NotesDao.deleteCleanNotIn`).
  Future<void> deleteCleanNotIn(Set<String> serverIds) async {
    final db = await _db;
    final rows = await db.query('folders', columns: ['id'], where: 'dirty = 0');
    final stale = [for (final r in rows) r['id'] as String]..removeWhere(serverIds.contains);
    await deleteByIds(db, 'folders', stale, onlyClean: true);
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

  /// Propaga la cancellazione di una cartella a tutte le sottocartelle e
  /// note ancora attive al suo interno, usando lo stesso timestamp per
  /// l'intero sottoalbero. Speculare alla cascade server-side in
  /// `internal/handlers/api_sync.go`, così che anche in assenza di
  /// connettività l'utente veda immediatamente sparire l'intero sottoalbero,
  /// senza dover attendere la prossima sync.
  ///
  /// RESISTENZA ALLA CHIUSURA IMPROVVISA: prima le righe delle cartelle
  /// venivano marcate una alla volta (radice per prima) con statement
  /// separati; un kill dell'app a metà lasciava la radice cancellata e
  /// sottocartelle/note ancora attive ("orfane" di un genitore tombstone),
  /// visibili in "Tutte le note" fino alla sync successiva. Ora:
  ///  1. il sottoalbero attivo si calcola con UNA sola lettura (in memoria,
  ///     senza una query per livello);
  ///  2. si cancellano PRIMA le note di ogni cartella;
  ///  3. infine le cartelle, tutte insieme in UNA transazione.
  /// Se l'app viene interrotta tra 2 e 3 le note risultano già cancellate
  /// (e `dirty`) e le cartelle restano attive ma vuote: nessuno stato
  /// incoerente, e ripetere l'eliminazione completa l'operazione.
  ///
  /// La radice viene marcata cancellata anche se lo era già (come prima):
  /// senza questo UPDATE la sua riga resterebbe con `deleted_at = NULL` e
  /// non sarebbe mai inviata al server.
  Future<void> cascadeSoftDelete(
    String rootFolderId,
    int now, {
    required Future<void> Function(String folderId, int now) deleteNotesInFolder,
  }) async {
    final db = await _db;
    final subtree = await _collectActiveSubtreeIds(db, rootFolderId);

    for (final folderId in subtree) {
      await deleteNotesInFolder(folderId, now);
    }

    await db.transaction((txn) async {
      for (final ids in chunked(subtree)) {
        await txn.rawUpdate(
          'UPDATE folders SET updated_at = ?, deleted_at = ?, dirty = 1 '
          'WHERE id IN (${sqlPlaceholders(ids.length)})',
          [now, now, ...ids],
        );
      }
    });
  }

  /// ID della cartella [rootId] (sempre incluso, per primo) e di tutte le sue
  /// discendenti ATTIVE, in ampiezza. Una sola query sulle cartelle attive
  /// (poche, per natura) e visita in memoria; il set `seen` rende la visita
  /// sicura anche con riferimenti `parent_id` ciclici in un database
  /// corrotto.
  Future<List<String>> _collectActiveSubtreeIds(Database db, String rootId) async {
    final rows = await db.query('folders', columns: ['id', 'parent_id'], where: 'deleted_at IS NULL');
    final childrenByParent = <String, List<String>>{};
    for (final r in rows) {
      final parent = r['parent_id'] as String?;
      if (parent == null) continue;
      (childrenByParent[parent] ??= <String>[]).add(r['id'] as String);
    }

    final result = <String>[rootId];
    final seen = <String>{rootId};
    for (var i = 0; i < result.length; i++) {
      for (final child in childrenByParent[result[i]] ?? const <String>[]) {
        if (seen.add(child)) result.add(child);
      }
    }
    return result;
  }

  Future<void> hardDeleteIds(List<String> ids) async {
    if (ids.isEmpty) return;
    await deleteByIds(await _db, 'folders', ids);
  }

  Future<void> hardDeleteAll() async {
    final db = await _db;
    await db.delete('folders');
  }
}
