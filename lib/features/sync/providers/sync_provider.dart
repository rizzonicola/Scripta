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
import 'package:uuid/uuid.dart';
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

/// Esito di un tentativo di rinnovo della sessione. Distinguere "token
/// rifiutato" da "server non raggiungibile" evita di cancellare le credenziali
/// quando il refresh fallisce per rete o per un 5xx temporaneo.
enum _RefreshOutcome { success, invalid, blocked, unavailable }

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
  static const _prefLastOnline = 'scripta_last_online';

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

  /// Budget complessivo del login interattivo, comprensivo di timeout, retry e
  /// attese. Oltre questo limite il pulsante torna attivo e l'utente vede
  /// l'errore, invece di restare in caricamento a tempo indefinito.
  static const Duration _defaultLoginBudget = Duration(seconds: 10);

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

  /// Ultimo valore di [SyncConfig.isOnline] scritto su disco. Evita di
  /// riscrivere la preferenza ad ogni poll di connettività quando non cambia.
  bool? _lastPersistedOnline;

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

  /// Ricorda l'ultimo stato Online/Offline per il prossimo avvio. È
  /// intenzionalmente best effort: un errore di SharedPreferences non deve
  /// interferire con la sync o con l'indicatore.
  void _rememberOnline(bool value) {
    if (_lastPersistedOnline == value) return;
    _lastPersistedOnline = value;
    unawaited(_persistOnline(value));
  }

  Future<void> _persistOnline(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefLastOnline, value);
    } catch (_) {
      _lastPersistedOnline = null;
    }
  }

  late final Future<void> initialized;

  /// Attesa fra due tentativi e sorgente del jitter: sostituibili nei test.
  final Future<void> Function(Duration) _retryWait;
  final Random _random;

  /// Limite complessivo del login interattivo (vedi [_defaultLoginBudget]).
  final Duration _loginBudget;

  /// Capability annunciate dal server, per URL (Y-14). Si aggiornano a ogni
  /// risposta 200 di sync; una risposta senza `caps` cancella la voce.
  final Map<String, ServerCaps> _capsByUrl = {};
  final _uuid = const Uuid();

  /// Cambia a ogni login/logout/401: una risposta partita nella sessione
  /// precedente non deve essere applicata alla sessione corrente (né far
  /// scattare un logout della nuova sessione con un 401 ormai vecchio).
  int _sessionGeneration = 0;

  /// Refresh in corso (single-flight): più richieste che ricevono 401 quasi
  /// insieme devono condividere un solo rinnovo, altrimenti la seconda
  /// rotazione userebbe un refresh token già consumato e revocherebbe la
  /// famiglia. La generazione evita di riusare il future di una sessione
  /// precedente.
  Future<_RefreshOutcome>? _refreshInFlight;
  int? _refreshGeneration;

  /// Identifica il trigger di sync attualmente proprietario di `isSyncing`.
  /// Un trigger vecchio non deve azzerare il flag di uno nuovo partito dopo
  /// un login (che azzera `isSyncing` mentre una sync precedente è in volo).
  int _syncTriggerId = 0;

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
    Duration loginBudget = _defaultLoginBudget,
  })  : _foldersDao = foldersDao ?? FoldersDao(),
        _notesDao = notesDao ?? NotesDao(),
        _syncMetaDao = syncMetaDao ?? SyncMetaDao(),
        _retryWait = retryWait ?? Future<void>.delayed,
        _random = random ?? Random(),
        _loginBudget = loginBudget,
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

  /// Chiude la sessione [generation] per un 401 o per un account bloccato.
  /// Incrementa la generazione PRIMA di cancellare, così ogni altra risposta
  /// in volo della stessa sessione viene scartata; se nel frattempo è partito
  /// un login nuovo, non ne cancella le credenziali.
  Future<void> _endSession(int generation) async {
    if (generation != _sessionGeneration) return;
    final endedGeneration = ++_sessionGeneration;
    _ref.read(settingsProvider.notifier).discardPendingPush();
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

  /// Esegue il refresh una sola volta per sessione/generazione. Se più
  /// richieste ricevono 401 insieme, la seconda attende lo stesso future
  /// invece di consumare due volte il refresh token (la rotazione è monouso).
  Future<_RefreshOutcome> _refreshSession(int generation) {
    final existing = _refreshInFlight;
    if (existing != null && _refreshGeneration == generation) {
      return existing;
    }
    final future = _doRefresh(generation);
    _refreshGeneration = generation;
    _refreshInFlight = future;
    future.whenComplete(() {
      if (identical(_refreshInFlight, future)) {
        _refreshInFlight = null;
        _refreshGeneration = null;
      }
    });
    return future;
  }

  Future<_RefreshOutcome> _doRefresh(int generation) async {
    if (!_isCurrentSession(generation)) return _RefreshOutcome.invalid;
    final serverUrl = state.serverUrl;
    final refreshToken = await _secureStorage.getRefreshToken();
    if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
      return _RefreshOutcome.invalid;
    }
    if (refreshToken == null || refreshToken.isEmpty || serverUrl.isEmpty) {
      return _RefreshOutcome.invalid;
    }

    try {
      final response = await _apiService.refresh(
        baseUrl: serverUrl,
        refreshToken: refreshToken,
      );
      if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
        return _RefreshOutcome.invalid;
      }
      final applied = await _withSessionWriteLock(() async {
        if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
          return false;
        }
        // Prima il refresh token nuovo, poi l'access token: se il processo
        // muore fra le due scritture, al riavvio il refresh nuovo è ancora
        // utilizzabile (quello vecchio è già stato consumato dal server).
        await _secureStorage.saveRefreshToken(response.refreshToken);
        await _secureStorage.saveAuthToken(response.token);
        await _saveTokenExpiry(response.expiresAt);
        return true;
      });
      return applied ? _RefreshOutcome.success : _RefreshOutcome.invalid;
    } on SyncApiException catch (e) {
      if (!_isCurrentSession(generation)) return _RefreshOutcome.invalid;
      if (e.statusCode == 401 || e.code == 'invalid_grant') {
        return _RefreshOutcome.invalid;
      }
      if (_isAccountBlocked(e)) return _RefreshOutcome.blocked;
      return _RefreshOutcome.unavailable;
    } catch (_) {
      return _RefreshOutcome.unavailable;
    }
  }

  /// Esegue una richiesta autenticata e, su 401, rinnova la sessione una volta
  /// e riprova. Un refresh rifiutato o un account bloccato lasciano al
  /// chiamante il compito di chiudere la sessione; un errore di rete/5xx non
  /// cancella le credenziali.
  Future<T> _authorizedRequest<T>(
      Future<T> Function(String token) request) async {
    final generation = _sessionGeneration;
    final token = await _secureStorage.getAuthToken();
    if (!_isCurrentSession(generation) || token == null || token.isEmpty) {
      throw const SyncApiException(
          'Sessione scaduta o non autorizzata', 401, [], 'invalid_token');
    }

    try {
      return await request(token);
    } on SyncApiException catch (e) {
      if (e.statusCode != 401) rethrow;
      final outcome = await _refreshSession(generation);
      if (!_isCurrentSession(generation)) rethrow;
      switch (outcome) {
        case _RefreshOutcome.success:
          final nextToken = await _secureStorage.getAuthToken();
          if (nextToken == null || nextToken.isEmpty) rethrow;
          return await request(nextToken);
        case _RefreshOutcome.blocked:
          throw const SyncApiException(
            'Account bloccato dall\'amministratore. Contatta l\'assistenza.',
            403,
            [],
            'account_blocked',
          );
        case _RefreshOutcome.invalid:
          rethrow;
        case _RefreshOutcome.unavailable:
          throw const SyncApiException(
            'Impossibile rinnovare la sessione: server non raggiungibile',
            503,
            [],
            'refresh_unavailable',
          );
      }
    }
  }

  /// Prima di un upload grosso con un token che sembra scaduto, verifica il
  /// token con una richiesta leggera (GET impostazioni) invece di spedire
  /// megabyte per ricevere un 401. Un 401 viene rilanciato (è la sessione
  /// scaduta, gestita dal chiamante); se il server risponde bene l'orologio del
  /// dispositivo è sfasato e si prosegue; ogni altro errore (rete) non decide
  /// nulla: si procede con la sync normale, che ha già i suoi ritentativi.
  Future<void> _verifyTokenBeforeLargeUpload(List<NoteRow> dirtyNotes) async {
    var chars = 0;
    for (final n in dirtyNotes) {
      chars += n.content.length;
    }
    if (chars < _largeUploadChars || !await _tokenLooksExpired()) return;
    try {
      await _authorizedRequest(
        (token) => _withNetworkRetry(
          () => _apiService.getUserSettings(
            baseUrl: state.serverUrl,
            token: token,
          ),
        ),
      );
      // Il token è valido: l'orologio locale è sbagliato. Non si ripete il controllo.
      await _clearTokenExpiry();
    } on SyncApiException catch (e) {
      if (e.statusCode == 401 || _isAccountBlocked(e)) rethrow;
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
    final savedOnline = prefs.getBool(_prefLastOnline);

    final savedServerUrl = await _secureStorage.getServerUrl() ?? '';
    final savedUsername = await _secureStorage.getUsername();
    final savedToken = await _secureStorage.getAuthToken();

    if (!mounted) return;

    final hasToken = savedToken != null && savedToken.isNotEmpty;
    // All'avvio non far lampeggiare l'indicatore giallo se l'ultima sessione
    // era Online: il check di raggiungibilità parte subito dopo e correggerà
    // lo stato se il server non risponde. Senza un valore salvato (primo
    // avvio della 1.0.3) si parte ottimisticamente Online quando c'è una
    // sessione, esattamente come dopo una login riuscita.
    final initialOnline =
        hasToken && savedServerUrl.isNotEmpty ? (savedOnline ?? true) : false;
    _lastPersistedOnline = initialOnline;

    state = state.copyWith(
      syncOnAppLaunch: launchSync,
      syncOnAppLifecycle: lifecycleSync,
      syncOnNoteSwitch: noteSwitchSync,
      syncOnInactivity: inactivitySync,
      inactivitySeconds: inactivitySeconds.clamp(10, 300),
      serverUrl: savedServerUrl,
      username: () => savedUsername,
      isAuthenticated: hasToken,
      isOnline: initialOnline,
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

  /// L'account è stato bloccato dall'amministratore. Il server risponde 403
  /// con un codice stabile: non va confuso con un 401 (sessione scaduta) né
  /// con un 429 (rate limit temporaneo).
  bool _isAccountBlocked(Object error) =>
      error is SyncApiException &&
      error.statusCode == 403 &&
      error.code == 'account_blocked';

  /// True when the error represents a connectivity/timeout problem (as
  /// opposed to an authenticated/HTTP-level error), and therefore eligible
  /// for the automatic retry mechanism.
  bool _isTransientNetworkError(Object error) {
    if (error is SyncApiException) {
      // A SyncApiException with no status code means the request never
      // reached / completed against the server in a way that produced an
      // HTTP response (e.g. wrapped timeout), so treat it as transient.
      // 503 (server occupato) e 429 (rate limit) sono transitori; per il
      // secondo `_retryDelayFor` rispetta Retry-After.
      return error.statusCode == null ||
          error.statusCode == 503 ||
          error.statusCode == 429;
    }
    // Anything else (SocketException, TimeoutException, http.ClientException,
    // etc.) reaching this point means the request itself failed at the
    // transport level.
    return true;
  }

  /// Vero se il server ha prodotto una risposta HTTP, anche se di errore.
  /// Serve a distinguere "server irraggiungibile" da "server raggiunto ma in
  /// errore": il 400 locale di `_cleanUrl` (URL non valido) non è una risposta.
  bool _serverRespondedTo(Object error) {
    if (error is SyncApiException) {
      final status = error.statusCode;
      return status != null && status != 400;
    }
    return error is FormatException;
  }

  /// Errori ritentabili del login: trasporto/timeout e risposte transitorie.
  /// Credenziali errate, URL non valido, richiesta rifiutata o risposta
  /// malformata non devono essere ritentati.
  bool _isRetryableLoginError(Object error) {
    if (error is SyncApiException) {
      final status = error.statusCode;
      if (status == null) return true;
      return status == 408 ||
          status == 425 ||
          status == 429 ||
          status == 500 ||
          status == 503 ||
          status == 504;
    }
    return error is! FormatException;
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

  /// Login interattivo con budget complessivo di [_loginBudget]. Ritenta solo
  /// gli errori transitori, usando il tempo residuo come timeout del singolo
  /// tentativo: superato il budget il pulsante torna attivo e l'errore è
  /// visibile.
  Future<LoginResponseDto> _loginWithRetry({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final deadline = DateTime.now().add(_loginBudget);
    Object lastError =
        const SyncApiException('Errore di connessione sconosciuto');

    for (var attempt = 1; attempt <= _maxRetryAttempts; attempt++) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;

      try {
        return await _apiService
            .login(
              baseUrl: serverUrl,
              username: username,
              password: password,
            )
            .timeout(remaining);
      } catch (e) {
        lastError = e;
        if (!_isRetryableLoginError(e) || attempt == _maxRetryAttempts) {
          rethrow;
        }
        final delay = _retryDelayFor(attempt, e);
        if (deadline.difference(DateTime.now()) <= delay) {
          rethrow;
        }
        await _retryWait(delay);
      }
    }

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
    _rememberOnline(isOnline);
    return isOnline;
  }

  static String _normalizedServerUrl(String url) =>
      url.trim().replaceAll(RegExp(r'/+$'), '');

  static String _accountIdentity(String serverUrl, String userId) =>
      '${_normalizedServerUrl(serverUrl)}|$userId';

  /// Cambio account: i dati locali dell'utenza precedente non devono essere
  /// mostrati né spinti sul server della nuova. Si cancellano note, cartelle
  /// e stato di sync (cursore compreso) e si azzerano i notifier; restano
  /// invece le preferenze di aspetto, che non appartengono a un account.
  Future<void> _resetForAccountSwitch(String newIdentity) async {
    _resyncRequested = false;
    _inactivityTimer?.cancel();
    _noteSwitchDebounceTimer?.cancel();
    _folderStructureDebounceTimer?.cancel();
    _capsByUrl.clear();

    // Attende anche le scritture di cartelle già accodate: una cascade o un
    // upsert partito prima del reset non deve scrivere dopo la cancellazione.
    await _ref.read(folderProvider.notifier).flushPendingWrites();
    // Annulla/attende l'autosave prima della cancellazione: un upsert tardivo
    // riscriverebbe una nota appena eliminata.
    await _ref.read(notesProvider.notifier).prepareForAccountReset();
    await _notesDao.hardDeleteAll();
    await _foldersDao.hardDeleteAll();
    await _syncMetaDao.clearSyncState(accountIdentity: newIdentity);

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefLastSyncTime);

    await _ref.read(folderProvider.notifier).refreshFromDb();
    await _ref.read(notesProvider.notifier).refreshFromDb();

    if (mounted) {
      state = state.copyWith(
        lastSyncTime: () => null,
        lastSyncMessage: () => null,
        lastError: () => null,
      );
    }
  }

  String _loginErrorMessage(Object error) {
    if (error is SyncApiException) return error.message;
    if (error is TimeoutException) {
      return 'Tempo scaduto durante la connessione al server';
    }
    if (error is FormatException) return 'Risposta del server non valida';
    return 'Impossibile connettersi al server. Controlla la connessione e riprova.';
  }

  Future<bool> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    // Se il login parte mentre `_init` sta ancora leggendo le credenziali
    // salvate, senza questa attesa `_init` potrebbe applicare per ultimo lo
    // stato del vecchio account (o `isAuthenticated: false`) sopra quello
    // appena impostato dal login.
    await initialized;
    if (!mounted) return false;
    final generation = ++_sessionGeneration;
    state = state.copyWith(
      isSyncing: true,
      lastError: () => null,
      serverUrl: serverUrl,
    );

    try {
      // Login interattivo: budget complessivo di 10 s. Gli errori transitori
      // (timeout, rete, 429/500/503/504) vengono ritentati finché c'è tempo;
      // credenziali errate e altri errori definitivi si fermano subito.
      final response = await _loginWithRetry(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );
      // Un secondo login (o un logout) è partito mentre questa richiesta era
      // in volo: non sovrascrivere credenziali e stato della sessione nuova.
      if (!_isCurrentSession(generation)) return false;

      final applied = await _withSessionWriteLock(() async {
        if (!_isCurrentSession(generation)) return false;

        final newIdentity = _accountIdentity(serverUrl, response.userId);
        final previousIdentity = await _syncMetaDao.getAccountIdentity();
        String? previousUserId;
        try {
          previousUserId = await _secureStorage.getUserId();
        } catch (_) {}
        final previousUrl = await _secureStorage.getServerUrl();

        // `previousIdentity` è la fonte nuova; il confronto con userId/URL
        // salvati copre chi arriva da una versione precedente (dove
        // l'identità in `sync_meta` non esisteva ancora).
        final switchedByIdentity =
            previousIdentity != null && previousIdentity != newIdentity;
        final switchedByLegacy = previousIdentity == null &&
            previousUserId != null &&
            previousUserId.isNotEmpty &&
            (previousUserId != response.userId ||
                _normalizedServerUrl(previousUrl ?? '') !=
                    _normalizedServerUrl(serverUrl));
        if (switchedByIdentity || switchedByLegacy) {
          await _resetForAccountSwitch(newIdentity);
        } else {
          await _syncMetaDao.setAccountIdentity(newIdentity);
        }
        if (!_isCurrentSession(generation)) return false;

        // Prima il refresh token, poi l'access token: se il processo muore
        // fra le due scritture, il refresh resta utilizzabile al riavvio.
        await _secureStorage.saveRefreshToken(response.refreshToken);
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
        _rememberOnline(true);
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
        // Se il server ha risposto (401, 429, 500...) siamo Online anche se il
        // login è fallito; Offline solo quando la richiesta non è arrivata.
        final nextOnline = _serverRespondedTo(e);
        state = state.copyWith(
          isAuthenticated: false,
          isOnline: nextOnline,
          isSyncing: false,
          lastError: () => _loginErrorMessage(e),
        );
        _rememberOnline(nextOnline);
      }
      return false;
    }
  }

  Future<void> logout() async {
    final generation = ++_sessionGeneration;
    _ref.read(settingsProvider.notifier).discardPendingPush();
    _inactivityTimer?.cancel();
    _noteSwitchDebounceTimer?.cancel();
    _folderStructureDebounceTimer?.cancel();
    _stopConnectivityWatchdog();

    // Revoca il token anche lato server (best effort, non lancia): senza
    // questo il JWT resterebbe valido fino a scadenza anche dopo il logout.
    // Il refresh token permette al server di chiudere la famiglia anche se
    // l'access token è già scaduto.
    final token = await _secureStorage.getAuthToken();
    final refreshToken = await _secureStorage.getRefreshToken();
    final url = state.serverUrl;
    if (token != null && token.isNotEmpty && url.isNotEmpty) {
      await _apiService.logout(
        baseUrl: url,
        token: token,
        refreshToken: refreshToken,
      );
    }

    await _finishLogout(generation);
  }

  /// Chiude tutte le sessioni dell'utente, su ogni dispositivo. Prova prima
  /// la revoca lato server (con refresh automatico se l'access token è
  /// scaduto), poi chiude comunque la sessione locale.
  Future<bool> logoutAllDevices() async {
    final generation = _sessionGeneration;
    _ref.read(settingsProvider.notifier).discardPendingPush();
    _inactivityTimer?.cancel();
    _noteSwitchDebounceTimer?.cancel();
    _folderStructureDebounceTimer?.cancel();
    _stopConnectivityWatchdog();

    final url = state.serverUrl;
    var revoked = false;
    if (url.isNotEmpty) {
      try {
        revoked = await _authorizedRequest(
          (token) => _apiService.logoutAll(baseUrl: url, token: token),
        );
      } catch (_) {
        // La sessione locale viene chiusa comunque: l'utente ha chiesto di
        // uscire. Il chiamante usa `revoked` per distinguere l'avviso.
      }
    }

    // Un login partito durante la revoca ha la precedenza: non cancellare le
    // sue credenziali.
    if (!_isCurrentSession(generation)) return revoked;
    final endedGeneration = ++_sessionGeneration;
    await _finishLogout(endedGeneration);
    return revoked;
  }

  Future<void> _finishLogout(int generation) async {
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
      if (!mounted) return;
      unawaited(() async {
        // La UI aggiorna lo stato in modo sincrono ma la scrittura SQLite è
        // accodata: senza questa attesa la sync può leggere `dirty` prima
        // che la nuova cartella/rinomina sia davvero persistita.
        await _ref.read(folderProvider.notifier).flushPendingWrites();
        if (mounted) await triggerSync();
      }());
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
    final triggerId = ++_syncTriggerId;
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
      if (mounted && _syncTriggerId == triggerId && state.isSyncing) {
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

    // Scrive il testo ancora in debounce (500 ms) e le mutazioni di cartelle
    // già accodate prima di leggere le righe dirty, così anche l'ultima
    // modifica rientra in questo giro.
    await _ref.read(notesProvider.notifier).flushPendingSaves();
    await _ref.read(folderProvider.notifier).flushPendingWrites();
    if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
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
        await _verifyTokenBeforeLargeUpload(dirtyNotes);
        if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
          return false;
        }

        final SyncResponse response;
        try {
          response = await _authorizedRequest(
            (token) => _withNetworkRetry(
              () => _apiService.sync(
                baseUrl: serverUrl,
                token: token,
                lastSyncedAt: cursor,
                folders: dirtyFolders.map(_toFolderDto).toList(),
                notes: dirtyNotes.map(_toNoteDto).toList(),
              ),
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

        // Tutte le scritture derivate dalla risposta avvengono sotto il lock
        // di sessione: il reset per cambio account non può cancellare il DB
        // nel mezzo, e ogni await ricontrolla la generazione per non applicare
        // dati della sessione precedente a quella nuova.
        final applied = await _withSessionWriteLock(() async {
          if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
            return false;
          }

          // Y-14: capability annunciate dal server in QUESTA risposta (assenti
          // = server senza caps: nessuna funzione opzionale).
          _rememberServerCaps(serverUrl, response.caps);

          // 1) Righe inviate -> pulite (solo se non ri-modificate durante il
          //    round-trip). 2) Applica la risposta (che include anche la
          //    versione del server per i conflitti persi). Ordine importante:
          //    markSynced prima, così l'eco del server sostituisce le righe.
          await _foldersDao
              .markSynced({for (final f in dirtyFolders) f.id: f.updatedAt});
          await _notesDao
              .markSynced({for (final n in dirtyNotes) n.id: n.updatedAt});

          if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
            return false;
          }

          await _foldersDao.applyRemoteLWWBatch(
              response.folders.map(_fromFolderDto).toList());
          await _notesDao
              .applyRemoteLWWBatch(response.notes.map(_fromNoteDto).toList());

          if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
            return false;
          }

          if (response.fullResync) {
            // Un full_resync VUOTO su un dispositivo che ha dati locali è
            // quasi sempre una risposta anomala (server appena inizializzato,
            // errore di account, backup parziale): cancellare tutto in blocco
            // sarebbe irreversibile. Si conserva il locale e si segnala
            // l'anomalia; il cursore non avanza, quindi il prossimo giro
            // riproverà.
            if (response.folders.isEmpty &&
                response.notes.isEmpty &&
                (await _foldersDao.getActive()).isNotEmpty) {
              throw const SyncApiException(
                'Il server ha restituito un archivio vuoto: dati locali conservati.',
                502,
              );
            }
            if (response.folders.isEmpty &&
                response.notes.isEmpty &&
                (await _notesDao.getActive()).isNotEmpty) {
              throw const SyncApiException(
                'Il server ha restituito un archivio vuoto: dati locali conservati.',
                502,
              );
            }

            // Cursore più vecchio della retention dei tombstone del server:
            // la risposta è lo stato completo. Le righe pulite che il server
            // non elenca sono state eliminate mentre eravamo offline.
            await _foldersDao
                .deleteCleanNotIn({for (final f in response.folders) f.id});
            await _notesDao
                .deleteCleanNotIn({for (final n in response.notes) n.id});
          }

          // Tombstone locali ormai inutili (confermati dal server o ricevuti
          // da lui): eliminati fisicamente, non si accumulano nel DB locale.
          await _foldersDao.purgeCleanTombstones();
          await _notesDao.purgeCleanTombstones();

          await _syncMetaDao.setSyncCursor(response.serverTime);

          if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
            return false;
          }

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
          await prefs.setInt(
              _prefLastSyncTime, syncedAt.millisecondsSinceEpoch);

          if (!_isCurrentSession(generation) ||
              serverUrl != state.serverUrl ||
              !mounted) {
            return false;
          }
          state = state.copyWith(
            isOnline: true,
            isSyncing: false,
            lastSyncTime: () => syncedAt,
            lastSyncMessage: () =>
                'Sincronizzato (${dirtyFolders.length + dirtyNotes.length} inviate, ${response.folders.length + response.notes.length} ricevute)',
            lastError: () => null,
          );
          return true;
        });
        if (!applied) return false;
        _rememberOnline(true);
        return true;
      }
      return false; // irraggiungibile: il ciclo ritorna o lancia
    } catch (e) {
      // Un errore (anche 401) della sessione precedente non deve toccare la
      // sessione nuova.
      if (!_isCurrentSession(generation)) return false;
      final isAuthError = e is SyncApiException && e.statusCode == 401;
      final isBlocked = _isAccountBlocked(e);
      final isRejected = e is SyncApiException && e.statusCode == 422;
      final isRateLimited = e is SyncApiException && e.statusCode == 429;
      // 502 = risposta 200 non decodificabile: il server ha risposto, quindi
      // non è offline; il messaggio deve dire che il problema è la risposta.
      final isBadResponse = e is SyncApiException && e.statusCode == 502;
      // Un errore di SQLite locale non dice nulla sulla raggiungibilità del
      // server: prima veniva mostrato come "server non raggiungibile".
      final isLocalDbError = e is DatabaseException;
      final isServerBusy = e is SyncApiException && e.statusCode == 503;
      if (isLocalDbError) {
        debugPrint('SyncNotifier: errore del database locale: $e');
      }
      // Qualunque risposta HTTP (401, 422, 429, 500, 502, 503...) prova che il
      // server è raggiungibile: l'indicatore resta Online. Offline solo per
      // timeout/trasporto. Un errore DB locale non cambia la raggiungibilità.
      final nextOnline = _serverRespondedTo(e)
          ? true
          : isLocalDbError
              ? state.isOnline
              : false;
      state = state.copyWith(
        isAuthenticated:
            isAuthError || isBlocked ? false : state.isAuthenticated,
        isOnline: nextOnline,
        isSyncing: false,
        lastError: () => e is SyncApiException ? e.message : e.toString(),
        lastSyncMessage: () => isBlocked
            ? 'Account bloccato: contatta l\'amministratore'
            : isAuthError
                ? 'Sessione scaduta: effettua nuovamente l\'accesso'
                : isRateLimited
                    ? 'Sincronizzazione non riuscita: limite di richieste raggiunto, riprova tra poco'
                    : isRejected
                        ? 'Sincronizzazione non riuscita: alcuni elementi non sono validi per il server'
                        : isBadResponse
                            ? 'Sincronizzazione non riuscita: risposta del server non valida'
                            : isLocalDbError
                                ? 'Sincronizzazione non riuscita: errore del database locale'
                                : isServerBusy
                                    ? 'Sincronizzazione non riuscita: server temporaneamente occupato'
                                    : e is SyncApiException &&
                                            e.statusCode != null
                                        ? 'Sincronizzazione non riuscita: errore del server'
                                        : 'Sincronizzazione non riuscita: server non raggiungibile',
      );
      _rememberOnline(nextOnline);
      if (isAuthError || isBlocked) {
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
  ///
  /// Gli id non validi si riparano PRIMA dei riferimenti: se il server ha
  /// rifiutato sia una cartella sia una nota che la referenzia, rimappare
  /// l'id per primo evita di spostare inutilmente la nota alla radice.
  Future<void> _repairRejected(List<SyncRejectedItem> rejected) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;

    for (final r in rejected.where((r) => r.reason == 'invalid_id')) {
      // L'id non è valido per il server (es. riga importata/corrotta da una
      // vecchia versione): il contenuto resta, cambia solo la chiave. Il
      // replaceId rimappa già figli e note di una cartella.
      if (r.kind == 'note') {
        await _notesDao.replaceId(r.id, _uuid.v4());
      } else if (r.kind == 'folder') {
        await _foldersDao.replaceId(r.id, _uuid.v4(), now);
      }
    }

    for (final r in rejected.where((r) => r.reason != 'invalid_id')) {
      if (r.kind == 'note') {
        final row = await _notesDao.getById(r.id);
        final folderId = row?.folderId;
        if (row == null || folderId == null) continue;
        // Se la cartella esiste ancora (magari appena riparata in questa
        // stessa passata), il riferimento è valido: spostare la nota alla
        // radice perderebbe un'associazione che il retry può salvare.
        final folder = await _foldersDao.getById(folderId);
        if (folder == null || folder.deletedAt != null) {
          await _notesDao.upsert(row.copyWith(folderId: null, updatedAt: now));
        }
      } else if (r.kind == 'folder') {
        final row = await _foldersDao.getById(r.id);
        final parentId = row?.parentId;
        if (row == null || parentId == null) continue;
        final parent = await _foldersDao.getById(parentId);
        if (parent == null || parent.deletedAt != null) {
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

    final mark = _reachabilityMark();
    final settingsRevision = _ref.read(settingsProvider.notifier).revision;
    try {
      final remoteSettings = await _authorizedRequest(
        (token) => _withNetworkRetry(
          () => _apiService.getUserSettings(
            baseUrl: serverUrl,
            token: token,
          ),
        ),
      );
      if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
        return;
      }
      _networkSuccessCount++;
      unawaited(_ref.read(settingsProvider.notifier).applyRemoteSettings(
            remoteSettings,
            expectedRevision: settingsRevision,
          ));
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
      } else if (e is SyncApiException && _isAccountBlocked(e)) {
        state = state.copyWith(
          isAuthenticated: false,
          lastError: () => e.message,
          lastSyncMessage: () => 'Account bloccato: contatta l\'amministratore',
        );
        await _endSession(generation);
      } else if (!_reachedServerSince(mark)) {
        // Se nel frattempo un'altra richiesta è riuscita (all'avvio gira in
        // parallelo alla sync), questo fallimento è vecchio: vedi
        // [_reachabilityMark]. Se invece il server ha risposto con un errore,
        // resta Online: non è un problema di raggiungibilità.
        final nextOnline = _serverRespondedTo(e);
        state = state.copyWith(isOnline: nextOnline);
        _rememberOnline(nextOnline);
      }
    }
  }

  /// Sends updated preferences to PUT /api/v1/user/settings.
  ///
  /// Ritorna `true` solo se il server ha accettato il payload. Il chiamante
  /// (SettingsNotifier) usa l'esito per NON perdere una modifica quando il
  /// push fallisce o la sessione cambia nel frattempo.
  Future<bool> pushUserSettings(UserSettingsDto settings) async {
    if (!state.isAuthenticated) return false;
    final generation = _sessionGeneration;
    final serverUrl = state.serverUrl;

    try {
      await _authorizedRequest(
        (token) => _withNetworkRetry(
          () => _apiService.updateUserSettings(
            baseUrl: serverUrl,
            token: token,
            settings: settings,
          ),
        ),
      );
      return _isCurrentSession(generation) && serverUrl == state.serverUrl;
    } catch (e) {
      if (!_isCurrentSession(generation) || serverUrl != state.serverUrl) {
        return false;
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
      } else if (e is SyncApiException && _isAccountBlocked(e)) {
        state = state.copyWith(
          isAuthenticated: false,
          lastError: () => e.message,
          lastSyncMessage: () => 'Account bloccato: contatta l\'amministratore',
        );
        await _endSession(generation);
      } else {
        final nextOnline = _serverRespondedTo(e);
        state = state.copyWith(isOnline: nextOnline);
        _rememberOnline(nextOnline);
      }
      return false;
    }
  }
}

final syncProvider = StateNotifierProvider<SyncNotifier, SyncConfig>((ref) {
  final apiService = ref.watch(syncApiServiceProvider);
  final secureStorage = ref.watch(secureStorageProvider);
  return SyncNotifier(ref, apiService, secureStorage);
});
