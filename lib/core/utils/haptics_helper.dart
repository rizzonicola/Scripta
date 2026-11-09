import 'dart:async';

import 'package:flutter/services.dart';

import 'platform_utils.dart';

/// Livelli di intensità del feedback tattile configurabili dall'utente
/// nelle Impostazioni (vedi `settings_view.dart` / `AppSettings.hapticIntensity`).
enum HapticIntensity {
  /// Nessun feedback tattile, mai.
  off,

  /// Tocco leggero e impercettibile (default): un solo colpetto all'inizio
  /// della selezione, silenzio durante ogni trascinamento.
  light,

  /// Feedback continuo/marcato durante la selezione e il trascinamento.
  strong,
}

/// Punto centrale e isolato da cui l'app governa il feedback aptico.
///
/// Da Flutter 3.x (flutter/flutter#115373) il framework invoca
/// `HapticFeedback.vibrate()` da solo quando cambia la selezione di un
/// `TextField`, senza passare da questa classe. L'unico punto di controllo
/// è quindi il platform channel: `_HapticGatingBinaryMessenger` in
/// `main.dart` chiede a [gateNativeHapticCall] se lasciar passare ogni
/// vibrazione, in base all'intensità corrente e allo stato "armato"
/// tracciato da [reportSelectionState].
class HapticsHelper {
  HapticsHelper._();

  /// Intensità corrente, sincronizzata ad ogni build di `ScriptaApp` con
  /// `settingsProvider.hapticIntensity` (vedi `app.dart`). Vive qui, fuori
  /// dall'albero dei widget, perché il gate del platform channel in
  /// `main.dart` non ha accesso al `BuildContext`/Riverpod.
  static HapticIntensity intensity = HapticIntensity.light;

  /// true quando la PROSSIMA vibrazione nativa richiesta durante una
  /// selezione "light" deve essere lasciata passare (un solo colpetto per
  /// ogni nuova selezione). Si disarma non appena [gateNativeHapticCall] la
  /// concede, e viene riarmato SOLO da [reportSelectionState] dopo un breve
  /// periodo di quiete a selezione collassata (debounce), per non
  /// riarmarsi per errore su un attraversamento-zero momentaneo durante il
  /// trascinamento di una maniglia (vedi doc di quel metodo).
  static bool _armed = true;
  static Timer? _rearmTimer;
  static const _rearmDelay = Duration(milliseconds: 200);

  /// true mentre un auto-scroll di selezione (vedi `SelectionAutoScroller`)
  /// sta facendo scorrere la vista. In quel caso la selezione cambia a ogni
  /// frame e, con l'intensità "strong", ogni cambio produrrebbe una
  /// vibrazione (sia quella nativa del framework sia [selectionDragTick]):
  /// una raffica continua. Finché è true, [gateNativeHapticCall] lascia
  /// passare al massimo una vibrazione ogni [_autoScrollTickInterval].
  /// Fuori dall'auto-scroll il comportamento resta quello di sempre.
  static bool selectionAutoScrollActive = false;
  static const _autoScrollTickInterval = Duration(milliseconds: 140);
  static DateTime? _lastAutoScrollTick;

  /// true sui soli sistemi Desktop dove l'aptica non ha senso. Usato solo
  /// dalle chiamate esplicite residue di questa classe (vedi
  /// [selectionDragTick]); il gate del platform channel filtra comunque
  /// anche le eventuali chiamate native, quindi è una doppia sicurezza.
  static bool get _isDesktop {
    try {
      return isDesktopPlatform;
    } catch (_) {
      return true;
    }
  }

  /// Da chiamare dal listener del `TextEditingController` ad ogni notifica
  /// che NON sia dovuta a digitazione di testo (vedi `_SelectionHapticBinder`),
  /// passando lo stato corrente di `selection.isCollapsed`.
  ///
  /// Il suo UNICO compito è pianificare il riarmo di [_armed] con un
  /// debounce: se la selezione è collassata, un timer riarma [_armed] dopo
  /// [_rearmDelay] di quiete; qualunque ulteriore notifica (anche se ancora
  /// collassata) annulla e ripianifica il timer. Questo metodo non
  /// DISARMA mai [_armed] direttamente: quello spetta solo a
  /// [gateNativeHapticCall], per evitare ambiguità sull'ordine relativo fra
  /// la chiamata nativa a `HapticFeedback.vibrate` e l'aggiornamento del
  /// controller (che possono avvenire in un ordine non garantito).
  static void reportSelectionState({required bool isCollapsed}) {
    _rearmTimer?.cancel();
    if (!isCollapsed) return;
    _rearmTimer = Timer(_rearmDelay, () => _armed = true);
  }

  /// Da chiamare dall'interceptor del platform channel in `main.dart` ogni
  /// volta che sta per partire una `HapticFeedback.vibrate` (nostra o del
  /// framework). Ritorna true per lasciarla passare, false per sopprimerla.
  static bool gateNativeHapticCall() {
    switch (intensity) {
      case HapticIntensity.off:
        return false;
      case HapticIntensity.strong:
        if (!selectionAutoScrollActive) return true;
        final now = DateTime.now();
        final last = _lastAutoScrollTick;
        if (last != null && now.difference(last) < _autoScrollTickInterval) {
          return false;
        }
        _lastAutoScrollTick = now;
        return true;
      case HapticIntensity.light:
        if (_armed) {
          _armed = false;
          _rearmTimer?.cancel();
          return true;
        }
        return false;
    }
  }

  /// Feedback RIPETUTO invocato ESPLICITAMENTE ad ogni variazione del range
  /// di selezione durante un trascinamento (vedi `_SelectionHapticBinder`).
  /// Usato solo dall'intensità "strong": su Android la vibrazione nativa già
  /// descritta sopra la rende ridondante (ma innocua, passa comunque dal
  /// gate), mentre su iOS il framework vibra nativamente SOLO alla
  /// creazione della selezione: questa chiamata è quindi ciò che garantisce
  /// una vibrazione continua durante il drag anche su iOS.
  static void selectionDragTick(HapticIntensity currentIntensity) {
    if (currentIntensity != HapticIntensity.strong) return;
    if (_isDesktop) return;

    try {
      HapticFeedback.mediumImpact();
    } catch (_) {
      // Best-effort: un plugin/piattaforma che non implementa il metodo
      // non deve mai far crollare l'interazione dell'utente con l'editor.
    }
  }
}
