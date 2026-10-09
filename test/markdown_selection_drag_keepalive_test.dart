import 'package:flutter/gestures.dart'
    show GestureBinding, PointerDeviceKind, PointerRemovedEvent;
import 'package:flutter/material.dart';
import 'package:flutter_md/flutter_md.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/features/editor/presentation/markdown_rendered_view.dart';

// Regressione 0.9.9: trascinando una maniglia a velocità media/alta attraverso
// gli "spazi vuoti" fra i blocchi, l'evidenziazione della selezione saltava e
// sfarfallava, e a dito fermo su uno spazio vuoto continuava finché non lo si
// staccava dallo schermo.
//
// Causa (vedi `_KeepAliveWhileSelectionEdge` e `_syncEdgeIds` in
// `markdown_rendered_view.dart`): il keep-alive degli estremi seguiva la
// selezione in tempo reale. Durante il drag l'estremo mobile cambia blocco a
// quasi ogni evento puntatore (fra un paragrafo e l'altro il parser inserisce
// un blocco spaziatore, cioè un item a sé), e ogni cambio rilasciava un blocco
// e ne fissava un altro in sincrono, dentro la `notifyListeners()` del
// controller: una mutazione strutturale della lista a ogni evento.
//
// Contratto verificato qui:
//   1. con un puntatore premuto, spostare l'estremo MOBILE non cambia lo stato
//      dei keep-alive (nessun rilascio, nessun nuovo blocco fissato);
//   2. l'ANCORA (l'estremo fisso) si fissa subito, anche a dito giù, ma al
//      massimo una volta per gesto (se cambiasse a ogni evento, ad esempio con
//      le maniglie scavalcate l'una sull'altra, il resto aspetta il rilascio);
//   3. al rilascio (up o cancel) si pubblica lo stato reale: l'estremo mobile
//      viene fissato e quello precedente rilasciato;
//   4. la route globale dei puntatori non sopravvive allo smontaggio, e un
//      gesto rimasto "aperto" (puntatore mai rilasciato) si chiude da solo.
//
// Come si simula "un dito giù" senza toccare la vista: un puntatore premuto su
// una zona neutra FUORI dalla vista (`_fingerPadKey`), esattamente come una
// maniglia, che vive in un `OverlayEntry` fuori da ogni `Listener` della vista.
// Così non partono long-press né tap-a-vuoto, che altrimenti cambierebbero la
// selezione sotto i piedi del test. Il drag della maniglia si simula con
// `controller.extendToGlobal`, la stessa API di selezione che usa il drag.
//
// Nota: gli indici PARI della nota di prova sono paragrafi di testo; fra due
// paragrafi c'è un blocco spaziatore (indice dispari).

/// Chiave della `ListView` della vista di lettura (vedi `_buildFormattedView`).
const _listKey = ValueKey<String>('markdown-formatted-listview');

/// Zona neutra sopra la vista, dove si preme il "dito".
const _fingerPadKey = ValueKey<String>('finger-pad');

String _longNote(int paragraphs) =>
    List.generate(paragraphs, (i) => 'Paragrafo $i con **testo**.')
        .join('\n\n');

