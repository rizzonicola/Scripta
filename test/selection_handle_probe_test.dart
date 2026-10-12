import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/features/editor/presentation/selection_handle_probe.dart';

// Test della sonda `inspectSelectionHandles` (HANDOFF A.16) con alberi
// SINTETICI: nessuna dipendenza da `flutter_md` né dal gesto di selezione,
// quindi sono deterministici e non hanno bisogno di attese reali.
//
// COME FUNZIONA IL TRUCCO. La sonda trova le maniglie per NOME del tipo
// (`_SelectionHandleOverlay`, un widget privato del framework). Qui si
// definisce un widget privato con lo STESSO nome, costruito come il
// framework costruisce una maniglia (follower con `showWhenUnlinked: false`
// > `FadeTransition` > foglia): per `runtimeType.toString()` è
// indistinguibile dall'originale. È la forma che il framework ha secondo la
// memoria dell'autore, NON riletta dal sorgente (vedi HANDOFF A.16): se
// queste prove passano ma sulla maniglia vera la sonda sbaglia, sarà la
// prova che la forma vera è diversa (lo dicono i test del file
// `selection_recall_test.dart`, che usano le maniglie vere).
//
// COSA DIMOSTRANO. Il vecchio criterio (esistenza del widget) risponderebbe
// «presente» in TUTTI i casi sotto, compresi quelli in cui la maniglia non
// si vede: queste prove fissano la differenza fra «esiste» e «è dipinta».

class _SelectionHandleOverlay extends StatefulWidget {
  const _SelectionHandleOverlay({
    super.key,
    required this.link,
    this.opacity = 1.0,
    this.offstage = false,
  });

  final LayerLink link;
  final double opacity;
  final bool offstage;

  @override
  State<_SelectionHandleOverlay> createState() =>
      _SelectionHandleOverlayState();
}

class _SelectionHandleOverlayState extends State<_SelectionHandleOverlay> {
  @override
  Widget build(BuildContext context) {
    Widget handle = CompositedTransformFollower(
      link: widget.link,
      showWhenUnlinked: false,
      child: FadeTransition(
        opacity: AlwaysStoppedAnimation<double>(widget.opacity),
        child: const SizedBox(width: 24, height: 24),
      ),
    );
    if (widget.offstage) handle = Offstage(child: handle);
    return handle;
  }
}

const Key _targetKey = ValueKey('leader-target');

/// Contesto (un `Element`) da passare alla sonda. Si ricava al momento
/// dell'uso, subito prima di chiamarla, e non si conserva attraverso un `await`.
BuildContext _context(WidgetTester tester) =>
    tester.element(find.byType(Scaffold));

/// Monta un'app con (opzionale) un leader in posizione nota, inserisce nel
/// suo overlay radice una maniglia sintetica per ciascun elemento di
/// [handles], esegue [body] e poi rimuove e distrugge le entry. La pulizia è
/// DENTRO il corpo del test (try/finally) e non in un `addTearDown`: i
/// callback di `addTearDown` possono girare dopo lo smontaggio dell'albero.
Future<void> _withHandles(
  WidgetTester tester, {
  required List<_SelectionHandleOverlay> handles,
  LayerLink? leaderLink,
  required Future<void> Function() body,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.center,
          child: leaderLink == null
              ? const SizedBox.shrink()
              : CompositedTransformTarget(
                  link: leaderLink,
                  child: const SizedBox(
                    key: _targetKey,
                    width: 40,
                    height: 40,
                  ),
                ),
        ),
      ),
    ),
  );

  final overlay = Overlay.of(_context(tester), rootOverlay: true);
  final entries = <OverlayEntry>[
    for (final handle in handles) OverlayEntry(builder: (_) => handle),
  ];
  overlay.insertAll(entries);
  try {
    await tester.pump();
    await body();
  } finally {
    for (final entry in entries) {
      if (entry.mounted) entry.remove();
      entry.dispose();
    }
  }
}

