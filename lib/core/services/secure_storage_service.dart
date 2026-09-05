import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Service providing encrypted local storage for sensitive authentication tokens and credentials.
/// Uses Android Keystore + EncryptedSharedPreferences on Android,
/// Keychain on iOS/macOS, and Secret Service on Linux.
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

  Future<void> saveAuthToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<String?> getAuthToken() async {
    return await _storage.read(key: _tokenKey);
  }

  Future<void> saveServerUrl(String url) async {
    await _storage.write(key: _serverUrlKey, value: url.trim());
  }

  Future<String?> getServerUrl() async {
    return await _storage.read(key: _serverUrlKey);
  }

  Future<void> saveUsername(String username) async {
    await _storage.write(key: _usernameKey, value: username.trim());
  }

  Future<String?> getUsername() async {
    return await _storage.read(key: _usernameKey);
  }

  Future<void> saveUserId(String userId) async {
    await _storage.write(key: _userIdKey, value: userId);
  }

  Future<String?> getUserId() async {
    return await _storage.read(key: _userIdKey);
  }

  Future<void> clearAuth() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _usernameKey);
    await _storage.delete(key: _userIdKey);
    // Keep serverUrl for user convenience unless explicitly cleared
  }

  Future<void> clearAll() async {
    await _storage.deleteAll();
  }
}
