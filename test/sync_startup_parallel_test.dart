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

// A-01 — avvio della rete in parallelo.
//
// Prima `SyncNotifier._init` attendeva in serie l'health check (fino a 15 s),
// poi le impostazioni (fino a 33 s) e solo dopo avviava la sync. Qui si
// trattiene una delle due richieste "preliminari" e si verifica che la sync
// parta comunque. I test del secondo gruppo riguardano la regola che
// accompagna il parallelismo: un esito negativo "vecchio" non deve riportare a
// Offline un indicatore che una richiesta riuscita nel frattempo ha già messo
// Online (la sync si riconosce da `lastSyncTime`, health check e impostazioni
// dal contatore interno: i due percorsi hanno un test ciascuno).

/// Secure storage in memoria, GIÀ con sessione: URL del server e token.
class _SeededSecureStorage extends SecureStorageService {
  final Map<String, String> _memory = {
    'url': 'http://localhost:8080',
    'user': 'mario',
    'token': 'token',
  };

  _SeededSecureStorage() : super(null);

  @override
  Future<String?> getAuthToken() async => _memory['token'];

  @override
  Future<String?> getServerUrl() async => _memory['url'];

  @override
  Future<String?> getUsername() async => _memory['user'];

  @override
  Future<void> clearAuth() async => _memory.clear();
}

/// Server finto con tre endpoint, ciascuno trattenibile da un [Completer] e
/// con lo stato HTTP configurabile. Una volta rilasciato il completer le
/// richieste successive rispondono subito.
class _StartupServer {
  Completer<void>? healthGate;
  int healthStatus = 200;
  int healthCalls = 0;

  Completer<void>? settingsGate;
  int settingsStatus = 200;
  int settingsCalls = 0;

  int syncStatus = 200;
  int syncCalls = 0;

  static const _headers = {'content-type': 'application/json'};

  late final http.Client client = MockClient(_handle);

  http.Response _error(int status) =>
      http.Response(json.encode({'error': 'errore di prova'}), status, headers: _headers);

