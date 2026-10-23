import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import '../../features/sync/models/sync_models.dart';

class SyncApiException implements Exception {
  final int? statusCode;
  final String message;

  /// Valorizzato solo per HTTP 422: i record rifiutati dal server. Il batch è
  /// stato annullato per intero e il cursore NON deve avanzare.
  final List<SyncRejectedItem> rejected;

  /// Valorizzato solo per HTTP 503 quando il server indica `Retry-After`
  /// (secondi): il ritentativo non deve partire prima (Y-11).
  final Duration? retryAfter;

  const SyncApiException(this.message,
      [this.statusCode, this.rejected = const []])
      : retryAfter = null;

  const SyncApiException.withRetryAfter(
      this.message, this.statusCode, this.retryAfter)
      : rejected = const [];

  @override
  String toString() =>
      'SyncApiException: $message${statusCode != null ? ' (Status: $statusCode)' : ''}';
}

/// Limiti di tempo del round di sync (Y-05). Prima c'era un solo `timeout(30 s)`
/// sull'intera richiesta: su una rete lenta ma VIVA (profilo «Edge»,
/// 400 kbit/s) un upload di qualche megabyte superava i 30 s, veniva
/// interrotto e ripartiva da zero, senza mai finire. Ora conta il PROGRESSO,
/// non la durata: finché passano byte (in su o in giù) la sync continua.
class SyncTimeouts {
  /// Dal via alla ricezione del primo blocco: connessione (TCP/TLS) inclusa.
  final Duration connect;

  /// Massimo silenzio ammesso mentre si inviano o si ricevono dati.
  final Duration idle;

  /// Dopo l'invio completo, attesa della risposta del server (elabora il
  /// batch in una transazione).
  final Duration serverWait;

  /// Tetto assoluto dell'intero round: oltre, anche una sync «viva» si ferma.
  final Duration total;

  const SyncTimeouts({
    this.connect = const Duration(seconds: 30),
    this.idle = const Duration(seconds: 20),
    this.serverWait = const Duration(seconds: 30),
    this.total = const Duration(minutes: 5),
  });
}

/// Richiesta con corpo in memoria inviata a blocchi, che segnala i progressi.
/// `onChunk` scatta quando il client HTTP ha consumato il blocco precedente
/// (cioè è passato sul socket, con il suo backpressure): è il segnale che
/// l'upload sta avanzando. `onUploaded` scatta a invio completato.
class _ProgressRequest extends http.BaseRequest {
  _ProgressRequest(
    super.method,
    super.url,
    this._bytes, {
    required this.onChunk,
    required this.onUploaded,
  }) {
    contentLength = _bytes.length;
  }

  static const int chunkSize = 16 * 1024;

  final Uint8List _bytes;
  final void Function() onChunk;
  final void Function() onUploaded;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_chunks());
  }

  Stream<List<int>> _chunks() async* {
    onChunk();
    for (var offset = 0; offset < _bytes.length; offset += chunkSize) {
      final end = min(offset + chunkSize, _bytes.length);
      yield Uint8List.sublistView(_bytes, offset, end);
      onChunk();
    }
    onUploaded();
  }
}

/// HTTP Service communicating with notes-server Go REST API.
class SyncApiService {
  final http.Client _client;
  final SyncTimeouts _timeouts;

  SyncApiService(
      [http.Client? client, SyncTimeouts timeouts = const SyncTimeouts()])
      : _client = client ?? http.Client(),
        _timeouts = timeouts;

  /// Identificativo dell'app inviato nell'header `X-Scripta-Client`. Il server
  /// lo usa SOLO nei log (non cambia nessun comportamento). Tenere allineato
  /// alla versione in pubspec.yaml.
  static const String clientHeaderValue = 'scripta/1.0.3';

  /// Legge `Retry-After` espresso in secondi. Altri formati (data HTTP) o
  /// valori non validi/negativi: nessuna indicazione (null).
  static Duration? parseRetryAfter(String? raw) {
    if (raw == null) return null;
    final seconds = int.tryParse(raw.trim());
    if (seconds == null || seconds < 0) return null;
    return Duration(seconds: seconds);
  }

