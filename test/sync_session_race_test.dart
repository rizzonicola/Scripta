// Cambio account con richieste ancora in volo: una risposta della sessione
// precedente non deve aggiornare le impostazioni né chiudere la sessione nuova
// con un 401 ormai vecchio.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/database/app_database.dart';
import 'package:scripta/core/database/folders_dao.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:scripta/core/database/sync_meta_dao.dart';
import 'package:scripta/core/services/secure_storage_service.dart';
import 'package:scripta/core/services/sync_api_service.dart';
import 'package:scripta/features/settings/providers/settings_provider.dart';
import 'package:scripta/features/sync/models/sync_models.dart';
import 'package:scripta/features/sync/providers/sync_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  Future<void> clearAuth() async => _memory.clear();
}

class _RaceServer {
  int settingsGets = 0;
  int settingsPuts = 0;
  int blockSettingsCall = -1;
  int blockPutCall = -1;
  Completer<void>? settingsGate;
  Completer<void>? putGate;

  late final http.Client client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    const json200 = {'content-type': 'application/json'};
    final path = request.url.path;

    if (path == '/api/v1/auth/login') {
      final body = json.decode(request.body) as Map<String, dynamic>;
      final username = body['username'] as String;
      return http.Response(
        json.encode({
          'token': 'token-$username',
          'expires_at': 4102444800,
          'user_id': 'uid-$username',
          'username': username,
        }),
        200,
        headers: json200,
      );
    }
    if (path == '/api/v1/auth/logout') {
      return http.Response('', 200);
    }
    if (path == '/api/v1/user/settings') {
      if (request.method == 'PUT') {
        settingsPuts++;
        if (settingsPuts == blockPutCall) {
          putGate = Completer<void>();
          await putGate!.future;
          return http.Response(json.encode({'error': 'token non valido'}), 401,
              headers: json200);
        }
        return http.Response(request.body, 200, headers: json200);
      }

      settingsGets++;
      final call = settingsGets;
      if (call == blockSettingsCall) {
        settingsGate = Completer<void>();
        await settingsGate!.future;
      }
      final token = request.headers['authorization'];
      final light = token == 'Bearer token-B';
      return http.Response(
        json.encode({
          'theme': light ? 'light' : 'dark',
          'color_scheme': light ? 'clean_light' : 'dark_teal',
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
      return http.Response(
        json.encode({
          'server_time': 1000,
          'full_resync': false,
          'folders': <Object>[],
          'notes': <Object>[],
        }),
        200,
        headers: json200,
      );
    }
    return http.Response('not found', 404);
  }
}

class _Harness {
  _Harness(this.server) {
    container = ProviderContainer(
      overrides: [
        syncProvider.overrideWith(
          (ref) => SyncNotifier(
            ref,
            SyncApiService(server.client),
            _MemorySecureStorage(),
            retryWait: (d) async {},
          ),
        ),
      ],
    );
    notifier = container.read(syncProvider.notifier);
  }

  final _RaceServer server;
  late final ProviderContainer container;
  late final SyncNotifier notifier;

  Future<bool> login(String username) async {
    await notifier.initialized;
    // Materializza il notifier e lascia finire il caricamento iniziale da
    // SharedPreferences prima che arrivi applyRemoteSettings.
    container.read(settingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final ok = await notifier.login(
      serverUrl: 'http://localhost:8080',
      username: username,
      password: 'password',
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return ok;
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condizione non raggiunta');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
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
      'scripta_race_${DateTime.now().microsecondsSinceEpoch}.db',
    );
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = null;
  });

  test('una risposta impostazioni della sessione A non sovrascrive B',
      () async {
    final server = _RaceServer();
    final h = _Harness(server);
    addTearDown(h.container.dispose);

    expect(await h.login('A'), isTrue);
    await _waitUntil(
      () => h.container.read(settingsProvider).themeMode == ThemeMode.dark,
    );

    // La prossima GET resta bloccata: è la richiesta della sessione A.
    server.blockSettingsCall = server.settingsGets + 1;
    final pending = h.notifier.fetchRemoteUserSettings();
    await _waitUntil(() => server.settingsGets == server.blockSettingsCall);
    await _waitUntil(() => server.settingsGate != null);

    await h.notifier.logout();
    expect(await h.login('B'), isTrue);
    await _waitUntil(
      () => h.container.read(settingsProvider).themeMode == ThemeMode.light,
    );

    server.settingsGate!.complete();
    await pending;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(h.container.read(settingsProvider).themeMode, ThemeMode.light,
        reason: 'la risposta dark di A è arrivata dopo il login di B');
    expect(h.container.read(syncProvider).isAuthenticated, isTrue);
    expect(h.container.read(syncProvider).username, 'B');
  });

  test('un 401 impostazioni della sessione A non chiude la sessione B',
      () async {
    final server = _RaceServer();
    final h = _Harness(server);
    addTearDown(h.container.dispose);

    expect(await h.login('A'), isTrue);

    server.blockPutCall = server.settingsPuts + 1;
    final pending = h.notifier.pushUserSettings(
      const UserSettingsDto(
          theme: 'dark', colorScheme: 'dark_teal', language: 'it'),
    );
    await _waitUntil(() => server.settingsPuts == server.blockPutCall);
    await _waitUntil(() => server.putGate != null);

    await h.notifier.logout();
    expect(await h.login('B'), isTrue);

    server.putGate!.complete();
    await pending;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = h.container.read(syncProvider);
    expect(state.isAuthenticated, isTrue, reason: 'il 401 di A è vecchio');
    expect(state.username, 'B');
  });

  test(
      'cambiare account cancella note, cartelle e cursore della sessione precedente',
      () async {
    final server = _RaceServer();
    final h = _Harness(server);
    addTearDown(h.container.dispose);

    expect(await h.login('A'), isTrue);

    final notesDao = NotesDao();
    final foldersDao = FoldersDao();
    final metaDao = SyncMetaDao();
    await notesDao.upsert(const NoteRow(
      id: 'nota-di-A',
      title: 'Riservata',
      content: 'contenuto A',
      folderId: null,
      isFavorite: false,
      isPinned: false,
      orderIndex: 0,
      createdAt: 1,
      updatedAt: 1,
      deletedAt: null,
    ));
    await foldersDao.upsert(const FolderRow(
      id: 'cartella-di-A',
      name: 'Lavoro A',
      parentId: null,
      isExpanded: true,
      updatedAt: 1,
      deletedAt: null,
    ));
    await metaDao.setSyncCursor(123);
    await metaDao.setAccountIdentity('http://localhost:8080|uid-A');

    await h.notifier.logout();
    expect(await h.login('B'), isTrue);

    expect(await notesDao.getById('nota-di-A'), isNull);
    expect(await foldersDao.getById('cartella-di-A'), isNull);
    // Il cursore viene azzerato dal reset e poi riallineato dalla sync
    // iniziale di B: qui conta che non sia rimasto quello di A.
    expect(await metaDao.getSyncCursor(), isNot(123));
    expect(await metaDao.getAccountIdentity(), 'http://localhost:8080|uid-B');
    expect(h.container.read(syncProvider).username, 'B');
  });
}
