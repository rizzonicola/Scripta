import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
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

  StoredSession copyWith({String? token, String? refreshToken}) =>
      StoredSession(
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

/// Descrizione di una chiave logica: nome corrente, nome usato dalle versioni
/// precedenti e regole di migrazione. Un'unica tabella evita che le liste di
/// chiavi da migrare, ripulire o cancellare divergano tra i metodi.
class _KeySpec {
  const _KeySpec(
    this.current,
    this.legacy, {
    required this.secret,
    this.fallback = false,
    this.clearOnLogout = true,
  });

  final String current;
  final String legacy;

  /// I segreti non vengono mai scritti nel fallback in chiaro.
  final bool secret;

  /// I valori non segreti possono essere migrati anche dal fallback.
  final bool fallback;

  /// `clearAuth` elimina questa chiave. L'URL del server resta per comodità.
  final bool clearOnLogout;
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
  static const _tokenKey = 'scripta_jwt_token';
  static const _refreshTokenKey = 'scripta_refresh_token';
  static const _serverUrlKey = 'scripta_server_url';
  static const _usernameKey = 'scripta_username';
  static const _userIdKey = 'scripta_user_id';

  /// Chiave unica della sessione atomica. Le chiavi separate sopra restano
  /// solo per leggere/migrare installazioni precedenti e per i test.
  static const _sessionKey = 'scripta_session_v1';

  // Chiavi usate dalle versioni precedenti (nome "inkflow"): vengono lette
  // una sola volta e rimosse dopo la copia.
  static const _legacyTokenKey = 'inkflow_jwt_token';
  static const _legacyRefreshTokenKey = 'inkflow_refresh_token';
  static const _legacyServerUrlKey = 'inkflow_server_url';
  static const _legacyUsernameKey = 'inkflow_username';
  static const _legacyUserIdKey = 'inkflow_user_id';
  static const _legacySessionKey = 'inkflow_session_v1';

  static const _sessionKeys = _KeySpec(
    _sessionKey,
    _legacySessionKey,
    secret: true,
  );
  static const _tokenKeys = _KeySpec(_tokenKey, _legacyTokenKey, secret: true);
  static const _refreshTokenKeys = _KeySpec(
    _refreshTokenKey,
    _legacyRefreshTokenKey,
    secret: true,
  );
  static const _serverUrlKeys = _KeySpec(
    _serverUrlKey,
    _legacyServerUrlKey,
    secret: false,
    fallback: true,
    clearOnLogout: false,
  );
  static const _usernameKeys = _KeySpec(
    _usernameKey,
    _legacyUsernameKey,
    secret: false,
    fallback: true,
  );
  static const _userIdKeys = _KeySpec(
    _userIdKey,
    _legacyUserIdKey,
    secret: false,
    fallback: true,
  );

  static const _allKeys = <_KeySpec>[
    _sessionKeys,
    _tokenKeys,
    _refreshTokenKeys,
    _serverUrlKeys,
    _usernameKeys,
    _userIdKeys,
  ];

  /// Chiavi che non devono mai restare nel fallback in chiaro.
  static Iterable<_KeySpec> get _secretKeys =>
      _allKeys.where((spec) => spec.secret);

  /// Tutto ciò che `clearAuth` elimina; l'URL del server resta per comodità.
  static Iterable<_KeySpec> get _clearedKeys =>
      _allKeys.where((spec) => spec.clearOnLogout);

  /// Chiavi separate che un bundle di sessione completo rende obsolete.
  static const _splitAuthKeys = <_KeySpec>[
    _tokenKeys,
    _refreshTokenKeys,
    _usernameKeys,
  ];

  final FlutterSecureStorage _storage;
  final bool? _fallbackEnabledOverride;

  bool _legacyMigrationDone = false;

  SecureStorageService([FlutterSecureStorage? storage])
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
  SecureStorageService.withFallback(
    FlutterSecureStorage storage, {
    required bool fallbackEnabled,
  }) : _storage = storage,
       _fallbackEnabledOverride = fallbackEnabled;

  /// Prefisso delle chiavi usate SOLO dal fallback su SharedPreferences.
  static const _fallbackPrefix = AppConstants.prefSecureFallbackPrefix;

  static String _fallbackKey(String key) => '$_fallbackPrefix$key';

  /// Il fallback è attivo solo su iOS/macOS (vedi commento di classe).
  bool get _fallbackEnabled =>
      _fallbackEnabledOverride ?? (Platform.isIOS || Platform.isMacOS);

  /// Migra le chiavi del vecchio nome "inkflow" a "scripta".
  ///
  /// Il latch viene chiuso solo se TUTTE le chiavi sono state migrate: un
  /// errore transitorio del Keychain lascia la migrazione da riprovare alla
  /// chiamata successiva invece di bloccare per sempre la sessione legacy.
  Future<void> _ensureLegacyMigration() async {
    if (_legacyMigrationDone) return;
    if (await _migrateLegacyKeys()) _legacyMigrationDone = true;
  }

  Future<bool> _migrateLegacyKeys() async {
    var ok = true;
    for (final spec in _allKeys) {
      if (!await _migrateKey(spec)) ok = false;
    }

    // I vecchi segreti non devono restare nel fallback in chiaro, anche se
    // la migrazione della chiave sicura non è riuscita.
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final spec in _secretKeys) {
        await prefs.remove(_fallbackKey(spec.current));
        await prefs.remove(_fallbackKey(spec.legacy));
      }
    } catch (_) {
      ok = false;
    }
    return ok;
  }

  Future<bool> _migrateKey(_KeySpec spec) async {
    var ok = true;
    try {
      final legacy = await _storage.read(key: spec.legacy);
      if (legacy != null) {
        final current = await _storage.read(key: spec.current);
        if (current == null) {
          await _storage.write(key: spec.current, value: legacy);
        }
        // Rilegge prima di cancellare: se la scrittura non è stata
        // effettivamente persistita, la vecchia chiave resta l'unica copia
        // valida della sessione.
        final persisted = await _storage.read(key: spec.current);
        if (persisted == null) {
          ok = false;
        } else {
          await _storage.delete(key: spec.legacy);
        }
      }
    } catch (e) {
      debugPrint('SecureStorage: migrazione chiave legacy fallita ($e).');
      ok = false;
    }

    if (!spec.fallback) return ok;
    try {
      final prefs = await SharedPreferences.getInstance();
      final oldFallbackKey = _fallbackKey(spec.legacy);
      final legacy = prefs.getString(oldFallbackKey);
      if (legacy != null) {
        final newFallbackKey = _fallbackKey(spec.current);
        if (prefs.getString(newFallbackKey) == null) {
          await prefs.setString(newFallbackKey, legacy);
        }
        if (prefs.getString(newFallbackKey) == legacy) {
          await prefs.remove(oldFallbackKey);
        } else {
          ok = false;
        }
      }
    } catch (_) {
      ok = false;
    }
    return ok;
  }

  Future<void> _write(String key, String value) async {
    await _ensureLegacyMigration();
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      if (!_fallbackEnabled) rethrow;
      debugPrint(
        'SecureStorage: Keychain non disponibile ($e), uso il fallback.',
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_fallbackKey(key), value);
    }
  }

  Future<String?> _read(String key) async {
    await _ensureLegacyMigration();
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
    return prefs.getString(_fallbackKey(key));
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      if (!_fallbackEnabled) rethrow;
    }
    if (_fallbackEnabled) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_fallbackKey(key));
    }
  }

  /// Token tenuto SOLO in memoria quando il Keychain iOS/macOS rifiuta la
  /// scrittura (build non firmate). Mai persistito. È uno stato dell'istanza:
  /// due service (es. test o account diversi) non devono condividere token.
  String? _memoryOnlyToken;

  /// Stessa rete di sicurezza per il refresh token: senza Keychain resta
  /// valido solo per la sessione corrente.
  String? _memoryOnlyRefreshToken;

  /// Sessione completa tenuta in memoria quando il Keychain non è scrivibile:
  /// i token non finiscono MAI in SharedPreferences.
  StoredSession? _memoryOnlySession;

  /// Salva la sessione con UNA sola scrittura atomica. I token non usano mai
  /// il fallback in chiaro: se il Keychain non è disponibile restano solo in
  /// memoria per la sessione corrente.
  Future<void> saveSession(StoredSession session) async {
    if (!session.isUsable) {
      throw ArgumentError('sessione non valida: token, URL o userId mancanti');
    }
    await _ensureLegacyMigration();
    var stored = false;
    try {
      await _storage.write(
        key: _sessionKey,
        value: jsonEncode(session.toJson()),
      );
      stored = true;
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
    // non segreti e servono al riconoscimento degli account legacy. Il
    // vecchio bundle viene rimosso solo se il nuovo è stato scritto davvero.
    await _removeSplitAuthKeys(removeLegacyBundle: stored);
  }

  /// Elimina current+legacy per ogni spec senza fermarsi al primo errore.
  /// Restituisce il primo errore: i chiamanti decidono se propagarlo.
  Future<Object?> _deleteKeys(Iterable<_KeySpec> specs) async {
    Object? firstError;
    for (final spec in specs) {
      for (final key in [spec.current, spec.legacy]) {
        try {
          await _delete(key);
        } catch (e) {
          firstError ??= e;
        }
      }
    }
    return firstError;
  }

  Future<void> _removeSplitAuthKeys({required bool removeLegacyBundle}) async {
    await _deleteKeys(_splitAuthKeys);
    if (!removeLegacyBundle) return;
    try {
      await _delete(_legacySessionKey);
    } catch (_) {}
  }

  /// Legge la sessione atomica. Se non esiste, migra una tantum le chiavi
  /// separate delle versioni precedenti e la riscrive come bundle.
  Future<StoredSession?> getSession() async {
    await _ensureLegacyMigration();
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

      // Bundle presente ma illeggibile: NON si riattiva una sessione dalle
      // chiavi separate. Sono scritte in momenti diversi e la loro pulizia è
      // best-effort: potrebbero appartenere a un altro account (o a un altro
      // server) e resuscitare una sessione che l'utente ha già lasciato.
      // Meglio richiedere un nuovo login che autenticarsi con credenziali
      // stantie.
      //
      // Il bundle corrotto NON viene cancellato: resta come tombstone. Se la
      // pulizia delle chiavi separate fallisce (è best-effort), al prossimo
      // avvio senza bundle verrebbero migrate come sessione legacy. Finché il
      // bundle è presente, getSession entra sempre in questo ramo e richiede
      // un login; il primo saveSession riuscito lo sovrascrive.
      _memoryOnlySession = null;
      _memoryOnlyToken = null;
      _memoryOnlyRefreshToken = null;
      await _removeSplitAuthKeys(removeLegacyBundle: true);
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

  /// Scrive un segreto nel Keychain. Se il Keychain rifiuta, lo tiene solo in
  /// memoria e prova a rimuovere un eventuale valore stantio rimasto lì.
  Future<void> _saveSecret({
    required String key,
    required String value,
    required String memoryLabel,
    required void Function(String?) setMemoryValue,
  }) async {
    try {
      await _storage.write(key: key, value: value);
      setMemoryValue(null);
    } catch (e) {
      if (!_fallbackEnabled) rethrow;
      debugPrint(
        'SecureStorage: Keychain non disponibile ($e): $memoryLabel solo in memoria.',
      );
      setMemoryValue(value);
      // Se il Keychain è tornato accessibile in lettura, al prossimo avvio
      // vincerebbe il vecchio valore rimasto lì: prova a rimuoverlo. Se anche
      // la delete fallisce, il valore in memoria resta comunque prioritario
      // per la sessione corrente.
      try {
        await _storage.delete(key: key);
      } catch (_) {}
    }
  }

  Future<void> saveAuthToken(String token) => _saveSecret(
    key: _tokenKey,
    value: token,
    memoryLabel: 'token',
    setMemoryValue: (value) => _memoryOnlyToken = value,
  );

  Future<String?> getAuthToken() async {
    await _ensureLegacyMigration();
    // Un token scritto in memoria è la sessione più recente: NON deve essere
    // scavalcato da un vecchio token rimasto nel Keychain quando la scrittura
    // era fallita.
    final memoryToken = _memoryOnlyToken;
    if (memoryToken != null && memoryToken.isNotEmpty) return memoryToken;
    // Versioni precedenti, in fallback, salvavano il token in chiaro in
    // SharedPreferences: se ne trovi uno lo elimina (login da rifare).
    if (_fallbackEnabled) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_fallbackKey(_tokenKeys.current));
      await prefs.remove(_fallbackKey(_tokenKeys.legacy));
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
    await _saveSecret(
      key: _refreshTokenKey,
      value: token,
      memoryLabel: 'refresh token',
      setMemoryValue: (value) => _memoryOnlyRefreshToken = value,
    );
  }

  Future<String?> getRefreshToken() async {
    await _ensureLegacyMigration();
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
    await _ensureLegacyMigration();
    _memoryOnlyToken = null;
    _memoryOnlyRefreshToken = null;
    _memoryOnlySession = null;
    final firstError = await _deleteKeys(_clearedKeys);
    // Keep serverUrl for user convenience unless explicitly cleared
    if (firstError != null) throw firstError;
  }
}
