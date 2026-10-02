import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/database/app_database.dart';
import 'package:scripta/core/services/secure_storage_service.dart';
import 'package:scripta/core/services/sync_api_service.dart';
import 'package:scripta/features/settings/providers/settings_provider.dart';
import 'package:scripta/features/sync/providers/sync_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Secure storage in memoria (include saveUserId, che il login richiama).
class _MemorySecureStorage extends SecureStorageService {
  final Map<String, String> _memory = {};

  _MemorySecureStorage() : super(null);

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
  Future<void> saveUserId(String userId) async => _memory['uid'] = userId;

  @override
  Future<void> clearAuth() async => _memory.clear();
}

/// Server finto: conta le sync, registra le PUT delle impostazioni e può
/// trattenere la PRIMA sync finché il test non la rilascia.
class _FakeServer {
  int syncCalls = 0;
  int syncStatus = 200;
  final List<Map<String, dynamic>> settingsPuts = [];

  /// Se valorizzato, la prima sync resta in attesa di questo completer.
  Completer<void>? firstSyncGate;
  final Completer<void> firstSyncReceived = Completer<void>();

  static const _headers = {'content-type': 'application/json'};

  late final http.Client client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;

    if (path == '/api/v1/auth/login') {
      return http.Response(
        json.encode({
          'token': 'token',
          'expires_at': 4102444800000,
          'user_id': 'u1',
          'username': 'mario',
        }),
        200,
        headers: _headers,
      );
    }

    if (path == '/api/v1/user/settings') {
      if (request.method == 'PUT') {
        final body = json.decode(request.body) as Map<String, dynamic>;
        settingsPuts.add(body);
        return http.Response(json.encode(body), 200, headers: _headers);
      }
      return http.Response(
        json.encode({
          'theme': 'dark',
          'color_scheme': 'dark_teal',
          'language': 'it',
          'font_family': 'Inter',
          'font_size': 16,
          'line_spacing': 1.6,
          'layout': 'split',
        }),
        200,
        headers: _headers,
      );
    }

    if (path == '/api/v1/sync') {
      syncCalls++;
      if (syncCalls == 1) {
        if (!firstSyncReceived.isCompleted) firstSyncReceived.complete();
        final gate = firstSyncGate;
        if (gate != null) await gate.future;
      }
      if (syncStatus != 200) {
        return http.Response(
          json.encode({'error': 'rifiutata'}),
          syncStatus,
          headers: _headers,
        );
      }
      return http.Response(
        json.encode({
          'server_time': 1000 + syncCalls,
          'folders': <Object>[],
          'notes': <Object>[],
        }),
        200,
        headers: _headers,
      );
    }

    return http.Response('not found', 404);
  }
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String reason = 'condizione non raggiunta in tempo',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppDatabase.ensureFactoryInitialized();
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = p.join(
      Directory.systemTemp.path,
      'scripta_robust_${DateTime.now().microsecondsSinceEpoch}.db',
    );
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = null;
  });

  ProviderContainer containerFor(_FakeServer server) {
    final container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(_MemorySecureStorage()),
        syncApiServiceProvider.overrideWithValue(SyncApiService(server.client)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<bool> loginFuture(SyncNotifier notifier) => notifier.login(
        serverUrl: 'http://localhost:8080',
        username: 'mario',
        password: 'password',
      );

  group('coalescing dei trigger di sync', () {
    test('i trigger arrivati durante una sync producono un solo giro di recupero', () async {
      final server = _FakeServer()..firstSyncGate = Completer<void>();
      final container = containerFor(server);
      final notifier = container.read(syncProvider.notifier);
      await notifier.initialized;

      final login = loginFuture(notifier);
      await server.firstSyncReceived.future.timeout(const Duration(seconds: 10));
      expect(container.read(syncProvider).isSyncing, isTrue);

      // Tre trigger mentre la prima sync è ancora in volo: nessuno parte in
      // parallelo, ma la richiesta viene ricordata.
      expect(await notifier.triggerSync(), isFalse);
      expect(await notifier.triggerSync(), isFalse);
      notifier.onAppPaused();

      server.firstSyncGate!.complete();
      expect(await login, isTrue);

      expect(server.syncCalls, 2, reason: '1 giro iniziale + 1 solo giro di recupero');
      expect(container.read(syncProvider).isSyncing, isFalse);

      // Nessuna richiesta residua: una sync successiva fa un solo giro.
      expect(await notifier.triggerSync(), isTrue);
      expect(server.syncCalls, 3);
    });

    test('dopo una sync fallita non si insiste con giri di recupero', () async {
      final server = _FakeServer()
        ..firstSyncGate = Completer<void>()
        ..syncStatus = 400;
      final container = containerFor(server);
      final notifier = container.read(syncProvider.notifier);
      await notifier.initialized;

      final login = loginFuture(notifier);
      await server.firstSyncReceived.future.timeout(const Duration(seconds: 10));

      expect(await notifier.triggerSync(), isFalse);

      server.firstSyncGate!.complete();
      expect(await login, isTrue);

      expect(server.syncCalls, 1, reason: 'con il server in errore non si riprova subito');
      expect(container.read(syncProvider).isSyncing, isFalse);
    });
  });

  group('invio remoto delle impostazioni', () {
    test('modifiche ravvicinate producono una sola PUT con l\'ultimo valore', () async {
      final server = _FakeServer();
      final container = containerFor(server);
      final sync = container.read(syncProvider.notifier);
      await sync.initialized;
      expect(await loginFuture(sync), isTrue);

      final settings = container.read(settingsProvider.notifier);
      await settings.setFontSize(18);
      await settings.setFontSize(19);
      await settings.setFontSize(20);

      await _waitUntil(
        () => server.settingsPuts.isNotEmpty,
        reason: 'la PUT delle impostazioni non è mai partita',
      );
      // Margine ben oltre il debounce: non devono arrivarne altre.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(server.settingsPuts.length, 1);
      expect(server.settingsPuts.single['font_size'], 20);
    });

    test('andando in background l\'invio in attesa parte subito e una volta sola', () async {
      final server = _FakeServer();
      final container = containerFor(server);
      final sync = container.read(syncProvider.notifier);
      await sync.initialized;
      expect(await loginFuture(sync), isTrue);

      final settings = container.read(settingsProvider.notifier);
      await settings.setFontSize(22);
      sync.onAppPaused();

      await _waitUntil(
        () => server.settingsPuts.isNotEmpty,
        reason: 'la PUT non è partita al passaggio in background',
      );
      // Oltre la scadenza originaria del debounce: nessun secondo invio.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(server.settingsPuts.length, 1);
      expect(server.settingsPuts.single['font_size'], 22);
    });
  });
}
