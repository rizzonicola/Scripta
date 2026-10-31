import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';

/// Sessione completa così com'è salvata nello storage sicuro: token, refresh
/// token, URL del server e identità dell'account. Viene scritta con UNA sola
/// operazione ([SecureStorageService.saveSession]): non esiste una finestra in
/// cui un token del server nuovo resta abbinato all'URL del server vecchio.
class StoredSession {
  const StoredSession({
    required this.token,
    required this.refreshToken,
    required this.serverUrl,
    required this.username,
    required this.userId,
  });

  final String token;
  final String refreshToken;
  final String serverUrl;
  final String username;
  final String userId;

  /// Una sessione è utilizzabile solo se ha token, URL e identità: senza uno
  /// di questi campi non si può sapere a quale server appartiene il token.
  bool get isUsable =>
      token.trim().isNotEmpty &&
      serverUrl.trim().isNotEmpty &&
      userId.trim().isNotEmpty;

  StoredSession copyWith({String? token, String? refreshToken}) => StoredSession(
    token: token ?? this.token,
    refreshToken: refreshToken ?? this.refreshToken,
    serverUrl: serverUrl,
    username: username,
    userId: userId,
  );

  Map<String, Object?> toJson() => {
    'v': 1,
    'token': token,
    'refresh_token': refreshToken,
    'server_url': serverUrl,
    'username': username,
    'user_id': userId,
  };

  static StoredSession? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final token = decoded['token'];
      final refreshToken = decoded['refresh_token'];
      final serverUrl = decoded['server_url'];
      final username = decoded['username'];
      final userId = decoded['user_id'];
      if (token is! String ||
          refreshToken is! String ||
          serverUrl is! String ||
          username is! String ||
          userId is! String) {
        return null;
      }
      final session = StoredSession(
        token: token,
        refreshToken: refreshToken,
        serverUrl: serverUrl,
        username: username,
        userId: userId,
      );
      return session.isUsable ? session : null;
    } catch (_) {
      return null;
    }
  }
}

/// Service providing encrypted local storage for sensitive authentication tokens and credentials.
/// Uses Android Keystore + EncryptedSharedPreferences on Android,
/// Keychain on iOS/macOS, and Secret Service on Linux.
///
/// FALLBACK iOS/macOS (build NON firmate): le build distribuite come .ipa non
/// firmato (sideloading) o come .app macOS con firma ad-hoc non hanno un
/// certificato/provisioning profile dello sviluppatore. In quei casi il
/// Keychain può rifiutare le operazioni (es. errSecMissingEntitlement -34018):
/// senza rete di sicurezza l'accesso alla sync fallirebbe ad ogni avvio.
/// Se — e SOLO se — il Keychain solleva un errore su iOS/macOS, i valori
/// vengono quindi salvati in SharedPreferences (NON cifrato, ma comunque
/// confinato nella sandbox dell'app) — MA SOLO i valori non segreti (URL del
/// server, username, id utente). Il TOKEN di autenticazione non viene MAI
/// scritto in chiaro: se il Keychain non è disponibile resta solo in memoria
/// per la durata della sessione (all'avvio successivo serve un nuovo login).
/// Su tutte le altre piattaforme il comportamento è invariato: nessun
/// degrado silenzioso della sicurezza.
class SecureStorageService {
  static const _tokenKey = 'inkflow_jwt_token';
  static const _refreshTokenKey = 'inkflow_refresh_token';
  static const _serverUrlKey = 'inkflow_server_url';
  static const _usernameKey = 'inkflow_username';
  static const _userIdKey = 'inkflow_user_id';

  /// Chiave unica della sessione atomica. Le chiavi separate sopra restano
  /// solo per leggere/migrare installazioni precedenti e per i test.
  static const _sessionKey = 'inkflow_session_v1';

  final FlutterSecureStorage _storage;
  final bool? _fallbackEnabledOverride;

