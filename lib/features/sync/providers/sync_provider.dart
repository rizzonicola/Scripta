import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/database/folders_dao.dart';
import '../../../core/database/notes_dao.dart';
import '../../../core/database/sync_meta_dao.dart';
import '../../../core/services/secure_storage_service.dart';
import '../../../core/services/sync_api_service.dart';
import '../../folders/providers/folder_provider.dart';
import '../../notes/providers/notes_provider.dart';
import '../../settings/providers/settings_provider.dart';
import '../models/sync_config.dart';
import '../models/sync_models.dart';

final secureStorageProvider = Provider<SecureStorageService>((ref) {
  return const SecureStorageService();
});

final syncApiServiceProvider = Provider<SyncApiService>((ref) {
  return SyncApiService();
});

/// Motore di sincronizzazione Local-First: Delta Sync Push/Pull con
/// risoluzione dei conflitti Last-Write-Wins, speculare 1:1 al protocollo
/// implementato da `SyncHandler.Sync` nel backend Go.
///
/// A differenza della generazione precedente, qui NON esiste alcuna nozione
/// di percorso: non c'è `_resolveRelativePath`, non c'è
/// `_collectAllFolderPaths`, non c'è `pendingOldRelativePath`, non c'è un
/// meccanismo di tombstone separato basato sul nome file. Tutto ruota
/// attorno a un singolo cursore intero (`last_synced_at`, salvato in
/// [SyncMetaDao]) e a due query dirette sul database locale ("dammi tutto
/// ciò che ho modificato dopo il cursore"), esattamente come fa il server
/// con la propria colonna `updated_at`.
class SyncNotifier extends StateNotifier<SyncConfig> {
  static const _prefLaunchSync = 'scripta_sync_on_launch';
  static const _prefLifecycleSync = 'scripta_sync_on_lifecycle';
  static const _prefNoteSwitchSync = 'scripta_sync_on_note_switch';
  static const _prefInactivitySync = 'scripta_sync_on_inactivity';
  static const _prefInactivitySeconds = 'scripta_sync_inactivity_seconds';
  static const _prefLastSyncTime = 'scripta_last_sync_timestamp';

  /// Number of sequential attempts made before a connection/network failure
  /// is considered final and the status indicator flips to Offline.
  static const int _maxRetryAttempts = 3;

  /// Delay between retry attempts.
  static const Duration _retryDelay = Duration(milliseconds: 1500);

  /// Interval for the background connectivity watchdog that keeps the
  /// online/offline indicator accurate even when no sync is otherwise
  /// triggered (e.g. the user isn't editing notes).
  static const Duration _connectivityPollInterval = Duration(seconds: 25);

  final Ref _ref;
  final SyncApiService _apiService;
  final SecureStorageService _secureStorage;
  final FoldersDao _foldersDao;
  final NotesDao _notesDao;
  final SyncMetaDao _syncMetaDao;
  Timer? _inactivityTimer;
  Timer? _noteSwitchDebounceTimer;
  Timer? _folderStructureDebounceTimer;
  Timer? _connectivityTimer;
  late final Future<void> initialized;

  SyncNotifier(
    this._ref,
    this._apiService,
    this._secureStorage, {
    FoldersDao? foldersDao,
    NotesDao? notesDao,
    SyncMetaDao? syncMetaDao,
  })  : _foldersDao = foldersDao ?? FoldersDao(),
        _notesDao = notesDao ?? NotesDao(),
        _syncMetaDao = syncMetaDao ?? SyncMetaDao(),
        super(const SyncConfig()) {
    initialized = _init();
  }