  Future<http.Response> _handle(http.Request request) async {
    switch (request.url.path) {
      case '/healthz':
        healthCalls++;
        final healthWait = healthGate;
        if (healthWait != null) await healthWait.future;
        return http.Response('ok', healthStatus);

      case '/api/v1/user/settings':
        settingsCalls++;
        final settingsWait = settingsGate;
        if (settingsWait != null) await settingsWait.future;
        if (settingsStatus != 200) return _error(settingsStatus);
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

      case '/api/v1/sync':
        syncCalls++;
        if (syncStatus != 200) return _error(syncStatus);
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
        secureStorageProvider.overrideWithValue(_SeededSecureStorage()),
        syncApiServiceProvider.overrideWithValue(SyncApiService(server.client)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Attende che il primo giro di sync sia concluso con successo.
  Future<void> waitFirstSyncDone(ProviderContainer container) => _waitUntil(
        () {
          final s = container.read(syncProvider);
          return s.lastSyncTime != null && !s.isSyncing;
        },
        reason: 'la prima sync non si è conclusa in tempo',
      );

  group('avvio in parallelo', () {
    test('la sync parte anche se l\'health check non risponde', () async {
      final server = _StartupServer()..healthGate = Completer<void>();
      final container = containerFor(server);
      final notifier = container.read(syncProvider.notifier); // avvia _init

      // `_init` non attende più la rete: si completa anche col health check
      // bloccato. Il vecchio codice restava fermo ~15 s (3 tentativi da 4 s +
      // 2 pause da 1,5 s), quindi 5 s bastano a distinguere i due casi.
      await notifier.initialized.timeout(const Duration(seconds: 5));

      // Il vecchio codice avrebbe iniziato la sync dopo 15 s: il limite di
      // 10 s di _waitUntil lo boccia.
      await _waitUntil(
        () => server.syncCalls >= 1,
        reason: 'la sync non è partita mentre l\'health check era in attesa',
      );
      expect(server.healthCalls, greaterThanOrEqualTo(1),
          reason: 'l\'health check è partito ed è ancora in attesa');
      expect(server.healthGate!.isCompleted, isFalse,
          reason: 'la sync è partita senza che il health check abbia risposto');

      // Rilascia e lascia finire tutto prima del tearDown.
      server.healthGate!.complete();
      await waitFirstSyncDone(container);
      await _waitUntil(() => container.read(syncProvider).isOnline);
    });

    test('la sync parte anche se le impostazioni non rispondono', () async {
      final server = _StartupServer()..settingsGate = Completer<void>();
      final container = containerFor(server);
      container.read(syncProvider);

      // Il vecchio codice avrebbe iniziato la sync dopo oltre 30 s (3 tentativi
      // da 10 s del fetch): il limite di 10 s di _waitUntil lo boccia.
      await _waitUntil(
        () => server.syncCalls >= 1,
        reason: 'la sync non è partita mentre le impostazioni erano in attesa',
      );
      expect(server.settingsCalls, greaterThanOrEqualTo(1),
          reason: 'il fetch delle impostazioni è partito ed è ancora in attesa');

      server.settingsGate!.complete();
      await waitFirstSyncDone(container);
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

    test('lo stato Online persistito evita il giallo prima del health check',
        () async {
      SharedPreferences.setMockInitialValues({
        'scripta_sync_on_launch': false,
        'scripta_last_online': true,
      });
      final server = _StartupServer()..healthGate = Completer<void>();
      final container = containerFor(server);
      final notifier = container.read(syncProvider.notifier);
      await notifier.initialized;
      await _waitUntil(() => server.healthCalls >= 1);

      expect(container.read(syncProvider).isOnline, isTrue,
          reason: 'lo stato dell\'ultima sessione deve valere fino al check');
      expect(server.healthGate!.isCompleted, isFalse);

      server.healthGate!.complete();
      await _waitUntil(() => container.read(syncProvider).isOnline);
    });

    test('l\'esito del health check aggiorna lo stato persistito', () async {
      SharedPreferences.setMockInitialValues({
        'scripta_sync_on_launch': false,
        'scripta_last_online': false,
      });
      final server = _StartupServer();
      final container = containerFor(server);
      container.read(syncProvider.notifier);

      await _waitUntil(() => container.read(syncProvider).isOnline);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('scripta_last_online'), isTrue);
    });
  });

  group('indicatore online/offline con richieste concorrenti', () {
    test('un health check che fallisce DOPO una sync riuscita non riporta Offline', () async {
      final server = _StartupServer()
        ..healthGate = Completer<void>()
        ..healthStatus = 500;
      final container = containerFor(server);
      container.read(syncProvider);

      await waitFirstSyncDone(container);
      expect(container.read(syncProvider).isOnline, isTrue);

      // Ora l'health check (partito PRIMA della sync) fallisce, tutti e 3 i
      // tentativi (pause da 1,5 s fra l'uno e l'altro).
      server.healthGate!.complete();
      await _waitUntil(() => server.healthCalls >= 3);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(container.read(syncProvider).isOnline, isTrue,
          reason: 'la sync era riuscita dopo la partenza del controllo: il server è raggiungibile');
    });

    test('un fetch delle impostazioni fallito DOPO una sync riuscita non riporta Offline', () async {
      final server = _StartupServer()
        ..settingsGate = Completer<void>()
        ..settingsStatus = 500;
      final container = containerFor(server);
      container.read(syncProvider);

      await waitFirstSyncDone(container);
      expect(container.read(syncProvider).isOnline, isTrue);

      // Il 500 non è transitorio: nessun nuovo tentativo, il fallimento
      // arriva subito dopo il rilascio.
      server.settingsGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(container.read(syncProvider).isOnline, isTrue);
    });

    test('un controllo che fallisce DOPO una richiesta leggera riuscita non riporta Offline', () async {
      // Percorso del contatore (health check e impostazioni), distinto da
      // `lastSyncTime`: con la sync all'avvio disattivata non ci sono sync, quindi
      // l'unico segnale di raggiungibilità è la richiesta delle impostazioni,
      // chiamata qui a mano. Con la sola regola su `lastSyncTime` questo test
      // fallirebbe.
      SharedPreferences.setMockInitialValues({'scripta_sync_on_launch': false});
      final server = _StartupServer();
      final container = containerFor(server);
      final notifier = container.read(syncProvider.notifier);
      await notifier.initialized;
      await _waitUntil(
        () => container.read(syncProvider).isOnline,
        reason: 'il health check iniziale non ha portato lo stato a Online',
      );

      // Un nuovo controllo parte e resta in attesa del gate; poi fallirà.
      server.healthGate = Completer<void>();
      server.healthStatus = 500;
      final probe = notifier.checkConnection();
      await _waitUntil(
        () => server.healthCalls >= 2,
        reason: 'il secondo controllo non è partito',
      );

      // Nel frattempo le impostazioni rispondono: il server è raggiungibile.
      await notifier.fetchRemoteUserSettings();
      expect(server.settingsCalls, 1);

      // Ora il controllo fallisce (3 tentativi, pause da 1,5 s).
      server.healthGate!.complete();
      expect(await probe, isFalse, reason: 'il valore di ritorno resta quello del controllo');
      expect(container.read(syncProvider).isOnline, isTrue,
          reason: 'le impostazioni sono riuscite dopo la partenza del controllo');
    });

    test('un controllo che fallisce SENZA successi nel frattempo abbassa l\'indicatore', () async {
      final server = _StartupServer(); // tutto risponde 200
      final container = containerFor(server);
      final notifier = container.read(syncProvider.notifier);

      await waitFirstSyncDone(container);
      await _waitUntil(() => container.read(syncProvider).isOnline);

      // Server che smette di rispondere bene: nessuna altra richiesta in volo
      // (il watchdog scatta ogni 25 s), quindi l'esito negativo è l'ultimo
      // dato disponibile e deve valere.
      server.healthStatus = 500;
      final probeResult = await notifier.checkConnection();

      expect(probeResult, isFalse);
      expect(container.read(syncProvider).isOnline, isFalse);
    });
  });
}