Future<void> _pumpNote(WidgetTester tester, String content) async {
  // Viewport da telefono: 390x844 punti logici.
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(
              key: _fingerPadKey,
              height: 40,
              width: double.infinity,
            ),
            Expanded(
              child: ProviderScope(
                // Titolo vuoto: nessun item titolo, quindi l'indice dell'item
                // nella lista coincide con il numero di `documentId`
                // ('block-N').
                child: MarkdownRenderedView(title: '', content: content),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Item della lista per indice (chiave assegnata da `_buildItem`).
Finder _item(int index, {bool skipOffstage = true}) => find.byKey(
      ValueKey<String>('rendered-block-$index'),
      skipOffstage: skipOffstage,
    );

MarkdownSelectionScopeState _scope(WidgetTester tester) =>
    tester.state<MarkdownSelectionScopeState>(find.byType(MarkdownSelectionScope));

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(_listKey),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

Future<void> _scrollTo(WidgetTester tester, double offset) async {
  _position(tester).jumpTo(offset);
  await tester.pump();
}

Offset _padCenter(WidgetTester tester) =>
    tester.getCenter(find.byKey(_fingerPadKey));

/// Seleziona via controller dalla prima parola dell'item [from] fino dentro
/// l'item [to] (base nel primo, extent nel secondo).
void _selectBetween(WidgetTester tester, {required int from, required int to}) {
  final controller = _scope(tester).controller;
  final start = tester.getTopLeft(_item(from)) + const Offset(8, 8);
  final end = tester.getTopLeft(_item(to)) + const Offset(60, 8);
  expect(
    controller.selectWordAtGlobal(start),
    isNotNull,
    reason: "l'item $from deve contenere testo selezionabile",
  );
  controller.extendToGlobal(end);
  _expectSelectionBlocks(tester, from, to);
}

/// Verifica che la selezione corrente abbia gli estremi negli item [a] e [b]
/// (senza assumere quale sia base e quale extent).
void _expectSelectionBlocks(WidgetTester tester, int a, int b) {
  final selection = _scope(tester).controller.selection;
  expect(selection, isNotNull);
  expect(selection!.isCollapsed, isFalse);
  expect(
    <Object>[selection.base.documentId, selection.extent.documentId],
    unorderedEquals(<String>['block-$a', 'block-$b']),
    reason: 'gli estremi devono stare negli item $a e $b',
  );
}

/// Sposta l'estremo MOBILE dentro l'item [index], come un update di drag.
void _moveExtentTo(WidgetTester tester, int index) {
  _scope(tester)
      .controller
      .extendToGlobal(tester.getTopLeft(_item(index)) + const Offset(60, 8));
}

void main() {
  group('Keep-alive degli estremi durante il trascinamento della selezione', () {
    testWidgets(
      "con un dito giù, spostare l'estremo mobile non cambia i blocchi tenuti vivi",
      (tester) async {
        await _pumpNote(tester, _longNote(600));

        // A riposo: gli estremi (4 e 8) vengono fissati subito.
        _selectBetween(tester, from: 4, to: 8);
        await tester.pump();

        final finger = await tester.startGesture(_padCenter(tester));

        // Come un drag di maniglia: l'estremo mobile passa dal blocco 8 al 12
        // (in mezzo ci sono blocchi spaziatori).
        _moveExtentTo(tester, 12);
        await tester.pump();
        _expectSelectionBlocks(tester, 4, 12);

        // Si va lontano MENTRE il dito è giù (es. auto-scroll).
        await _scrollTo(tester, 12000);
        expect(
          _item(4, skipOffstage: false),
          findsOneWidget,
          reason: "l'ancora resta fissata",
        );
        expect(
          _item(8, skipOffstage: false),
          findsOneWidget,
          reason: 'nessun rilascio durante il gesto: lo stato dei keep-alive '
              'è congelato finché il dito è giù',
        );
        expect(
          _item(12, skipOffstage: false),
          findsNothing,
          reason: "il nuovo estremo mobile non viene fissato a ogni evento: "
              "segue il dito, quindi è in viewport e non serve",
        );

        // Al rilascio si pubblica lo stato reale: l'estremo congelato (8) non
        // è più un estremo e viene rilasciato.
        await finger.up();
        await tester.pumpAndSettle();
        expect(_item(8, skipOffstage: false), findsNothing);
        expect(_item(4, skipOffstage: false), findsOneWidget);
      },
    );

    for (final cancelled in <bool>[false, true]) {
      testWidgets(
        'al rilascio (${cancelled ? 'cancel' : 'up'}) il nuovo estremo viene '
        'fissato e il precedente rilasciato',
        (tester) async {
          await _pumpNote(tester, _longNote(600));

          _selectBetween(tester, from: 4, to: 8);
          await tester.pump();

          final finger = await tester.startGesture(_padCenter(tester));
          _moveExtentTo(tester, 12);
          await tester.pump();

          if (cancelled) {
            await finger.cancel();
          } else {
            await finger.up();
          }
          await tester.pump();

          await _scrollTo(tester, 12000);
          expect(_item(4, skipOffstage: false), findsOneWidget);
          expect(
            _item(12, skipOffstage: false),
            findsOneWidget,
            reason: 'al rilascio il nuovo estremo viene fissato',
          );
          expect(
            _item(8, skipOffstage: false),
            findsNothing,
            reason: "l'estremo precedente viene rilasciato",
          );
        },
      );
    }

    testWidgets(
      "l'ancora si fissa subito anche se la selezione nasce a dito giù",
      (tester) async {
        await _pumpNote(tester, _longNote(600));

        // Come long-press + trascinamento senza staccare il dito: la
        // selezione nasce con il puntatore ancora premuto.
        final finger = await tester.startGesture(_padCenter(tester));
        _selectBetween(tester, from: 4, to: 8);
        await tester.pump();

        // L'auto-scroll può portare l'ancora lontano prima del rilascio:
        // deve già essere tenuta viva.
        await _scrollTo(tester, 12000);
        expect(
          _item(4, skipOffstage: false),
          findsOneWidget,
          reason: "l'ancora non deve sparire se si scrolla lontano a dito giù",
        );
        expect(
          _item(8, skipOffstage: false),
          findsNothing,
          reason: "l'estremo mobile non è fissato finché il dito è giù",
        );

        await finger.up();
        await tester.pumpAndSettle();
        expect(_item(4, skipOffstage: false), findsOneWidget);
      },
    );

    testWidgets(
      "durante un gesto l'ancora cambia al massimo una volta",
      (tester) async {
        await _pumpNote(tester, _longNote(600));

        _selectBetween(tester, from: 4, to: 8);
        await tester.pump();

        final finger = await tester.startGesture(_padCenter(tester));
        final controller = _scope(tester).controller;

        // Prima nuova selezione nel gesto: ancora nel blocco 6. È l'unico
        // cambio di ancora pubblicato subito.
        controller.selectWordAtGlobal(
          tester.getTopLeft(_item(6)) + const Offset(8, 8),
        );
        await tester.pump();
        // Seconda nuova selezione nello stesso gesto: ancora nel blocco 10.
        // Il cambio NON viene pubblicato fino al rilascio.
        controller.selectWordAtGlobal(
          tester.getTopLeft(_item(10)) + const Offset(8, 8),
        );
        await tester.pump();

        await _scrollTo(tester, 12000);
        expect(
          _item(6, skipOffstage: false),
          findsOneWidget,
          reason: 'primo cambio di ancora: pubblicato subito',
        );
        expect(
          _item(8, skipOffstage: false),
          findsOneWidget,
          reason: "l'estremo mobile pubblicato resta com'era",
        );
        expect(
          _item(4, skipOffstage: false),
          findsNothing,
          reason: 'la vecchia ancora è stata sostituita dal primo cambio',
        );
        expect(
          _item(10, skipOffstage: false),
          findsNothing,
          reason: 'secondo cambio di ancora nello stesso gesto: congelato '
              'fino al rilascio',
        );

        await finger.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'senza puntatori premuti lo stato segue la selezione subito',
      (tester) async {
        await _pumpNote(tester, _longNote(600));

        _selectBetween(tester, from: 4, to: 8);
        await tester.pump();
        _moveExtentTo(tester, 12);
        await tester.pump();

        await _scrollTo(tester, 12000);
        expect(_item(4, skipOffstage: false), findsOneWidget);
        expect(_item(12, skipOffstage: false), findsOneWidget);
        expect(
          _item(8, skipOffstage: false),
          findsNothing,
          reason: 'a riposo (tastiera, "seleziona tutto", ...) nessun ritardo',
        );
      },
    );

    testWidgets(
      'un puntatore rimosso senza PointerUp chiude il gesto rimasto aperto',
      (tester) async {
        await _pumpNote(tester, _longNote(600));

        _selectBetween(tester, from: 4, to: 8);
        await tester.pump();

        // Puntatore touch del device 7 premuto sulla zona neutra: il suo
        // PointerUp "non arriva mai" (es. mouse rilasciato fuori finestra).
        final pointer = TestPointer(1, PointerDeviceKind.touch, 7);
        await tester.sendEventToBinding(pointer.down(_padCenter(tester)));

        _moveExtentTo(tester, 12);
        await tester.pump();

        // Il device viene rimosso: la rete di sicurezza chiude il gesto e
        // pubblica lo stato reale.
        await tester.sendEventToBinding(const PointerRemovedEvent(device: 7));
        await tester.pump();

        await _scrollTo(tester, 12000);
        expect(_item(12, skipOffstage: false), findsOneWidget);
        expect(_item(8, skipOffstage: false), findsNothing);

        // Chiude il puntatore anche lato binding (hit test in cache).
        await tester.sendEventToBinding(pointer.up());
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'lo smontaggio toglie la route globale dei puntatori',
      (tester) async {
        final router = GestureBinding.instance.pointerRouter;
        final baseline = router.debugGlobalRouteCount;

        await _pumpNote(tester, _longNote(20));
        expect(
          router.debugGlobalRouteCount,
          greaterThan(baseline),
          reason: 'la vista registra le sue route globali (auto-scroll e '
              'tracciamento dei puntatori)',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        expect(
          router.debugGlobalRouteCount,
          baseline,
          reason: 'nessuna route globale deve sopravvivere allo smontaggio',
        );
      },
    );
  });
}
