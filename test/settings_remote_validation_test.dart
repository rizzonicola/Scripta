import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scripta/core/constants/app_constants.dart';
import 'package:scripta/features/settings/models/app_settings.dart';
import 'package:scripta/features/settings/providers/settings_provider.dart';
import 'package:scripta/features/sync/models/sync_models.dart';

Future<void> _expectPrefs({
  required String theme,
  required String themeId,
  required String fontFamily,
  required double fontSize,
  required double lineHeight,
}) async {
  final prefs = await SharedPreferences.getInstance();
  expect(prefs.getString(AppConstants.prefThemeMode), theme);
  expect(prefs.getString(AppConstants.prefThemeId), themeId);
  expect(prefs.getString(AppConstants.prefFontFamily), fontFamily);
  expect(prefs.getDouble(AppConstants.prefFontSize), fontSize);
  expect(prefs.getDouble(AppConstants.prefLineHeight), lineHeight);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('valori remoti fuori scala vengono clampati', () async {
    final notifier = SettingsNotifier(
      null,
      const AppSettings(
        themeMode: ThemeMode.dark,
        selectedThemeId: 'nord',
        fontFamily: 'Merriweather',
        fontSize: 18,
        lineHeight: 1.8,
      ),
    );
    addTearDown(notifier.dispose);

    await notifier.applyRemoteSettings(
      const UserSettingsDto(
        theme: 'light',
        colorScheme: 'dark_teal',
        language: 'it',
        fontFamily: 'Comic Sans',
        fontSize: 999,
        lineSpacing: 99,
      ),
    );

    expect(notifier.state.themeMode, ThemeMode.light);
    expect(notifier.state.fontFamily, 'Merriweather');
    expect(notifier.state.fontSize, AppConstants.maxFontSize);
    expect(notifier.state.lineHeight, AppConstants.maxLineHeight);

    await _expectPrefs(
      theme: 'light',
      themeId: 'dark_teal',
      fontFamily: 'Merriweather',
      fontSize: AppConstants.maxFontSize,
      lineHeight: AppConstants.maxLineHeight,
    );
  });

  test('valori remoti non validi ripiegano sui limiti o sullo stato', () async {
    final notifier = SettingsNotifier(
      null,
      const AppSettings(
        themeMode: ThemeMode.dark,
        selectedThemeId: 'nord',
        fontFamily: 'Inter',
        fontSize: 16,
        lineHeight: 1.6,
      ),
    );
    addTearDown(notifier.dispose);

    await notifier.applyRemoteSettings(
      const UserSettingsDto(
        theme: 'sconosciuto',
        colorScheme: 'palette_inesistente',
        language: 'it',
        fontFamily: 'Font Inesistente',
        fontSize: 0,
        lineSpacing: 0,
      ),
    );

    expect(notifier.state.themeMode, ThemeMode.system);
    expect(notifier.state.selectedThemeId, 'nord');
    expect(notifier.state.fontFamily, 'Inter');
    expect(notifier.state.fontSize, AppConstants.minFontSize);
    expect(notifier.state.lineHeight, AppConstants.minLineHeight);

    await _expectPrefs(
      theme: 'system',
      themeId: 'nord',
      fontFamily: 'Inter',
      fontSize: AppConstants.minFontSize,
      lineHeight: AppConstants.minLineHeight,
    );
  });

  test('la lingua Sistema viene sincronizzata come valore dedicato', () async {
    expect(encodeRemoteLanguage(null), AppConstants.remoteLanguageSystem);
    expect(encodeRemoteLanguage(const Locale('fr')), 'fr');

    final notifier = SettingsNotifier(
      null,
      const AppSettings(locale: Locale('it')),
    );
    addTearDown(notifier.dispose);

    await notifier.applyRemoteSettings(
      const UserSettingsDto(language: AppConstants.remoteLanguageSystem),
    );
    expect(notifier.state.locale, isNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppConstants.prefLocale), isNull);

    await notifier.applyRemoteSettings(const UserSettingsDto(language: 'fr'));
    expect(notifier.state.locale, const Locale('fr'));
    expect(prefs.getString(AppConstants.prefLocale), 'fr');
  });

  test('anche le preferenze locali corrotte vengono normalizzate', () async {
    SharedPreferences.setMockInitialValues({
      AppConstants.prefThemeMode: 'viola',
      AppConstants.prefThemeId: 'palette_inesistente',
      AppConstants.prefFontFamily: 'Comic Sans',
      AppConstants.prefFontSize: 999.0,
      AppConstants.prefLineHeight: 0.0,
    });

    final settings = readAppSettingsFromPrefs(
      await SharedPreferences.getInstance(),
    );

    expect(settings.themeMode, ThemeMode.system);
    expect(settings.selectedThemeId, 'dark_teal');
    expect(settings.fontFamily, 'Inter');
    expect(settings.fontSize, AppConstants.maxFontSize);
    expect(settings.lineHeight, AppConstants.minLineHeight);
  });
}
