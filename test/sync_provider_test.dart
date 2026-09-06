import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scripta/core/constants/app_constants.dart';
import 'package:scripta/core/services/secure_storage_service.dart';
import 'package:scripta/core/services/sync_api_service.dart';
import 'package:scripta/features/sync/providers/sync_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// In-memory mock for FlutterSecureStorage to test SecureStorageService
class MockSecureStorageService extends SecureStorageService {
  final Map<String, String> _memory = {};

  MockSecureStorageService() : super(null);

  @override
  Future<void> saveAuthToken(String token) async => _memory['token'] = token;

  @override
  Future<String?> getAuthToken() async => _memory['token'];

  @override
  Future<void> saveServerUrl(String url) async => _memory['url'] = url;

  @override
  Future<String?> getServerUrl() async => _memory['url'];

  @override
  Future<void> saveUsername(String username) async => _memory['user'] = username;

  @override
  Future<String?> getUsername() async => _memory['user'];

  @override
  Future<void> clearAuth() async {
    _memory.remove('token');
    _memory.remove('user');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SyncNotifier Unit Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Initial state loads defaults', () async {
      final mockStorage = MockSecureStorageService();
      final mockClient = MockClient((r) async => http.Response('ok', 200));
      final apiService = SyncApiService(mockClient);

      final container = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(mockStorage),
          syncApiServiceProvider.overrideWithValue(apiService),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(syncProvider.notifier);
      await notifier.initialized;

      final syncState = container.read(syncProvider);
      expect(syncState.serverUrl, AppConstants.defaultServerUrl);
      expect(syncState.syncOnAppLaunch, isTrue);
      expect(syncState.syncOnAppLifecycle, isTrue);
      expect(syncState.syncOnNoteSwitch, isTrue);
      expect(syncState.syncOnInactivity, isFalse);
      expect(syncState.inactivitySeconds, 30);
      expect(syncState.isAuthenticated, isFalse);
    });

    test('Sync toggles update state and persistence', () async {
      final mockStorage = MockSecureStorageService();
      final mockClient = MockClient((r) async => http.Response('ok', 200));
      final apiService = SyncApiService(mockClient);

      final container = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(mockStorage),
          syncApiServiceProvider.overrideWithValue(apiService),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(syncProvider.notifier);
      await notifier.initialized;

      await notifier.setSyncOnInactivity(true);
      await notifier.setInactivitySeconds(45);
      await notifier.setSyncOnAppLifecycle(false);

      final updatedState = container.read(syncProvider);
      expect(updatedState.syncOnInactivity, isTrue);
      expect(updatedState.inactivitySeconds, 45);
      expect(updatedState.syncOnAppLifecycle, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('scripta_sync_on_inactivity'), isTrue);
      expect(prefs.getInt('scripta_sync_inactivity_seconds'), 45);
      expect(prefs.getBool('scripta_sync_on_lifecycle'), isFalse);
    });
  });
}
