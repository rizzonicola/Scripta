import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/constants/app_constants.dart';
import 'core/l10n/app_localizations.dart';
import 'core/services/window_decoration_service.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/color_schemes.dart';
import 'core/utils/haptics_helper.dart';
import 'features/settings/providers/settings_provider.dart';
import 'shell/adaptive_app_shell.dart';
import 'shell/session_persistence.dart';

/// Temi chiaro e scuro, derivati SOLO da tema scelto e famiglia di font.
///
/// Costruire un `ThemeData` (con i `TextTheme` di Google Fonts) è costoso.
/// Tenerli in un provider significa ricalcolarli solo quando cambia uno di
/// questi due valori, e non a ogni ricostruzione di [ScriptaApp] (cambio di
/// luminosità del sistema, lingua, intensità aptica...).
final _appThemesProvider = Provider<({ThemeData light, ThemeData dark})>((ref) {
  final themeId = ref.watch(settingsProvider.select((s) => s.selectedThemeId));
  final fontFamily = ref.watch(settingsProvider.select((s) => s.fontFamily));
  return (
    light: AppTheme.lightTheme(themeId: themeId, fontFamily: fontFamily),
    dark: AppTheme.darkTheme(themeId: themeId, fontFamily: fontFamily),
  );
});

class ScriptaApp extends ConsumerWidget {
  const ScriptaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Attiva il salvataggio continuo dell'ultima posizione (modalità
    // Modifica/Visualizza, cartella, nota aperta): vedi session_persistence.dart.
    // Il provider non produce valori e non ricostruisce mai questo widget.
    ref.watch(sessionPersistenceProvider);

    // `select` mirati invece di `ref.watch(settingsProvider)` pieno: la
    // dimensione del font e l'interlinea (che cambiano di continuo mentre si
    // trascina lo slider in Impostazioni) NON influenzano MaterialApp, e
    // prima ne causavano comunque la ricostruzione completa a ogni tick,
    // con rigenerazione dei temi e chiamata al canale nativo della title bar.
    final themeMode = ref.watch(settingsProvider.select((s) => s.themeMode));
    final themeId = ref.watch(settingsProvider.select((s) => s.selectedThemeId));
    final locale = ref.watch(settingsProvider.select((s) => s.locale));
    final hapticIntensity =
        ref.watch(settingsProvider.select((s) => s.hapticIntensity));
    final themes = ref.watch(_appThemesProvider);

    // HapticsHelper vive fuori dall'albero dei widget (deve essere
    // consultabile anche dall'interceptor del platform channel installato da
    // ScriptaWidgetsFlutterBinding, che non ha accesso a Riverpod/BuildContext):
    // lo teniamo sincronizzato con l'impostazione dell'utente qui. Il watch
    // sopra fa ricostruire questo widget quando l'intensità cambia, quindi
    // la riga si aggiorna subito dopo un cambio nelle Impostazioni.
    HapticsHelper.intensity = hapticIntensity;

    final effectiveBrightness = switch (themeMode) {
      ThemeMode.dark => Brightness.dark,
      ThemeMode.light => Brightness.light,
      ThemeMode.system => MediaQuery.platformBrightnessOf(context),
    };

    final palette = AppThemePalettes.getById(
      themeId,
      fallbackBrightness: effectiveBrightness,
    );
    // Idempotente: il servizio salta la chiamata nativa se tema e
    // luminosità non sono cambiati dall'ultima volta.
    WindowDecorationService.updateTitleBarTheme(palette, effectiveBrightness);

    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,

      // Theme
      theme: themes.light,
      darkTheme: themes.dark,
      themeMode: themeMode,

      // Localization
      locale: locale,
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
