import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/services/secure_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestSecureStorage extends FlutterSecureStorage {
  _TestSecureStorage({
    Map<String, String>? data,
    this.writeFails = false,
    this.readFails = false,
    this.deleteFails = false,
  }) : data = data ?? {};

  final Map<String, String> data;
  final bool writeFails;
  final bool readFails;
  final bool deleteFails;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (writeFails) throw Exception('Keychain write failed');
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (readFails) throw Exception('Keychain read failed');
    return data[key];
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (deleteFails) throw Exception('Keychain delete failed');
    data.remove(key);
  }
}

const _fallbackPrefix = 'scripta_secure_fallback_';
const _tokenKey = '${_fallbackPrefix}inkflow_jwt_token';
const _refreshTokenKey = '${_fallbackPrefix}inkflow_refresh_token';
const _serverUrlKey = '${_fallbackPrefix}inkflow_server_url';
const _usernameKey = '${_fallbackPrefix}inkflow_username';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SecureStorageService service;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    service = SecureStorageService.withFallback(
      _TestSecureStorage(writeFails: true, readFails: true, deleteFails: true),
      fallbackEnabled: true,
    );
    await service.clearAuth();
  });

  test('non persiste i token nel fallback in chiaro', () async {
    await service.saveAuthToken('jwt-secret');
    await service.saveRefreshToken('refresh-secret');

    expect(await service.getAuthToken(), 'jwt-secret');
    expect(await service.getRefreshToken(), 'refresh-secret');
    expect(prefs.containsKey(_tokenKey), isFalse);
    expect(prefs.containsKey(_refreshTokenKey), isFalse);

    for (final key in prefs.getKeys()) {
      expect(prefs.get(key), isNot('jwt-secret'));
      expect(prefs.get(key), isNot('refresh-secret'));
    }
  });

  test('persiste nel fallback solo i valori non segreti', () async {
    await service.saveServerUrl(' https://notes.example ');
    await service.saveUsername('mario');

    expect(await service.getServerUrl(), 'https://notes.example');
    expect(await service.getUsername(), 'mario');
    expect(prefs.getString(_serverUrlKey), 'https://notes.example');
    expect(prefs.getString(_usernameKey), 'mario');
  });

  test('getAuthToken elimina un token legacy dal fallback', () async {
    SharedPreferences.setMockInitialValues({_tokenKey: 'legacy-token'});
    final legacyPrefs = await SharedPreferences.getInstance();
    final legacyService = SecureStorageService.withFallback(
      _TestSecureStorage(readFails: true, writeFails: true, deleteFails: true),
      fallbackEnabled: true,
    );

    expect(await legacyService.getAuthToken(), isNull);
    expect(legacyPrefs.containsKey(_tokenKey), isFalse);
  });

  test('clearAuth cancella token e dati personali ma conserva il server',
      () async {
    await service.saveAuthToken('jwt-secret');
    await service.saveRefreshToken('refresh-secret');
    await service.saveUsername('mario');
    await service.saveServerUrl('https://notes.example');

    await service.clearAuth();

    expect(await service.getAuthToken(), isNull);
    expect(await service.getRefreshToken(), isNull);
    expect(await service.getUsername(), isNull);
    expect(await service.getServerUrl(), 'https://notes.example');
    expect(prefs.containsKey(_tokenKey), isFalse);
    expect(prefs.containsKey(_refreshTokenKey), isFalse);
    expect(prefs.containsKey(_usernameKey), isFalse);
  });

  test('il token in memoria prevale su un vecchio token nel Keychain',
      () async {
    final staleStorage = _TestSecureStorage(
      data: {'inkflow_jwt_token': 'stale-token'},
      writeFails: true,
      deleteFails: true,
    );
    final staleService = SecureStorageService.withFallback(
      staleStorage,
      fallbackEnabled: true,
    );

    await staleService.saveAuthToken('fresh-token');

    expect(await staleService.getAuthToken(), 'fresh-token');
    expect(staleStorage.data['inkflow_jwt_token'], 'stale-token');
  });

  test('senza fallback un errore del Keychain non viene nascosto', () async {
    final strictService = SecureStorageService.withFallback(
      _TestSecureStorage(writeFails: true, readFails: true, deleteFails: true),
      fallbackEnabled: false,
    );

    await expectLater(
      strictService.saveAuthToken('jwt-secret'),
      throwsException,
    );
    await expectLater(strictService.getAuthToken(), throwsException);
  });
}
