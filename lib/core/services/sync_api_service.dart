import 'dart:convert';
import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import '../../features/sync/models/sync_models.dart';

class SyncApiException implements Exception {
  final int? statusCode;
  final String message;

  /// Valorizzato solo per HTTP 422: i record rifiutati dal server. Il batch è
  /// stato annullato per intero e il cursore NON deve avanzare.
  final List<SyncRejectedItem> rejected;

  const SyncApiException(this.message, [this.statusCode, this.rejected = const []]);

  @override
  String toString() =>
      'SyncApiException: $message${statusCode != null ? ' (Status: $statusCode)' : ''}';
}

/// HTTP Service communicating with notes-server Go REST API.
class SyncApiService {
  final http.Client _client;

  SyncApiService([http.Client? client]) : _client = client ?? http.Client();

  /// Dimensione (in caratteri) da cui la (de)serializzazione JSON di un round
  /// di sync passa a un isolate. Sotto soglia il lavoro è trascurabile e
  /// avviare un isolate costerebbe di più; sopra (prima sync di un archivio
  /// importante, migliaia di note) decodifica e codifica sul thread della UI
  /// la facevano scattare per centinaia di millisecondi.
  static const int isolateJsonThreshold = 128 * 1024;

  // Funzioni statiche (quindi utilizzabili da `compute`): lavorano solo su
  // stringhe e DTO puri, mai su oggetti Flutter.
  static SyncResponse _parseSyncResponse(String body) =>
      SyncResponse.fromJson(json.decode(body) as Map<String, dynamic>);

  static String _encodeSyncRequest(SyncRequest request) =>
      json.encode(request.toJson());

  /// Decodifica la risposta di sync, in un isolate se è voluminosa. Gli
  /// errori (JSON non valido) arrivano al chiamante come prima.
  Future<SyncResponse> _decodeSyncResponse(http.Response response) {
    final body = response.body;
    if (body.length < isolateJsonThreshold) {
      return Future.sync(() => _parseSyncResponse(body));
    }
    return compute(_parseSyncResponse, body);
  }

  /// Serializza la richiesta di sync, in un isolate se il contenuto delle note
  /// da inviare è voluminoso.
  Future<String> _encodeSyncBody(SyncRequest request) {
    var contentChars = 0;
    for (final note in request.notes) {
      contentChars += note.content.length;
    }
    if (contentChars < isolateJsonThreshold) {
      return Future.sync(() => _encodeSyncRequest(request));
    }
    return compute(_encodeSyncRequest, request);
  }

  String _cleanUrl(String baseUrl) {
    var url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    // Solo http/https: nessun altro schema (file:, ftp:, ...) è un server valido.
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
      throw const SyncApiException('URL del server non valido: usa http:// o https://', 400);
    }
    return url;
  }

  /// Pings the server health endpoint
  Future<bool> checkHealth(String baseUrl) async {
    try {
      final clean = _cleanUrl(baseUrl); // URL non valido -> catch -> false
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

  /// Revoca lato server il token corrente (POST /api/v1/auth/logout). Best
  /// effort: un errore di rete non deve impedire il logout locale, quindi non
  /// lancia mai.
  Future<void> logout({required String baseUrl, required String token}) async {
    try {
      final clean = _cleanUrl(baseUrl);
      await _client
          .post(
            Uri.parse('$clean/api/v1/auth/logout'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Ignorato: il token verrà comunque scartato localmente.
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
    final requestBody = await _encodeSyncBody(payload);

    final response = await _client
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: requestBody,
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      return _decodeSyncResponse(response);
    } else if (response.statusCode == 401) {
      throw const SyncApiException('Sessione scaduta o non autorizzata', 401);
    } else if (response.statusCode == 503) {
      throw const SyncApiException('Server temporaneamente occupato, riprovare a breve', 503);
    } else if (response.statusCode == 422) {
      // Record rifiutati: il server ha annullato l'intero batch.
      var rejected = <SyncRejectedItem>[];
      try {
        final decoded = json.decode(response.body) as Map<String, dynamic>;
        rejected = (decoded['rejected'] as List<dynamic>? ?? const [])
            .map((e) => SyncRejectedItem.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
      throw SyncApiException('Sincronizzazione rifiutata dal server (${rejected.length} elementi non validi)', 422, rejected);
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
