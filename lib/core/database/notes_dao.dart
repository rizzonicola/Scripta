import 'package:sqflite/sqflite.dart';

import 'app_database.dart';
import 'sql_helpers.dart';

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

/// Metadati minimi di una riga locale necessari a decidere la risoluzione
/// LWW in [NotesDao.applyRemoteLWWBatch]: si leggono SOLO queste colonne,
/// senza caricare `content` (che per note lunghe pesa molto di più del resto).
typedef _LocalNoteMeta = ({int createdAt, int updatedAt, bool dirty});

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
  ///
  /// Costo: una SELECT per blocco di 500 id (solo i metadati, non il
  /// contenuto) più UN batch di scritture, invece di due round-trip verso il
  /// motore SQLite per ogni nota ricevuta. Su una prima sync con migliaia di
  /// note la differenza è di ordini di grandezza (su Android ogni chiamata
  /// attraversa un platform channel). Se lo stesso id compare più volte nella
  /// risposta, lo stato locale tenuto in memoria viene aggiornato a ogni
  /// scrittura, così il risultato è identico a quello di un'applicazione
  /// sequenziale riga per riga.
  Future<void> applyRemoteLWWBatch(List<NoteRow> remotes) async {
    if (remotes.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      final local = <String, _LocalNoteMeta>{};
      for (final ids in chunked([for (final r in remotes) r.id])) {
        final rows = await txn.rawQuery(
          'SELECT id, created_at, updated_at, dirty FROM notes WHERE id IN (${sqlPlaceholders(ids.length)})',
          ids,
        );
        for (final row in rows) {
          local[row['id'] as String] = (
            createdAt: row['created_at'] as int,
            updatedAt: row['updated_at'] as int,
            dirty: (row['dirty'] as int? ?? 1) != 0,
          );
        }
      }

      final batch = txn.batch();
      for (final remote in remotes) {
        final existing = local[remote.id];
        final int createdAt;
        if (existing == null) {
          createdAt = remote.createdAt;
        } else if (existing.dirty && remote.updatedAt < existing.updatedAt) {
          continue; // modifica locale non ancora inviata e più recente: resta
        } else {
          // La creazione non può essere posteriore a una modifica
          // conosciuta: se la copia remota è più vecchia della data di
          // creazione locale (clock skew, o data di ripiego), si usa la
          // stima migliore invece di mostrare una nota "creata dopo
          // l'ultima modifica".
          createdAt = existing.createdAt <= remote.updatedAt ? existing.createdAt : remote.updatedAt;
        }
        batch.insert(
          'notes',
          {...remote.toMap(), 'created_at': createdAt, 'dirty': 0},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        local[remote.id] = (createdAt: createdAt, updatedAt: remote.updatedAt, dirty: false);
      }
      await batch.commit(noResult: true);
    });
  }

  /// Scrive più righe in un'unica transazione (usato da
  /// `NotesNotifier.reorderNotes` e dall'importazione in blocco): un solo
  /// batch atomico invece di N scritture sequenziali separate, una per nota.
  Future<void> upsertBatch(List<NoteRow> rows) async {
    if (rows.isEmpty) return;
    final db = await _db;
    final batch = db.batch();
    for (final row in rows) {
      batch.insert('notes', {...row.toMap(), 'dirty': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
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
    final batch = db.batch();
    for (final e in idToPushedUpdatedAt.entries) {
      batch.update('notes', {'dirty': 0}, where: 'id = ? AND updated_at = ?', whereArgs: [e.key, e.value]);
    }
    await batch.commit(noResult: true);
  }

  /// Elimina fisicamente i tombstone già confermati dal server
  /// (`deleted_at` valorizzato e `dirty = 0`): non servono più a nessuno,
  /// gli altri dispositivi li ricevono dal server.
  ///
  /// La sotto-query isola il solo predicato `deleted_at IS NOT NULL`, così il
  /// planner può risolverlo con l'indice parziale `idx_notes_tombstones`
  /// (covering: poche righe). Nella forma piatta `deleted_at IS NOT NULL AND
  /// dirty = 0` SQLite, senza statistiche, tende a considerare `dirty = 0`
  /// molto selettivo e a scegliere `idx_notes_dirty`, anche se quel valore
  /// riguarda quasi tutte le righe: lavoro proporzionale alla dimensione
  /// dell'archivio ad ogni sync. Il risultato è identico.
  Future<void> purgeCleanTombstones() async {
    final db = await _db;
    await db.rawDelete(
      'DELETE FROM notes WHERE dirty = 0 AND id IN '
      '(SELECT id FROM notes WHERE deleted_at IS NOT NULL)',
    );
  }

  /// Dopo un `full_resync` (il server ha risposto con lo stato completo):
  /// elimina le righe PULITE che il server non conosce più (es. tombstone
  /// purgati mentre il dispositivo era offline). Le righe sporche restano:
  /// la DELETE ripete `dirty = 0`, quindi una nota modificata dall'utente
  /// mentre la sync era in corso non viene eliminata.
  Future<void> deleteCleanNotIn(Set<String> serverIds) async {
    final db = await _db;
    final rows = await db.query('notes', columns: ['id'], where: 'dirty = 0');
    final stale = [for (final r in rows) r['id'] as String]..removeWhere(serverIds.contains);
    await deleteByIds(db, 'notes', stale, onlyClean: true);
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
    await deleteByIds(await _db, 'notes', ids);
  }

  Future<void> hardDeleteAll() async {
    final db = await _db;
    await db.delete('notes');
  }
}
