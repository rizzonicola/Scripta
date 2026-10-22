import 'dart:async';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3: StateNotifier/StateNotifierProvider sono "legacy" (spostati in
// questo import separato, non rimossi). SyncNotifier resta deliberatamente
// una StateNotifier: implementa il protocollo di sync (payload, endpoint,
// retry, risoluzione LWW) 1:1 speculare al backend Go — la logica NON viene
// toccata in questa modernizzazione, solo l'import necessario a compilare.
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show DatabaseException;
import '../../../core/database/folders_dao.dart';
import '../../../core/database/notes_dao.dart';
import '../../../core/database/sync_meta_dao.dart';
import '../../../core/services/secure_storage_service.dart';
import '../../../core/services/sync_api_service.dart';
import '../../../core/utils/perf_marks.dart';
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

/// Istantanea di "quanto è già riuscito" per la regola sull'indicatore
/// Online/Offline: vedi [SyncNotifier._reachabilityMark].
typedef _ReachabilityMark = ({int successes, DateTime? lastSync});

/// Motore di sincronizzazione Local-First: Delta Sync Push/Pull con
/// risoluzione dei conflitti Last-Write-Wins, speculare 1:1 al protocollo
/// implementato da `SyncHandler.Sync` nel backend Go.
///
/// A differenza della generazione precedente, qui NON esiste alcuna nozione
/// di percorso: non c'è `_resolveRelativePath`, non c'è
/// `_collectAllFolderPaths`, non c'è `pendingOldRelativePath`, non c'è un
/// meccanismo di tombstone separato basato sul nome file. Tutto ruota
/// attorno a un cursore intero (`last_synced_at`, stamp del SERVER salvato in
/// [SyncMetaDao], usato solo per la pull) e al flag locale `dirty` (cosa
/// inviare). `updated_at` (orologio del client) serve solo alla risoluzione LWW.
class SyncNotifier extends StateNotifier<SyncConfig> {
  static const _prefLaunchSync = 'scripta_sync_on_launch';
  static const _prefLifecycleSync = 'scripta_sync_on_lifecycle';
  static const _prefNoteSwitchSync = 'scripta_sync_on_note_switch';
  static const _prefInactivitySync = 'scripta_sync_on_inactivity';
  static const _prefInactivitySeconds = 'scripta_sync_inactivity_seconds';
  static const _prefLastSyncTime = 'scripta_last_sync_timestamp';

  /// Scadenza del token (millisecondi Unix), calcolata dall'`expires_at` della
  /// login (Y-13-A). Non è un segreto: sta fra le preferenze.
  static const _prefTokenExpiresAt = 'scripta_token_expires_at_ms';

  /// Margine con cui un token si considera «in scadenza» rispetto all'orologio
  /// locale.
  static const int _tokenExpirySkewMs = 60 * 1000;

  /// Da questa quantità di testo da inviare (caratteri del contenuto delle
  /// note) un upload è «grosso»: vale la pena verificare il token PRIMA di
  /// spedire megabyte per ricevere un 401.
  static const int _largeUploadChars = 256 * 1024;

  /// Number of sequential attempts made before a connection/network failure
  /// is considered final and the status indicator flips to Offline.
  static const int _maxRetryAttempts = 3;

  /// Base del backoff fra i tentativi (raddoppia a ogni tentativo, con jitter).
  static const Duration _retryDelay = Duration(milliseconds: 1500);

  /// Tetto di una singola attesa fra due tentativi.
  static const Duration _retryMaxDelay = Duration(seconds: 15);

  /// Tetto della somma delle attese di una stessa operazione: oltre, si rinuncia
  /// subito (il prossimo trigger o il watchdog riproveranno) invece di tenere
  /// l'utente in attesa. Vale anche per un `Retry-After` troppo lungo.
  static const Duration _retryBudget = Duration(seconds: 20);

  /// Interval for the background connectivity watchdog that keeps the
  /// online/offline indicator accurate even when no sync is otherwise
  /// triggered (e.g. the user isn't editing notes).
  static const Duration _connectivityPollInterval = Duration(seconds: 25);

  /// Quanti giri di sync "di recupero" consecutivi si accettano al massimo
  /// dopo il primo, per le richieste arrivate mentre una sync era in corso
  /// (vedi [_resyncRequested]). Il limite evita che trigger continui (es.
  /// digitazione con sync su inattività) tengano il motore occupato
  /// indefinitamente.
  static const int _maxFollowUpRounds = 2;

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

  /// Vero se un trigger (cambio nota, modifica cartelle, inattività,
  /// lifecycle...) è arrivato MENTRE una sync era già in corso. Prima quel
  /// trigger veniva semplicemente scartato: una modifica fatta dopo la lettura
  /// delle righe `dirty` del giro in corso restava non inviata fino al
  /// trigger successivo (anche molto più tardi, o mai se l'utente smetteva di
  /// interagire). Ora la richiesta viene ricordata e, a sync riuscita, si
  /// esegue un solo giro di recupero (vedi [triggerSync]).
  bool _resyncRequested = false;

  /// Quante richieste di rete "leggere" (health check e impostazioni) sono
  /// riuscite finora. Serve SOLO all'indicatore Online/Offline, insieme a
  /// `lastSyncTime` (che `_runSync` aggiorna solo a giro riuscito): vedi
  /// [_reachabilityMark].
  int _networkSuccessCount = 0;

  /// Istantanea di "quanto è già riuscito", da prendere PRIMA di inviare una
  /// richiesta che potrebbe scrivere `isOnline: false`.
  ///
  /// PERCHÉ: all'avvio health check, impostazioni e sync partono insieme e
  /// terminano in ordine imprevedibile. Un health check che fallisce dopo 15 s
  /// non deve riportare a Offline un indicatore che nel frattempo una sync (o
  /// un'altra richiesta) riuscita ha già messo Online: il server era
  /// raggiungibile. Chi sta per scrivere `isOnline: false` verifica con
  /// [_reachedServerSince]: se qualcosa è riuscito dopo la partenza della sua
  /// richiesta, il suo esito negativo è "vecchio" e non si scrive. Un
  /// fallimento senza alcun successo nel frattempo abbassa l'indicatore come
  /// sempre.
  ///
  /// La sync si riconosce da `lastSyncTime`, che cambia solo quando un giro
  /// riesce: così la regola non richiede NESSUNA modifica dentro `_runSync`
  /// (LWW, `dirty`, cursore e tombstone restano intatti).
  _ReachabilityMark _reachabilityMark() =>
      (successes: _networkSuccessCount, lastSync: state.lastSyncTime);

  /// Vero se, da quando è stata presa [mark], una richiesta è riuscita.
  bool _reachedServerSince(_ReachabilityMark mark) =>
      _networkSuccessCount != mark.successes ||
      state.lastSyncTime != mark.lastSync;

  late final Future<void> initialized;

  /// Attesa fra due tentativi e sorgente del jitter: sostituibili nei test.
  final Future<void> Function(Duration) _retryWait;
  final Random _random;

  /// Capability annunciate dal server, per URL (Y-14). Si aggiornano a ogni
  /// risposta 200 di sync; una risposta senza `caps` cancella la voce.
  final Map<String, ServerCaps> _capsByUrl = {};

  /// Cambia a ogni login/logout/401: una risposta partita nella sessione
  /// precedente non deve essere applicata alla sessione corrente (né far
  /// scattare un logout della nuova sessione con un 401 ormai vecchio).
  int _sessionGeneration = 0;

  bool _isCurrentSession(int generation) =>
      mounted && generation == _sessionGeneration;

  /// Serializza le scritture delle credenziali: due login/logout che si
  /// incrociano non devono mescolare token, URL e username nella secure
  /// storage (es. token della sessione A con server della sessione B).
  Future<void> _sessionWriteQueue = Future<void>.value();

  Future<T> _withSessionWriteLock<T>(Future<T> Function() action) async {
    final previous = _sessionWriteQueue;
    final gate = Completer<void>();
    _sessionWriteQueue = gate.future;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
    }
  }

  SyncNotifier(
    this._ref,
    this._apiService,
    this._secureStorage, {
    FoldersDao? foldersDao,
    NotesDao? notesDao,
    SyncMetaDao? syncMetaDao,
    Future<void> Function(Duration)? retryWait,
    Random? random,
  })  : _foldersDao = foldersDao ?? FoldersDao(),
        _notesDao = notesDao ?? NotesDao(),
        _syncMetaDao = syncMetaDao ?? SyncMetaDao(),
        _retryWait = retryWait ?? Future<void>.delayed,
        _random = random ?? Random(),
        super(const SyncConfig()) {
    initialized = _init();
  }

  /// Capability del server corrente, come annunciate nell'ULTIMA risposta 200
  /// di sync. Null se non ancora note (nessuna sync riuscita con questo URL in
  /// questa sessione) o se il server non le annuncia (2.1.0 e precedenti):
  /// in entrambi i casi nessuna funzione opzionale va usata.
  ServerCaps? get serverCaps => _capsByUrl[_capsKey(state.serverUrl)];

  static String _capsKey(String url) =>
      url.trim().replaceAll(RegExp(r'/+$'), '');

  void _rememberServerCaps(String serverUrl, ServerCaps? caps) {
    final key = _capsKey(serverUrl);
    if (caps == null) {
      _capsByUrl.remove(key);
    } else {
      _capsByUrl[key] = caps;
    }
  }

  /// `expires_at` della login è in SECONDI Unix (come `exp` di un JWT), mentre
  /// tutti i timestamp di sync sono in millisecondi. Restituisce la scadenza in
  /// millisecondi, o null se il valore non è utilizzabile. Un numero già in
  /// millisecondi (>= 1e11, che in secondi sarebbe oltre l'anno 5138) non viene
  /// moltiplicato.
  static int? tokenExpiryMillis(int rawExpiresAt) {
    if (rawExpiresAt <= 0) return null;
    return rawExpiresAt >= 100000000000 ? rawExpiresAt : rawExpiresAt * 1000;
  }

  Future<void> _saveTokenExpiry(int rawExpiresAt) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = tokenExpiryMillis(rawExpiresAt);
      if (ms == null) {
        await prefs.remove(_prefTokenExpiresAt);
      } else {
        await prefs.setInt(_prefTokenExpiresAt, ms);
      }
    } catch (_) {
      // Best effort: senza scadenza nota si cade nel comportamento di prima.
    }
  }

  Future<void> _clearTokenExpiry() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefTokenExpiresAt);
    } catch (_) {}
  }

  /// Cancella le credenziali locali e la scadenza memorizzata.
  Future<void> _clearAuthCredentials() async {
    await _secureStorage.clearAuth();
    await _clearTokenExpiry();
  }

  /// Chiude la sessione [generation] per un 401. Incrementa la generazione
  /// PRIMA di cancellare, così ogni altra risposta in volo della stessa
  /// sessione viene scartata; se nel frattempo è partito un login nuovo, non
  /// ne cancella le credenziali.
  Future<void> _endSession(int generation) async {
    if (generation != _sessionGeneration) return;
    final endedGeneration = ++_sessionGeneration;
    await _withSessionWriteLock(() async {
      if (_sessionGeneration != endedGeneration) return;
      await _clearAuthCredentials();
    });
    if (_sessionGeneration == endedGeneration) _stopConnectivityWatchdog();
  }

  /// Vero se, secondo l'orologio LOCALE, il token è scaduto o sta per
  /// scadere. Scadenza ignota => falso.
  Future<bool> _tokenLooksExpired() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final expiry = prefs.getInt(_prefTokenExpiresAt);
      if (expiry == null) return false;
      return DateTime.now().millisecondsSinceEpoch >=
          expiry - _tokenExpirySkewMs;
    } catch (_) {
      return false;
    }
  }

  /// Prima di un upload grosso con un token che sembra scaduto, verifica il
  /// token con una richiesta leggera (GET impostazioni) invece di spedire
  /// megabyte per ricevere un 401. Un 401 viene rilanciato (è la sessione
  /// scaduta, gestita dal chiamante); se il server risponde bene l'orologio del
  /// dispositivo è sfasato e si prosegue; ogni altro errore (rete) non decide
  /// nulla: si procede con la sync normale, che ha già i suoi ritentativi.
  Future<void> _verifyTokenBeforeLargeUpload(
      String token, List<NoteRow> dirtyNotes) async {
    var chars = 0;
    for (final n in dirtyNotes) {
      chars += n.content.length;
    }
    if (chars < _largeUploadChars || !await _tokenLooksExpired()) return;
    try {
      await _apiService.getUserSettings(baseUrl: state.serverUrl, token: token);
      // Il token è valido: l'orologio locale è sbagliato. Non si ripete il controllo.
      await _clearTokenExpiry();
    } on SyncApiException catch (e) {
      if (e.statusCode == 401) rethrow;
    } catch (_) {}
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
    final lastSyncTime = lastSyncMillis != null
        ? DateTime.fromMillisecondsSinceEpoch(lastSyncMillis)
        : null;

    final savedServerUrl = await _secureStorage.getServerUrl() ?? '';
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

    // Controllo di raggiungibilità iniziale (se c'è un URL): NON si attende.
    // Prima `await checkConnection()` poteva durare fino a 15 s su rete morta
    // (3 tentativi da 4 s + 2 pause da 1,5 s) e ritardava di altrettanto
    // watchdog, impostazioni e sync, che non lo leggono nemmeno: l'esito serve
    // solo all'indicatore online/offline (vedi [_reachabilityMark]).
    if (savedServerUrl.isNotEmpty && mounted) {
      unawaited(PerfMarks.timeAsync('sync.health', checkConnection));
    }

    if (hasToken) {
      _startConnectivityWatchdog();
    }

    // If authenticated and launch sync enabled, trigger sync & fetch remote settings
    if (hasToken && launchSync && mounted) {
      // Defer slightly to let UI settle
      unawaited(Future.delayed(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        // Indipendenti: le impostazioni cambiano solo l'aspetto, la sync solo
        // i dati. Attendere le prime (fino a 33 s su rete morta) prima di
        // avviare la seconda ritardava l'invio di modifiche locali senza
        // alcun motivo. Un errore dell'una non impedisce più l'altra (prima,
        // se il fetch delle impostazioni lanciava, la sync non partiva).
        // Se le impostazioni rispondono 401 la sync fa comunque la sua
        // richiesta e riceve lo stesso 401, che ripulisce le credenziali come
        // prima: nessun dato locale viene toccato (il 401 non scrive righe).
        //
        // Marker per DevTools (vedi PerfMarks): non cambiano il comportamento.
        // `launchRequests` segna il momento in cui partono insieme; per il
        // momento esatto del POST vale il protocollo M8 (`tshark`).
        PerfMarks.mark('sync.launchRequests');
        unawaited(
            PerfMarks.timeAsync('sync.settings', fetchRemoteUserSettings));
        // `sync.initial` copre l'intera `triggerSync`, compresi gli eventuali
        // giri di recupero (fino a 3 giri): non è il tempo sul filo.
        unawaited(PerfMarks.timeAsync('sync.initial', triggerSync));
      }));
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
      unawaited(checkConnection());
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

  /// Attesa prima del tentativo successivo: [_retryDelay] raddoppiato a ogni
  /// tentativo, con jitter ±25% (evita che molti client riprovino insieme),
  /// limitato a [_retryMaxDelay]. Se il server ha indicato `Retry-After` non si
  /// riprova prima.
  @visibleForTesting
  Duration retryDelayFor(int attempt, Object error) =>
      _retryDelayFor(attempt, error);

  Duration _retryDelayFor(int attempt, Object error) {
    final exponential = _retryDelay.inMilliseconds * (1 << (attempt - 1));
    final jitter = 0.75 + _random.nextDouble() * 0.5;
    var delay = Duration(milliseconds: (exponential * jitter).round());
    if (delay > _retryMaxDelay) delay = _retryMaxDelay;
    if (error is SyncApiException) {
      final hint = error.retryAfter;
      if (hint != null && hint > delay) delay = hint;
    }
    return delay;
  }

  /// Runs [action] with up to [_maxRetryAttempts] sequential attempts. Only
  /// retries transient connection/timeout style failures; anything else (e.g.
  /// a 401) is rethrown immediately without retry.
  ///
  /// L'attesa fra i tentativi è un backoff esponenziale con jitter (vedi
  /// [_retryDelayFor]) e rispetta `Retry-After` di un 503. La somma delle attese
  /// non supera [_retryBudget]: se la prossima non ci sta, si rinuncia subito.
  Future<T> _withNetworkRetry<T>(Future<T> Function() action) async {
    Object lastError =
        const SyncApiException('Errore di connessione sconosciuto');
    var waited = Duration.zero;

    for (int attempt = 1; attempt <= _maxRetryAttempts; attempt++) {
      try {
        return await action();
      } catch (e) {
        lastError = e;
        final isLastAttempt = attempt == _maxRetryAttempts;
        if (!_isTransientNetworkError(e) || isLastAttempt) {
          rethrow;
        }
        final delay = _retryDelayFor(attempt, e);
        if (waited + delay > _retryBudget) {
          rethrow;
        }
        waited += delay;
        await _retryWait(delay);
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
    final mark = _reachabilityMark();

    for (int attempt = 1; attempt <= _maxRetryAttempts; attempt++) {
      isOnline = await _apiService.checkHealth(state.serverUrl);
      if (isOnline) break;
      if (attempt < _maxRetryAttempts) {
        await Future.delayed(_retryDelay);
      }
    }

    if (!mounted) return isOnline;
    if (isOnline) {
      _networkSuccessCount++;
    } else if (_reachedServerSince(mark)) {
      // Mentre questo controllo falliva, un'altra richiesta (sync o
      // impostazioni) è riuscita: il server era raggiungibile e l'indicatore
      // non va riportato a Offline da un esito ormai vecchio. Il valore di
      // ritorno resta quello del controllo.
      return isOnline;
    }
    state = state.copyWith(isOnline: isOnline);
    return isOnline;
  }

  Future<bool> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final generation = ++_sessionGeneration;
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
      // Un secondo login (o un logout) è partito mentre questa richiesta era
      // in volo: non sovrascrivere credenziali e stato della sessione nuova.
      if (!_isCurrentSession(generation)) return false;

      final applied = await _withSessionWriteLock(() async {
        if (!_isCurrentSession(generation)) return false;
        await _secureStorage.saveAuthToken(response.token);
        await _secureStorage.saveServerUrl(serverUrl);
        await _secureStorage.saveUsername(response.username);
        await _secureStorage.saveUserId(response.userId);
        await _saveTokenExpiry(response.expiresAt);
        if (!_isCurrentSession(generation)) return false;

        state = state.copyWith(
          isAuthenticated: true,
          isOnline: true,
          username: () => response.username,
          isSyncing: false,
          lastError: () => null,
        );
        return true;
      });
      if (!applied) return false;

      _startConnectivityWatchdog();

      // Fetch remote settings & run initial sync
      await fetchRemoteUserSettings();
      await triggerSync();

      return _isCurrentSession(generation);
    } catch (e) {
      if (_isCurrentSession(generation)) {
        state = state.copyWith(
          isAuthenticated: false,
          isOnline: false,
          isSyncing: false,
          lastError: () => e is SyncApiException ? e.message : e.toString(),
        );
      }
      return false;
    }
  }

  Future<void> logout() async {
    final generation = ++_sessionGeneration;
    _inactivityTimer?.cancel();
    _noteSwitchDebounceTimer?.cancel();
    _folderStructureDebounceTimer?.cancel();
    _stopConnectivityWatchdog();

    // Revoca il token anche lato server (best effort, non lancia): senza
    // questo il JWT resterebbe valido fino a scadenza anche dopo il logout.
    final token = await _secureStorage.getAuthToken();
    final url = state.serverUrl;
    if (token != null && token.isNotEmpty && url.isNotEmpty) {
      await _apiService.logout(baseUrl: url, token: token);
    }

    // Se nel frattempo è partito un nuovo login, non cancellare le sue
    // credenziali appena scritte: la sessione nuova vince.
    await _withSessionWriteLock(() async {
      if (_sessionGeneration != generation) return;
      await _clearAuthCredentials();
    });
    if (!_isCurrentSession(generation)) return;
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
        // Se una sync è già in corso, triggerSync() accoda un giro di
        // recupero invece di perdere la richiesta (vedi _resyncRequested).
        if (mounted && state.syncOnInactivity) {
          unawaited(triggerSync());
        }
      },
    );
  }

  /// Hook for note change / editor close (debounced by 600ms to avoid bursts during rapid navigation)
  void onNoteChangedOrClosed() {
    if (!state.isAuthenticated || !state.syncOnNoteSwitch) return;

    _noteSwitchDebounceTimer?.cancel();
    _noteSwitchDebounceTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted && state.syncOnNoteSwitch) {
        unawaited(triggerSync());
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
    _folderStructureDebounceTimer =
        Timer(const Duration(milliseconds: 600), () {
      if (mounted) {
        unawaited(triggerSync());
      }
    });
  }

  /// Hook for app lifecycle (pause / exit)
  void onAppPaused() {
    // Ferma il poll periodico di connettività mentre l'app è in background:
    // senza questo, il watchdog continuerebbe a contattare l'endpoint di
    // health ogni `_connectivityPollInterval` anche a finestra minimizzata
    // (rilevante soprattutto su desktop, dove l'isolate Dart resta vivo),
    // sprecando rete/batteria senza alcun beneficio percepibile dall'utente.
    _stopConnectivityWatchdog();
    // Invia subito eventuali impostazioni di aspetto ancora in debounce (vedi
    // SettingsNotifier.flushRemotePush), prima che l'app possa essere chiusa.
    _ref.read(settingsProvider.notifier).flushRemotePush();
    if (state.syncOnAppLifecycle) {
      unawaited(
          triggerSync()); // no-op se non autenticati; accoda se già in corso
    }
  }

  /// Hook for app resuming to the foreground: re-validates connectivity
  /// immediately so the status indicator doesn't show stale information
  /// after the device was asleep, on a different network, etc.
  void onAppResumed() {
    if (state.isAuthenticated && !state.isSyncing) {
      unawaited(checkConnection());
      // Riavvia il poll periodico messo in pausa da onAppPaused (annulla
      // internamente eventuali timer residui, quindi è sicuro anche se non
      // era mai stato fermato).
      _startConnectivityWatchdog();
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
        isFavorite: r.isFavorite,
        isPinned: r.isPinned,
        orderIndex: r.orderIndex,
        updatedAt: r.updatedAt,
        deletedAt: r.deletedAt,
      );

  FolderRow _fromFolderDto(FolderChangeDto d) => FolderRow(
        id: d.id,
        name: d.name,
        parentId: d.parentId,
        isExpanded:
            true, // valore di default: applyRemoteLWW preserva quello locale se già presente
        updatedAt: d.updatedAt,
        deletedAt: d.deletedAt,
      );

  NoteRow _fromNoteDto(NoteChangeDto d) => NoteRow(
        id: d.id,
        title: d.title,
        content: d.content,
        folderId: d.folderId,
        isFavorite: d.isFavorite,
        isPinned: d.isPinned,
        orderIndex: d.orderIndex,
        createdAt: d
            .updatedAt, // valore di fallback: applyRemoteLWW preserva quello locale se già presente
        updatedAt: d.updatedAt,
        deletedAt: d.deletedAt,
      );

  /// Sincronizza cartelle e note bidirezionalmente con il server
  /// (Last-Write-Wins), interamente ID-based.
  ///
  /// Protocollo (speculare a SyncHandler.Sync nel backend):
  ///  1. Legge dal DB locale le righe `dirty = 1` (modifiche locali non
  ///     ancora confermate). NON confronta più `updated_at` col cursore:
  ///     erano due orologi diversi (client vs server) e con clock skew si
  ///     perdevano modifiche o si rispedivano righe inutilmente.
  ///  2. Le invia con POST /api/v1/sync insieme al cursore (`server_time`
  ///     dell'ultima sync riuscita, usato dal server solo per la pull).
  ///  3. Segna pulite le righe inviate, ma solo se non modificate di nuovo
  ///     nel frattempo (`markSynced`), poi applica la risposta del server.
  ///  4. Con `full_resync` elimina le righe pulite sconosciute al server;
  ///     elimina sempre i tombstone locali già confermati.
  ///  5. Salva `server_time` come nuovo cursore SOLO a sync completata: su
  ///     qualunque errore (incluso il 422 con record rifiutati) il cursore
  ///     resta invariato.
  Future<bool> triggerSync({bool force = false}) async {
    // GUARDIA ATOMICA: controllo e impostazione di `isSyncing` avvengono nello
    // stesso blocco sincrono, PRIMA di qualunque `await`. Prima il flag veniva
    // impostato dopo flush + letture DB + lettura del token: due trigger quasi
    // simultanei (es. cambio nota + lifecycle) passavano entrambi la guardia e
    // avviavano due sync concorrenti sugli stessi dati.
    if (!state.isAuthenticated) return false;
    if (state.isSyncing) {
      // Non si avviano due round concorrenti sugli stessi dati, ma la
      // richiesta non va persa: vedi [_resyncRequested].
      _resyncRequested = true;
      return false;
    }
    // Questo giro leggerà ORA le righe dirty: copre ogni richiesta precedente.
    // Il flag torna a true solo se un trigger arriva mentre si sincronizza.
    _resyncRequested = false;
    _markSyncStarted();

    try {
      var ok = await _runSyncGuarded();

      // Giri di recupero: una richiesta arrivata durante la sync (modifiche
      // fatte dopo la lettura delle righe dirty) viene servita subito, ma
      // solo dopo un giro riuscito (se la rete è giù non ha senso insistere:
      // ci pensano i trigger e il watchdog di connettività) e al massimo
      // [_maxFollowUpRounds] volte di fila.
      for (var round = 0; round < _maxFollowUpRounds; round++) {
        if (!ok || !_resyncRequested || !mounted || !state.isAuthenticated) {
          break;
        }
        _resyncRequested = false;
        _markSyncStarted();
        ok = await _runSyncGuarded();
      }
      return ok;
    } finally {
      // Rete di sicurezza: qualunque uscita (anche eccezione inattesa) deve
      // riportare isSyncing a false, altrimenti la sync resterebbe bloccata.
      if (mounted && state.isSyncing) {
        state = state.copyWith(isSyncing: false);
      }
    }
  }

  /// Imposta lo stato "sincronizzazione in corso". Sempre SINCRONO (nessun
  /// `await` tra il controllo di `isSyncing` e questa chiamata), così due
  /// trigger quasi simultanei non possono passare entrambi la guardia.
  void _markSyncStarted() {
    state = state.copyWith(
      isSyncing: true,
      lastError: () => null,
      lastSyncMessage: () => 'Sincronizzazione in corso...',
    );
  }

  /// Esegue [_runSync] garantendo che nessuna eccezione sfugga: `triggerSync`
  /// viene spesso lanciata da un Timer senza `await`, dove un errore non
  /// gestito diventerebbe un'eccezione asincrona non catturata. Gli errori
  /// attesi (rete, HTTP, database) sono già gestiti dentro [_runSync]; qui
  /// finisce solo ciò che sfugge (es. keystore di sistema illeggibile durante
  /// la lettura del token).
  Future<bool> _runSyncGuarded() async {
    final generation = _sessionGeneration;
    try {
      return await _runSync();
    } catch (e, st) {
      debugPrint('SyncNotifier: errore imprevisto durante la sync: $e\n$st');
      if (_isCurrentSession(generation)) {
        state = state.copyWith(
          isSyncing: false,
          lastError: () => e.toString(),
          lastSyncMessage: () =>
              'Sincronizzazione non riuscita: errore interno',
        );
      }
      return false;
    }
  }

  Future<bool> _runSync() async {
    // Sessione e URL vanno catturati PRIMA di ogni await: se nel frattempo
    // l'utente cambia account, questa sync non deve applicare la risposta
    // della vecchia sessione al DB/alla UI della nuova.
    final generation = _sessionGeneration;
    final serverUrl = state.serverUrl;

    // Scrive il testo ancora in debounce (500 ms) prima di leggere le righe
    // dirty, così anche l'ultima battitura rientra in questo giro.
    await _ref.read(notesProvider.notifier).flushPendingSaves();
    if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
      return false;
    }

    final token = await _secureStorage.getAuthToken();
    if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
      return false;
    }
    if (token == null || token.isEmpty) {
      if (mounted) {
        state = state.copyWith(isAuthenticated: false, isSyncing: false);
      }
      return false;
    }

    try {
      // Vero se _repairRejected ha modificato righe nel DB locale: lo stato in
      // memoria non lo sa, quindi serve rileggere dal DB a fine giro.
      var repaired = false;

      // Massimo 2 tentativi: il secondo solo dopo aver riparato i record
      // rifiutati dal server con 422.
      for (var attempt = 0; attempt < 2; attempt++) {
        if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
          return false;
        }

        final cursor = await _syncMetaDao.getSyncCursor();
        final dirtyFolders = await _foldersDao.listDirty();
        final dirtyNotes = await _notesDao.listDirty();
        if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
          return false;
        }

        // Y-13-A: con un upload grosso e un token che sembra scaduto, prima si
        // verifica il token (un 401 arriva dal catch esterno, come sempre).
        await _verifyTokenBeforeLargeUpload(token, dirtyNotes);
        if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
          return false;
        }

        final SyncResponse response;
        try {
          response = await _withNetworkRetry(
            () => _apiService.sync(
              baseUrl: serverUrl,
              token: token,
              lastSyncedAt: cursor,
              folders: dirtyFolders.map(_toFolderDto).toList(),
              notes: dirtyNotes.map(_toNoteDto).toList(),
            ),
          );
        } on SyncApiException catch (e) {
          if (e.statusCode == 422 && e.rejected.isNotEmpty && attempt == 0) {
            if (!_isCurrentSession(generation) ||
                serverUrl != state.serverUrl) {
              return false;
            }
            // Il server ha annullato l'intero batch e NON ha restituito un
            // cursore: il nostro resta invariato. Si ripara il riferimento
            // non valido (cartella inesistente sul server) e si riprova.
            await _repairRejected(e.rejected);
            repaired = true;
            continue;
          }
          rethrow;
        }

        // La sessione può essere cambiata mentre la richiesta era in volo:
        // scartare la risposta è l'unico modo per non applicare i dati di un
        // account al DB dell'altro.
        if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
          return false;
        }

        // Y-14: capability annunciate dal server in QUESTA risposta (assenti =
        // server senza caps: nessuna funzione opzionale).
        _rememberServerCaps(serverUrl, response.caps);

        // 1) Righe inviate -> pulite (solo se non ri-modificate durante il
        //    round-trip). 2) Applica la risposta (che include anche la
        //    versione del server per i conflitti persi). Ordine importante:
        //    markSynced prima, così l'eco del server sostituisce le righe.
        await _foldersDao
            .markSynced({for (final f in dirtyFolders) f.id: f.updatedAt});
        await _notesDao
            .markSynced({for (final n in dirtyNotes) n.id: n.updatedAt});

        await _foldersDao
            .applyRemoteLWWBatch(response.folders.map(_fromFolderDto).toList());
        await _notesDao
            .applyRemoteLWWBatch(response.notes.map(_fromNoteDto).toList());

        if (response.fullResync) {
          // Cursore più vecchio della retention dei tombstone del server:
          // la risposta è lo stato completo. Le righe pulite che il server non
          // elenca sono state eliminate mentre eravamo offline.
          await _foldersDao
              .deleteCleanNotIn({for (final f in response.folders) f.id});
          await _notesDao
              .deleteCleanNotIn({for (final n in response.notes) n.id});
        }

        // Tombstone locali ormai inutili (confermati dal server o ricevuti da
        // lui): eliminati fisicamente, non si accumulano nel DB locale.
        await _foldersDao.purgeCleanTombstones();
        await _notesDao.purgeCleanTombstones();

        await _syncMetaDao.setSyncCursor(response.serverTime);

        // Si rilegge dal DB (tutte le note, contenuto incluso) SOLO se il DB
        // locale è cambiato rispetto allo stato in memoria: il server ha
        // restituito righe, è stato un full_resync oppure sono stati
        // riparati dei record. Con "sync al cambio nota" attiva ogni
        // cambio nota avvia un giro: rileggere e ricostruire l'intero
        // archivio a ogni giro, anche con risposta vuota, era puro lavoro
        // sprecato. markSynced e la purge dei tombstone non toccano nulla
        // che la UI mostri.
        final localDbChanged = repaired ||
            response.fullResync ||
            response.folders.isNotEmpty ||
            response.notes.isNotEmpty;
        if (localDbChanged) {
          await _ref.read(folderProvider.notifier).refreshFromDb();
          await _ref.read(notesProvider.notifier).refreshFromDb();
        }

        final syncedAt = DateTime.now();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_prefLastSyncTime, syncedAt.millisecondsSinceEpoch);

        if (!mounted) return true;
        state = state.copyWith(
          isOnline: true,
          isSyncing: false,
          lastSyncTime: () => syncedAt,
          lastSyncMessage: () =>
              'Sincronizzato (${dirtyFolders.length + dirtyNotes.length} inviate, ${response.folders.length + response.notes.length} ricevute)',
          lastError: () => null,
        );
        return true;
      }
      return false; // irraggiungibile: il ciclo ritorna o lancia
    } catch (e) {
      // Un errore (anche 401) della sessione precedente non deve toccare la
      // sessione nuova.
      if (!_isCurrentSession(generation)) return false;
      final isAuthError = e is SyncApiException && e.statusCode == 401;
      final isRejected = e is SyncApiException && e.statusCode == 422;
      // Un errore di SQLite locale non dice nulla sulla raggiungibilità del
      // server: prima veniva mostrato come "server non raggiungibile".
      final isLocalDbError = e is DatabaseException;
      if (isLocalDbError) {
        debugPrint('SyncNotifier: errore del database locale: $e');
      }
      state = state.copyWith(
        isAuthenticated: isAuthError ? false : state.isAuthenticated,
        // Un 422 è una risposta del server (quindi è online): non va mostrato Offline.
        isOnline: (isAuthError || isRejected || isLocalDbError)
            ? state.isOnline
            : false,
        isSyncing: false,
        lastError: () => e is SyncApiException ? e.message : e.toString(),
        lastSyncMessage: () => isAuthError
            ? 'Sessione scaduta: effettua nuovamente l\'accesso'
            : isRejected
                ? 'Sincronizzazione non riuscita: alcuni elementi non sono validi per il server'
                : isLocalDbError
                    ? 'Sincronizzazione non riuscita: errore del database locale'
                    : 'Sincronizzazione non riuscita: server non raggiungibile',
      );
      if (isAuthError) {
        await _endSession(generation);
      }
      return false;
    }
  }

  /// Ripara i record rifiutati dal server (422) portandoli in uno stato
  /// valido: una nota con `folder_id` sconosciuto al server viene spostata
  /// fuori da ogni cartella, una cartella con `parent_id` sconosciuto diventa
  /// radice. Le righe riparate risultano modificate (`dirty`, `updated_at`
  /// nuovo) e verranno inviate al tentativo successivo. Nessun dato di
  /// contenuto va perso.
  Future<void> _repairRejected(List<SyncRejectedItem> rejected) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    for (final r in rejected) {
      if (r.kind == 'note') {
        final row = await _notesDao.getById(r.id);
        if (row != null && row.folderId != null) {
          await _notesDao.upsert(row.copyWith(folderId: null, updatedAt: now));
        }
      } else if (r.kind == 'folder') {
        final row = await _foldersDao.getById(r.id);
        if (row != null && row.parentId != null) {
          await _foldersDao
              .upsert(row.copyWith(parentId: null, updatedAt: now));
        }
      }
    }
  }

  /// Downloads remote user preferences and applies them locally
  Future<void> fetchRemoteUserSettings() async {
    if (!state.isAuthenticated) return;
    final generation = _sessionGeneration;
    final serverUrl = state.serverUrl;
    final token = await _secureStorage.getAuthToken();
    if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) return;
    if (token == null) return;

    final mark = _reachabilityMark();
    try {
      final remoteSettings = await _withNetworkRetry(
        () => _apiService.getUserSettings(
          baseUrl: serverUrl,
          token: token,
        ),
      );
      if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
        return;
      }
      _networkSuccessCount++;
      unawaited(_ref
          .read(settingsProvider.notifier)
          .applyRemoteSettings(remoteSettings));
    } catch (e) {
      if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
        return;
      }
      if (e is SyncApiException && e.statusCode == 401) {
        final reason = e.message;
        state = state.copyWith(
          isAuthenticated: false,
          lastError: () => reason,
          lastSyncMessage: () =>
              'Sessione scaduta: effettua nuovamente l\'accesso',
        );
        await _endSession(generation);
      } else if (!_reachedServerSince(mark)) {
        // Se nel frattempo un'altra richiesta è riuscita (all'avvio gira in
        // parallelo alla sync), questo fallimento è vecchio: vedi
        // [_reachabilityMark].
        state = state.copyWith(isOnline: false);
      }
    }
  }

  /// Sends updated preferences to PUT /api/v1/user/settings
  Future<void> pushUserSettings(UserSettingsDto settings) async {
    if (!state.isAuthenticated) return;
    final generation = _sessionGeneration;
    final serverUrl = state.serverUrl;
    final token = await _secureStorage.getAuthToken();
    if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) return;
    if (token == null) return;

    try {
      await _withNetworkRetry(
        () => _apiService.updateUserSettings(
          baseUrl: serverUrl,
          token: token,
          settings: settings,
        ),
      );
    } catch (e) {
      if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
        return;
      }
      if (e is SyncApiException && e.statusCode == 401) {
        final reason = e.message;
        state = state.copyWith(
          isAuthenticated: false,
          lastError: () => reason,
          lastSyncMessage: () =>
              'Sessione scaduta: effettua nuovamente l\'accesso',
        );
        await _endSession(generation);
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
