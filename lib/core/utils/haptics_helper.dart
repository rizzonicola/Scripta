import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'dart:io' show Platform;

/// Livelli di intensità del feedback tattile configurabili dall'utente
/// nelle Impostazioni (vedi `settings_view.dart` / `AppSettings.hapticIntensity`).
enum HapticIntensity {
  /// Nessun feedback tattile, mai.
  off,

  /// Tocco leggero e impercettibile (default). Usa `HapticFeedback.selectionClick()`,
  /// lo stesso tipo di feedback nativo usato per scroll wheel / selezione testo.
  light,

  /// Feedback più marcato, per chi preferisce una conferma tattile più netta.
  strong,
}

/// Punto centrale e ISOLATO da cui l'app invoca qualunque feedback aptico.
///
/// PERCHÉ CENTRALIZZARE:
///  - Evita chiamate dirette a `HapticFeedback.*` sparse nei widget, che
///    sarebbero facili da dimenticare di disabilitare/adattare in un punto
///    e non nell'altro.
///  - Garantisce SEMPRE lo stesso guardiano di piattaforma: su Desktop
///    (Linux/Windows/macOS) le API dei plugin haptic non hanno alcun
///    effetto reale (nessun motore di vibrazione) ma la MethodChannel
///    invocation ha comunque un costo (context switch, log di canale non
///    implementato) e su alcune build Linux può anche stampare errori nel
///    log. Ritorniamo quindi immediatamente senza invocare il platform
///    channel su quelle piattaforme.
///  - Un solo posto da testare/modificare se in futuro cambiano le API o si
///    vuole aggiungere un nuovo livello di intensità.
class HapticsHelper {
  HapticsHelper._();

  /// true sui soli sistemi Desktop dove l'aptica non ha senso ed è solo
  /// overhead. Il Web è escluso a priori (kIsWeb) perché `Platform.isX`
  /// solleverebbe un'eccezione se interrogato lì.
  static bool get _isDesktop {
    if (kIsWeb) return true; // niente aptica sensata anche sul Web
    try {
      return Platform.isLinux || Platform.isWindows || Platform.isMacOS;
    } catch (_) {
      // Piattaforma non riconosciuta/non disponibile: per sicurezza non
      // emettiamo feedback piuttosto che rischiare un'eccezione a runtime.
      return true;
    }
  }

  /// Feedback da invocare ESCLUSIVAMENTE nel momento in cui una selezione
  /// di testo (o un trascinamento) HA INIZIO, mai durante l'aggiornamento
  /// continuo di un drag (vedi `markdown_editor_field.dart`, che traccia la
  /// transizione "nessuna selezione -> selezione" e chiama questo metodo
  /// una sola volta per transizione).
  static void selectionStart(HapticIntensity intensity) {
    if (intensity == HapticIntensity.off) return;
    if (_isDesktop) return;

    try {
      switch (intensity) {
        case HapticIntensity.off:
          return;
        case HapticIntensity.light:
          HapticFeedback.selectionClick();
          break;
        case HapticIntensity.strong:
          HapticFeedback.mediumImpact();
          break;
      }
    } catch (_) {
      // Best-effort: un plugin/piattaforma che non implementa il metodo
      // non deve mai far crollare l'interazione dell'utente con l'editor.
    }
  }
}
