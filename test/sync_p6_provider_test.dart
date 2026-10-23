// P6, fase 1 (app): backoff e Retry-After (Y-11), capability del server
// (Y-14), scadenza del token (Y-13-A). Il server è finto e scriptabile; le
// attese del backoff sono registrate invece di essere attese.

import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/database/app_database.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:scripta/core/services/secure_storage_service.dart';
import 'package:scripta/core/services/sync_api_service.dart';
import 'package:scripta/features/sync/providers/sync_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Chiave delle preferenze con la scadenza del token (ms). Stessa stringa di
/// `SyncNotifier._prefTokenExpiresAt`.
const _expiryKey = 'scripta_token_expires_at_ms';

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
  Future<void> saveUsername(String username) async =>
      _memory['user'] = username;

  @override
  Future<String?> getUsername() async => _memory['user'];

  @override
  Future<void> saveUserId(String userId) async => _memory['uid'] = userId;

  @override
  Future<String?> getUserId() async => _memory['uid'];

  @override
  Future<void> clearAuth() async => _memory.clear();
}

class _FixedRandom implements Random {
  _FixedRandom(this.value);
  double value;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;
}

class _Reply {
  _Reply(this.status, {this.headers = const {}, String? body})
      : body = body ?? json.encode({'error': 'x'});

  _Reply.ok({Map<String, Object?>? caps})
      : status = 200,
        headers = const {'content-type': 'application/json'},
        body = json.encode({
          'server_time': 1000,
          'full_resync': false,
          'folders': <Object>[],
          'notes': <Object>[],
          if (caps != null) 'caps': caps,
        });

  final int status;
  final Map<String, String> headers;
  final String body;
}

class _Server {
  _Server({this.loginExpiresAt = 4102444800});

  /// `expires_at` restituito dalla login (secondi Unix, come il server vero).
  final int loginExpiresAt;

  int syncCalls = 0;
  int settingsGets = 0;
  int settingsStatus = 200;

  /// Risposte di sync in coda; esaurite, il server risponde 200 senza caps.
  final List<_Reply> syncScript = [];

  late final http.Client client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    const json200 = {'content-type': 'application/json'};
    final path = request.url.path;

    if (path == '/api/v1/auth/login') {
      return http.Response(
        json.encode({
          'token': 'token',
          'expires_at': loginExpiresAt,
          'user_id': 'u1',
          'username': 'mario'
        }),
        200,
        headers: json200,
      );
    }
    if (path == '/api/v1/user/settings') {
      if (request.method == 'PUT') {
        return http.Response(request.body, 200, headers: json200);
      }
      settingsGets++;
      if (settingsStatus != 200) {
        return http.Response(
            json.encode({'error': 'token non valido'}), settingsStatus,
            headers: json200);
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
        headers: json200,
      );
    }
    if (path == '/api/v1/sync') {
      syncCalls++;
      final reply =
          syncScript.isNotEmpty ? syncScript.removeAt(0) : _Reply.ok();
      return http.Response(reply.body, reply.status,
          headers: {'content-type': 'application/json', ...reply.headers});
    }
    return http.Response('not found', 404);
  }
}

class _Harness {
  _Harness(this.server) : random = _FixedRandom(0.5) {
    container = ProviderContainer(
      overrides: [
        syncProvider.overrideWith(
          (ref) => SyncNotifier(
            ref,
            SyncApiService(server.client),
            _MemorySecureStorage(),
            retryWait: (d) async => delays.add(d),
            random: random,
          ),
        ),
      ],
    );
    notifier = container.read(syncProvider.notifier);
  }

  final _Server server;
  final _FixedRandom random;
  final List<Duration> delays = [];
  late final ProviderContainer container;
  late final SyncNotifier notifier;

  Future<bool> login() async {
    await notifier.initialized;
    final ok = await notifier.login(
        serverUrl: 'http://localhost:8080',
        username: 'mario',
        password: 'password');
    // Lascia chiudere ciò che la login avvia in parallelo (impostazioni).
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return ok;
  }
}

