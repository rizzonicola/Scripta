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

class SettingsNotifier extends StateNotifier<AppSettings> {
  /// Attesa prima di inviare al server le impostazioni "di aspetto". Gli
  /// slider (dimensione font, interlinea) chiamano il setter a ogni
  /// variazione: senza debounce un singolo trascinamento produceva decine di
  /// PUT, e risposte in ordine diverso da quello di invio potevano lasciare
  /// sul server un valore intermedio invece dell'ultimo.
  static const Duration _remotePushDebounce = Duration(milliseconds: 400);

  final Ref? _ref;
  Timer? _remotePushTimer;

  /// Vero se esiste una modifica non ancora inviata al server. Flag esplicito
  /// invece di `Timer.isActive`: dentro il callback del timer stesso il suo
  /// valore dipende dall'implementazione, e un falso negativo farebbe
  /// scartare l'invio.
  bool _remotePushPending = false;

  SettingsNotifier([this._ref]) : super(const AppSettings()) {
    _loadSettings();
  }

  @override
  void dispose() {
    _remotePushTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    final themeStr = prefs.getString(AppConstants.prefThemeMode);
    final themeMode = themeStr == 'dark'
        ? ThemeMode.dark
        : themeStr == 'light'
            ? ThemeMode.light
            : ThemeMode.system;

    final themeId =
        prefs.getString(AppConstants.prefThemeId) ?? 'dark_teal';

    final langCode = prefs.getString(AppConstants.prefLocale);
    final locale =
        (langCode != null && langCode.isNotEmpty) ? Locale(langCode) : null;

    final fontFamily =
        prefs.getString(AppConstants.prefFontFamily) ?? 'Inter';
    final fontSize = prefs.getDouble(AppConstants.prefFontSize) ?? 16.0;
    final lineHeight = prefs.getDouble(AppConstants.prefLineHeight) ?? 1.6;

    final hapticStr = prefs.getString(AppConstants.prefHapticIntensity);
    final hapticIntensity = HapticIntensity.values.firstWhere(
      (v) => v.name == hapticStr,
      orElse: () => HapticIntensity.light,
    );

    state = AppSettings(
      themeMode: themeMode,
      selectedThemeId: themeId,
      locale: locale,
      fontFamily: fontFamily,
      fontSize: fontSize,
      lineHeight: lineHeight,
      hapticIntensity: hapticIntensity,
    );
  }

  /// Pianifica l'invio al server dello stato CORRENTE (debounced: vince
  /// sempre l'ultimo valore).
  void _pushRemoteSettings() {
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
    _remotePushPending = false;
    _remotePushTimer?.cancel();
    _remotePushTimer = null;

    final themeStr = state.themeMode == ThemeMode.dark
        ? 'dark'
        : state.themeMode == ThemeMode.light
            ? 'light'
            : 'system';

    final payload = UserSettingsDto(
      theme: themeStr,
      colorScheme: state.selectedThemeId,
      language: state.locale?.languageCode ?? 'it',
      fontFamily: state.fontFamily,
      fontSize: state.fontSize.toInt(),
      lineSpacing: state.lineHeight,
      layout: 'split',
    );
    unawaited(ref.read(syncProvider.notifier).pushUserSettings(payload));
  }

  Future<void> applyRemoteSettings(UserSettingsDto remote) async {
    final themeMode = remote.theme == 'dark'
        ? ThemeMode.dark
        : remote.theme == 'light'
            ? ThemeMode.light
            : ThemeMode.system;

    final locale =
        remote.language.isNotEmpty ? Locale(remote.language) : null;

    state = state.copyWith(
      themeMode: themeMode,
      selectedThemeId: remote.colorScheme.isNotEmpty
          ? remote.colorScheme
          : state.selectedThemeId,
      locale: () => locale,
      fontFamily: remote.fontFamily.isNotEmpty
          ? remote.fontFamily
          : state.fontFamily,
      fontSize:
          remote.fontSize > 0 ? remote.fontSize.toDouble() : state.fontSize,
      lineHeight:
          remote.lineSpacing > 0 ? remote.lineSpacing : state.lineHeight,
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

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  return SettingsNotifier(ref);
});

