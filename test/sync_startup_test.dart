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
import 'package:scripta/features/sync/providers/sync_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Avvio di rete di SyncNotifier con una sessione già salvata (URL + token):
// health check, impostazioni remote e prima sync devono partire INSIEME, non in
// serie. Prima il health check (fino a 15 s su rete morta) e poi le impostazioni
// (fino a 33 s) ritardavano la prima richiesta di sync.

/// Secure storage in memoria, già popolato come dopo un login riuscito.
class _SeededStorage extends SecureStorageService {
  final Map<String, String> _memory = {
    'url': 'http://localhost:8080',
    'user': 'mario',
    'token': 'token',
  };

  _SeededStorage() : super(null);

  @override
  Future<String?> getServerUrl() async => _memory['url'];

  @override
  Future<String?> getUsername() async => _memory['user'];

  @override
  Future<String?> getAuthToken() async => _memory['token'];

  @override
  Future<void> clearAuth() async => _memory.clear();
}

/// Server finto: conta le richieste di ogni endpoint e può trattenere le
/// risposte di health e impostazioni finché il test non le rilascia.
class _StartupServer {
  int healthCalls = 0;
  int settingsCalls = 0;
  int syncCalls = 0;

  int healthStatus = 200;
  int settingsStatus = 200;

  /// Se valorizzati, la risposta resta in attesa del completer.
  Completer<void>? healthGate;
  Completer<void>? settingsGate;

  final Completer<void> firstSyncReceived = Completer<void>();

  static const _json = {'content-type': 'application/json'};

  late final http.Client client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    switch (request.url.path) {
      case '/healthz':
        healthCalls++;
        await healthGate?.future;
        return http.Response('ok', healthStatus);

      case '/api/v1/user/settings':
        settingsCalls++;
        await settingsGate?.future;
        if (settingsStatus != 200) {
          return http.Response(
            json.encode({'error': 'rifiutata'}),
            settingsStatus,
            headers: _json,
          );
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
          headers: _json,
        );

      case '/api/v1/sync':
        syncCalls++;
        if (!firstSyncReceived.isCompleted) firstSyncReceived.complete();
        return http.Response(
          json.encode({
            'server_time': 1000 + syncCalls,
            'folders': <Object>[],
            'notes': <Object>[],
          }),
          200,
          headers: _json,
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
      'scripta_startup_${DateTime.now().microsecondsSinceEpoch}.db',
    );
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = null;
  });

  ProviderContainer containerFor(_StartupServer server) {
    final container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(_SeededStorage()),
        syncApiServiceProvider.overrideWithValue(SyncApiService(server.client)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Vero quando la prima sync dell'avvio si è conclusa con successo: così il
  /// DB temporaneo non viene chiuso mentre la sync lo sta ancora usando.
  bool firstRoundDone(ProviderContainer container) {
    final s = container.read(syncProvider);
    return !s.isSyncing && s.lastSyncTime != null;
  }

  group('avvio di rete in parallelo', () {
    test('la prima sync parte senza aspettare che risponda il health check', () async {
      final server = _StartupServer()..healthGate = Completer<void>();
      final container = containerFor(server);
      final notifier = container.read(syncProvider.notifier);

      // `_init` non attende più la rete: si completa anche col health check
      // bloccato. Col codice precedente restava fermo ~15 s (3 tentativi da
      // 4 s + 2 pause da 1,5 s), quindi 5 s bastano a distinguere i due casi.
      await notifier.initialized.timeout(const Duration(seconds: 5));

      // Dopo i 500 ms di rinvio la sync parte mentre il health check non ha
      // MAI avuto risposta (il test non rilascia il suo gate).
      await server.firstSyncReceived.future.timeout(const Duration(seconds: 8));
      expect(server.healthCalls, greaterThanOrEqualTo(1));
      expect(server.healthGate!.isCompleted, isFalse);

      // Le impostazioni partono insieme alla sync, non dopo la sua fine.
      await _waitUntil(
        () => server.settingsCalls == 1,
        reason: 'la richiesta delle impostazioni non è partita',
      );

      await _waitUntil(
        () => firstRoundDone(container),
        reason: 'la prima sync non si è conclusa',
      );
      expect(container.read(syncProvider).isOnline, isTrue);

      server.healthGate!.complete();
    });

    test('con la sync all\'avvio disattivata parte solo il health check', () async {
      // Guardia di regressione: il ramo `launchSync == false` non deve
      // lanciare né sync né impostazioni.
      SharedPreferences.setMockInitialValues({'scripta_sync_on_launch': false});
      final server = _StartupServer();
      final container = containerFor(server);
      container.read(syncProvider.notifier);

      await _waitUntil(
        () => container.read(syncProvider).isOnline,
        reason: 'il health check non ha portato lo stato a Online',
      );
      // Oltre i 500 ms di rinvio con cui, se abilitata, partirebbe la sync.
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(server.healthCalls, 1);
      expect(server.syncCalls, 0);
      expect(server.settingsCalls, 0);
    });
  });

  group('indicatore Online/Offline con richieste concorrenti', () {
    test('un health check che fallisce DOPO una sync riuscita non riporta Offline', () async {
      // Health check sempre in errore: tre tentativi con pausa di 1,5 s, quindi
      // termina intorno ai 3 s, ben dopo la prima sync (che dura pochi ms).
      final server = _StartupServer()..healthStatus = 503;
      final container = containerFor(server);
      container.read(syncProvider.notifier);

      await _waitUntil(
        () => firstRoundDone(container),
        reason: 'la prima sync non si è conclusa',
      );
      expect(
        container.read(syncProvider).isOnline,
        isTrue,
        reason: 'una sync riuscita prova che il server risponde',
      );

      await _waitUntil(
        () => server.healthCalls >= 3,
        reason: 'il health check non ha esaurito i tentativi',
      );
      // Margine perché il terzo esito negativo venga elaborato.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        container.read(syncProvider).isOnline,
        isTrue,
        reason: 'un esito negativo più vecchio della sync non deve vincere',
      );
    });

    test('un fallimento delle impostazioni DOPO una sync riuscita non riporta Offline', () async {
      // Le impostazioni restano in attesa finché la sync non è finita, poi
      // rispondono con un errore del server.
      final server = _StartupServer()
        ..settingsGate = Completer<void>()
        ..settingsStatus = 500;
      final container = containerFor(server);
      container.read(syncProvider.notifier);

      await _waitUntil(
        () => firstRoundDone(container),
        reason: 'la prima sync non si è conclusa',
      );
      await _waitUntil(
        () => server.settingsCalls == 1,
        reason: 'la richiesta delle impostazioni non è partita',
      );
      expect(container.read(syncProvider).isOnline, isTrue);

      server.settingsGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        container.read(syncProvider).isOnline,
        isTrue,
        reason: 'la sync riuscita nel frattempo prova che il server risponde',
      );
    });
  });
}