  @override
  void dispose() {
    _inactivityTimer?.cancel();
    _noteSwitchDebounceTimer?.cancel();
    _folderStructureDebounceTimer?.cancel();
    _connectivityTimer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();

    final launchSync = prefs.getBool(_prefLaunchSync) ?? true;
    final lifecycleSync = prefs.getBool(_prefLifecycleSync) ?? true;
    final noteSwitchSync = prefs.getBool(_prefNoteSwitchSync) ?? true;
    final inactivitySync = prefs.getBool(_prefInactivitySync) ?? false;
    final inactivitySeconds = prefs.getInt(_prefInactivitySeconds) ?? 30;

    final lastSyncMillis = prefs.getInt(_prefLastSyncTime);
    final lastSyncTime =
        lastSyncMillis != null ? DateTime.fromMillisecondsSinceEpoch(lastSyncMillis) : null;

    final savedServerUrl = await _secureStorage.getServerUrl() ?? AppConstants.defaultServerUrl;
    final savedUsername = await _secureStorage.getUsername();
    final savedToken = await _secureStorage.getAuthToken();

    if (!mounted) return;

    final hasToken = savedToken != null && savedToken.isNotEmpty;

    state = state.copyWith(
      syncOnAppLaunch: launchSync,
      syncOnAppLifecycle: lifecycleSync,
      syncOnNoteSwitch: noteSwitchSync,
      syncOnInactivity: inactivitySync,
      inactivitySeconds: inactivitySeconds.clamp(10, 300),
      serverUrl: savedServerUrl,
      username: () => savedUsername,
      isAuthenticated: hasToken,
      lastSyncTime: () => lastSyncTime,
    );

    // Initial health check if server url is present
    if (savedServerUrl.isNotEmpty && mounted) {
      await checkConnection();
    }

    if (hasToken) {
      _startConnectivityWatchdog();
    }

    // If authenticated and launch sync enabled, trigger sync & fetch remote settings
    if (hasToken && launchSync && mounted) {
      // Defer slightly to let UI settle
      Future.delayed(const Duration(milliseconds: 500), () async {
        if (!mounted) return;
        await fetchRemoteUserSettings();
        if (!mounted) return;
        await triggerSync();
      });
    }
  }

  /// Starts (or restarts) the periodic background connectivity check that
  /// keeps the online/offline indicator reactive even without an explicit
  /// sync trigger. Safe to call multiple times; it cancels any previous
  /// timer first to avoid leaking duplicate periodic timers.
  void _startConnectivityWatchdog() {
    _connectivityTimer?.cancel();
    _connectivityTimer = Timer.periodic(_connectivityPollInterval, (_) {
      if (!mounted || state.isSyncing) return;
      if (!state.isAuthenticated) {
        _connectivityTimer?.cancel();
        return;
      }
      checkConnection();
    });
  }

  void _stopConnectivityWatchdog() {
    _connectivityTimer?.cancel();
    _connectivityTimer = null;
  }

  /// True when the error represents a connectivity/timeout problem (as
  /// opposed to an authenticated/HTTP-level error), and therefore eligible
  /// for the automatic retry mechanism.
  bool _isTransientNetworkError(Object error) {
    if (error is SyncApiException) {
      // A SyncApiException with no status code means the request never
      // reached / completed against the server in a way that produced an
      // HTTP response (e.g. wrapped timeout), so treat it as transient.
      // A 503 (server temporaneamente occupato, vedi SyncHandler lato
      // backend) è transitorio per definizione: vale la pena ritentare.
      return error.statusCode == null || error.statusCode == 503;
    }
    // Anything else (SocketException, TimeoutException, http.ClientException,
    // etc.) reaching this point means the request itself failed at the
    // transport level.
    return true;
  }

