import 'package:sqflite/sqflite.dart';

import 'app_database.dart';

/// Riga grezza della tabella `notes`. `createdAt` esiste solo localmente
/// (serve per l'ordinamento "data di creazione" in UI): non viene mai
/// inviato al server, che non ha una colonna corrispondente nel proprio
/// schema (vedi `models.NoteDTO` nel backend).
class NoteRow {
  final String id;
  final String title;
  final String content;
  final String? folderId;
  final bool isFavorite;
  final bool isPinned;
  final int orderIndex;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;

  const NoteRow({
    required this.id,
    required this.title,
    required this.content,
    required this.folderId,
    required this.isFavorite,
    required this.isPinned,
    required this.orderIndex,
    required this.createdAt,
    required this.updatedAt,
    required this.deletedAt,
  });

  bool get isDeleted => deletedAt != null;

  factory NoteRow.fromMap(Map<String, Object?> m) => NoteRow(
        id: m['id'] as String,
        title: m['title'] as String,
        content: m['content'] as String,
        folderId: m['folder_id'] as String?,
        isFavorite: (m['is_favorite'] as int) != 0,
        isPinned: (m['is_pinned'] as int) != 0,
        orderIndex: m['order_index'] as int,
        createdAt: m['created_at'] as int,
        updatedAt: m['updated_at'] as int,
        deletedAt: m['deleted_at'] as int?,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'content': content,
        'folder_id': folderId,
        'is_favorite': isFavorite ? 1 : 0,
        'is_pinned': isPinned ? 1 : 0,
        'order_index': orderIndex,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'deleted_at': deletedAt,
      };

  NoteRow copyWith({
    String? title,
    String? content,
    Object? folderId = _unset,
    bool? isFavorite,
    bool? isPinned,
    int? orderIndex,
    int? updatedAt,
    Object? deletedAt = _unset,
  }) {
    return NoteRow(
      id: id,
      title: title ?? this.title,
      content: content ?? this.content,
      folderId: identical(folderId, _unset) ? this.folderId : folderId as String?,
      isFavorite: isFavorite ?? this.isFavorite,
      isPinned: isPinned ?? this.isPinned,
      orderIndex: orderIndex ?? this.orderIndex,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: identical(deletedAt, _unset) ? this.deletedAt : deletedAt as int?,
    );
  }
}

const Object _unset = Object();

/// Data Access Object per le note. Ogni mutazione locale imposta `updated_at`
/// (per la risoluzione LWW) e `dirty = 1` (per decidere cosa spingere al
/// server); le righe applicate dalla pull sono scritte con `dirty = 0`.
class NotesDao {
  Future<Database> get _db => AppDatabase.instance.db;

  /// Tutte le note attive (non cancellate). È la SINGOLA query da cui
  /// derivano sia la vista "Tutte le note" sia le viste per cartella (che
  /// sono un semplice filtro applicato in memoria da filteredNotesProvider):
  /// nessuna delle due interroga mai il DB con criteri diversi da questo.
  Future<List<NoteRow>> getActive() async {
    final db = await _db;
    final rows = await db.query('notes', where: 'deleted_at IS NULL', orderBy: 'updated_at DESC');
    return rows.map(NoteRow.fromMap).toList();
  }