void main() {
  const viewport = Rect.fromLTWH(0, 0, 400, 800);

  testWidgets('nessuna maniglia nel root overlay: elenco vuoto', (tester) async {
    await _withHandles(
      tester,
      handles: const [],
      body: () async {
        expect(inspectSelectionHandles(_context(tester)), isEmpty);
      },
    );
  });

  testWidgets(
    'maniglia collegata e opaca: dipinta, nel punto del leader e dentro la viewport',
    (tester) async {
      final link = LayerLink();
      await _withHandles(
        tester,
        leaderLink: link,
        handles: [_SelectionHandleOverlay(link: link)],
        body: () async {
          final handles = inspectSelectionHandles(_context(tester));
          expect(handles, hasLength(1));
          final handle = handles.single;
          expect(handle.isLinked, isTrue);
          expect(handle.opacity, closeTo(1.0, 1e-9));
          expect(handle.isOffstage, isFalse);
          expect(handle.isPainted, isTrue);
          expect(handle.isVisibleIn(viewport), isTrue);
          // Il rettangolo si misura su un discendente del follower, quindi
          // coincide con la posizione REALE del leader (angolo alto-sinistro,
          // `offset` nullo), non con l'origine dell'overlay.
          expect(
            handle.rect?.topLeft,
            offsetMoreOrLessEquals(tester.getTopLeft(find.byKey(_targetKey))),
            reason: 'la maniglia deve stare dove sta il suo leader',
          );
        },
      );
    },
  );

  testWidgets(
    'maniglia ESISTENTE ma scollegata (leader assente): NON dipinta',
    (tester) async {
      // Nessun `CompositedTransformTarget` nell'albero: il `LayerLink` della
      // maniglia non ha leader. È lo stato di un estremo della selezione il
      // cui blocco è smontato (o rimontato e non ricollegato): il widget
      // della maniglia c'è, ma il follower non dipinge nulla.
      await _withHandles(
        tester,
        handles: [_SelectionHandleOverlay(link: LayerLink())],
        body: () async {
          final handles = inspectSelectionHandles(_context(tester));
          // Per il vecchio criterio (esistenza) questo basterebbe a dire «le
          // maniglie ci sono».
          expect(handles, hasLength(1));
          expect(handles.single.isLinked, isFalse);
          expect(handles.single.isPainted, isFalse);
          expect(handles.single.isVisibleIn(viewport), isFalse);
        },
      );
    },
  );

  testWidgets('maniglia con opacità zero: NON dipinta', (tester) async {
    final link = LayerLink();
    await _withHandles(
      tester,
      leaderLink: link,
      handles: [_SelectionHandleOverlay(link: link, opacity: 0.0)],
      body: () async {
        final handle = inspectSelectionHandles(_context(tester)).single;
        expect(handle.isLinked, isTrue);
        expect(handle.opacity, 0.0);
        expect(handle.isPainted, isFalse);
        expect(handle.isVisibleIn(viewport), isFalse);
      },
    );
  });

  testWidgets('maniglia in un Offstage: NON dipinta', (tester) async {
    final link = LayerLink();
    await _withHandles(
      tester,
      leaderLink: link,
      handles: [_SelectionHandleOverlay(link: link, offstage: true)],
      body: () async {
        final handle = inspectSelectionHandles(_context(tester)).single;
        expect(handle.isOffstage, isTrue);
        expect(handle.isPainted, isFalse);
      },
    );
  });

  testWidgets('opacità parziale (dissolvenza in corso): dipinta', (tester) async {
    final link = LayerLink();
    await _withHandles(
      tester,
      leaderLink: link,
      handles: [_SelectionHandleOverlay(link: link, opacity: 0.4)],
      body: () async {
        final handle = inspectSelectionHandles(_context(tester)).single;
        expect(handle.opacity, closeTo(0.4, 1e-9));
        expect(handle.isPainted, isTrue);
      },
    );
  });

  testWidgets(
    'stato parziale: una maniglia dipinta e una scollegata sono distinte',
    (tester) async {
      // È lo stato che la politica B' di `_selectionHandlesNeedRebuild`
      // vuole riconoscere: «non tutte dipinte» anche se una lo è.
      final linked = LayerLink();
      await _withHandles(
        tester,
        leaderLink: linked,
        handles: [
          _SelectionHandleOverlay(link: linked),
          _SelectionHandleOverlay(link: LayerLink()),
        ],
        body: () async {
          final handles = inspectSelectionHandles(_context(tester));
          expect(handles, hasLength(2));
          expect(handles.where((h) => h.isPainted), hasLength(1));
          expect(handles.every((h) => h.isPainted), isFalse);
        },
      );
    },
  );
}