  /// Runs [action] with up to [_maxRetryAttempts] sequential attempts,
  /// waiting [_retryDelay] between tries. Only retries transient
  /// connection/timeout style failures; anything else (e.g. a 401) is
  /// rethrown immediately without retry.
  Future<T> _withNetworkRetry<T>(Future<T> Function() action) async {
    Object lastError = const SyncApiException('Errore di connessione sconosciuto');

    for (int attempt = 1; attempt <= _maxRetryAttempts; attempt++) {
      try {
        return await action();
      } catch (e) {
        lastError = e;
        final isLastAttempt = attempt == _maxRetryAttempts;
        if (!_isTransientNetworkError(e) || isLastAttempt) {
          rethrow;
        }
        await Future.delayed(_retryDelay);
      }
    }

    // Unreachable in practice (loop either returns or rethrows), but keeps
    // the analyzer happy about a guaranteed return/throw.
    throw lastError;
  }

  /// Pings the server health endpoint, retrying up to [_maxRetryAttempts]
  /// times (with a short delay in between) before concluding the server is
  /// genuinely unreachable. Updates [SyncConfig.isOnline] reactively so the
  /// status indicator in the UI reflects the real connection state
  /// immediately, without requiring an app restart.
  Future<bool> checkConnection() async {
    bool isOnline = false;

    for (int attempt = 1; attempt <= _maxRetryAttempts; attempt++) {
      isOnline = await _apiService.checkHealth(state.serverUrl);
      if (isOnline) break;
      if (attempt < _maxRetryAttempts) {
        await Future.delayed(_retryDelay);
      }
    }

    if (!mounted) return isOnline;
    state = state.copyWith(isOnline: isOnline);
    return isOnline;
  }

  Future<bool> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    state = state.copyWith(
      isSyncing: true,
      lastError: () => null,
      serverUrl: serverUrl,
    );

