import '../../../core/database/notes_dao.dart';

enum NoteSortOrder {
  updatedDesc,
  updatedAsc,
  createdDesc,
  createdAsc,
  titleAsc,
  titleDesc,
  custom,
}

/// Modello di dominio di una nota, usato da UI e provider.
///
/// A differenza della generazione precedente, NON esiste più alcun concetto
/// di percorso (niente `relativePath`, niente `pendingOldRelativePath`): la
/// posizione di una nota è determinata unicamente da [folderId] (null =
/// nessuna cartella, la nota compare comunque in "Tutte le note"). Spostare
/// una nota tra cartelle è un semplice cambio di [folderId], propagato alla
/// sync come un normale aggiornamento con un nuovo `updated_at` — non più un
/// "vecchio percorso / nuovo percorso" da riconciliare lato server.
class NoteModel {
  final String id;
  final String title;
  final String content;
  final String? folderId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isFavorite;
  final bool isPinned;
  final int orderIndex;

  const NoteModel({
    required this.id,
    required this.title,
    required this.content,
    this.folderId,
    required this.createdAt,
    required this.updatedAt,
    this.isFavorite = false,
    this.isPinned = false,
    this.orderIndex = 0,
  });

  NoteModel copyWith({
    String? id,
    String? title,
    String? content,
    String? Function()? folderId,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isFavorite,
    bool? isPinned,
    int? orderIndex,
  }) {
    return NoteModel(
      id: id ?? this.id,
      title: title ?? this.title,
      content: content ?? this.content,
      folderId: folderId != null ? folderId() : this.folderId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isFavorite: isFavorite ?? this.isFavorite,
      isPinned: isPinned ?? this.isPinned,
      orderIndex: orderIndex ?? this.orderIndex,
    );
  }

  int get wordCount {
    if (content.trim().isEmpty) return 0;
    return content.trim().split(RegExp(r'\s+')).length;
  }

  int get characterCount => content.length;

  int get readingTimeMinutes {
    final words = wordCount;
    return (words / 200).ceil().clamp(1, 999);
  }

  String get previewSnippet {
    // Strip markdown formatting symbols for clean preview
    final cleaned = content
        .replaceAll(RegExp(r'#+\s*'), '')
        .replaceAll(RegExp(r'\*+'), '')
        .replaceAll(RegExp(r'`+'), '')
        .replaceAll(RegExp(r'\[(.*?)\]\(.*?\)'), r'$1')
        .replaceAll(RegExp(r'- \[( |x)\]'), '')
        .trim();
    if (cleaned.isEmpty) return 'Nessun testo aggiuntivo';
    return cleaned.length > 120 ? '${cleaned.substring(0, 120)}...' : cleaned;
  }

  /// Converte la riga grezza del database locale nel modello di dominio.
  factory NoteModel.fromRow(NoteRow row) {
    return NoteModel(
      id: row.id,
      title: row.title,
      content: row.content,
      folderId: row.folderId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt, isUtc: true).toLocal(),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt, isUtc: true).toLocal(),
      isFavorite: row.isFavorite,
      isPinned: row.isPinned,
      orderIndex: row.orderIndex,
    );
  }

  /// Converte verso la riga grezza da persistere. [deletedAt] resta a carico
  /// del chiamante (NotesNotifier), che lo valorizza solo per le operazioni
  /// di soft-delete: un NoteModel visibile in UI è per definizione sempre
  /// attivo, quindi il modello di dominio stesso non porta questo campo.
  NoteRow toRow({int? deletedAt}) {
    return NoteRow(
      id: id,
      title: title,
      content: content,
      folderId: folderId,
      isFavorite: isFavorite,
      isPinned: isPinned,
      orderIndex: orderIndex,
      createdAt: createdAt.toUtc().millisecondsSinceEpoch,
      updatedAt: updatedAt.toUtc().millisecondsSinceEpoch,
      deletedAt: deletedAt,
    );
  }
}
