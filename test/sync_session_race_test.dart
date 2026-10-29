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
import 'package:scripta/features/notes/providers/notes_provider.dart';
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

class _BlockingNotesDao extends NotesDao {
  bool block = true;
  Completer<void>? entered;
  Completer<void>? releaseGate;

  void blockNextMarkSynced() {
    entered = Completer<void>();
    releaseGate = Completer<void>();
  }

  void release() {
    block = false;
    releaseGate?.complete();
  }

  @override
  Future<void> markSynced(Map<String, int> idToPushedUpdatedAt) async {
    if (block && releaseGate != null) {
      entered?.complete();
      await releaseGate!.future;
    }
    await super.markSynced(idToPushedUpdatedAt);
  }
}

class _RaceServer {
  int loginCalls = 0;
  int syncCalls = 0;
  int settingsGets = 0;
  int settingsPuts = 0;
  int blockSettingsCall = -1;
  int blockPutCall = -1;
  int blockSyncCall = -1;
  Completer<void>? settingsGate;
  Completer<void>? putGate;
  Completer<void>? syncGate;
  List<Map<String, dynamic>> firstSyncNotes = const [];

  late final http.Client client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    const json200 = {'content-type': 'application/json'};
    final path = request.url.path;

    if (path == '/api/v1/auth/login') {
      loginCalls++;
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
          return http.Response(
            json.encode({'error': 'token non valido'}),
            401,
            headers: json200,
          );
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
      syncCalls++;
      final call = syncCalls;
      if (call == blockSyncCall) {
        syncGate = Completer<void>();
        await syncGate!.future;
      }
      return http.Response(
        json.encode({
          'server_time': 1000,
          'full_resync': false,
          'folders': <Object>[],
          'notes': call == 1 ? firstSyncNotes : <Object>[],
        }),
        200,
        headers: json200,
      );
    }
    return http.Response('not found', 404);
  }
}

class _Harness {
  _Harness(this.server, {NotesDao? notesDao}) {
    container = ProviderContainer(
      overrides: [
        syncProvider.overrideWith(
          (ref) => SyncNotifier(
            ref,
            SyncApiService(server.client),
            _MemorySecureStorage(),
            notesDao: notesDao,
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

Future<void> _waitUntil(
  bool Function() predicate, {
  String reason = 'condizione non raggiunta',
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason);
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

  test(
    'una risposta impostazioni della sessione A non sovrascrive B',
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

      expect(
        h.container.read(settingsProvider).themeMode,
        ThemeMode.light,
        reason: 'la risposta dark di A è arrivata dopo il login di B',
      );
      expect(h.container.read(syncProvider).isAuthenticated, isTrue);
      expect(h.container.read(syncProvider).username, 'B');
    },
  );

  test(
    'un 401 impostazioni della sessione A non chiude la sessione B',
    () async {
      final server = _RaceServer();
      final h = _Harness(server);
      addTearDown(h.container.dispose);

      expect(await h.login('A'), isTrue);

      server.blockPutCall = server.settingsPuts + 1;
      final pending = h.notifier.pushUserSettings(
        const UserSettingsDto(
          theme: 'dark',
          colorScheme: 'dark_teal',
          language: 'it',
        ),
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
    },
  );

  test('un push impostazioni di A non viene riaccodato per B', () async {
    final server = _RaceServer();
    final h = _Harness(server);
    addTearDown(h.container.dispose);

    expect(await h.login('A'), isTrue);
    final settings = h.container.read(settingsProvider.notifier);

    server.blockPutCall = server.settingsPuts + 1;
    await settings.setThemeMode(ThemeMode.dark);
    settings.flushRemotePush();
    await _waitUntil(() => server.settingsPuts == server.blockPutCall);
    await _waitUntil(() => server.putGate != null);

    await h.notifier.logout();
    expect(await h.login('B'), isTrue);
    server.putGate!.complete();
    await _waitUntil(() => !settings.hasPendingRemotePush);

    expect(
      server.settingsPuts,
      server.blockPutCall,
      reason: 'la PUT di A non deve essere ritentata come B',
    );
    expect(settings.hasPendingRemotePush, isFalse);
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
      await notesDao.upsert(
        const NoteRow(
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
        ),
      );
      await foldersDao.upsert(
        const FolderRow(
          id: 'cartella-di-A',
          name: 'Lavoro A',
          parentId: null,
          isExpanded: true,
          updatedAt: 1,
          deletedAt: null,
        ),
      );
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
    },
  );

  test(
    'il logout conserva le note e il login dello stesso account non le cancella',
    () async {
      final server = _RaceServer();
      final h = _Harness(server);
      addTearDown(h.container.dispose);

      expect(await h.login('A'), isTrue);

      final notesDao = NotesDao();
      const note = NoteRow(
        id: 'nota-locale',
        title: 'Nota locale',
        content: 'deve restare dopo il logout',
        folderId: null,
        isFavorite: false,
        isPinned: false,
        orderIndex: 0,
        createdAt: 1,
        updatedAt: 1,
        deletedAt: null,
      );
      await notesDao.upsert(note);
      final notes = h.container.read(notesProvider.notifier);
      await notes.refreshFromDb();
      expect(
        h.container.read(notesProvider).notes.any((n) => n.id == note.id),
        isTrue,
      );

      await h.notifier.logout();

      expect(
        await notesDao.getById(note.id),
        isNotNull,
        reason: 'il logout non deve cancellare i dati locali',
      );
      expect(
        h.container.read(notesProvider).notes.any((n) => n.id == note.id),
        isTrue,
        reason: 'la nota deve restare visibile anche da disconnessi',
      );

      expect(await h.login('A'), isTrue);

      expect(
        await notesDao.getById(note.id),
        isNotNull,
        reason: 'lo stesso account ritrova le proprie note',
      );
      expect(
        h.container.read(notesProvider).notes.any((n) => n.id == note.id),
        isTrue,
      );
    },
  );

  test(
    'una risposta sync di A non viene applicata dopo il login di B',
    () async {
      final server = _RaceServer()
        ..blockSyncCall = 1
        ..firstSyncNotes = [
          {
            'id': 'nota-remota-A',
            'title': 'Remota A',
            'content': 'non deve apparire in B',
            'folder_id': null,
            'is_favorite': false,
            'is_pinned': false,
            'order_index': 0,
            'updated_at': 1,
            'deleted_at': null,
          },
        ];
      final notesDao = _BlockingNotesDao()..blockNextMarkSynced();
      final h = _Harness(server, notesDao: notesDao);
      addTearDown(h.container.dispose);

      // La prima sync di A resta bloccata dopo la risposta HTTP, dentro
      // markSynced: è la finestra in cui il vecchio codice applicava la
      // risposta anche se nel frattempo era partito il login di B.
      final loginA = h.login('A');
      await _waitUntil(
        () => server.syncGate != null,
        reason: 'sync A non partita',
      );
      server.syncGate!.complete();
      await _waitUntil(
        () => notesDao.entered?.isCompleted ?? false,
        reason: 'markSynced A non bloccato',
      );

      final logout = h.notifier.logout();
      final loginB = h.login('B');
      await _waitUntil(
        () => server.loginCalls >= 2,
        reason: 'login B non partito',
      );
      notesDao.release();

      await Future.wait([loginA, logout, loginB]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        await notesDao.getById('nota-remota-A'),
        isNull,
        reason: 'la risposta della sessione A non deve finire nel DB di B',
      );
      expect(h.container.read(syncProvider).isAuthenticated, isTrue);
      expect(h.container.read(syncProvider).username, 'B');
    },
  );
}
