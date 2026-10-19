import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/app.dart';
import 'package:scripta/core/constants/app_constants.dart';
import 'package:scripta/core/database/app_database.dart';
import 'package:scripta/core/theme/color_schemes.dart';
import 'package:scripta/core/utils/haptics_helper.dart';
import 'package:scripta/features/settings/models/app_settings.dart';
import 'package:scripta/features/settings/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Impostazioni (tema, font, lingua, aptica) lette PRIMA del primo frame, come la
// sessione: chi ha impostazioni personalizzate non deve vedere un primo frame
// coi default e poi una seconda costruzione di MaterialApp e dei temi.

/// Impostazioni diverse da quelle di default in OGNI campo.
const AppSettings _saved = AppSettings(
  themeMode: ThemeMode.light,
  selectedThemeId: 'solarized_light',
  locale: Locale('en'),
  fontFamily: 'Merriweather',
  fontSize: 19.0,
  lineHeight: 1.9,
  hapticIntensity: HapticIntensity.off,
);

/// Le stesse impostazioni, come stanno su disco.
Map<String, Object> _savedPrefs() => {
      AppConstants.prefThemeMode: 'light',
      AppConstants.prefThemeId: 'solarized_light',
      AppConstants.prefLocale: 'en',
      AppConstants.prefFontFamily: 'Merriweather',
      AppConstants.prefFontSize: 19.0,
      AppConstants.prefLineHeight: 1.9,
      AppConstants.prefHapticIntensity: 'off',
    };

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String reason = 'condizione non raggiunta in tempo',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('istantanea delle impostazioni', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('senza nulla di salvato restituisce i valori di default', () async {
      expect(await loadSettingsSnapshot(), const AppSettings());
    });

    test('rilegge tutti e 7 i campi salvati', () async {
      SharedPreferences.setMockInitialValues(_savedPrefs());
      expect(await loadSettingsSnapshot(), _saved);
    });

    test('valori sconosciuti o vuoti ricadono sui default', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.prefThemeMode: 'tema-inventato',
        AppConstants.prefLocale: '',
        AppConstants.prefHapticIntensity: 'intensita-inventata',
      });
      final s = await loadSettingsSnapshot();
      expect(s?.themeMode, ThemeMode.system);
      expect(s?.locale, isNull);
      expect(s?.hapticIntensity, HapticIntensity.light);
    });

    test('valori di tipo sbagliato non lanciano mai', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.prefFontSize: 'grande',
        AppConstants.prefThemeMode: 42,
      });
      // Nessuna eccezione verso `main()`: o `null` (il notifier ripiega sul
      // caricamento asincrono) o i default.
      final s = await loadSettingsSnapshot();
      expect(s, anyOf(isNull, const AppSettings()));
    });

    test('con l\'istantanea il PRIMO read è già lo stato salvato, e non cambia dopo', () async {
      // Su disco non c'è nulla (quindi i default, diversi dall'istantanea): se
      // il notifier ricaricasse comunque dopo il primo frame, lo stato cambierebbe.
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [settingsSnapshotProvider.overrideWithValue(_saved)],
      );
      addTearDown(container.dispose);

      // Lettura SINCRONA: nessun frame coi default.
      expect(container.read(settingsProvider), _saved);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(container.read(settingsProvider), _saved);
    });

    test('senza istantanea il notifier carica in modo asincrono come prima', () async {
      // Guardia di regressione del ripiego (test, lettura fallita in main()).
      SharedPreferences.setMockInitialValues(_savedPrefs());
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(settingsProvider), const AppSettings(),
          reason: 'parte coi default');
      await _waitUntil(
        () => container.read(settingsProvider) != const AppSettings(),
        reason: 'il caricamento asincrono non è arrivato',
      );

      // Stesse chiavi e stessi default dell'istantanea: stesso valore.
      expect(container.read(settingsProvider), _saved);
      expect(container.read(settingsProvider), await loadSettingsSnapshot());
    });
  });

  group('primo frame di ScriptaApp', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      AppDatabase.ensureFactoryInitialized();
      await AppDatabase.instance.close();
      AppDatabase.debugDatabasePathOverride = p.join(
        Directory.systemTemp.path,
        'scripta_settings_snapshot_${DateTime.now().microsecondsSinceEpoch}.db',
      );
    });

    tearDown(() async {
      // Stesso motivo di test/widget_test.dart: i notifier avviano letture
      // SQLite non attese dal pump, chiudere subito il DB le farebbe fallire.
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      await AppDatabase.instance.close();
      AppDatabase.debugDatabasePathOverride = null;
    });

    testWidgets('usa già tema, modalità e lingua salvati e non ricostruisce i temi dopo', (tester) async {
      final savedPalette = AppThemePalettes.getById(
        _saved.selectedThemeId,
        fallbackBrightness: Brightness.light,
      );
      final defaultPalette = AppThemePalettes.getById(
        const AppSettings().selectedThemeId,
        fallbackBrightness: Brightness.light,
      );
      // Premessa del test: il tema salvato è davvero diverso da quello di default.
      expect(savedPalette.primary, isNot(defaultPalette.primary));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [settingsSnapshotProvider.overrideWithValue(_saved)],
          child: const ScriptaApp(),
        ),
      );

      // Un solo pumpWidget e nessun pump successivo: questo È il primo frame.
      final first = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(first.themeMode, ThemeMode.light);
      expect(first.locale, const Locale('en'));
      expect(first.theme!.colorScheme.primary, savedPalette.primary);

      await tester.pumpAndSettle();

      // Nessuno "scatto" dopo: stessa modalità, stessa lingua e SOLTANTO lo
      // stesso oggetto ThemeData (nessuna seconda costruzione dei temi).
      final settled = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(settled.themeMode, ThemeMode.light);
      expect(settled.locale, const Locale('en'));
      expect(identical(settled.theme, first.theme), isTrue);
      expect(identical(settled.darkTheme, first.darkTheme), isTrue);
    });
  });
}
