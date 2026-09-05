import 'dart:convert';

enum NoteSortOrder {
  updatedDesc,
  updatedAsc,
  createdDesc,
  createdAsc,
  titleAsc,
  titleDesc,
  custom,
}

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
  final String? relativePath;

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
    this.relativePath,
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
    String? Function()? relativePath,
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
      relativePath: relativePath != null ? relativePath() : this.relativePath,
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

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'folderId': folderId,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'isFavorite': isFavorite,
      'isPinned': isPinned,
      'orderIndex': orderIndex,
      'relativePath': relativePath,
    };
  }

  factory NoteModel.fromMap(Map<String, dynamic> map) {
    return NoteModel(
      id: map['id'] ?? '',
      title: map['title'] ?? '',
      content: map['content'] ?? '',
      folderId: map['folderId'],
      createdAt: DateTime.tryParse(map['createdAt'] ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(map['updatedAt'] ?? '') ?? DateTime.now(),
      isFavorite: map['isFavorite'] ?? false,
      isPinned: map['isPinned'] ?? false,
      orderIndex: map['orderIndex'] ?? 0,
      relativePath: map['relativePath'],
    );
  }

  String toJson() => json.encode(toMap());

  factory NoteModel.fromJson(String source) =>
      NoteModel.fromMap(json.decode(source));
}
