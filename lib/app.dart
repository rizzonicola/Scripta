import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/constants/app_constants.dart';
import 'core/l10n/app_localizations.dart';
import 'core/services/window_decoration_service.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/color_schemes.dart';
import 'features/settings/providers/settings_provider.dart';
import 'shell/adaptive_app_shell.dart';

class ScriptaApp extends ConsumerWidget {
  const ScriptaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final Brightness effectiveBrightness;
    switch (settings.themeMode) {
      case ThemeMode.dark:
        effectiveBrightness = Brightness.dark;
        break;
      case ThemeMode.light:
        effectiveBrightness = Brightness.light;
        break;
      case ThemeMode.system:
        effectiveBrightness = platformBrightness;
        break;
    }

    final palette = AppThemePalettes.getById(
      settings.selectedThemeId,
      fallbackBrightness: effectiveBrightness,
    );
    WindowDecorationService.updateTitleBarTheme(palette, effectiveBrightness);

    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,

      // Theme
      theme: AppTheme.lightTheme(
        themeId: settings.selectedThemeId,
        fontFamily: settings.fontFamily,
      ),
      darkTheme: AppTheme.darkTheme(
        themeId: settings.selectedThemeId,
        fontFamily: settings.fontFamily,
      ),
      themeMode: settings.themeMode,

      // Localization
      locale: settings.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      // Home shell
      home: const AdaptiveAppShell(),
    );
  }
}
