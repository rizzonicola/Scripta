import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
/// confinato nella sandbox dell'app). Su tutte le altre piattaforme il
/// comportamento è invariato: nessun degrado silenzioso della sicurezza.
class SecureStorageService {
  static const _tokenKey = 'inkflow_jwt_token';
  static const _serverUrlKey = 'inkflow_server_url';
  static const _usernameKey = 'inkflow_username';
  static const _userIdKey = 'inkflow_user_id';

  final FlutterSecureStorage _storage;

  const SecureStorageService([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                resetOnError: true,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  /// Prefisso delle chiavi usate SOLO dal fallback su SharedPreferences.
  static const _fallbackPrefix = 'scripta_secure_fallback_';

  /// Il fallback è attivo solo su iOS/macOS (vedi commento di classe).
  static bool get _fallbackEnabled {
    if (kIsWeb) return false;
    return Platform.isIOS || Platform.isMacOS;
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      if (!_fallbackEnabled) rethrow;
      debugPrint('SecureStorage: Keychain non disponibile ($e), uso il fallback.');
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
      debugPrint('SecureStorage: Keychain non disponibile ($e), uso il fallback.');
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

  Future<void> saveAuthToken(String token) => _write(_tokenKey, token);

  Future<String?> getAuthToken() => _read(_tokenKey);

  Future<void> saveServerUrl(String url) => _write(_serverUrlKey, url.trim());

  Future<String?> getServerUrl() => _read(_serverUrlKey);

  Future<void> saveUsername(String username) => _write(_usernameKey, username.trim());

  Future<String?> getUsername() => _read(_usernameKey);

  Future<void> saveUserId(String userId) => _write(_userIdKey, userId);

  Future<void> clearAuth() async {
    await _delete(_tokenKey);
    await _delete(_usernameKey);
    await _delete(_userIdKey);
    // Keep serverUrl for user convenience unless explicitly cleared
  }
}