  Future<NoteRow?> getById(String id) async {
    final db = await _db;
    final rows = await db.query('notes', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return NoteRow.fromMap(rows.first);
  }

  /// Scrittura LOCALE (mutazione dell'utente): la riga viene marcata
  /// `dirty = 1`, cioè "da inviare al server". Il flag è la sola fonte di
  /// verità per la selezione del push: NON si confronta più `updated_at`
  /// (orologio del client) con il cursore di sync (orologio del server),
  /// perché con clock skew si perdevano modifiche o si rispedivano righe
  /// inutilmente.
  Future<void> upsert(NoteRow row) async {
    final db = await _db;
    await db.insert('notes', {...row.toMap(), 'dirty': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Applica una riga ricevuta dal server (vedi [applyRemoteLWWBatch]).
  Future<void> applyRemoteLWW(NoteRow remote) => applyRemoteLWWBatch([remote]);

  /// Applica righe ricevute dal server in un'UNICA transazione.
  ///
  /// Regola: la copia remota sostituisce quella locale se
  ///  - la riga locale non esiste, oppure
  ///  - la riga locale è PULITA (`dirty = 0`, nessuna modifica in attesa di
  ///    invio): il server è autoritativo (include il caso in cui il server
  ///    ha corretto un timestamp con clock skew o ha risolto un conflitto), oppure
  ///  - la copia remota è più recente o uguale (`updated_at`, LWW).
  /// Una riga locale SPORCA e più recente resta intatta (e dirty): la
  /// modifica non ancora inviata non viene mai cancellata da una pull.
  /// Le righe applicate diventano pulite (`dirty = 0`).
  ///
  /// `createdAt` è puramente locale (il server non lo conosce): viene
  /// preservato dalla copia locale.
  Future<void> applyRemoteLWWBatch(List<NoteRow> remotes) async {
    if (remotes.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      for (final remote in remotes) {
        final rows = await txn.query('notes', where: 'id = ?', whereArgs: [remote.id], limit: 1);
        if (rows.isEmpty) {
          await txn.insert('notes', {...remote.toMap(), 'dirty': 0}, conflictAlgorithm: ConflictAlgorithm.replace);
          continue;
        }
        final local = NoteRow.fromMap(rows.first);
        final localIsDirty = (rows.first['dirty'] as int? ?? 1) != 0;
        if (!localIsDirty || remote.updatedAt >= local.updatedAt) {
          final merged = NoteRow(
            id: remote.id,
            title: remote.title,
            content: remote.content,
            folderId: remote.folderId,
            isFavorite: remote.isFavorite,
            isPinned: remote.isPinned,
            orderIndex: remote.orderIndex,
            createdAt: local.createdAt,
            updatedAt: remote.updatedAt,
            deletedAt: remote.deletedAt,
          );
          await txn.insert('notes', {...merged.toMap(), 'dirty': 0}, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
  }

  /// Scrive più righe in un'unica transazione (usato da
  /// `NotesNotifier.reorderNotes`, dove altrimenti un riordino coinvolgerebbe
  /// N scritture sequenziali separate, una per nota).
  Future<void> upsertBatch(List<NoteRow> rows) async {
    if (rows.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      for (final row in rows) {
        await txn.insert('notes', {...row.toMap(), 'dirty': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// Righe con modifiche locali non ancora confermate dal server.
  Future<List<NoteRow>> listDirty() async {
    final db = await _db;
    final rows = await db.query('notes', where: 'dirty = 1');
    return rows.map(NoteRow.fromMap).toList();
  }

  /// Segna come pulite le righe appena inviate, MA solo se non sono state
  /// modificate di nuovo durante il round-trip di rete: la condizione su
  /// `updated_at` (valore che era stato inviato) evita di perdere una
  /// modifica fatta mentre la sync era in corso.
  Future<void> markSynced(Map<String, int> idToPushedUpdatedAt) async {
    if (idToPushedUpdatedAt.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      for (final e in idToPushedUpdatedAt.entries) {
        await txn.update('notes', {'dirty': 0}, where: 'id = ? AND updated_at = ?', whereArgs: [e.key, e.value]);
      }
    });
  }

  /// Elimina fisicamente i tombstone già confermati dal server
  /// (`deleted_at` valorizzato e `dirty = 0`): non servono più a nessuno,
  /// gli altri dispositivi li ricevono dal server.
  Future<void> purgeCleanTombstones() async {
    final db = await _db;
    await db.delete('notes', where: 'deleted_at IS NOT NULL AND dirty = 0');
  }

  /// Dopo un `full_resync` (il server ha risposto con lo stato completo):
  /// elimina le righe PULITE che il server non conosce più (es. tombstone
  /// purgati mentre il dispositivo era offline). Le righe sporche restano.
  Future<void> deleteCleanNotIn(Set<String> serverIds) async {
    final db = await _db;
    final rows = await db.query('notes', columns: ['id'], where: 'dirty = 0');
    final stale = [for (final r in rows) r['id'] as String]..removeWhere(serverIds.contains);
    await hardDeleteIds(stale);
  }

  /// Soft-delete di tutte le note attive di una cartella, usata dalla
  /// cascade quando quella cartella (o un suo antenato) viene cancellata.
  Future<void> softDeleteByFolder(String folderId, int now) async {
    final db = await _db;
    await db.update(
      'notes',
      {'updated_at': now, 'deleted_at': now, 'dirty': 1},
      where: 'folder_id = ? AND deleted_at IS NULL',
      whereArgs: [folderId],
    );
  }

  Future<void> hardDeleteIds(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await _db;
    // A blocchi: SQLite limita il numero di variabili per statement (999).
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      final placeholders = List.filled(chunk.length, '?').join(',');
      await db.delete('notes', where: 'id IN ($placeholders)', whereArgs: chunk);
    }
  }

  Future<void> hardDeleteAll() async {
    final db = await _db;
    await db.delete('notes');
  }
}
