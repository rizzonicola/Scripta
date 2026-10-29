import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3: StateNotifier/StateNotifierProvider sono "legacy" (non
// rimossi, ma spostati fuori dall'API principale) per scoraggiarne l'uso a
// favore di Notifier/AsyncNotifier. Qui la classe resta volutamente una
// StateNotifier: la logica di persistenza/push verso il server (vedi
// _pushRemoteSettings/applyRemoteSettings) è delicata e già corretta, quindi
// viene preservata 1:1 — la migrazione riguarda solo l'import necessario a
// compilare sotto Riverpod 3.
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/haptics_helper.dart';
import '../../sync/models/sync_models.dart';
import '../../sync/providers/sync_provider.dart';
import '../models/app_settings.dart';

/// Legge le impostazioni di aspetto da SharedPreferences. Funzione PURA e unica
/// fonte di chiavi e valori di default: la usano sia il caricamento prima del
/// primo frame ([loadSettingsSnapshot]) sia quello asincrono di
/// [SettingsNotifier], così i due non possono divergere.
AppSettings readAppSettingsFromPrefs(SharedPreferences prefs) {
  final themeStr = prefs.getString(AppConstants.prefThemeMode);
  final themeMode = themeStr == 'dark'
      ? ThemeMode.dark
      : themeStr == 'light'
      ? ThemeMode.light
      : ThemeMode.system;

  final themeId = prefs.getString(AppConstants.prefThemeId) ?? 'dark_teal';

  final langCode = prefs.getString(AppConstants.prefLocale);
  final locale = (langCode != null && langCode.isNotEmpty)
      ? Locale(langCode)
      : null;

  final fontFamily = prefs.getString(AppConstants.prefFontFamily) ?? 'Inter';
  final fontSize = prefs.getDouble(AppConstants.prefFontSize) ?? 16.0;
  final lineHeight = prefs.getDouble(AppConstants.prefLineHeight) ?? 1.6;

  final hapticStr = prefs.getString(AppConstants.prefHapticIntensity);
  final hapticIntensity = HapticIntensity.values.firstWhere(
    (v) => v.name == hapticStr,
    orElse: () => HapticIntensity.light,
  );

  return AppSettings(
    themeMode: themeMode,
    selectedThemeId: themeId,
    locale: locale,
    fontFamily: fontFamily,
    fontSize: fontSize,
    lineHeight: lineHeight,
    hapticIntensity: hapticIntensity,
  );
}

/// Legge le impostazioni PRIMA del primo frame (chiamata da `main()`, come
/// `SessionStateService.load`). Usa la stessa `SharedPreferences.getInstance()`
/// già attesa per la sessione (l'istanza è in cache: nessun I/O in più).
///
/// PERCHÉ: `SettingsNotifier` è sincrono. Se partisse sempre dai default e
/// caricasse dopo, chi ha tema, lingua o font personalizzati vedrebbe un primo
/// frame col tema di default (flash) e poi un secondo, con due costruzioni
/// complete dei temi e di `MaterialApp`.
///
/// Non lancia mai: con preferenze illeggibili restituisce `null` e il notifier
/// ripiega sul caricamento asincrono di prima.
Future<AppSettings?> loadSettingsSnapshot() async {
  try {
    return readAppSettingsFromPrefs(await SharedPreferences.getInstance());
  } catch (_) {
    // Nessun log: è lo stesso errore che incontrerebbe `_loadSettings`, che
    // viene eseguito comunque quando l'istantanea manca.
    return null;
  }
}

/// Impostazioni lette all'avvio da `main()`. `null` (default, anche nei test
/// senza override) = nessuna istantanea: il notifier parte dai default e
/// carica da SharedPreferences in modo asincrono, come prima.
///
/// CACHE: l'istantanea è solo il valore INIZIALE dello stato e non si invalida
/// mai: da lì in poi vale lo stato del notifier, aggiornato come prima dai
/// setter e da `applyRemoteSettings`. Se il dato è "vecchio" l'utente vede, al
/// più, per qualche istante le impostazioni locali precedenti, finché le
/// remote (che arrivano dopo ≥ 500 ms) le aggiornano, come già accadeva. Non
/// può causare perdite né sovrascritture: sono 7 preferenze di aspetto (non
/// note né cartelle), la lettura non scrive nulla e il push al server parte
/// solo dai setter, mai dalla costruzione dello stato.
final settingsSnapshotProvider = Provider<AppSettings?>((ref) => null);

class SettingsNotifier extends StateNotifier<AppSettings> {
  /// Attesa prima di inviare al server le impostazioni "di aspetto". Gli
  /// slider (dimensione font, interlinea) chiamano il setter a ogni
  /// variazione: senza debounce un singolo trascinamento produceva decine di
  /// PUT, e risposte in ordine diverso da quello di invio potevano lasciare
  /// sul server un valore intermedio invece dell'ultimo.
  static const Duration _remotePushDebounce = Duration(milliseconds: 400);
  static const Duration _remotePushRetryDelay = Duration(seconds: 5);

  final Ref? _ref;
  Timer? _remotePushTimer;
  Timer? _remotePushRetryTimer;

  /// Vero se esiste una modifica non ancora inviata al server. Flag esplicito
  /// invece di `Timer.isActive`: dentro il callback del timer stesso il suo
  /// valore dipende dall'implementazione, e un falso negativo farebbe
  /// scartare l'invio.
  bool _remotePushPending = false;

  /// Ultimo payload da inviare. Se durante una PUT arrivano altre modifiche,
  /// il payload più recente sostituisce quello in coda: niente invii
  /// concorrenti fuori ordine, e nessuna modifica persa.
  UserSettingsDto? _queuedPayload;
  bool _remotePushInFlight = false;

  /// Incrementato ad ogni modifica locale di aspetto. Una GET partita prima
  /// della modifica non deve applicare la risposta remota sopra quella locale.
  int _localRevision = 0;

  int get revision => _localRevision;

  /// Cambia quando la sessione viene chiusa: una PUT già in volo non deve
  /// riaccodare le impostazioni dell'account precedente per inviarle al
  /// successivo.
  int _pushEpoch = 0;

  @visibleForTesting
  bool get hasPendingRemotePush =>
      _remotePushPending || _queuedPayload != null || _remotePushInFlight;

  /// [initial]: impostazioni già lette prima del primo frame (vedi
  /// [loadSettingsSnapshot]). Se presenti il notifier parte già dallo stato
  /// giusto e NON ricarica (rileggerebbe gli stessi valori); se assenti carica
  /// in modo asincrono partendo dai default, come sempre.
  SettingsNotifier([this._ref, AppSettings? initial])
    : super(initial ?? const AppSettings()) {
    if (initial == null) _loadSettings();
  }

  @override
  void dispose() {
    _remotePushTimer?.cancel();
    _remotePushRetryTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    state = readAppSettingsFromPrefs(prefs);
  }

  /// Pianifica l'invio al server dello stato CORRENTE (debounced: vince
  /// sempre l'ultimo valore).
  void _pushRemoteSettings() {
    _localRevision++;
    if (_ref == null) return;
    _remotePushPending = true;
    _remotePushTimer?.cancel();
    _remotePushTimer = Timer(_remotePushDebounce, flushRemotePush);
  }

  /// Invia subito l'eventuale invio in attesa. Chiamato anche quando l'app va
  /// in background ([SyncNotifier.onAppPaused]): all'avvio successivo le
  /// impostazioni remote prevalgono su quelle locali, quindi un invio perso
  /// per la chiusura dell'app durante il debounce farebbe "tornare indietro"
  /// l'ultima modifica.
  void flushRemotePush() {
    final ref = _ref;
    if (ref == null || !mounted || !_remotePushPending) return;
    _remotePushTimer?.cancel();
    _remotePushTimer = null;

    final themeStr = state.themeMode == ThemeMode.dark
        ? 'dark'
        : state.themeMode == ThemeMode.light
        ? 'light'
        : 'system';

    _queuedPayload = UserSettingsDto(
      theme: themeStr,
      colorScheme: state.selectedThemeId,
      language: state.locale?.languageCode ?? 'it',
      fontFamily: state.fontFamily,
      fontSize: state.fontSize.toInt(),
      lineSpacing: state.lineHeight,
      layout: 'split',
    );
    _remotePushPending = true;
    unawaited(_drainRemotePush());
  }

  /// Scarta un invio rimasto in sospeso quando la sessione finisce. Le
  /// preferenze locali restano applicate, ma non vengono attribuite a un
  /// account diverso al login successivo.
  void discardPendingPush() {
    _pushEpoch++;
    _remotePushTimer?.cancel();
    _remotePushTimer = null;
    _remotePushRetryTimer?.cancel();
    _remotePushRetryTimer = null;
    _queuedPayload = null;
    _remotePushPending = false;
    // Invalida anche le GET delle impostazioni partite prima della chiusura.
    _localRevision++;
  }

  Future<void> _drainRemotePush() async {
    final epoch = _pushEpoch;
    final ref = _ref;
    if (ref == null || !mounted || _remotePushInFlight) return;
    _remotePushInFlight = true;
    try {
      while (mounted && epoch == _pushEpoch && _queuedPayload != null) {
        final payload = _queuedPayload!;
        _queuedPayload = null;
        final sent = await ref
            .read(syncProvider.notifier)
            .pushUserSettings(payload);
        if (!mounted || epoch != _pushEpoch) return;
        if (!sent) {
          // Conserva il payload più recente (potrebbe essere arrivato mentre
          // la PUT era in volo) e ritenta più tardi, ma solo se c'è ancora una
          // sessione: da disconnessi non ha senso martellare il server.
          _queuedPayload ??= payload;
          _remotePushPending = true;
          if (ref.read(syncProvider).isAuthenticated) {
            _scheduleRemotePushRetry();
          }
          return;
        }
        if (_queuedPayload == null) {
          _remotePushPending = false;
        }
      }
    } finally {
      _remotePushInFlight = false;
    }
    if (epoch == _pushEpoch && _queuedPayload != null) {
      _scheduleRemotePushRetry();
    }
  }

  void _scheduleRemotePushRetry() {
    if (_remotePushRetryTimer?.isActive ?? false) return;
    _remotePushRetryTimer = Timer(_remotePushRetryDelay, () {
      _remotePushRetryTimer = null;
      if (mounted && _remotePushPending) flushRemotePush();
    });
  }

  Future<void> applyRemoteSettings(
    UserSettingsDto remote, {
    int? expectedRevision,
  }) async {
    // Una modifica locale (o un push ancora in coda) vince sulla fotografia
    // remota: applicarla qui la sovrascriverebbe silenziosamente.
    if (_remotePushPending || _remotePushInFlight || _queuedPayload != null) {
      return;
    }
    if (expectedRevision != null && expectedRevision != _localRevision) {
      return;
    }
    if (!mounted) return;

    final themeMode = remote.theme == 'dark'
        ? ThemeMode.dark
        : remote.theme == 'light'
        ? ThemeMode.light
        : ThemeMode.system;

    final locale = remote.language.isNotEmpty ? Locale(remote.language) : null;

    state = state.copyWith(
      themeMode: themeMode,
      selectedThemeId: remote.colorScheme.isNotEmpty
          ? remote.colorScheme
          : state.selectedThemeId,
      locale: () => locale,
      fontFamily: remote.fontFamily.isNotEmpty
          ? remote.fontFamily
          : state.fontFamily,
      fontSize: remote.fontSize > 0
          ? remote.fontSize.toDouble()
          : state.fontSize,
      lineHeight: remote.lineSpacing > 0
          ? remote.lineSpacing
          : state.lineHeight,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefThemeMode, remote.theme);
    await prefs.setString(AppConstants.prefThemeId, state.selectedThemeId);
    if (locale != null) {
      await prefs.setString(AppConstants.prefLocale, locale.languageCode);
    } else {
      await prefs.remove(AppConstants.prefLocale);
    }
    await prefs.setString(AppConstants.prefFontFamily, state.fontFamily);
    await prefs.setDouble(AppConstants.prefFontSize, state.fontSize);
    await prefs.setDouble(AppConstants.prefLineHeight, state.lineHeight);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AppConstants.prefThemeMode,
      mode == ThemeMode.dark
          ? 'dark'
          : mode == ThemeMode.light
          ? 'light'
          : 'system',
    );
    _pushRemoteSettings();
  }

  Future<void> setThemeId(String themeId) async {
    state = state.copyWith(selectedThemeId: themeId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefThemeId, themeId);
    _pushRemoteSettings();
  }

  Future<void> setLocale(Locale? locale) async {
    state = state.copyWith(locale: () => locale);
    final prefs = await SharedPreferences.getInstance();
    if (locale == null) {
      await prefs.remove(AppConstants.prefLocale);
    } else {
      await prefs.setString(AppConstants.prefLocale, locale.languageCode);
    }
    _pushRemoteSettings();
  }

  Future<void> setFontFamily(String family) async {
    state = state.copyWith(fontFamily: family);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefFontFamily, family);
    _pushRemoteSettings();
  }

  Future<void> setFontSize(double size) async {
    state = state.copyWith(fontSize: size);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(AppConstants.prefFontSize, size);
    _pushRemoteSettings();
  }

  Future<void> setLineHeight(double height) async {
    state = state.copyWith(lineHeight: height);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(AppConstants.prefLineHeight, height);
    _pushRemoteSettings();
  }

  /// Impostazione puramente locale (non fa parte del payload di sync
  /// remoto): il feedback tattile è una preferenza legata al dispositivo
  /// fisico in uso, non un'impostazione "di aspetto" condivisibile tra
  /// account/dispositivi diversi.
  Future<void> setHapticIntensity(HapticIntensity intensity) async {
    state = state.copyWith(hapticIntensity: intensity);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefHapticIntensity, intensity.name);
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>((
  ref,
) {
  // `read` e non `watch`: l'istantanea è fissata una volta all'avvio e non
  // cambia mai; osservarla ricreerebbe il notifier (e perderebbe lo stato).
  return SettingsNotifier(ref, ref.read(settingsSnapshotProvider));
});
