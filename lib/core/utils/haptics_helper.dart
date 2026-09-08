import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'dart:io' show Platform;

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

/// Punto centrale e ISOLATO da cui l'app governa il feedback aptico.
///
/// PERCHÉ QUESTA CLASSE NON CHIAMA PIÙ `HapticFeedback.*` DIRETTAMENTE PER
/// LA SELEZIONE DI TESTO (causa radice dei bug precedenti):
/// A partire da Flutter 3.x (flutter/flutter#115373), il FRAMEWORK STESSO
/// invoca `HapticFeedback.vibrate()` in modo completamente autonomo quando
/// l'utente interagisce con la selezione di un `TextField`:
///  - una vibrazione singola alla creazione di una selezione (long-press),
///    sia su Android che iOS;
///  - su Android, una vibrazione RIPETUTA ad ogni variazione del range
///    mentre si trascina una maniglia (creazione O ridimensionamento).
/// Questo avviene DENTRO al motore di rendering di Flutter
/// (`RenderEditable`/`EditableText`), non nel nostro codice applicativo:
/// nessuna nostra chiamata (o assenza di chiamata) a `HapticsHelper` può
/// influenzarla, perché quella vibrazione nativa non passa MAI dai metodi
/// di questa classe. È per questo che i tentativi precedenti — che
/// provavano a "decidere se vibrare" nel nostro `_SelectionHapticBinder` —
/// non potevano funzionare per "Leggero" e "Disattivata": qualunque cosa
/// facesse il nostro codice, il framework vibrava comunque per conto suo.
///
/// LA SOLUZIONE:
/// Non possiamo impedire al framework di CHIAMARE `HapticFeedback.vibrate`,
/// ma possiamo intercettare quella chiamata PRIMA che raggiunga il sistema
/// operativo, filtrando il platform channel `flutter/platform` (vedi
/// `main.dart`, `_HapticGatingBinaryMessenger`): ogni volta che qualunque
/// parte del framework (nativa o nostra) tenta di vibrare, viene chiesto a
/// [gateNativeHapticCall] il permesso, e la richiesta viene lasciata
/// passare o soppressa in base all'intensità corrente e allo stato
/// "armato" tracciato da [reportSelectionState] (aggiornato dal listener
/// del `TextEditingController` in `markdown_editor_field.dart`).
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

  /// true sui soli sistemi Desktop dove l'aptica non ha senso. Usato solo
  /// dalle chiamate esplicite residue di questa classe (vedi
  /// [selectionDragTick]); il gate del platform channel filtra comunque
  /// anche le eventuali chiamate native, quindi è una doppia sicurezza.
  static bool get _isDesktop {
    if (kIsWeb) return true;
    try {
      return Platform.isLinux || Platform.isWindows || Platform.isMacOS;
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