  /// Testo del corpo di una risposta, SEMPRE come UTF-8 (Y-02). Il pacchetto
  /// http, senza `charset` nel Content-Type, decodifica `response.body` con la
  /// codifica di default (Latin-1): per il JSON del server (UTF-8) accenti,
  /// frecce ed emoji diventerebbero mojibake. Se il corpo non fosse UTF-8
  /// valido si ripiega sul comportamento precedente, invece di fallire.
  static String bodyText(http.Response response) {
    try {
      return utf8.decode(response.bodyBytes);
    } on FormatException {
      return response.body;
    }
  }

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
  Future<SyncResponse> _decodeSyncResponse(http.Response response) async {
    final body = bodyText(response);
    try {
      if (body.length < isolateJsonThreshold) {
        return _parseSyncResponse(body);
      }
      return await compute(_parseSyncResponse, body);
    } catch (_) {
      // Un 200 con JSON malformato non è un problema di rete: ritentare la
      // stessa richiesta non può migliorare nulla. 502 = risposta del server
      // non valida (e NON transitoria, vedi SyncNotifier).
      throw const SyncApiException(
          'Risposta del server non valida (JSON malformato)', 502);
    }
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
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      throw const SyncApiException(
          'URL del server non valido: usa https://', 400);
    }
    // Il token viaggia nell'header Authorization: su http in chiaro può essere
    // letto da chiunque sulla rete. Consentiamo http solo verso il loopback
    // (server di sviluppo in locale/emulatore).
    if (uri.scheme == 'http' && !_isLoopbackHost(uri.host)) {
      throw const SyncApiException(
        'URL non sicuro: usa https:// (http è ammesso solo per localhost)',
        400,
      );
    }
    return url;
  }

  static bool _isLoopbackHost(String host) {
    final h = host.toLowerCase();
    return h == 'localhost' || h == '127.0.0.1' || h == '::1';
  }

  /// Pings the server health endpoint
  Future<bool> checkHealth(String baseUrl) async {
    try {
      final clean = _cleanUrl(baseUrl); // URL non valido -> catch -> false
      final uri = Uri.parse('$clean/healthz');
      final response =
          await _client.get(uri).timeout(const Duration(seconds: 4));
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
          headers: {
            'Content-Type': 'application/json',
            'X-Scripta-Client': clientHeaderValue
          },
          body: json.encode({
            'username': username,
            'password': password,
          }),
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final decoded = json.decode(bodyText(response)) as Map<String, dynamic>;
      return LoginResponseDto.fromJson(decoded);
    } else if (response.statusCode == 401) {
      throw const SyncApiException('Credenziali non valide', 401);
    } else {
      throw SyncApiException(
          _extractError(bodyText(response), 'Errore durante l\'autenticazione'),
          response.statusCode);
    }
  }

  /// Revoca lato server il token corrente (POST /api/v1/auth/logout). Best
  /// effort: un errore di rete non deve impedire il logout locale, quindi non
  /// lancia mai.
  Future<void> logout({required String baseUrl, required String token}) async {
    try {
      final clean = _cleanUrl(baseUrl);
      await _client.post(
        Uri.parse('$clean/api/v1/auth/logout'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 5));
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
      final decoded = json.decode(bodyText(response)) as Map<String, dynamic>;
      return UserSettingsDto.fromJson(decoded);
    } else if (response.statusCode == 401) {
      throw const SyncApiException('Sessione scaduta o non autorizzata', 401);
    } else {
      throw SyncApiException(
          _extractError(bodyText(response),
              'Impossibile scaricare le impostazioni remote'),
          response.statusCode);
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
      final decoded = json.decode(bodyText(response)) as Map<String, dynamic>;
      return UserSettingsDto.fromJson(decoded);
    } else if (response.statusCode == 401) {
      throw const SyncApiException('Sessione scaduta o non autorizzata', 401);
    } else {
      throw SyncApiException(
          _extractError(bodyText(response),
              'Impossibile aggiornare le impostazioni utente'),
          response.statusCode);
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

    final payload =
        SyncRequest(lastSyncedAt: lastSyncedAt, folders: folders, notes: notes);
    final requestBody = await _encodeSyncBody(payload);

    final response = await _postWithProgressTimeout(
      uri,
      {
        'Authorization': 'Bearer $token',
        // charset esplicito: è ciò che `http.post(body: String)` inviava già.
        'Content-Type': 'application/json; charset=utf-8',
        'X-Scripta-Client': clientHeaderValue,
      },
      const Utf8Encoder().convert(requestBody),
    );

    if (response.statusCode == 200) {
      return _decodeSyncResponse(response);
    } else if (response.statusCode == 401) {
      throw const SyncApiException('Sessione scaduta o non autorizzata', 401);
    } else if (response.statusCode == 503) {
      throw SyncApiException.withRetryAfter(
        'Server temporaneamente occupato, riprovare a breve',
        503,
        parseRetryAfter(response.headers['retry-after']),
      );
    } else if (response.statusCode == 422) {
      // Record rifiutati: il server ha annullato l'intero batch.
      var rejected = <SyncRejectedItem>[];
      try {
        final decoded = json.decode(bodyText(response)) as Map<String, dynamic>;
        rejected = (decoded['rejected'] as List<dynamic>? ?? const [])
            .map((e) => SyncRejectedItem.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
      throw SyncApiException(
          'Sincronizzazione rifiutata dal server (${rejected.length} elementi non validi)',
          422,
          rejected);
    } else {
      throw SyncApiException(
          _extractError(
              bodyText(response), 'Errore durante la sincronizzazione'),
          response.statusCode);
    }
  }

  /// POST con timeout «a progressi» (Y-05). Il corpo parte a blocchi e la
  /// risposta si legge a flusso; un watchdog scatta solo se NESSUN byte si muove
  /// per il tempo consentito dalla fase in corso (connessione, invio,
  /// attesa del server, ricezione) o se si supera il tetto assoluto.
  ///
  /// Allo scadere si lancia `TimeoutException` (come il vecchio `.timeout`, e
  /// quindi trattata come errore di rete transitorio dal chiamante) e, se la
  /// risposta era in ricezione, se ne annulla la lettura chiudendo la
  /// connessione. L'invio fermo non è annullabile con `http.Client`: come
  /// prima, resta in sospeso finché il sistema operativo non lo chiude.
  Future<http.Response> _postWithProgressTimeout(
      Uri uri, Map<String, String> headers, Uint8List body) {
    final t = _timeouts;
    final failure = Completer<http.Response>();
    Timer? watchdog;
    StreamSubscription<List<int>>? subscription;
    var finished = false;

    void fail(Duration limit, String what) {
      if (finished) return;
      finished = true;
      watchdog?.cancel();
      final sub = subscription;
      if (sub != null) unawaited(sub.cancel());
      failure.completeError(
          TimeoutException('Sync senza progressi: $what', limit));
    }

    void arm(Duration limit, String what) {
      if (finished) return;
      watchdog?.cancel();
      watchdog = Timer(limit, () => fail(limit, what));
    }

    final totalTimer =
        Timer(t.total, () => fail(t.total, 'tempo totale superato'));
    final request = _ProgressRequest(
      'POST',
      uri,
      body,
      onChunk: () => arm(t.idle, 'invio fermo'),
      onUploaded: () => arm(t.serverWait, 'nessuna risposta dal server'),
    )..headers.addAll(headers);
    arm(t.connect, 'connessione');

    final work = () async {
      final streamed = await _client.send(request);
      arm(t.idle, 'risposta ferma');
      final received = Completer<Uint8List>();
      final builder = BytesBuilder(copy: false);
      subscription = streamed.stream.listen(
        (chunk) {
          builder.add(chunk);
          arm(t.idle, 'risposta ferma');
        },
        onError: (Object error, StackTrace stack) {
          if (!received.isCompleted) received.completeError(error, stack);
        },
        onDone: () {
          if (!received.isCompleted) received.complete(builder.takeBytes());
        },
        cancelOnError: true,
      );
      final bytes = await received.future;
      return http.Response.bytes(
        bytes,
        streamed.statusCode,
        request: streamed.request,
        headers: streamed.headers,
        isRedirect: streamed.isRedirect,
        persistentConnection: streamed.persistentConnection,
        reasonPhrase: streamed.reasonPhrase,
      );
    }();

    return Future.any<http.Response>([work, failure.future]).whenComplete(() {
      finished = true;
      watchdog?.cancel();
      totalTimer.cancel();
    });
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
