import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Funzione con cui [SelectionAutoScroller] reinietta un evento puntatore
/// sintetico nel sistema di gesture. Il valore predefinito è
/// `GestureBinding.instance.handlePointerEvent`; esiste solo per poterlo
/// sostituire nei test.
typedef SelectionPointerDispatcher = void Function(PointerEvent event);

/// Auto-scroll continuo mentre si trascina una selezione di testo verso il
/// bordo superiore/inferiore di una viewport scrollabile.
///
/// Né `flutter_md` né `TextField` scansionano da soli a dito fermo: il
/// framework porta il cursore in vista solo su eventi del puntatore, da più
/// percorsi concorrenti che si contendono gli estremi della selezione
/// (flutter/flutter#132047). Insieme a [SelectionRevealShield], questo
/// componente governa lo scroll durante il trascinamento:
/// 1. osserva i puntatori con una route globale del `PointerRouter`, perché
///    le maniglie vivono in un `OverlayEntry` fuori dall'albero dei widget;
/// 2. considera "pilota" un puntatore che si è mosso oltre la soglia di
///    tocco e per cui [notifySelectionChanged] ha segnalato un cambio di
///    selezione (un normale swipe di scroll non lo fa);
/// 3. con un [Ticker] scorre lo [ScrollController] a velocità proporzionale
///    alla profondità nella fascia di bordo, anche a dito fermo;
/// 4. a layout aggiornato reinietta un `PointerMoveEvent` a delta zero, così
///    la logica di selezione ricalcola l'estremo sotto il dito.
class SelectionAutoScroller {
  SelectionAutoScroller({
    required TickerProvider vsync,
    required this.scrollController,
    required this.viewportRect,
    this.onScrollingChanged,
    this.edgeZone = 64.0,
    this.minSpeed = 80.0,
    this.maxSpeed = 1100.0,
    this.overshootForMaxSpeed = 48.0,
    SelectionPointerDispatcher? dispatchPointerEvent,
  }) : _dispatch =
           dispatchPointerEvent ??
           ((event) => GestureBinding.instance.handlePointerEvent(event)) {
    _ticker = vsync.createTicker(_onTick);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handlePointerEvent);
  }

  /// Controller della viewport da far scorrere (deve avere un solo client).
  final ScrollController scrollController;

  /// Rettangolo GLOBALE della viewport (l'area in cui il contenuto è
  /// realmente visibile), o `null` se non ancora disponibile.
  final Rect? Function() viewportRect;

  /// Chiamato quando l'auto-scroll parte/si ferma (serve, ad esempio, a
  /// limitare la frequenza delle vibrazioni durante lo scroll).
  final void Function(bool scrolling)? onScrollingChanged;

  /// Profondità (px) della fascia di bordo in cui il dito innesca lo scroll.
  /// Viene comunque limitata a un quarto dell'altezza della viewport.
  final double edgeZone;

  /// Velocità (px/s) all'ingresso nella fascia di bordo.
  final double minSpeed;

  /// Velocità massima (px/s), raggiunta quando il puntatore è
  /// [overshootForMaxSpeed] px OLTRE il bordo della viewport.
  final double maxSpeed;

  /// Quanto oltre il bordo (px) serve per raggiungere [maxSpeed].
  final double overshootForMaxSpeed;

  final SelectionPointerDispatcher _dispatch;
  late final Ticker _ticker;

  final Map<int, _PointerTrack> _pointers = <int, _PointerTrack>{};
  _PointerTrack? _driver;
  int _selectionSerial = 0;
  bool _releaseGraceActive = false;
  bool _syncScheduled = false;
  bool _dispatchingSynthetic = false;
  bool _scrollingReported = false;
  bool _disposed = false;
  Duration _lastElapsed = Duration.zero;

  /// `true` mentre un puntatore sta trascinando una selezione (e per un
  /// frame dopo il rilascio). Lo usa [SelectionRevealShield] per silenziare
  /// lo scroll "mostra il cursore" nativo, che altrimenti si contende lo
  /// scroll con questo componente.
  bool get isDraggingSelection =>
      !_disposed && (_driver != null || _releaseGraceActive);

  /// `true` mentre il [Ticker] sta effettivamente facendo scorrere.
  bool get isScrolling => !_disposed && _ticker.isActive;

  /// Da chiamare quando il VALORE della selezione è davvero cambiato
  /// (confrontato dal chiamante con quello precedente: notifiche che non
  /// cambiano la selezione non vanno segnalate).
  void notifySelectionChanged() {
    if (_disposed) return;
    _selectionSerial++;
    if (_driver != null) return;
    for (final track in _pointers.values) {
      if (track.moved) {
        _arm(track);
        return;
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _handlePointerEvent,
    );
    _driver = null;
    _pointers.clear();
    if (_ticker.isActive) _ticker.stop();
    _reportScrolling(false);
    _ticker.dispose();
  }

  // --- Tracciamento dei puntatori -----------------------------------------

  void _handlePointerEvent(PointerEvent event) {
    // Il nostro stesso evento sintetico non deve essere ri-elaborato.
    if (_disposed || _dispatchingSynthetic) return;

    if (event is PointerDownEvent) {
      _pointers[event.pointer] = _PointerTrack(
        pointer: event.pointer,
        device: event.device,
        origin: event.position,
        serialAtDown: _selectionSerial,
      );
      return;
    }

    if (event is PointerMoveEvent) {
      final track = _pointers[event.pointer];
      if (track == null) return;
      track.registerMove(event);
      if (!track.moved &&
          (event.position - track.origin).distance > kTouchSlop) {
        track.moved = true;
      }
      // La selezione può essere cambiata nello stesso dispatch di questo
      // evento ma PRIMA che `moved` diventasse vero (le route dei
      // recognizer girano prima di quelle globali): lo recuperiamo qui.
      if (_driver == null &&
          track.moved &&
          track.serialAtDown != _selectionSerial) {
        _arm(track);
      }
      if (identical(_driver, track)) _reevaluate();
      return;
    }

    if (event is PointerUpEvent || event is PointerCancelEvent) {
      final track = _pointers.remove(event.pointer);
      if (track != null && identical(track, _driver)) _disarm();
      return;
    }

    // Rete di sicurezza: un hover del mouse significa che nessun tasto è più
    // premuto, e la rimozione di un dispositivo invalida i suoi puntatori.
    // Evita che un `PointerUp` perso (focus perso a metà drag, ecc.) lasci
    // uno scroll "fantasma" attivo.
    if (event is PointerHoverEvent || event is PointerRemovedEvent) {
      _releaseDevice(event.device);
    }
  }

  void _releaseDevice(int device) {
    if (_pointers.isEmpty) return;
    final driver = _driver;
    var driverReleased = false;
    _pointers.removeWhere((pointer, track) {
      if (track.device != device) return false;
      if (identical(track, driver)) driverReleased = true;
      return true;
    });
    if (driverReleased) _disarm();
  }

  void _arm(_PointerTrack track) {
    _driver = track;
    _releaseGraceActive = false;
    _reevaluate();
  }

  void _disarm() {
    _driver = null;
    _stopTicker();
    // Per un frame dopo il rilascio lo scudo resta attivo: il framework
    // pianifica il suo "mostra il cursore" in un post-frame callback, che
    // può girare DOPO il `PointerUp` e farebbe comunque saltare la vista.
    _releaseGraceActive = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _releaseGraceActive = false;
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  // --- Scroll -------------------------------------------------------------

  /// Velocità con segno (px/s; negativa = verso l'alto) con cui scorrere dato
  /// il punto globale del puntatore, o 0 se non si deve scorrere (puntatore
  /// fuori dalle fasce di bordo oppure già a fine corsa in quella direzione).
  double _computeVelocity(Offset pointer) {
    final rect = viewportRect();
    if (rect == null || rect.height <= 0) return 0;
    if (!scrollController.hasClients) return 0;
    final position = scrollController.position;
    if (!position.hasContentDimensions) return 0;

    final zone = math.min(edgeZone, rect.height * 0.25);
    final topLimit = rect.top + zone;
    final bottomLimit = rect.bottom - zone;

    final double depth;
    final double direction;
    if (pointer.dy < topLimit) {
      depth = topLimit - pointer.dy;
      direction = -1;
    } else if (pointer.dy > bottomLimit) {
      depth = pointer.dy - bottomLimit;
      direction = 1;
    } else {
      return 0;
    }

    const epsilon = 0.5;
    if (direction < 0 &&
        position.pixels <= position.minScrollExtent + epsilon) {
      return 0;
    }
    if (direction > 0 &&
        position.pixels >= position.maxScrollExtent - epsilon) {
      return 0;
    }

    // Rampa quadratica: dolce all'ingresso nella fascia, veloce oltre il
    // bordo, così l'utente modula la velocità spostando il dito.
    final t = (depth / (zone + overshootForMaxSpeed))
        .clamp(0.0, 1.0)
        .toDouble();
    return direction * (minSpeed + (maxSpeed - minSpeed) * t * t);
  }

  void _reevaluate() {
    final driver = _driver;
    if (driver == null || _computeVelocity(driver.position) == 0) {
      _stopTicker();
      return;
    }
    _startTicker();
  }

  void _startTicker() {
    if (_ticker.isActive) return;
    _lastElapsed = Duration.zero;
    _ticker.start();
    _reportScrolling(true);
  }

  void _stopTicker() {
    if (_ticker.isActive) _ticker.stop();
    _reportScrolling(false);
  }

  void _reportScrolling(bool value) {
    if (_scrollingReported == value) return;
    _scrollingReported = value;
    onScrollingChanged?.call(value);
  }

  void _onTick(Duration elapsed) {
    final elapsedMicros = (elapsed - _lastElapsed).inMicroseconds;
    _lastElapsed = elapsed;

    final driver = _driver;
    if (_disposed || driver == null) {
      _stopTicker();
      return;
    }
    final velocity = _computeVelocity(driver.position);
    if (velocity == 0) {
      _stopTicker();
      return;
    }

    final position = scrollController.position;
    // Un altro scroll (un secondo dito, la rotella) è in corso: non
    // interferiamo, riproviamo al frame successivo.
    if (position.isScrollingNotifier.value) return;

    // Il tetto a 50 ms evita salti enormi dopo un frame molto lento.
    final dt = (elapsedMicros / Duration.microsecondsPerSecond)
        .clamp(0.0, 0.05)
        .toDouble();
    if (dt <= 0) return;

    final target = (position.pixels + velocity * dt)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((target - position.pixels).abs() < 0.01) {
      _stopTicker();
      return;
    }
    position.jumpTo(target);
    _scheduleSync();
  }

  // --- Risincronizzazione della selezione ---------------------------------

  /// Dopo lo scroll il contenuto sotto il dito è cambiato, ma il dito è
  /// fermo e quindi nessun evento farebbe ricalcolare l'estremo mobile della
  /// selezione. L'evento viene inviato in un post-frame callback perché
  /// l'hit-test deve vedere il layout GIÀ aggiornato con il nuovo offset
  /// (subito dopo `jumpTo` il render tree riflette ancora quello vecchio).
  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      _syncSelectionWithPointer();
    });
  }

  void _syncSelectionWithPointer() {
    if (_disposed) return;
    final driver = _driver;
    final lastMove = driver?.lastMove;
    if (driver == null || lastMove == null) return;
    if (!_pointers.containsKey(driver.pointer)) return;

    // Stessa identità (pointer, device, kind, buttons) dell'ultimo movimento
    // reale: i recognizer scartano un movimento con `buttons` diverso da
    // quello iniziale. Cambiano solo delta (zero) e timestamp (monotono,
    // per non dare campioni degeneri ai `VelocityTracker`).
    final event = PointerMoveEvent(
      timeStamp: lastMove.timeStamp + driver.sinceLastMove.elapsed,
      pointer: lastMove.pointer,
      kind: lastMove.kind,
      device: lastMove.device,
      position: driver.position,
      delta: Offset.zero,
      buttons: lastMove.buttons,
      pressure: lastMove.pressure,
    );

    _dispatchingSynthetic = true;
    try {
      _dispatch(event);
    } finally {
      _dispatchingSynthetic = false;
    }
  }
}

