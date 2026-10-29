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

// A-04 — impostazioni (tema, lingua, font) disponibili PRIMA del primo frame.
//
// Prima `SettingsNotifier` partiva sempre dai default e caricava dopo: chi
// aveva impostazioni personalizzate vedeva un frame col tema di default e poi
// un secondo (due costruzioni dei temi e di MaterialApp). Ora `main()` le
// legge insieme alla sessione e il notifier parte già dallo stato giusto.

/// Impostazioni volutamente diverse da OGNI default, per accorgersi di un
/// campo dimenticato.
const _saved = AppSettings(
  themeMode: ThemeMode.dark,
  selectedThemeId: 'nord',
  locale: Locale('en'),
  fontFamily: 'JetBrains Mono',
  fontSize: 19.0,
  lineHeight: 1.9,
  hapticIntensity: HapticIntensity.off,
);

/// Riempie SharedPreferences con i valori di [_saved], con le STESSE chiavi
/// che scrivono i setter di `SettingsNotifier`.
void _seedSavedSettings() {
  SharedPreferences.setMockInitialValues({
    AppConstants.prefThemeMode: 'dark',
    AppConstants.prefThemeId: 'nord',
    AppConstants.prefLocale: 'en',
    AppConstants.prefFontFamily: 'JetBrains Mono',
    AppConstants.prefFontSize: 19.0,
    AppConstants.prefLineHeight: 1.9,
    AppConstants.prefHapticIntensity: 'off',
  });
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'condizione non raggiunta in tempo',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('readAppSettingsFromPrefs', () {
    test(
      'senza nulla di salvato restituisce i default di AppSettings',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();

        expect(readAppSettingsFromPrefs(prefs), const AppSettings());
      },
    );

    test('legge tutti e 7 i campi dalle chiavi dei setter', () async {
      _seedSavedSettings();
      final prefs = await SharedPreferences.getInstance();

      expect(readAppSettingsFromPrefs(prefs), _saved);
    });

    test(
      'valori sconosciuti o vuoti ripiegano sui default, come prima',
      () async {
        SharedPreferences.setMockInitialValues({
          AppConstants.prefThemeMode: 'altro',
          AppConstants.prefLocale: '',
          AppConstants.prefHapticIntensity: 'inesistente',
        });
        final prefs = await SharedPreferences.getInstance();

        final s = readAppSettingsFromPrefs(prefs);
        expect(s.themeMode, ThemeMode.system);
        expect(s.locale, isNull);
        expect(s.hapticIntensity, HapticIntensity.light);
      },
    );
  });

  group('loadSettingsSnapshot', () {
    test('senza nulla di salvato restituisce i valori di default', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await loadSettingsSnapshot(), const AppSettings());
    });

    test('restituisce le impostazioni salvate', () async {
      _seedSavedSettings();
      expect(await loadSettingsSnapshot(), _saved);
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
  });

  group('SettingsNotifier', () {
    test('con l\'istantanea il PRIMO stato letto è già quello salvato', () {
      _seedSavedSettings();
      final container = ProviderContainer(
        overrides: [settingsSnapshotProvider.overrideWithValue(_saved)],
      );
      addTearDown(container.dispose);

      // Lettura SINCRONA, senza alcun await: è ciò che vede il primo build.
      // Prima di A-04 questo era `const AppSettings()` (tema di default).
      expect(container.read(settingsProvider), _saved);
    });

    test(
      'con l\'istantanea non arriva un secondo stato (una sola costruzione dei temi)',
      () async {
        _seedSavedSettings();
        final container = ProviderContainer(
          overrides: [settingsSnapshotProvider.overrideWithValue(_saved)],
        );
        addTearDown(container.dispose);

        var emissions = 0;
        container.listen<AppSettings>(
          settingsProvider,
          (previous, next) => emissions++,
        );
        container.read(settingsProvider);

        // Margine ampio: un eventuale caricamento asincrono (che rileggerebbe
        // gli stessi valori) emetterebbe il suo stato in pochi millisecondi.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(emissions, 0);
      },
    );

    test(
      'senza istantanea parte dai default e poi carica (comportamento di prima)',
      () async {
        _seedSavedSettings();
        final container = ProviderContainer();
        addTearDown(container.dispose);

        expect(container.read(settingsProvider), const AppSettings());
        await _waitUntil(
          () => container.read(settingsProvider) == _saved,
          reason: 'il caricamento asincrono delle impostazioni non è avvenuto',
        );
      },
    );

    test(
      'istantanea e caricamento asincrono producono LO STESSO stato',
      () async {
        _seedSavedSettings();
        final snapshot = await loadSettingsSnapshot();

        final asyncContainer = ProviderContainer();
        addTearDown(asyncContainer.dispose);
        asyncContainer.read(settingsProvider);
        await _waitUntil(
          () => asyncContainer.read(settingsProvider) != const AppSettings(),
          reason: 'il caricamento asincrono delle impostazioni non è avvenuto',
        );

        expect(asyncContainer.read(settingsProvider), snapshot);
      },
    );

    test(
      'i setter continuano a funzionare partendo dall\'istantanea',
      () async {
        _seedSavedSettings();
        final container = ProviderContainer(
          overrides: [settingsSnapshotProvider.overrideWithValue(_saved)],
        );
        addTearDown(container.dispose);

        await container
            .read(settingsProvider.notifier)
            .setThemeMode(ThemeMode.light);

        expect(container.read(settingsProvider).themeMode, ThemeMode.light);
        // Il resto dello stato resta quello dell'istantanea.
        expect(container.read(settingsProvider).selectedThemeId, 'nord');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(AppConstants.prefThemeMode), 'light');
      },
    );
  });

  // Il test più "esposto" del file: pompa l'app intera come `widget_test.dart`
  // (stessa esposizione ai font inclusi e a SQLite). Se in CI risultasse
  // instabile si può togliere da solo senza perdere le garanzie dei test sopra.
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
      // SQLite non attese dal pump; chiudere subito il DB le farebbe fallire.
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      await AppDatabase.instance.close();
      AppDatabase.debugDatabasePathOverride = null;
    });

    testWidgets(
      'usa già tema, modalità e lingua salvati e non ricostruisce i temi dopo',
      (tester) async {
        const savedLight = AppSettings(
          themeMode: ThemeMode.light,
          selectedThemeId: 'solarized_light',
          locale: Locale('en'),
        );
        final savedPalette = AppThemePalettes.getById(
          savedLight.selectedThemeId,
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
            overrides: [settingsSnapshotProvider.overrideWithValue(savedLight)],
            child: const ScriptaApp(),
          ),
        );

        // Un solo pumpWidget e nessun pump successivo: questo È il primo frame.
        final first = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(first.themeMode, ThemeMode.light);
        expect(first.locale, const Locale('en'));
        expect(first.theme!.colorScheme.primary, savedPalette.primary);

        await tester.pumpAndSettle();

        // Nessuno scatto dopo: stessa modalità, stessa lingua e SOLTANTO lo
        // stesso oggetto ThemeData (nessuna seconda costruzione dei temi).
        final settled = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(settled.themeMode, ThemeMode.light);
        expect(settled.locale, const Locale('en'));
        expect(identical(settled.theme, first.theme), isTrue);
        expect(identical(settled.darkTheme, first.darkTheme), isTrue);
      },
    );
  });
}