NoteRow _note(String id, String content) => NoteRow(
      id: id,
      title: 't',
      content: content,
      folderId: null,
      isFavorite: false,
      isPinned: false,
      orderIndex: 0,
      createdAt: 1,
      updatedAt: 1000,
      deletedAt: null,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppDatabase.ensureFactoryInitialized();
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = p.join(
      Directory.systemTemp.path,
      'scripta_p6_${DateTime.now().microsecondsSinceEpoch}.db',
    );
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = null;
  });

  _Harness harness(_Server server) {
    final h = _Harness(server);
    addTearDown(h.container.dispose);
    return h;
  }

  group('Y-11: backoff e Retry-After', () {
    test('un 503 con Retry-After non viene ritentato prima del tempo indicato',
        () async {
      final server = _Server()
        ..syncScript.add(_Reply(503, headers: const {'retry-after': '2'}));
      final h = harness(server);
      await h.login();

      expect(server.syncCalls, 2, reason: 'un secondo tentativo dopo il 503');
      expect(h.delays, hasLength(1));
      expect(h.delays.single, greaterThanOrEqualTo(const Duration(seconds: 2)));
    });

    test('senza Retry-After l\'attesa raddoppia a ogni tentativo', () async {
      final server = _Server()
        ..syncScript.addAll([_Reply(503), _Reply(503), _Reply(503)]);
      final h = harness(server);
      await h.login();

      expect(server.syncCalls, 3, reason: 'tre tentativi in tutto');
      // Jitter fisso a 0.5 => fattore 1.0: 1,5 s poi 3 s.
      expect(h.delays,
          [const Duration(milliseconds: 1500), const Duration(seconds: 3)]);
    });

    test('un Retry-After oltre il budget fa rinunciare subito, senza attendere',
        () async {
      final server = _Server()
        ..syncScript.add(_Reply(503, headers: const {'retry-after': '100'}));
      final h = harness(server);
      await h.login();

      expect(server.syncCalls, 1);
      expect(h.delays, isEmpty);
    });

    test(
        'il jitter resta fra -25% e +25%, e una singola attesa non supera il tetto',
        () async {
      final h = harness(_Server());
      await h.notifier.initialized;
      const error = SyncApiException('x');

      h.random.value = 0.0;
      expect(h.notifier.retryDelayFor(1, error),
          const Duration(milliseconds: 1125));
      h.random.value = 1.0;
      expect(h.notifier.retryDelayFor(1, error),
          const Duration(milliseconds: 1875));
      h.random.value = 0.5;
      expect(h.notifier.retryDelayFor(2, error), const Duration(seconds: 3));
      expect(h.notifier.retryDelayFor(10, error), const Duration(seconds: 15),
          reason: 'tetto della singola attesa');
    });

    test('un errore non transitorio (401) non viene ritentato', () async {
      final server = _Server()..syncScript.add(_Reply(401));
      final h = harness(server);
      await h.login();

      expect(server.syncCalls, 1);
      expect(h.delays, isEmpty);
    });
  });

  group('risposta 200 non decodificabile', () {
    test('resta online e distingue la risposta malformata dalla rete assente',
        () async {
      final server = _Server();
      final h = harness(server);
      expect(await h.login(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      server.syncScript.add(_Reply(200, body: '<html>non json</html>'));
      expect(await h.notifier.triggerSync(), isFalse);
      expect(h.notifier.state.isOnline, isTrue);
      expect(
        h.notifier.state.lastSyncMessage,
        contains('risposta del server non valida'),
      );
      expect(h.delays, isEmpty, reason: 'un 502 non è transitorio');
    });
  });

  group('422 invalid_id', () {
    test('ripara l\'id locale e riprova, senza perdere la nota', () async {
      final dao = NotesDao();
      await dao.upsert(_note('bad-id', 'contenuto'));

      final server = _Server()
        ..syncScript.add(_Reply(
          422,
          body: json.encode({
            'error': 'record non validi',
            'rejected': [
              {'kind': 'note', 'id': 'bad-id', 'reason': 'invalid_id'},
            ],
          }),
        ));
      final h = harness(server);

      expect(await h.login(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(server.syncCalls, 2, reason: 'primo 422 + retry riparato');
      expect(await dao.getById('bad-id'), isNull);
      final repaired = (await dao.getActive()).single;
      expect(repaired.id, isNot('bad-id'));
      expect(repaired.content, 'contenuto');
      expect(await dao.listDirty(), isEmpty);
    });
  });

  group('Y-14: capability del server', () {
    test(
        'si ricordano dall\'ultima risposta 200 e si dimenticano se spariscono',
        () async {
      final server = _Server()
        ..syncScript.add(_Reply.ok(caps: const {'proto': 2}));
      final h = harness(server);
      await h.login();

      expect(h.notifier.serverCaps, isNotNull);
      expect(h.notifier.serverCaps!.proto, 2);
      expect(h.notifier.serverCaps!.has('page'), isFalse);

      // Il giro successivo non annuncia nulla (server sostituito da uno vecchio):
      // nessuna funzione opzionale va più usata.
      server.syncScript.add(_Reply.ok());
      await h.notifier.triggerSync();
      expect(h.notifier.serverCaps, isNull);
    });

    test('prima della prima risposta non si sa nulla', () async {
      final h = harness(_Server());
      await h.notifier.initialized;
      expect(h.notifier.serverCaps, isNull);
    });
  });

  group('Y-13-A: scadenza del token', () {
    test('expires_at è in secondi: si salva in millisecondi', () async {
      final h = harness(_Server(loginExpiresAt: 4102444800));
      await h.login();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_expiryKey), 4102444800000);
    });

    test('un valore già in millisecondi non viene moltiplicato di nuovo',
        () async {
      final h = harness(_Server(loginExpiresAt: 4102444800000));
      await h.login();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_expiryKey), 4102444800000);
    });

    test('tokenExpiryMillis', () {
      expect(SyncNotifier.tokenExpiryMillis(0), isNull);
      expect(SyncNotifier.tokenExpiryMillis(-5), isNull);
      expect(SyncNotifier.tokenExpiryMillis(1767225600), 1767225600000);
      expect(SyncNotifier.tokenExpiryMillis(1767225600000), 1767225600000);
    });

    test('il logout cancella la scadenza', () async {
      final h = harness(_Server());
      await h.login();
      await h.notifier.logout();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_expiryKey), isNull);
    });

    test('token scaduto + upload grosso: nessun upload, solo la verifica',
        () async {
      final server = _Server();
      final h = harness(server);
      await h.login();
      await NotesDao().upsert(_note('grossa', 'a' * 300000));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_expiryKey, 1000); // scaduto da un pezzo
      server.settingsStatus = 401;
      final syncsBefore = server.syncCalls;

      final ok = await h.notifier.triggerSync();

      expect(ok, isFalse);
      expect(server.syncCalls, syncsBefore,
          reason: 'nessun megabyte spedito per ricevere un 401');
      final state = h.container.read(syncProvider);
      expect(state.isAuthenticated, isFalse);
      expect(state.lastSyncMessage, contains('Sessione scaduta'));
    });

    test('orologio del dispositivo sfasato: il token è valido, l\'upload parte',
        () async {
      final server = _Server();
      final h = harness(server);
      await h.login();
      await NotesDao().upsert(_note('grossa', 'a' * 300000));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_expiryKey, 1000);
      final syncsBefore = server.syncCalls;

      final ok = await h.notifier.triggerSync();

      expect(ok, isTrue);
      expect(server.syncCalls, syncsBefore + 1);
      expect(prefs.getInt(_expiryKey), isNull,
          reason: 'la scadenza non attendibile viene dimenticata');
      expect(h.container.read(syncProvider).isAuthenticated, isTrue);
    });

    test(
        'upload piccolo con token «scaduto»: nessuna verifica, si sincronizza e basta',
        () async {
      final server = _Server();
      final h = harness(server);
      await h.login();
      await NotesDao().upsert(_note('piccola', 'poche righe'));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_expiryKey, 1000);
      final syncsBefore = server.syncCalls;
      final getsBefore = server.settingsGets;

      expect(await h.notifier.triggerSync(), isTrue);
      expect(server.syncCalls, syncsBefore + 1);
      expect(server.settingsGets, getsBefore);
    });

    test('un 401 sulle impostazioni dà un messaggio chiaro', () async {
      final server = _Server();
      final h = harness(server);
      await h.login();
      server.settingsStatus = 401;

      await h.notifier.fetchRemoteUserSettings();

      final state = h.container.read(syncProvider);
      expect(state.isAuthenticated, isFalse);
      expect(state.lastSyncMessage, contains('Sessione scaduta'));
      expect(state.lastError, isNotNull);
    });
  });
}