/// Stato di un puntatore premuto, dal `PointerDown` al `PointerUp`.
class _PointerTrack {
  _PointerTrack({
    required this.pointer,
    required this.device,
    required this.origin,
    required this.serialAtDown,
  }) : position = origin;

  final int pointer;
  final int device;
  final Offset origin;

  /// Valore di `_selectionSerial` al momento del `PointerDown`: se è diverso
  /// da quello corrente, la selezione è cambiata mentre il dito era giù.
  final int serialAtDown;

  Offset position;
  bool moved = false;
  PointerMoveEvent? lastMove;
  final Stopwatch sinceLastMove = Stopwatch()..start();

  void registerMove(PointerMoveEvent event) {
    position = event.position;
    lastMove = event;
    sinceLastMove
      ..reset()
      ..start();
  }
}

/// Silenzia le richieste `showOnScreen` che attraversano questo widget
/// mentre [isBlocking] è `true`.
///
/// `TextField`/`EditableText` portano il cursore a schermo chiamando
/// `RenderEditable.showOnScreen`, che risale ricorsivamente fino
/// all'`SingleChildScrollView` esterno. Durante il trascinamento di una
/// selezione quel meccanismo (event-driven, e con più chiamate concorrenti
/// su estremi diversi della selezione) entra in conflitto con
/// [SelectionAutoScroller]: va quindi interrotto QUI, tra il campo di testo
/// e lo scroll view. Fuori dal trascinamento ([isBlocking] `false`) il
/// comportamento è identico a prima, quindi digitare continua a mantenere il
/// cursore in vista.
///
/// Va posto sopra i `TextField` e sotto lo scroll view; non influisce su
/// layout, paint o hit-test.
class SelectionRevealShield extends SingleChildRenderObjectWidget {
  const SelectionRevealShield({
    super.key,
    required this.isBlocking,
    super.child,
  });

  final bool Function() isBlocking;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderSelectionRevealShield(isBlocking);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSelectionRevealShield renderObject,
  ) {
    renderObject.isBlocking = isBlocking;
  }
}

/// Render object di [SelectionRevealShield].
///
/// È volutamente pubblico: compare nella firma di `updateRenderObject`, che
/// è API pubblica, e un tipo privato lì dentro fa scattare la lint
/// `library_private_types_in_public_api` (che con `flutter analyze` nel
/// workflow fa fallire la build). Non rinominarlo con il `_` iniziale.
class RenderSelectionRevealShield extends RenderProxyBox {
  RenderSelectionRevealShield(this.isBlocking);

  bool Function() isBlocking;

  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    if (isBlocking()) return;
    super.showOnScreen(
      descendant: descendant,
      rect: rect,
      duration: duration,
      curve: curve,
    );
  }
}
