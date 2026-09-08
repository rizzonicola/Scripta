import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'haptics_helper.dart';

/// [WidgetsFlutterBinding] personalizzato che installa
/// [_HapticGatingBinaryMessenger] al posto del `BinaryMessenger` di
/// default, per poter filtrare (sopprimere o lasciar passare) OGNI
/// richiesta di vibrazione — comprese quelle emesse autonomamente dal
/// framework Flutter per la selezione di testo (vedi
/// `haptics_helper.dart` per il perché questo sia necessario e non
/// evitabile con un semplice controllo applicativo).
///
/// USO: in `main.dart`, sostituire `WidgetsFlutterBinding.ensureInitialized()`
/// con `ScriptaWidgetsFlutterBinding();` (semplice istanziazione: il
/// pattern singleton delle binding class di Flutter fa sì che il
/// costruttore stesso registri l'istanza, esattamente come farebbe
/// `ensureInitialized()`).
class ScriptaWidgetsFlutterBinding extends WidgetsFlutterBinding {
  @override
  BinaryMessenger createBinaryMessenger() {
    return _HapticGatingBinaryMessenger(super.createBinaryMessenger());
  }
}

/// Decoratore trasparente attorno al `BinaryMessenger` reale: inoltra tutti
/// i messaggi invariati, TRANNE le chiamate al metodo
/// `HapticFeedback.vibrate` sul canale `flutter/platform`, che vengono
/// concesse o soppresse in base a [HapticsHelper.gateNativeHapticCall].
///
/// Perché è sicuro filtrare l'intero canale `flutter/platform` e non solo
/// le chiamate della nostra classe: `HapticFeedback.vibrate/.selectionClick/
/// .mediumImpact/...` invocano TUTTE lo stesso metodo di canale
/// `'HapticFeedback.vibrate'` (il tipo specifico di feedback è solo un
/// argomento), quindi un'unica intercettazione per nome-metodo copre sia le
/// vibrazioni native del framework sia le nostre chiamate esplicite
/// residue (vedi [HapticsHelper.selectionDragTick]), garantendo una fonte
/// di verità unica invece di doverle sincronizzare in due punti diversi.
class _HapticGatingBinaryMessenger implements BinaryMessenger {
  _HapticGatingBinaryMessenger(this._inner);

  final BinaryMessenger _inner;

  static const String _platformChannel = 'flutter/platform';
  static const String _hapticMethod = 'HapticFeedback.vibrate';

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    if (channel == _platformChannel && message != null) {
      try {
        final MethodCall call =
            SystemChannels.platform.codec.decodeMethodCall(message);
        if (call.method == _hapticMethod &&
            !HapticsHelper.gateNativeHapticCall()) {
          // Soppressa: rispondiamo subito con un "successo" vuoto senza
          // inoltrare nulla al sistema operativo, così l'eventuale Future
          // restituita da `HapticFeedback.vibrate()` (nostra o interna al
          // framework) si risolve normalmente e nessuna vibrazione reale
          // viene generata.
          return Future<ByteData?>.value(
            SystemChannels.platform.codec.encodeSuccessEnvelope(null),
          );
        }
      } catch (_) {
        // Decodifica fallita per qualunque motivo: non blocchiamo mai il
        // messaggio in questo caso, meglio una vibrazione di troppo che un
        // platform channel bloccato o un crash.
      }
    }
    return _inner.send(channel, message);
  }

  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    ui.PlatformMessageResponseCallback? callback,
  ) {
    return _inner.handlePlatformMessage(channel, data, callback);
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) {
    _inner.setMessageHandler(channel, handler);
  }
}
