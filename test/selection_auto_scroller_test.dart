import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/utils/selection_auto_scroller.dart';

/// Viewport 400x400 in alto a sinistra, con 200 righe da 40px (8000px di
/// contenuto). `NeverScrollableScrollPhysics`: nel test il dito simula il
/// trascinamento di una SELEZIONE, non deve far scorrere la lista da solo;
/// l'auto-scroll usa `jumpTo`, che funziona comunque.
class _Harness extends StatelessWidget {
  const _Harness({required this.controller});

  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 400,
            child: ListView.builder(
              controller: controller,
              physics: const NeverScrollableScrollPhysics(),
              itemExtent: 40,
              itemCount: 200,
              itemBuilder: (context, index) => const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }
}

SelectionAutoScroller _makeScroller(
  WidgetTester tester,
  ScrollController controller,
  List<PointerEvent> synthetic,
) {
  return SelectionAutoScroller(
    vsync: tester,
    scrollController: controller,
    viewportRect: () => tester.getRect(find.byType(ListView)),
    // Gli eventi sintetici vengono solo raccolti: così il test non dipende
    // dal modo in cui il binding di test filtra gli eventi "da dispositivo".
    dispatchPointerEvent: synthetic.add,
  );
}

Future<void> _pumpFrames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  group('SelectionAutoScroller', () {
    testWidgets(
      'scorre in basso a dito fermo e reinietta movimenti a delta zero',
      (tester) async {
        final controller = ScrollController();
        addTearDown(controller.dispose);
        final synthetic = <PointerEvent>[];
        await tester.pumpWidget(_Harness(controller: controller));
        final scroller = _makeScroller(tester, controller, synthetic);

        try {
          final gesture = await tester.startGesture(const Offset(200, 100));
          // Fascia inferiore: viewport 0..400, zona 64px => da y=336 in giù.
          await gesture.moveTo(const Offset(200, 390));
          // La selezione cambia mentre il dito è giù e si è mosso.
          scroller.notifySelectionChanged();
          expect(scroller.isDraggingSelection, isTrue);

          await _pumpFrames(tester, 30);

          expect(controller.offset, greaterThan(100));
          expect(scroller.isScrolling, isTrue);
          expect(synthetic, isNotEmpty);
          expect(
            synthetic.every(
              (e) =>
                  e is PointerMoveEvent &&
                  e.delta == Offset.zero &&
                  e.position == const Offset(200, 390),
            ),
            isTrue,
          );

          // Rilascio: lo scroll si ferma e lo scudo si disattiva dopo un frame.
          await gesture.up();
          await tester.pump();
          expect(scroller.isScrolling, isFalse);
          expect(scroller.isDraggingSelection, isFalse);

          final offsetAtRelease = controller.offset;
          await _pumpFrames(tester, 10);
          expect(controller.offset, offsetAtRelease);
        } finally {
          scroller.dispose();
        }
      },
    );

    testWidgets(
      'un trascinamento senza cambio di selezione (scroll normale) non fa scattare nulla',
      (tester) async {
        final controller = ScrollController();
        addTearDown(controller.dispose);
        final synthetic = <PointerEvent>[];
        await tester.pumpWidget(_Harness(controller: controller));
        final scroller = _makeScroller(tester, controller, synthetic);

        try {
          final gesture = await tester.startGesture(const Offset(200, 100));
          await gesture.moveTo(const Offset(200, 390));
          await _pumpFrames(tester, 30);

          expect(controller.offset, 0);
          expect(scroller.isDraggingSelection, isFalse);
          expect(scroller.isScrolling, isFalse);
          expect(synthetic, isEmpty);

          await gesture.up();
          await tester.pump();
        } finally {
          scroller.dispose();
        }
      },
    );

    testWidgets('senza movimento oltre la soglia non arma l\'auto-scroll', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final synthetic = <PointerEvent>[];
      await tester.pumpWidget(_Harness(controller: controller));
      final scroller = _makeScroller(tester, controller, synthetic);

      try {
        // Long-press fermo già dentro la fascia di bordo: la selezione
        // cambia (parola selezionata) ma il dito non si è mosso.
        final gesture = await tester.startGesture(const Offset(200, 390));
        scroller.notifySelectionChanged();
        await _pumpFrames(tester, 30);

        expect(controller.offset, 0);
        expect(scroller.isDraggingSelection, isFalse);

        await gesture.up();
        await tester.pump();
      } finally {
        scroller.dispose();
      }
    });

    testWidgets('scorre verso l\'alto nella fascia superiore', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final synthetic = <PointerEvent>[];
      await tester.pumpWidget(_Harness(controller: controller));
      controller.jumpTo(2000);
      await tester.pump();
      final scroller = _makeScroller(tester, controller, synthetic);

      try {
        final gesture = await tester.startGesture(const Offset(200, 300));
        await gesture.moveTo(const Offset(200, 10));
        scroller.notifySelectionChanged();

        await _pumpFrames(tester, 30);

        expect(controller.offset, lessThan(1900));
        expect(synthetic, isNotEmpty);

        await gesture.up();
        await tester.pump();
      } finally {
        scroller.dispose();
      }
    });

    testWidgets('si ferma da solo a fine contenuto', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final synthetic = <PointerEvent>[];
      await tester.pumpWidget(_Harness(controller: controller));
      final maxExtent = controller.position.maxScrollExtent;
      controller.jumpTo(maxExtent - 20);
      await tester.pump();
      final scroller = _makeScroller(tester, controller, synthetic);

      try {
        final gesture = await tester.startGesture(const Offset(200, 100));
        await gesture.moveTo(const Offset(200, 395));
        scroller.notifySelectionChanged();

        await _pumpFrames(tester, 60);

        expect(controller.offset, closeTo(maxExtent, 0.5));
        expect(scroller.isScrolling, isFalse);

        await gesture.up();
        await tester.pump();
      } finally {
        scroller.dispose();
      }
    });
  });

  group('SelectionRevealShield', () {
    testWidgets('silenzia showOnScreen solo mentre isBlocking è true', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var blocking = true;
      const targetKey = ValueKey<String>('shield-target');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                height: 300,
                child: SingleChildScrollView(
                  controller: controller,
                  child: Column(
                    children: [
                      const SizedBox(height: 2000),
                      SelectionRevealShield(
                        isBlocking: () => blocking,
                        child: const SizedBox(key: targetKey, height: 50),
                      ),
                      const SizedBox(height: 2000),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final target = tester.renderObject(find.byKey(targetKey));

      target.showOnScreen();
      await tester.pump();
      expect(controller.offset, 0.0);

      blocking = false;
      target.showOnScreen();
      await tester.pump();
      expect(controller.offset, greaterThan(0.0));
    });
  });
}
