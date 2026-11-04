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

  factory FolderChangeDto.fromJson(Map<String, dynamic> json) =>
      FolderChangeDto(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        parentId: json['parent_id'] as String?,
        updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
        deletedAt: (json['deleted_at'] as num?)?.toInt(),
      );
}

/// Speculare a `models.NoteDTO` nel backend Go: il contenuto Markdown
/// viaggia per intero nel campo `content`, non più come file separato.
///
/// [isFavorite]/[isPinned]/[orderIndex]/[createdAt] sono metadati della nota
/// esattamente come [title]/[content]/[folderId]: viaggiano nel protocollo
/// di sync e sono soggetti alla stessa risoluzione LWW basata su
/// [updatedAt]. In precedenza questo DTO non li includeva affatto, quindi
/// impostare/rimuovere il pin in locale non veniva mai inviato al server né
/// mai restituito dalla pull: il giro di sync successivo applicava
/// comunque localmente la nota appena echeggiata dal server (con
/// updated_at >= a quello locale), sovrascrivendo silenziosamente isPinned
/// con un default false — questa era la causa del bug "il pin non
/// persiste dopo la sync". Stessa storia per [createdAt], che prima era
/// solo locale e quindi non seguiva l'utente sugli altri dispositivi.
class NoteChangeDto {
  final String id;
  final String title;
  final String content;
  final String? folderId;
  final bool isFavorite;
  final bool isPinned;
  final int orderIndex;
  final int createdAt; // unix millis UTC
  final int updatedAt; // unix millis UTC
  final int? deletedAt; // unix millis UTC, null = attiva

  const NoteChangeDto({
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

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'content': content,
    'folder_id': folderId,
    'is_favorite': isFavorite,
    'is_pinned': isPinned,
    'order_index': orderIndex,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'deleted_at': deletedAt,
  };

  factory NoteChangeDto.fromJson(Map<String, dynamic> json) {
    final updatedAt = (json['updated_at'] as num?)?.toInt() ?? 0;
    final rawCreatedAt = (json['created_at'] as num?)?.toInt();
    return NoteChangeDto(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      folderId: json['folder_id'] as String?,
      isFavorite: json['is_favorite'] as bool? ?? false,
      isPinned: json['is_pinned'] as bool? ?? false,
      orderIndex: (json['order_index'] as num?)?.toInt() ?? 0,
      createdAt: (rawCreatedAt == null || rawCreatedAt <= 0)
          ? updatedAt
          : rawCreatedAt,
      updatedAt: updatedAt,
      deletedAt: (json['deleted_at'] as num?)?.toInt(),
    );
  }
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

  /// Presente solo quando il client ha modifiche locali di posizionamento da
  /// inviare. Assente = non toccare lo stato del server.
  final OrderingPush? ordering;

  const SyncRequest({
    required this.lastSyncedAt,
    required this.folders,
    required this.notes,
    this.ordering,
  });

  Map<String, dynamic> toJson() => {
    'last_synced_at': lastSyncedAt,
    'folders': folders.map((f) => f.toJson()).toList(),
    'notes': notes.map((n) => n.toJson()).toList(),
    if (ordering != null) 'ordering': ordering!.toJson(),
  };
}

/// Blob di posizionamento inviato al server (ordine cartelle, ordinamento per
/// vista, ordini manuali delle note). Il server lo conserva senza
/// interpretarlo. [baseVersion] è la versione su cui il client ha costruito la
/// modifica: se non coincide con quella corrente il server ignora il push e
/// restituisce lo stato autoritativo (vedi [OrderingState]).
class OrderingPush {
  final int baseVersion;
  final Map<String, dynamic> data;

  const OrderingPush({required this.baseVersion, required this.data});

  Map<String, dynamic> toJson() => {'base_version': baseVersion, 'data': data};
}

/// Converte un valore JSON in un intero non negativo e finito. Un server
/// compromesso o un blob corrotto potrebbe inviare `Infinity`, `NaN` o numeri
/// fuori scala: non devono far fallire la serializzazione della sync.
int? _finiteNonNegativeInt(Object? value) {
  if (value is! num || !value.isFinite) return null;
  final converted = value.toInt();
  return converted >= 0 ? converted : null;
}

/// Stato di posizionamento restituito dal server a ogni sync.
class OrderingState {
  final int version;
  final Map<String, dynamic> data;

