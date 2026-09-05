import 'dart:convert';

/// Representation of a single note sent from the client to the server during sync.
class NoteChange {
  final String relativePath;
  final String content;
  final int updatedAt; // Unix millis
  final bool deleted;

  /// Previous relative path of the note, set only when the note has been
  /// moved to a different folder since the last successful sync. Lets the
  /// backend rename/move the underlying file on disk instead of creating a
  /// duplicate at the new path.
  final String? oldRelativePath;

  /// Marks this change as representing a folder (not a note file). Used so
  /// the backend can materialize/persist empty folders that contain no
  /// note files yet.
  final bool isFolder;

  const NoteChange({
    required this.relativePath,
    required this.content,
    required this.updatedAt,
    this.deleted = false,
    this.oldRelativePath,
    this.isFolder = false,
  });

  Map<String, dynamic> toJson() => {
        'relative_path': relativePath,
        'content': content,
        'updated_at': updatedAt,
        'deleted': deleted,
        if (oldRelativePath != null && oldRelativePath!.isNotEmpty)
          'old_relative_path': oldRelativePath,
        'is_folder': isFolder,
      };

  factory NoteChange.fromJson(Map<String, dynamic> json) => NoteChange(
        relativePath: json['relative_path'] as String? ?? '',
        content: json['content'] as String? ?? '',
        updatedAt: json['updated_at'] as int? ?? 0,
        deleted: json['deleted'] as bool? ?? false,
        oldRelativePath: json['old_relative_path'] as String?,
        isFolder: json['is_folder'] as bool? ?? false,
      );
}

/// Representation of a note returned by the server (accepted or server_wins).
class NoteResult {
  final String relativePath;
  final String? content;
  final int updatedAt; // Unix millis
  final bool deleted;

  const NoteResult({
    required this.relativePath,
    this.content,
    required this.updatedAt,
    this.deleted = false,
  });

  Map<String, dynamic> toJson() => {
        'relative_path': relativePath,
        if (content != null) 'content': content,
        'updated_at': updatedAt,
        'deleted': deleted,
      };

  factory NoteResult.fromJson(Map<String, dynamic> json) => NoteResult(
        relativePath: json['relative_path'] as String? ?? '',
        content: json['content'] as String?,
        updatedAt: json['updated_at'] as int? ?? 0,
        deleted: json['deleted'] as bool? ?? false,
      );
}

/// Request body for POST /api/v1/sync
class SyncRequest {
  final List<NoteChange> notes;

  const SyncRequest({required this.notes});

  Map<String, dynamic> toJson() => {
        'notes': notes.map((n) => n.toJson()).toList(),
      };
}

/// Response body from POST /api/v1/sync
class SyncResponse {
  final List<NoteResult> accepted;
  final List<NoteResult> serverWins;

  const SyncResponse({
    this.accepted = const [],
    this.serverWins = const [],
  });

  factory SyncResponse.fromJson(Map<String, dynamic> json) {
    return SyncResponse(
      accepted: (json['accepted'] as List<dynamic>?)
              ?.map((e) => NoteResult.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      serverWins: (json['server_wins'] as List<dynamic>?)
              ?.map((e) => NoteResult.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
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