  const SecureStorageService([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(resetOnError: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          ),
      _fallbackEnabledOverride = null;

  @visibleForTesting
  const SecureStorageService.withFallback(
    FlutterSecureStorage storage, {
    required bool fallbackEnabled,
  }) : _storage = storage,
       _fallbackEnabledOverride = fallbackEnabled;

  /// Prefisso delle chiavi usate SOLO dal fallback su SharedPreferences.
  static const _fallbackPrefix = AppConstants.prefSecureFallbackPrefix;

  /// Il fallback è attivo solo su iOS/macOS (vedi commento di classe).
  bool get _fallbackEnabled {
    if (kIsWeb) return false;
    return _fallbackEnabledOverride ?? (Platform.isIOS || Platform.isMacOS);
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      if (!_fallbackEnabled) rethrow;
      debugPrint(
        'SecureStorage: Keychain non disponibile ($e), uso il fallback.',
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_fallbackPrefix$key', value);
    }
  }

  Future<String?> _read(String key) async {
    try {
      final value = await _storage.read(key: key);
      if (value != null || !_fallbackEnabled) return value;
    } catch (e) {
      if (!_fallbackEnabled) rethrow;
      debugPrint(
        'SecureStorage: Keychain non disponibile ($e), uso il fallback.',
      );
    }
    // Keychain vuoto o non accessibile: controlla un eventuale valore salvato
    // dal fallback in una sessione precedente.
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_fallbackPrefix$key');
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      if (!_fallbackEnabled) rethrow;
    }
    if (_fallbackEnabled) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_fallbackPrefix$key');
    }
  }

  /// Token tenuto SOLO in memoria quando il Keychain iOS/macOS rifiuta la
  /// scrittura (build non firmate). Mai persistito.
  static String? _memoryOnlyToken;

  /// Stessa rete di sicurezza per il refresh token: senza Keychain resta
  /// valido solo per la sessione corrente.
  static String? _memoryOnlyRefreshToken;

  /// Sessione completa tenuta in memoria quando il Keychain non è scrivibile:
  /// i token non finiscono MAI in SharedPreferences.
  static StoredSession? _memoryOnlySession;

  /// Salva la sessione con UNA sola scrittura atomica. I token non usano mai
  /// il fallback in chiaro: se il Keychain non è disponibile restano solo in
  /// memoria per la sessione corrente.
  Future<void> saveSession(StoredSession session) async {
    if (!session.isUsable) {
      throw ArgumentError('sessione non valida: token, URL o userId mancanti');
    }
    try {
      await _storage.write(
        key: _sessionKey,
        value: jsonEncode(session.toJson()),
      );
      _memoryOnlySession = null;
      _memoryOnlyToken = null;
      _memoryOnlyRefreshToken = null;
    } catch (e) {
      if (!_fallbackEnabled) rethrow;
      debugPrint(
        'SecureStorage: Keychain non disponibile ($e): sessione solo in memoria.',
      );
      _memoryOnlySession = session;
      _memoryOnlyToken = session.token;
      _memoryOnlyRefreshToken = session.refreshToken;
      try {
        await _storage.delete(key: _sessionKey);
      } catch (_) {}
    }
    // Le vecchie chiavi separate non devono poter resuscitare una sessione
    // precedente dopo un logout o un downgrade. URL e userId restano: sono
    // non segreti e servono al riconoscimento degli account legacy.
    await _removeLegacySecretKeys();
  }

  Future<void> _removeLegacySecretKeys() async {
    for (final key in [_tokenKey, _refreshTokenKey, _usernameKey]) {
      try {
        await _delete(key);
      } catch (_) {}
    }
  }

  /// Legge la sessione atomica. Se non esiste, migra una tantum le chiavi
  /// separate delle versioni precedenti e la riscrive come bundle.
  Future<StoredSession?> getSession() async {
    final memorySession = _memoryOnlySession;
    if (memorySession != null && memorySession.isUsable) return memorySession;

    String? raw;
    try {
      raw = await _storage.read(key: _sessionKey);
    } catch (e) {
      if (!_fallbackEnabled) rethrow;
      debugPrint(
        'SecureStorage: Keychain non disponibile ($e), uso il fallback.',
      );
      return _legacySession();
    }

    if (raw != null) {
      final parsed = StoredSession.fromJsonString(raw);
      if (parsed != null) return parsed;
      // Bundle presente ma illeggibile: non si riattiva una sessione dalle
      // vecchie chiavi, che potrebbero appartenere a un altro account.
      try {
        await _storage.delete(key: _sessionKey);
      } catch (_) {}
      return null;
    }

    return _legacySession();
  }