  const OrderingState({required this.version, this.data = const {}});

  factory OrderingState.fromJson(Map<String, dynamic> json) {
    final rawVersion = _finiteNonNegativeInt(json['version']);
    return OrderingState(
      // Il server usa int64; un valore fuori scala renderebbe poi impossibile
      // costruire un base_version valido per il push successivo.
      version: rawVersion != null && rawVersion <= 0x7fffffff ? rawVersion : 0,
      data: _sanitizeData(json['data']),
    );
  }

  /// Conserva solo le chiavi e i tipi previsti dal contratto. Oltre a evitare
  /// crash su valori non finiti, impedisce che un blob arbitrario finisca
  /// nello snapshot locale e venga rispedito al server.
  static Map<String, dynamic> _sanitizeData(Object? raw) {
    final source = raw is Map ? raw : const {};
    final folders = <String, int>{};
    final rawFolders = source['folders'];
    if (rawFolders is Map) {
      rawFolders.forEach((key, value) {
        final index = _finiteNonNegativeInt(value);
        if (key is String && index != null && index <= 0x7fffffff) {
          folders[key] = index;
        }
      });
    }
    final sortModes = <String, String>{};
    final rawModes = source['sort_modes'];
    if (rawModes is Map) {
      rawModes.forEach((key, value) {
        if (key is String && value is String) sortModes[key] = value;
      });
    }
    final folderOrders = <String, List<String>>{};
    final rawOrders = source['folder_orders'];
    if (rawOrders is Map) {
      rawOrders.forEach((key, value) {
        if (key is String && value is List) {
          folderOrders[key] = value.whereType<String>().toList();
        }
      });
    }
    return {
      'folders': folders,
      'sort_modes': sortModes,
      'folder_orders': folderOrders,
    };
  }
}

/// Occupazione e tetto dello spazio di sincronizzazione dell'account.
/// [quotaBytes] = 0 significa illimitato.
class StorageInfo {
  final int usageBytes;
  final int quotaBytes;

  const StorageInfo({this.usageBytes = 0, this.quotaBytes = 0});

  factory StorageInfo.fromJson(Map<String, dynamic> json) => StorageInfo(
    usageBytes: _finiteNonNegativeInt(json['usage_bytes']) ?? 0,
    quotaBytes: _finiteNonNegativeInt(json['quota_bytes']) ?? 0,
  );

  bool get quotaExceeded => quotaBytes > 0 && usageBytes >= quotaBytes;
}

/// Response body da POST /api/v1/sync — speculare a `models.SyncResponse`.
///
/// [serverTime] è il nuovo cursore da salvare per la prossima sync.
/// [folders]/[notes] sono TUTTE le entità con `updated_at` maggiore del
/// cursore inviato nella richiesta: include sia le modifiche remote di altri
/// dispositivi sia l'esito (accettato o "server wins") di quanto appena
/// inviato. Non esistono più liste separate "accepted"/"server_wins".
/// Record che il server ha rifiutato (HTTP 422) perché fa riferimento a una
/// cartella (`folder_id` / `parent_id`) inesistente o non dell'utente.
class SyncRejectedItem {
  final String kind; // "folder" | "note"
  final String id;
  final String reason; // es. "invalid_folder_id", "invalid_parent_id"

  const SyncRejectedItem({
    required this.kind,
    required this.id,
    required this.reason,
  });

  factory SyncRejectedItem.fromJson(Map<String, dynamic> json) =>
      SyncRejectedItem(
        kind: json['kind']?.toString() ?? '',
        id: json['id']?.toString() ?? '',
        reason: json['reason']?.toString() ?? '',
      );
}

/// Funzioni opzionali che il server annuncia nella risposta 200 di sync (campo
/// `caps`, Y-14). Regole: una chiave assente vale «non supportato», una chiave
/// sconosciuta si ignora, e senza `caps` (server 2.1.0 e precedenti) il client
/// si comporta esattamente come prima.
class ServerCaps {
  /// Versione del contratto. 1 = il server non annuncia nulla.
  final int proto;

