import 'dart:convert';

/// Speculare a `models.FolderDTO` nel backend Go: nessun campo di percorso,
/// solo id/parent_id.
class FolderChangeDto {
  final String id;
  final String name;
  final String? parentId;
  final int updatedAt; // unix millis UTC
  final int? deletedAt; // unix millis UTC, null = attiva

  const FolderChangeDto({
    required this.id,
    required this.name,
    required this.parentId,
    required this.updatedAt,
    required this.deletedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'parent_id': parentId,
        'updated_at': updatedAt,
        'deleted_at': deletedAt,
      };

  factory FolderChangeDto.fromJson(Map<String, dynamic> json) => FolderChangeDto(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        parentId: json['parent_id'] as String?,
        updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
        deletedAt: (json['deleted_at'] as num?)?.toInt(),
      );
}

/// Speculare a `models.NoteDTO` nel backend Go: il contenuto Markdown
/// viaggia per intero nel campo `content`, non più come file separato.
class NoteChangeDto {
  final String id;
  final String title;
  final String content;
  final String? folderId;
  final int updatedAt; // unix millis UTC
  final int? deletedAt; // unix millis UTC, null = attiva

  const NoteChangeDto({
    required this.id,
    required this.title,
    required this.content,
    required this.folderId,
    required this.updatedAt,
    required this.deletedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        'folder_id': folderId,
        'updated_at': updatedAt,
        'deleted_at': deletedAt,
      };

  factory NoteChangeDto.fromJson(Map<String, dynamic> json) => NoteChangeDto(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        content: json['content'] as String? ?? '',
        folderId: json['folder_id'] as String?,
        updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
        deletedAt: (json['deleted_at'] as num?)?.toInt(),
      );
}

/// Request body per POST /api/v1/sync — speculare a `models.SyncRequest`.
///
/// [lastSyncedAt] è il cursore restituito dal server nella risposta della
/// sync precedente (0 alla primissima sync di un dispositivo). [folders] e
/// [notes] contengono TUTTE le entità locali con `updated_at` maggiore di
/// quel cursore: non serve alcuna coda/outbox separata lato client, è
/// esattamente la query "cosa ho modificato dall'ultima sync" (vedi
/// SyncNotifier._collectDirtyFolders/_collectDirtyNotes).
class SyncRequest {
  final int lastSyncedAt;
  final List<FolderChangeDto> folders;
  final List<NoteChangeDto> notes;

  const SyncRequest({
    required this.lastSyncedAt,
    required this.folders,
    required this.notes,
  });

  Map<String, dynamic> toJson() => {
        'last_synced_at': lastSyncedAt,
        'folders': folders.map((f) => f.toJson()).toList(),
        'notes': notes.map((n) => n.toJson()).toList(),
      };
}

/// Response body da POST /api/v1/sync — speculare a `models.SyncResponse`.
///
/// [serverTime] è il nuovo cursore da salvare per la prossima sync.
/// [folders]/[notes] sono TUTTE le entità con `updated_at` maggiore del
/// cursore inviato nella richiesta: include sia le modifiche remote di altri
/// dispositivi sia l'esito (accettato o "server wins") di quanto appena
/// inviato. Non esistono più liste separate "accepted"/"server_wins".
class SyncResponse {
  final int serverTime;
  final List<FolderChangeDto> folders;
  final List<NoteChangeDto> notes;

  const SyncResponse({
    required this.serverTime,
    this.folders = const [],
    this.notes = const [],
  });

  factory SyncResponse.fromJson(Map<String, dynamic> json) {
    return SyncResponse(
      serverTime: (json['server_time'] as num?)?.toInt() ?? 0,
      folders: (json['folders'] as List<dynamic>?)
              ?.map((e) => FolderChangeDto.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      notes: (json['notes'] as List<dynamic>?)
              ?.map((e) => NoteChangeDto.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }
}

/// DTO for GET & PUT /api/v1/user/settings
class UserSettingsDto {
  final String theme; // "light" | "dark" | "system"
  final String colorScheme; // e.g. "dark_teal", "solarized", "nord"
  final String language; // "it", "en", "fr"
  final String fontFamily; // "Inter", "JetBrains Mono", etc.
  final int fontSize; // px/pt
  final double lineSpacing;
  final String layout; // "single_pane", "split", "grid"
  final int? updatedAt;

  const UserSettingsDto({
    this.theme = 'system',
    this.colorScheme = 'dark_teal',
    this.language = 'it',
    this.fontFamily = 'Inter',
    this.fontSize = 16,
    this.lineSpacing = 1.6,
    this.layout = 'split',
    this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'theme': theme,
        'color_scheme': colorScheme,
        'language': language,
        'font_family': fontFamily,
        'font_size': fontSize,
        'line_spacing': lineSpacing,
        'layout': layout,
        if (updatedAt != null) 'updated_at': updatedAt,
      };

  factory UserSettingsDto.fromJson(Map<String, dynamic> json) => UserSettingsDto(
        theme: json['theme'] as String? ?? 'system',
        colorScheme: json['color_scheme'] as String? ?? 'dark_teal',
        language: json['language'] as String? ?? 'it',
        fontFamily: json['font_family'] as String? ?? 'Inter',
        fontSize: (json['font_size'] as num?)?.toInt() ?? 16,
        lineSpacing: (json['line_spacing'] as num?)?.toDouble() ?? 1.6,
        layout: json['layout'] as String? ?? 'split',
        updatedAt: (json['updated_at'] as num?)?.toInt(),
      );

  String toJsonString() => json.encode(toJson());

  factory UserSettingsDto.fromJsonString(String source) =>
      UserSettingsDto.fromJson(json.decode(source) as Map<String, dynamic>);
}

/// DTO for POST /api/v1/auth/login response
class LoginResponseDto {
  final String token;
  final int expiresAt;
  final String userId;
  final String username;

  const LoginResponseDto({
    required this.token,
    required this.expiresAt,
    required this.userId,
    required this.username,
  });

  factory LoginResponseDto.fromJson(Map<String, dynamic> json) => LoginResponseDto(
        token: json['token'] as String? ?? '',
        expiresAt: (json['expires_at'] as num?)?.toInt() ?? 0,
        userId: json['user_id'] as String? ?? '',
        username: json['username'] as String? ?? '',
      );
}
