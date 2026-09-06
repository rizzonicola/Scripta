import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../features/sync/models/sync_models.dart';

class SyncApiException implements Exception {
  final int? statusCode;
  final String message;

  const SyncApiException(this.message, [this.statusCode]);

  @override
  String toString() =>
      'SyncApiException: $message${statusCode != null ? ' (Status: $statusCode)' : ''}';
}

/// HTTP Service communicating with notes-server Go REST API.
class SyncApiService {
  final http.Client _client;

  SyncApiService([http.Client? client]) : _client = client ?? http.Client();

  String _cleanUrl(String baseUrl) {
    var url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// Pings the server health endpoint
  Future<bool> checkHealth(String baseUrl) async {
    try {
      final clean = _cleanUrl(baseUrl);
      final uri = Uri.parse('$clean/healthz');
      final response = await _client.get(uri).timeout(const Duration(seconds: 4));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Authenticates user and returns JWT credentials
  Future<LoginResponseDto> login({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final clean = _cleanUrl(baseUrl);
    final uri = Uri.parse('$clean/api/v1/auth/login');

    final response = await _client
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'username': username,
            'password': password,
          }),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final decoded = json.decode(response.body) as Map<String, dynamic>;
      return LoginResponseDto.fromJson(decoded);
    } else if (response.statusCode == 401) {
      throw const SyncApiException('Credenziali non valide', 401);
    } else {
      throw SyncApiException(_extractError(response.body, 'Errore durante l\'autenticazione'), response.statusCode);
    }
  }

  /// Fetches remote user preferences
  Future<UserSettingsDto> getUserSettings({
    required String baseUrl,
    required String token,
  }) async {
    final clean = _cleanUrl(baseUrl);
    final uri = Uri.parse('$clean/api/v1/user/settings');

    final response = await _client.get(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final decoded = json.decode(response.body) as Map<String, dynamic>;
      return UserSettingsDto.fromJson(decoded);
    } else if (response.statusCode == 401) {
      throw const SyncApiException('Sessione scaduta o non autorizzata', 401);
    } else {
      throw SyncApiException(
          _extractError(response.body, 'Impossibile scaricare le impostazioni remote'), response.statusCode);
    }
  }

  /// Updates remote user preferences
  Future<UserSettingsDto> updateUserSettings({
    required String baseUrl,
    required String token,
    required UserSettingsDto settings,
  }) async {
    final clean = _cleanUrl(baseUrl);
    final uri = Uri.parse('$clean/api/v1/user/settings');

    final response = await _client
        .put(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: json.encode(settings.toJson()),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final decoded = json.decode(response.body) as Map<String, dynamic>;
      return UserSettingsDto.fromJson(decoded);
    } else if (response.statusCode == 401) {
      throw const SyncApiException('Sessione scaduta o non autorizzata', 401);
    } else {
      throw SyncApiException(
          _extractError(response.body, 'Impossibile aggiornare le impostazioni utente'), response.statusCode);
    }
  }

  /// Esegue un round di sync Delta Sync Push/Pull con risoluzione dei
  /// conflitti Last-Write-Wins, speculare a `SyncHandler.Sync` nel backend:
  /// invia tutte le cartelle/note modificate localmente dall'ultimo cursore
  /// [lastSyncedAt] e riceve indietro tutto ciò che è cambiato (da altri
  /// dispositivi, o come esito del conflitto sulle stesse entità appena
  /// inviate) più il nuovo cursore da salvare per il round successivo.
  Future<SyncResponse> sync({
    required String baseUrl,
    required String token,
    required int lastSyncedAt,
    required List<FolderChangeDto> folders,
    required List<NoteChangeDto> notes,
  }) async {
    final clean = _cleanUrl(baseUrl);
    final uri = Uri.parse('$clean/api/v1/sync');

    final payload = SyncRequest(lastSyncedAt: lastSyncedAt, folders: folders, notes: notes);

    final response = await _client
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: json.encode(payload.toJson()),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final decoded = json.decode(response.body) as Map<String, dynamic>;
      return SyncResponse.fromJson(decoded);
    } else if (response.statusCode == 401) {
      throw const SyncApiException('Sessione scaduta o non autorizzata', 401);
    } else if (response.statusCode == 503) {
      throw const SyncApiException('Server temporaneamente occupato, riprovare a breve', 503);
    } else {
      throw SyncApiException(_extractError(response.body, 'Errore durante la sincronizzazione'), response.statusCode);
    }
  }

  /// Scarica il contenuto Markdown grezzo di una singola nota dal server,
  /// per ID (nessun percorso testuale coinvolto).
  Future<String> downloadNoteMarkdown({
    required String baseUrl,
    required String token,
    required String noteId,
  }) async {
    final clean = _cleanUrl(baseUrl);
    final uri = Uri.parse('$clean/api/v1/notes/download?id=${Uri.encodeComponent(noteId)}');

    final response = await _client.get(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode == 200) {
      return utf8.decode(response.bodyBytes);
    } else if (response.statusCode == 401) {
      throw const SyncApiException('Sessione scaduta o non autorizzata', 401);
    } else {
      throw SyncApiException(_extractError(response.body, 'Impossibile scaricare la nota dal server'), response.statusCode);
    }
  }

  String _extractError(String body, String fallback) {
    try {
      final decoded = json.decode(body) as Map<String, dynamic>;
      if (decoded.containsKey('error')) {
        return decoded['error'].toString();
      }
    } catch (_) {}
    return fallback;
  }
}