    try {
      final response = await _withNetworkRetry(
        () => _apiService.login(
          baseUrl: serverUrl,
          username: username,
          password: password,
        ),
      );

      await _secureStorage.saveAuthToken(response.token);
      await _secureStorage.saveServerUrl(serverUrl);
      await _secureStorage.saveUsername(response.username);
      await _secureStorage.saveUserId(response.userId);

      state = state.copyWith(
        isAuthenticated: true,
        isOnline: true,
        username: () => response.username,
        isSyncing: false,
        lastError: () => null,
      );

      _startConnectivityWatchdog();

      // Fetch remote settings & run initial sync
      await fetchRemoteUserSettings();
      await triggerSync();

      return true;
    } catch (e) {
      state = state.copyWith(
        isAuthenticated: false,
        isOnline: false,
        isSyncing: false,
        lastError: () => e is SyncApiException ? e.message : e.toString(),
      );
      return false;
    }
  }

  Future<void> logout() async {
    _inactivityTimer?.cancel();
    _noteSwitchDebounceTimer?.cancel();
    _folderStructureDebounceTimer?.cancel();
    _stopConnectivityWatchdog();
    await _secureStorage.clearAuth();
    state = state.copyWith(
      isAuthenticated: false,
      username: () => null,
      lastSyncMessage: () => null,
      lastError: () => null,
    );
  }

  Future<void> setSyncOnAppLaunch(bool value) async {
    state = state.copyWith(syncOnAppLaunch: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefLaunchSync, value);
  }

  Future<void> setSyncOnAppLifecycle(bool value) async {
    state = state.copyWith(syncOnAppLifecycle: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefLifecycleSync, value);
  }

  Future<void> setSyncOnNoteSwitch(bool value) async {
    state = state.copyWith(syncOnNoteSwitch: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefNoteSwitchSync, value);
    // Immediately cancel any debounce timer already in flight so a disabled
    // toggle can't still trigger a sync moments later.
    if (!value) {
      _noteSwitchDebounceTimer?.cancel();
    }
  }

  Future<void> setSyncOnInactivity(bool value) async {
    state = state.copyWith(syncOnInactivity: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefInactivitySync, value);
    if (!value) {
      _inactivityTimer?.cancel();
    }
  }

  Future<void> setInactivitySeconds(int seconds) async {
    final clamped = seconds.clamp(10, 300);
    state = state.copyWith(inactivitySeconds: clamped);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefInactivitySeconds, clamped);
  }

  /// Called whenever note contents change to reset inactivity debounce timer
  void notifyEditorActivity() {
    if (!state.isAuthenticated || !state.syncOnInactivity) return;

    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(
      Duration(seconds: state.inactivitySeconds),
      () {
        // Re-check the toggle at execution time too: it may have been
        // disabled after the timer was scheduled but before it fired.
        if (mounted && !state.isSyncing && state.syncOnInactivity) {
          triggerSync();
        }
      },
    );
  }

  /// Hook for note change / editor close (debounced by 600ms to avoid bursts during rapid navigation)
  void onNoteChangedOrClosed() {
    if (!state.isAuthenticated || !state.syncOnNoteSwitch) return;

    _noteSwitchDebounceTimer?.cancel();
    _noteSwitchDebounceTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted && !state.isSyncing && state.syncOnNoteSwitch) {
        triggerSync();
      }
    });
  }

  /// Hook for folder structure changes (new folder, move, rename, delete) so
  /// they reach the backend promptly without waiting for an unrelated note
  /// edit to trigger a sync. Chiamato internamente da [FolderNotifier] dopo
  /// OGNI mutazione strutturale (inclusa la cancellazione, che nella
  /// generazione precedente non lo invocava affatto).
  void onFolderStructureChanged() {
    if (!state.isAuthenticated) return;

    _folderStructureDebounceTimer?.cancel();
    _folderStructureDebounceTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted && !state.isSyncing) {
        triggerSync();
      }
    });
  }

  /// Hook for app lifecycle (pause / exit)
  void onAppPaused() {
    if (state.isAuthenticated && state.syncOnAppLifecycle && !state.isSyncing) {
      triggerSync();
    }
  }

  /// Hook for app resuming to the foreground: re-validates connectivity
  /// immediately so the status indicator doesn't show stale information
  /// after the device was asleep, on a different network, etc.
  void onAppResumed() {
    if (state.isAuthenticated && !state.isSyncing) {
      checkConnection();
    }
  }

  FolderChangeDto _toFolderDto(FolderRow r) => FolderChangeDto(
        id: r.id,
        name: r.name,
        parentId: r.parentId,
        updatedAt: r.updatedAt,
        deletedAt: r.deletedAt,
      );

  NoteChangeDto _toNoteDto(NoteRow r) => NoteChangeDto(
        id: r.id,
        title: r.title,
        content: r.content,
        folderId: r.folderId,
        updatedAt: r.updatedAt,
        deletedAt: r.deletedAt,
      );

  FolderRow _fromFolderDto(FolderChangeDto d) => FolderRow(
        id: d.id,
        name: d.name,
        parentId: d.parentId,
        isExpanded: true, // valore di default: applyRemoteLWW preserva quello locale se già presente
        updatedAt: d.updatedAt,
        deletedAt: d.deletedAt,
      );

  NoteRow _fromNoteDto(NoteChangeDto d) => NoteRow(
        id: d.id,
        title: d.title,
        content: d.content,
        folderId: d.folderId,
        isFavorite: false,
        isPinned: false,
        orderIndex: 0,
        createdAt: d.updatedAt, // valore di fallback: applyRemoteLWW preserva quello locale se già presente
        updatedAt: d.updatedAt,
        deletedAt: d.deletedAt,
      );

  /// Sincronizza cartelle e note bidirezionalmente con il server
  /// (Last-Write-Wins), interamente ID-based.
  ///
  /// Protocollo (speculare a SyncHandler.Sync nel backend):
  ///  1. Legge dal DB locale tutte le cartelle/note con `updated_at` >
  ///     cursore locale ([SyncMetaDao]) — è l'intero "da inviare", senza
  ///     bisogno di alcuna coda/outbox separata.
  ///  2. Le invia al server in un'unica richiesta POST /api/v1/sync insieme
  ///     al cursore stesso.
  ///  3. Applica localmente (con la stessa logica LWW) tutte le entità che
  ///     il server restituisce nella risposta: sono sia le modifiche remote
  ///     di altri dispositivi sia l'esito (accettato o "server wins") di
  ///     quanto appena inviato.
  ///  4. Salva `server_time` come nuovo cursore.
  Future<bool> triggerSync({bool force = false}) async {
    if (!state.isAuthenticated || state.isSyncing) return false;

    // Flush di eventuali modifiche testo ancora in debounce, così anche
    // l'ultima battitura rientra in questo giro di sync.
    //
    // CRITICO: questo `await` è OBBLIGATORIO, MA da solo non basta più a
    // garantire la correttezza. La vera causa radice del bug (pulsante
    // manuale, avvio app, inattività e lifecycle che non inviavano mai i
    // dati pur mostrando "successo") era in NotesNotifier.flushPendingSaves:
    // scriveva `activeNote` (derivato da `state.activeNoteId`, uno stato
    // mutabile su cui questo provider non ha alcun controllo) invece della
    // nota che aveva DAVVERO una modifica in sospeso. È stata corretta lì
    // (vedi il commento su `NotesNotifier._pendingNote`): ora
    // `flushPendingSaves()` scrive sempre la modifica realmente pendente,
    // indipendentemente da chi lo chiama e da cosa sia `activeNoteId` in
    // questo istante.
    await _ref.read(notesProvider.notifier).flushPendingSaves();

    final cursor = await _syncMetaDao.getSyncCursor();
    final dirtyFolders = await _foldersDao.listDirtySince(cursor);
    final dirtyNotes = await _notesDao.listDirtySince(cursor);

    // NOTA: qui esisteva un "fast-path" che, quando dirtyFolders/dirtyNotes
    // risultavano vuoti, si limitava a un checkConnection() e restituiva
    // `true` ("successo") SENZA MAI contattare l'endpoint di sync. Finché
    // il flush sopra poteva mancare la modifica realmente pendente (vedi
    // causa radice), questo fast-path trasformava quel bug silenzioso in un
    // falso "Sincronizzazione avvenuta con successo" mostrato in UI, pur
    // non avendo mai inviato nulla al server: esattamente il sintomo
    // riportato sul pulsante manuale. Va rimosso: un trigger di sync deve
    // sempre tradursi in una vera richiesta al server (anche con liste
    // vuote, per effettuare comunque il pull di eventuali modifiche remote
    // da altri dispositivi) quando l'utente è autenticato, mai in un
    // "successo" dedotto solo dalla connettività. `force` resta nella firma
    // per compatibilità, ma non serve più per garantire un giro reale.
    final token = await _secureStorage.getAuthToken();
    if (token == null || token.isEmpty) {
      state = state.copyWith(isAuthenticated: false);
      return false;
    }

    state = state.copyWith(
      isSyncing: true,
      lastError: () => null,
      lastSyncMessage: () => 'Sincronizzazione in corso...',
    );

    try {
      final response = await _withNetworkRetry(
        () => _apiService.sync(
          baseUrl: state.serverUrl,
          token: token,
          lastSyncedAt: cursor,
          folders: dirtyFolders.map(_toFolderDto).toList(),
          notes: dirtyNotes.map(_toNoteDto).toList(),
        ),
      );

      // Applica le entità restituite dal server (già risolte LWW lato
      // server) al database locale, con LWW anche qui come difesa in
      // profondità contro modifiche fatte durante il round-trip di rete.
      for (final f in response.folders) {
        await _foldersDao.applyRemoteLWW(_fromFolderDto(f));
      }
      for (final n in response.notes) {
        await _notesDao.applyRemoteLWW(_fromNoteDto(n));
      }

      // Purge locale dei tombstone appena confermati dal server: una volta
      // che il server li ha ricevuti, non serve più tenerli anche
      // localmente (gli altri dispositivi li riceveranno dal server stesso
      // alla propria prossima pull).
      final pushedDeletedFolderIds =
          dirtyFolders.where((f) => f.deletedAt != null).map((f) => f.id).toList();
      final pushedDeletedNoteIds =
          dirtyNotes.where((n) => n.deletedAt != null).map((n) => n.id).toList();
      if (pushedDeletedFolderIds.isNotEmpty) {
        await _foldersDao.hardDeleteIds(pushedDeletedFolderIds);
      }
      if (pushedDeletedNoteIds.isNotEmpty) {
        await _notesDao.hardDeleteIds(pushedDeletedNoteIds);
      }

      await _syncMetaDao.setSyncCursor(response.serverTime);

      // Rilegge lo stato in memoria dai DAO: la UI resta reattiva
      // esclusivamente al database locale, mai a questa risposta HTTP
      // direttamente.
      await _ref.read(folderProvider.notifier).refreshFromDb();
      await _ref.read(notesProvider.notifier).refreshFromDb();

      final syncedAt = DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefLastSyncTime, syncedAt.millisecondsSinceEpoch);

      state = state.copyWith(
        isOnline: true,
        isSyncing: false,
        lastSyncTime: () => syncedAt,
        lastSyncMessage: () =>
            'Sincronizzato (${dirtyFolders.length + dirtyNotes.length} inviate, ${response.folders.length + response.notes.length} ricevute)',
        lastError: () => null,
      );

      return true;
    } catch (e) {
      final isAuthError = e is SyncApiException && e.statusCode == 401;
      state = state.copyWith(
        isAuthenticated: isAuthError ? false : state.isAuthenticated,
        isOnline: isAuthError ? state.isOnline : false,
        isSyncing: false,
        lastError: () => e is SyncApiException ? e.message : e.toString(),
        lastSyncMessage: () =>
            isAuthError ? 'Sessione scaduta: effettua nuovamente l\'accesso' : 'Sincronizzazione non riuscita: server non raggiungibile',
      );
      if (isAuthError) {
        await _secureStorage.clearAuth();
        _stopConnectivityWatchdog();
      }
      return false;
    }
  }

  /// Downloads remote user preferences and applies them locally
  Future<void> fetchRemoteUserSettings() async {
    if (!state.isAuthenticated) return;
    final token = await _secureStorage.getAuthToken();
    if (token == null) return;

    try {
      final remoteSettings = await _withNetworkRetry(
        () => _apiService.getUserSettings(
          baseUrl: state.serverUrl,
          token: token,
        ),
      );
      _ref.read(settingsProvider.notifier).applyRemoteSettings(remoteSettings);
    } catch (e) {
      if (e is SyncApiException && e.statusCode == 401) {
        state = state.copyWith(isAuthenticated: false);
        await _secureStorage.clearAuth();
        _stopConnectivityWatchdog();
      } else {
        state = state.copyWith(isOnline: false);
      }
    }
  }

  /// Sends updated preferences to PUT /api/v1/user/settings
  Future<void> pushUserSettings(UserSettingsDto settings) async {
    if (!state.isAuthenticated) return;
    final token = await _secureStorage.getAuthToken();
    if (token == null) return;

    try {
      await _withNetworkRetry(
        () => _apiService.updateUserSettings(
          baseUrl: state.serverUrl,
          token: token,
          settings: settings,
        ),
      );
    } catch (e) {
      if (e is SyncApiException && e.statusCode == 401) {
        state = state.copyWith(isAuthenticated: false);
        await _secureStorage.clearAuth();
        _stopConnectivityWatchdog();
      } else {
        state = state.copyWith(isOnline: false);
      }
    }
  }
}

final syncProvider = StateNotifierProvider<SyncNotifier, SyncConfig>((ref) {
  final apiService = ref.watch(syncApiServiceProvider);
  final secureStorage = ref.watch(secureStorageProvider);
  return SyncNotifier(ref, apiService, secureStorage);
});
