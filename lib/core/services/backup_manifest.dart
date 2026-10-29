import 'dart:convert';

/// Nome del file di metadati scritto alla radice di ogni backup Scripta.
const String backupManifestFileName = 'scripta-backup.json';
const String backupManifestFormat = 'scripta-backup';
const int backupManifestVersion = 1;

/// Metadati di una nota nel manifest. `path` è il percorso della voce ZIP
/// (con `/`) e serve a collegare il manifest al file Markdown corrispondente.
class BackupNote {
  final String path;
  final String id;
  final String title;
  final String content;
  final String? folderId;
  final bool isFavorite;
  final bool isPinned;
  final int orderIndex;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const BackupNote({
    required this.path,
    required this.id,
    required this.title,
    required this.content,
    required this.folderId,
    required this.isFavorite,
    required this.isPinned,
    required this.orderIndex,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, Object?> toJson() => {
    'path': path,
    'id': id,
    'title': title,
    'content': content,
    'folderId': folderId,
    'isFavorite': isFavorite,
    'isPinned': isPinned,
    'orderIndex': orderIndex,
    'createdAt': createdAt?.toUtc().toIso8601String(),
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
  };

  factory BackupNote.fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    if (path is! String || path.trim().isEmpty) {
      throw const FormatException('Manifest: nota senza path');
    }
    return BackupNote(
      path: path,
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      folderId: json['folderId'] as String?,
      isFavorite: json['isFavorite'] as bool? ?? false,
      isPinned: json['isPinned'] as bool? ?? false,
      orderIndex: (json['orderIndex'] as num?)?.toInt() ?? 0,
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
    );
  }
}

/// Cartella del backup, incluse quelle vuote (che non hanno file Markdown e
/// quindi andrebbero perse senza manifest). `path` è relativo alla radice
/// dell'archivio e non include la cartella contenitore `Non_Catalogate`.
class BackupFolder {
  final String id;
  final String name;
  final String? parentId;
  final String path;

  const BackupFolder({
    required this.id,
    required this.name,
    required this.parentId,
    required this.path,
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'parentId': parentId,
    'path': path,
  };

  factory BackupFolder.fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    if (path is! String || path.trim().isEmpty) {
      throw const FormatException('Manifest: cartella senza path');
    }
    return BackupFolder(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      parentId: json['parentId'] as String?,
      path: path,
    );
  }
}

/// Manifest versionato del backup. È volutamente composto solo da tipi
/// primitivi: viene costruito e letto anche negli isolate di export/import.
class BackupManifest {
  final int version;
  final List<BackupFolder> folders;
  final List<BackupNote> notes;
  final Map<String, Object?>? settings;

  const BackupManifest({
    this.version = backupManifestVersion,
    required this.folders,
    required this.notes,
    this.settings,
  });

  Map<String, Object?> toJson() => {
    'format': backupManifestFormat,
    'version': version,
    'folders': [for (final folder in folders) folder.toJson()],
    'notes': [for (final note in notes) note.toJson()],
    if (settings != null) 'settings': settings,
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory BackupManifest.fromJson(Map<String, dynamic> json) {
    if (json['format'] != backupManifestFormat) {
      throw const FormatException('Manifest: formato non riconosciuto');
    }
    final version = (json['version'] as num?)?.toInt();
    if (version == null || version < 1) {
      throw const FormatException('Manifest: versione mancante');
    }
    if (version > backupManifestVersion) {
      throw FormatException(
        'Manifest creato da una versione più recente di Scripta '
        '(versione $version, supportata fino a $backupManifestVersion)',
      );
    }

    final rawFolders = json['folders'];
    final rawNotes = json['notes'];
    if (rawFolders is! List || rawNotes is! List) {
      throw const FormatException('Manifest: folders/notes mancanti');
    }

    final rawSettings = json['settings'];
    return BackupManifest(
      version: version,
      folders: [
        for (final item in rawFolders)
          if (item is Map)
            BackupFolder.fromJson(Map<String, dynamic>.from(item)),
      ],
      notes: [
        for (final item in rawNotes)
          if (item is Map) BackupNote.fromJson(Map<String, dynamic>.from(item)),
      ],
      settings: rawSettings is Map
          ? Map<String, Object?>.from(rawSettings)
          : null,
    );
  }

  static BackupManifest decode(String source) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const FormatException('Manifest: JSON malformato');
    }
    if (decoded is! Map) {
      throw const FormatException('Manifest: oggetto JSON atteso');
    }
    return BackupManifest.fromJson(Map<String, dynamic>.from(decoded));
  }
}

DateTime? _parseDate(Object? value) {
  if (value is String) return DateTime.tryParse(value);
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
  }
  return null;
}