  Future<StoredSession?> _legacySession() async {
    final token = await getAuthToken();
    if (token == null || token.isEmpty) return null;
    final session = StoredSession(
      token: token,
      refreshToken: await getRefreshToken() ?? '',
      serverUrl: await getServerUrl() ?? '',
      username: await getUsername() ?? '',
      userId: await getUserId() ?? '',
    );
    if (!session.isUsable) return null;
    // Migrazione best effort: se la scrittura fallisce la sessione resta
    // utilizzabile per questo avvio tramite le vecchie chiavi.
    try {
      await saveSession(session);
    } catch (_) {}
    return session;
  }

  Future<void> saveAuthToken(String token) async {
    try {
      await _storage.write(key: _tokenKey, value: token);
      _memoryOnlyToken = null;
    } catch (e) {
      if (!_fallbackEnabled) rethrow;
      debugPrint(
        'SecureStorage: Keychain non disponibile ($e): token solo in memoria.',
      );
      _memoryOnlyToken = token;
      // Se il Keychain è tornato accessibile in lettura, al prossimo avvio
      // vincerebbe il vecchio token rimasto lì: prova a rimuoverlo. Se anche
      // la delete fallisce, il token in memoria resta comunque prioritario
      // per la sessione corrente.
      try {
        await _storage.delete(key: _tokenKey);
      } catch (_) {}
    }
  }

  Future<String?> getAuthToken() async {
    // Un token scritto in memoria è la sessione più recente: NON deve essere
    // scavalcato da un vecchio token rimasto nel Keychain quando la scrittura
    // era fallita.
    final memoryToken = _memoryOnlyToken;
    if (memoryToken != null && memoryToken.isNotEmpty) return memoryToken;
    // Versioni precedenti, in fallback, salvavano il token in chiaro in
    // SharedPreferences: se ne trovi uno lo elimina (login da rifare).
    if (_fallbackEnabled) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_fallbackPrefix$_tokenKey');
    }
    try {
      final value = await _storage.read(key: _tokenKey);
      if (value != null) return value;
    } catch (e) {
      if (!_fallbackEnabled) rethrow;
    }
    return _fallbackEnabled ? _memoryOnlyToken : null;
  }

  Future<void> saveRefreshToken(String token) async {
    if (token.isEmpty) {
      await clearRefreshToken();
      return;
    }
    try {
      await _storage.write(key: _refreshTokenKey, value: token);
      _memoryOnlyRefreshToken = null;
    } catch (e) {
      if (!_fallbackEnabled) rethrow;
      debugPrint(
        'SecureStorage: Keychain non disponibile ($e): refresh token solo in memoria.',
      );
      _memoryOnlyRefreshToken = token;
      try {
        await _storage.delete(key: _refreshTokenKey);
      } catch (_) {}
    }
  }

  Future<String?> getRefreshToken() async {
    final memoryToken = _memoryOnlyRefreshToken;
    if (memoryToken != null && memoryToken.isNotEmpty) return memoryToken;
    try {
      final value = await _storage.read(key: _refreshTokenKey);
      if (value != null) return value;
    } catch (e) {
      if (!_fallbackEnabled) rethrow;
    }
    return _fallbackEnabled ? _memoryOnlyRefreshToken : null;
  }

  Future<void> clearRefreshToken() async {
    _memoryOnlyRefreshToken = null;
    await _delete(_refreshTokenKey);
  }

  Future<void> saveServerUrl(String url) => _write(_serverUrlKey, url.trim());

  Future<String?> getServerUrl() => _read(_serverUrlKey);

  Future<void> saveUsername(String username) =>
      _write(_usernameKey, username.trim());

  Future<String?> getUsername() => _read(_usernameKey);

  Future<void> saveUserId(String userId) => _write(_userIdKey, userId);

  Future<String?> getUserId() => _read(_userIdKey);

  Future<void> clearAuth() async {
    _memoryOnlyToken = null;
    _memoryOnlyRefreshToken = null;
    _memoryOnlySession = null;
    Object? firstError;
    for (final key in [
      _sessionKey,
      _tokenKey,
      _refreshTokenKey,
      _usernameKey,
      _userIdKey,
    ]) {
      try {
        await _delete(key);
      } catch (e) {
        firstError ??= e;
      }
    }
    // Keep serverUrl for user convenience unless explicitly cleared
    if (firstError != null) throw firstError;
  }
}