  /// Funzioni opzionali (solo i valori booleani del campo `caps`).
  final Map<String, bool> flags;

  const ServerCaps({this.proto = 1, this.flags = const {}});

  factory ServerCaps.fromJson(Map<String, dynamic> json) {
    final flags = <String, bool>{};
    json.forEach((key, value) {
      if (value is bool) flags[key] = value;
    });
    return ServerCaps(
      proto: (json['proto'] as num?)?.toInt() ?? 1,
      flags: flags,
    );
  }

  /// true solo se il server dichiara esplicitamente la funzione.
  bool has(String capability) => flags[capability] == true;
}

class SyncResponse {
  final int serverTime;

  /// true se il server ha risposto con lo stato COMPLETO dell'utente (cursore
  /// troppo vecchio rispetto alla retention dei tombstone): il client deve
  /// eliminare le righe locali pulite che non compaiono nella risposta.
  final bool fullResync;
  final List<FolderChangeDto> folders;
  final List<NoteChangeDto> notes;

  /// Capability del server; null se la risposta non le contiene.
  final ServerCaps? caps;

  /// Stato di posizionamento; null con i server che non lo supportano (in quel
  /// caso il client non applica e non considera sincronizzato nulla).
  final OrderingState? ordering;

  /// Occupazione/quota dell'account; null con i server precedenti.
  final StorageInfo? storage;

  const SyncResponse({
    required this.serverTime,
    this.fullResync = false,
    this.folders = const [],
    this.notes = const [],
    this.caps,
    this.ordering,
    this.storage,
  });

  factory SyncResponse.fromJson(Map<String, dynamic> json) {
    return SyncResponse(
      serverTime: (json['server_time'] as num?)?.toInt() ?? 0,
      fullResync: json['full_resync'] == true,
      folders:
          (json['folders'] as List<dynamic>?)
              ?.map((e) => FolderChangeDto.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      notes:
          (json['notes'] as List<dynamic>?)
              ?.map((e) => NoteChangeDto.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      caps: json['caps'] is Map<String, dynamic>
          ? ServerCaps.fromJson(json['caps'] as Map<String, dynamic>)
          : null,
      ordering: json['ordering'] is Map<String, dynamic>
          ? OrderingState.fromJson(json['ordering'] as Map<String, dynamic>)
          : null,
      storage: json['storage'] is Map<String, dynamic>
          ? StorageInfo.fromJson(json['storage'] as Map<String, dynamic>)
          : null,
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

  factory UserSettingsDto.fromJson(Map<String, dynamic> json) =>
      UserSettingsDto(
        theme: json['theme'] as String? ?? 'system',
        colorScheme: json['color_scheme'] as String? ?? 'dark_teal',
        language: json['language'] as String? ?? 'it',
        fontFamily: json['font_family'] as String? ?? 'Inter',
        fontSize: (json['font_size'] as num?)?.toInt() ?? 16,
        lineSpacing: (json['line_spacing'] as num?)?.toDouble() ?? 1.6,
        layout: json['layout'] as String? ?? 'split',
        updatedAt: (json['updated_at'] as num?)?.toInt(),
      );
}

/// DTO for POST /api/v1/auth/login and POST /api/v1/auth/refresh.
///
/// [refreshToken]/[refreshExpiresAt] are additive: an older server that does
/// not return them still produces a valid (access-token-only) response.
class LoginResponseDto {
  final String token;
  final int expiresAt;
  final String refreshToken;
  final int refreshExpiresAt;
  final String userId;
  final String username;

  const LoginResponseDto({
    required this.token,
    required this.expiresAt,
    this.refreshToken = '',
    this.refreshExpiresAt = 0,
    required this.userId,
    required this.username,
  });

  factory LoginResponseDto.fromJson(Map<String, dynamic> json) =>
      LoginResponseDto(
        token: json['token'] as String? ?? '',
        expiresAt: (json['expires_at'] as num?)?.toInt() ?? 0,
        refreshToken: json['refresh_token'] as String? ?? '',
        refreshExpiresAt: (json['refresh_expires_at'] as num?)?.toInt() ?? 0,
        userId: json['user_id'] as String? ?? '',
        username: json['username'] as String? ?? '',
      );
}
