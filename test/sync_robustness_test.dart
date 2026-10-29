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
  Future<void> saveRefreshToken(String token) async {
    if (token.isEmpty) {
      _memory.remove('refresh');
    } else {
      _memory['refresh'] = token;
    }
  }

  @override
  Future<String?> getRefreshToken() async => _memory['refresh'];

  @override
  Future<void> saveServerUrl(String url) async => _memory['url'] = url;

  @override
  Future<String?> getServerUrl() async => _memory['url'];

  @override
  Future<void> saveUsername(String username) async =>
      _memory['user'] = username;

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
  int loginCalls = 0;
  bool loginOffline = false;
  bool loginMalformed = false;
  int loginFailuresRemaining = 0;
  int loginFailureStatus = 500;
  String? loginFailureCode;
  int syncStatus = 200;
  String? syncFailureCode;
  final List<Map<String, dynamic>> settingsPuts = [];

  /// Se valorizzato, la login resta in attesa di questo completer.
  Completer<void>? loginGate;

  /// Se valorizzato, la prima sync resta in attesa di questo completer.
  Completer<void>? firstSyncGate;
  final Completer<void> firstSyncReceived = Completer<void>();

  static const _headers = {'content-type': 'application/json'};

  late final http.Client client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;

    if (path == '/api/v1/auth/login') {
      loginCalls++;
      final gate = loginGate;
      if (gate != null) await gate.future;
      if (loginOffline) {
        throw http.ClientException('rete assente');
      }
      if (loginFailuresRemaining > 0) {
        loginFailuresRemaining--;
        return http.Response(
          json.encode({
            'error': 'errore finto del server',
            if (loginFailureCode != null) 'code': loginFailureCode,
          }),
          loginFailureStatus,
          headers: _headers,
        );
      }
      if (loginMalformed) {
        return http.Response('<html>non json</html>', 200, headers: _headers);
      }
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
          json.encode({
            'error': 'rifiutata',
            if (syncFailureCode != null) 'code': syncFailureCode,
          }),
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

  ProviderContainer containerFor(
    _FakeServer server, {
    Duration loginBudget = const Duration(seconds: 20),
  }) {
    final storage = _MemorySecureStorage();
    final api = SyncApiService(server.client);
    final container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(storage),
        syncApiServiceProvider.overrideWithValue(api),
        syncProvider.overrideWith(
          (ref) => SyncNotifier(
            ref,
            api,
            storage,
            retryWait: (d) async {},
            loginBudget: loginBudget,
          ),
        ),
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

  group('login interattivo', () {
    test(
      'senza rete ritenta entro il budget e consente il retry manuale',
      () async {
        final server = _FakeServer()..loginOffline = true;
        final container = containerFor(server);
        final notifier = container.read(syncProvider.notifier);
        await notifier.initialized;

        expect(await loginFuture(notifier), isFalse);
        expect(
          server.loginCalls,
          3,
          reason: 'un errore di trasporto è transitorio: 3 tentativi',
        );
        expect(
          container.read(syncProvider).isSyncing,
          isFalse,
          reason: 'il pulsante deve tornare attivo',
        );
        expect(container.read(syncProvider).isAuthenticated, isFalse);
        expect(container.read(syncProvider).isOnline, isFalse);
        expect(
          container.read(syncProvider).lastError,
          contains('Impossibile connettersi'),
        );

        server.loginOffline = false;
        expect(
          await loginFuture(notifier),
          isTrue,
          reason: 'un nuovo tentativo manuale deve poter riuscire',
        );
        expect(server.loginCalls, 4);
        expect(container.read(syncProvider).isAuthenticated, isTrue);
        expect(container.read(syncProvider).isSyncing, isFalse);
      },
    );

    test('un 401 non viene ritentato e resta Online', () async {
      final server = _FakeServer()
        ..loginFailuresRemaining = 1
        ..loginFailureStatus = 401;
      final container = containerFor(server);
      final notifier = container.read(syncProvider.notifier);
      await notifier.initialized;

      expect(await loginFuture(notifier), isFalse);
      expect(
        server.loginCalls,
        1,
        reason: 'le credenziali errate non sono un errore transitorio',
      );
      expect(
        container.read(syncProvider).isOnline,
        isTrue,
        reason: 'il server ha risposto: non è Offline',
      );
      expect(container.read(syncProvider).isSyncing, isFalse);
      expect(
        container.read(syncProvider).lastError,
        contains('Credenziali non valide'),
      );
    });

    test(
      'un account bloccato ha un messaggio distinto e non viene ritentato',
      () async {
        final server = _FakeServer()
          ..loginFailuresRemaining = 1
          ..loginFailureStatus = 403
          ..loginFailureCode = 'account_blocked';
        final container = containerFor(server);
        final notifier = container.read(syncProvider.notifier);
        await notifier.initialized;

        expect(await loginFuture(notifier), isFalse);
        expect(
          server.loginCalls,
          1,
          reason: 'un account bloccato non è un errore transitorio',
        );
        expect(container.read(syncProvider).isAuthenticated, isFalse);
        expect(
          container.read(syncProvider).lastError,
          contains('Account bloccato'),
        );
        expect(
          container.read(syncProvider).lastError,
          isNot(contains('Credenziali non valide')),
        );
      },
    );

    test('un 429 al login mostra il messaggio rate limit', () async {
      final server = _FakeServer()
        ..loginFailuresRemaining = 10
        ..loginFailureStatus = 429
        ..loginFailureCode = 'rate_limited';
      final container = containerFor(server);
      final notifier = container.read(syncProvider.notifier);
      await notifier.initialized;

      expect(await loginFuture(notifier), isFalse);
      expect(
        server.loginCalls,
        3,
        reason: 'il 429 è transitorio e viene ritentato',
      );
      expect(
        container.read(syncProvider).lastError,
        contains('Troppi tentativi'),
      );
      expect(container.read(syncProvider).isOnline, isTrue);
    });

    test('un 500 transitorio viene ritentato e poi riesce', () async {
      final server = _FakeServer()
        ..loginFailuresRemaining = 1
        ..loginFailureStatus = 500;
      final container = containerFor(server);
      final notifier = container.read(syncProvider.notifier);
      await notifier.initialized;

      expect(await loginFuture(notifier), isTrue);
      expect(server.loginCalls, 2, reason: 'primo 500, poi successo');
      expect(container.read(syncProvider).isOnline, isTrue);
      expect(container.read(syncProvider).isAuthenticated, isTrue);
    });

    test('dopo tre 500 si ferma, mostra l\'errore e resta Online', () async {
      final server = _FakeServer()
        ..loginFailuresRemaining = 10
        ..loginFailureStatus = 500;
      final container = containerFor(server);
      final notifier = container.read(syncProvider.notifier);
      await notifier.initialized;

      expect(await loginFuture(notifier), isFalse);
      expect(server.loginCalls, 3);
      expect(container.read(syncProvider).isOnline, isTrue);
      expect(container.read(syncProvider).isSyncing, isFalse);
      expect(
        container.read(syncProvider).lastError,
        contains('errore finto del server'),
      );
    });

    test(
      'una risposta 200 malformata non viene ritentata e resta Online',
      () async {
        final server = _FakeServer()..loginMalformed = true;
        final container = containerFor(server);
        final notifier = container.read(syncProvider.notifier);
        await notifier.initialized;

        expect(await loginFuture(notifier), isFalse);
        expect(
          server.loginCalls,
          1,
          reason: 'un JSON malformato non migliora ritentando',
        );
        expect(container.read(syncProvider).isOnline, isTrue);
        expect(container.read(syncProvider).isSyncing, isFalse);
        expect(
          container.read(syncProvider).lastError,
          contains('Risposta del server non valida'),
        );
      },
    );

    test('il budget complessivo ferma un login che non risponde', () async {
      final server = _FakeServer()..loginGate = Completer<void>();
      final container = containerFor(
        server,
        loginBudget: const Duration(milliseconds: 150),
      );
      final notifier = container.read(syncProvider.notifier);
      await notifier.initialized;

      final stopwatch = Stopwatch()..start();
      expect(await loginFuture(notifier), isFalse);
      stopwatch.stop();

      expect(server.loginCalls, 1);
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: 'il timeout complessivo deve fermare il login',
      );
      expect(container.read(syncProvider).isOnline, isFalse);
      expect(container.read(syncProvider).isSyncing, isFalse);
      expect(container.read(syncProvider).lastError, contains('Tempo scaduto'));

      server.loginGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  });

  group('coalescing dei trigger di sync', () {
    test(
      'i trigger arrivati durante una sync producono un solo giro di recupero',
      () async {
        final server = _FakeServer()..firstSyncGate = Completer<void>();
        final container = containerFor(server);
        final notifier = container.read(syncProvider.notifier);
        await notifier.initialized;

        final login = loginFuture(notifier);
        await server.firstSyncReceived.future.timeout(
          const Duration(seconds: 10),
        );
        expect(container.read(syncProvider).isSyncing, isTrue);

        // Tre trigger mentre la prima sync è ancora in volo: nessuno parte in
        // parallelo, ma la richiesta viene ricordata.
        expect(await notifier.triggerSync(), isFalse);
        expect(await notifier.triggerSync(), isFalse);
        notifier.onAppPaused();

        server.firstSyncGate!.complete();
        expect(await login, isTrue);

        expect(
          server.syncCalls,
          2,
          reason: '1 giro iniziale + 1 solo giro di recupero',
        );
        expect(container.read(syncProvider).isSyncing, isFalse);

        // Nessuna richiesta residua: una sync successiva fa un solo giro.
        expect(await notifier.triggerSync(), isTrue);
        expect(server.syncCalls, 3);
      },
    );

    test('dopo una sync fallita non si insiste con giri di recupero', () async {
      final server = _FakeServer()
        ..firstSyncGate = Completer<void>()
        ..syncStatus = 400;
      final container = containerFor(server);
      final notifier = container.read(syncProvider.notifier);
      await notifier.initialized;

      final login = loginFuture(notifier);
      await server.firstSyncReceived.future.timeout(
        const Duration(seconds: 10),
      );

      expect(await notifier.triggerSync(), isFalse);

      server.firstSyncGate!.complete();
      expect(await login, isTrue);

      expect(
        server.syncCalls,
        1,
        reason: 'con il server in errore non si riprova subito',
      );
      expect(container.read(syncProvider).isSyncing, isFalse);
    });
  });

  group('errori account e rate limit durante la sync', () {
    test(
      'un account bloccato chiude la sessione con un messaggio distinto',
      () async {
        final server = _FakeServer();
        final container = containerFor(server);
        final notifier = container.read(syncProvider.notifier);
        await notifier.initialized;
        expect(await loginFuture(notifier), isTrue);

        server
          ..syncStatus = 403
          ..syncFailureCode = 'account_blocked';
        expect(await notifier.triggerSync(), isFalse);

        final state = container.read(syncProvider);
        expect(state.isAuthenticated, isFalse);
        expect(
          state.isOnline,
          isTrue,
          reason: 'il server ha risposto con un 403',
        );
        expect(state.lastSyncMessage, contains('Account bloccato'));
        expect(state.lastError, contains('Account bloccato'));
      },
    );

    test(
      'un 429 persistente mostra il limite di richieste senza sloggare',
      () async {
        final server = _FakeServer();
        final container = containerFor(server);
        final notifier = container.read(syncProvider.notifier);
        await notifier.initialized;
        expect(await loginFuture(notifier), isTrue);

        server
          ..syncStatus = 429
          ..syncFailureCode = 'rate_limited';
        expect(await notifier.triggerSync(), isFalse);

        final state = container.read(syncProvider);
        expect(
          state.isAuthenticated,
          isTrue,
          reason: 'il rate limit è temporaneo, non invalida il token',
        );
        expect(state.lastSyncMessage, contains('limite di richieste'));
        expect(state.lastError, isNot(contains('Account bloccato')));
      },
    );
  });

  group('invio remoto delle impostazioni', () {
    test(
      'modifiche ravvicinate producono una sola PUT con l\'ultimo valore',
      () async {
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
      },
    );

    test(
      'andando in background l\'invio in attesa parte subito e una volta sola',
      () async {
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
      },
    );
  });
}
