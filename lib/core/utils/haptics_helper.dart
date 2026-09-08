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

  /// Colpetto SINGOLO e impercettibile, da invocare ESCLUSIVAMENTE nel
  /// momento in cui una selezione di testo nasce ex-novo (nessun testo
  /// selezionato -> testo selezionato). Usato solo dall'intensità "light":
  /// per "off" e "strong" non fa nulla (per "strong" il feedback continuo
  /// durante il trascinamento è gestito da [selectionDragTick]).
  static void selectionStart(HapticIntensity intensity) {
    if (intensity != HapticIntensity.light) return;
    if (_isDesktop) return;

    try {
      HapticFeedback.selectionClick();
    } catch (_) {
      // Best-effort: un plugin/piattaforma che non implementa il metodo
      // non deve mai far crollare l'interazione dell'utente con l'editor.
    }
  }

  /// Feedback RIPETUTO, da invocare ad ogni variazione del range di
  /// selezione mentre l'utente sta trascinando una maniglia (o disegnando
  /// una nuova selezione). Usato SOLO dall'intensità "strong", per
  /// riprodurre la vibrazione continua/marcata di sistema richiesta in
  /// quella modalità. Per "off" e "light" non fa nulla.
  static void selectionDragTick(HapticIntensity intensity) {
    if (intensity != HapticIntensity.strong) return;
    if (_isDesktop) return;

    try {
      HapticFeedback.mediumImpact();
    } catch (_) {
      // Best-effort, vedi sopra.
    }
  }
}
