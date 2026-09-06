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

/// Data Access Object per le note. Come [FoldersDao], ogni mutazione imposta
/// sempre `updated_at`: è il segnale unico che la sync usa per decidere cosa
/// spingere al server, senza bisogno di una coda/outbox separata.
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

  Future<void> upsert(NoteRow row) async {
    final db = await _db;
    await db.insert('notes', row.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Applica una riga ricevuta dal server con semantica Last-Write-Wins
  /// (vedi il commento analogo in FoldersDao.applyRemoteLWW).
  Future<void> applyRemoteLWW(NoteRow remote) async {
    final local = await getById(remote.id);
    if (local == null) {
      await upsert(remote);
      return;
    }
    if (remote.updatedAt >= local.updatedAt) {
      // createdAt è puramente locale: il server non lo conosce (il suo
      // NoteDTO non ha questo campo), quindi lo preserviamo dalla copia
      // locale invece di perderlo nell'overwrite.
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
      await upsert(merged);
    }
  }

  Future<List<NoteRow>> listDirtySince(int sinceMillis) async {
    final db = await _db;
    final rows = await db.query('notes', where: 'updated_at > ?', whereArgs: [sinceMillis]);
    return rows.map(NoteRow.fromMap).toList();
  }

  /// Soft-delete di tutte le note attive di una cartella, usata dalla
  /// cascade quando quella cartella (o un suo antenato) viene cancellata.
  Future<void> softDeleteByFolder(String folderId, int now) async {
    final db = await _db;
    await db.update(
      'notes',
      {'updated_at': now, 'deleted_at': now},
      where: 'folder_id = ? AND deleted_at IS NULL',
      whereArgs: [folderId],
    );
  }

  Future<void> hardDeleteIds(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await _db;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete('notes', where: 'id IN ($placeholders)', whereArgs: ids);
  }

  Future<void> hardDeleteAll() async {
    final db = await _db;
    await db.delete('notes');
  }
}
