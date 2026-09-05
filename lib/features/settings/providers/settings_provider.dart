import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/constants/app_constants.dart';
import '../../sync/models/sync_models.dart';
import '../../sync/providers/sync_provider.dart';
import '../models/app_settings.dart';

class SettingsNotifier extends StateNotifier<AppSettings> {
  final Ref? _ref;

  SettingsNotifier([this._ref]) : super(const AppSettings()) {
    _loadSettings();
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

    state = AppSettings(
      themeMode: themeMode,
      selectedThemeId: themeId,
      locale: locale,
      fontFamily: fontFamily,
      fontSize: fontSize,
      lineHeight: lineHeight,
    );
  }

  void _pushRemoteSettings() {
    if (_ref == null) return;
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
    _ref.read(syncProvider.notifier).pushUserSettings(payload);
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
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  return SettingsNotifier(ref);
});

