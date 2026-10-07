import 'package:flutter/material.dart';
import 'package:flutter_md/flutter_md.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/core/utils/haptics_helper.dart';
import 'package:scripta/features/editor/presentation/markdown_rendered_view.dart';

// Regressione su orologio e `Timer` della vista di lettura.
//
// Nei test (`testWidgets`) il tempo è FINTO (`FakeAsync`): `tester.pump(d)`
// e `tester.longPressAt` fanno avanzare solo quell'orologio, mentre
// `DateTime.now()` continua a restituire l'ora di sistema. Due conseguenze,
// entrambe già costate un giro di CI:
//
// 1. La durata di un tap NON si può misurare con due `DateTime.now()`: un
//    long-press simulato sembrerebbe durare ~0 ms, verrebbe scambiato per un
//    tap breve e il rilascio annullerebbe subito la selezione appena creata.
//    La soglia è un `Timer` (che segue l'orologio finto): vedi
//    `_PendingTap` in `markdown_rendered_view.dart`.
// 2. A fine test `flutter_test` smonta l'albero e poi verifica che non sia
//    rimasto nessun `Timer` ("A Timer is still pending even after the widget
//    tree was disposed"). I timer di tap e quello di riarmo aptico (statico,
//    in `HapticsHelper`) devono quindi essere annullati da `dispose()`.

String _note(int paragraphs) =>
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
        body: ProviderScope(
          // Titolo vuoto: nessun item titolo, quindi l'indice dell'item nella
          // lista coincide con il numero di `documentId` ('block-N').
          child: MarkdownRenderedView(title: '', content: content),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Item della lista per indice (chiave assegnata da `_buildItem`). Gli indici
/// PARI sono paragrafi: fra un paragrafo e l'altro il parser inserisce un
/// blocco spaziatore (riga vuota).
Finder _item(int index) =>
    find.byKey(ValueKey<String>('rendered-block-$index'));

MarkdownSelectionScopeState _scope(WidgetTester tester) => tester
    .state<MarkdownSelectionScopeState>(find.byType(MarkdownSelectionScope));

/// Punto sulla prima parola dell'item [index].
Offset _wordPoint(WidgetTester tester, int index) =>
    tester.getTopLeft(_item(index)) + const Offset(8, 8);

/// Seleziona via controller (nessun puntatore, quindi nessun timer di gesto)
/// la prima parola dell'item [index].
void _selectWord(WidgetTester tester, int index) {
  expect(
    _scope(tester).controller.selectWordAtGlobal(_wordPoint(tester, index)),
    isNotNull,
    reason: "l'item $index deve contenere testo selezionabile",
  );
}

void main() {
  group('HapticsHelper: timer di riarmo', () {
    setUp(() {
      HapticsHelper.intensity = HapticIntensity.light;
      HapticsHelper.resetSelectionState();
    });
    tearDown(() {
      HapticsHelper.intensity = HapticIntensity.light;
      HapticsHelper.resetSelectionState();
    });

    testWidgets(
      'resetSelectionState annulla il timer di riarmo in sospeso',
      (tester) async {
        // Selezione collassata: parte il timer di riarmo (200 ms).
        HapticsHelper.reportSelectionState(isCollapsed: true);
        HapticsHelper.resetSelectionState();

        // Nessun pump: se il timer fosse ancora vivo, a fine test
        // `flutter_test` fallirebbe con "A Timer is still pending even after
        // the widget tree was disposed".
      },
    );

    testWidgets(
      'resetSelectionState riarma subito il colpetto "light"',
      (tester) async {
        expect(
          HapticsHelper.gateNativeHapticCall(),
          isTrue,
          reason: 'armato: il primo colpetto passa',
        );
        expect(
          HapticsHelper.gateNativeHapticCall(),
          isFalse,
          reason: 'già concesso per questa selezione',
        );

        // Riarmo pianificato fra 200 ms, poi azzerato dal reset...
        HapticsHelper.reportSelectionState(isCollapsed: true);
        HapticsHelper.resetSelectionState();

        // ...che riarma subito, senza aspettare il timer.
        expect(HapticsHelper.gateNativeHapticCall(), isTrue);
      },
    );

    testWidgets(
      'senza reset il riarmo scatta dopo 200 ms di quiete (orologio finto)',
      (tester) async {
        expect(HapticsHelper.gateNativeHapticCall(), isTrue);

        HapticsHelper.reportSelectionState(isCollapsed: true);
        expect(
          HapticsHelper.gateNativeHapticCall(),
          isFalse,
          reason: 'il timer di riarmo non è ancora scaduto',
        );

        await tester.pump(const Duration(milliseconds: 250));
        expect(HapticsHelper.gateNativeHapticCall(), isTrue);
      },
    );
  });

  group('Vista di lettura: tap, long-press e Timer', () {
    testWidgets(
      'un long-press (orologio finto) non è un tap: la selezione sopravvive '
      'al rilascio',
      (tester) async {
        await _pumpNote(tester, _note(30));

        // `longPressAt` tiene premuto 600 ms di tempo FINTO. Con una soglia
        // basata su `DateTime.now()` il rilascio sarebbe sembrato un tap
        // breve e avrebbe annullato la selezione appena creata.
        await tester.longPressAt(_wordPoint(tester, 4));
        await tester.pumpAndSettle();

        final selection = _scope(tester).controller.selection;
        expect(selection, isNotNull, reason: 'il long-press seleziona');
        expect(selection!.isCollapsed, isFalse);
      },
    );

    testWidgets(
      'un tap breve con una selezione attiva la annulla',
      (tester) async {
        await _pumpNote(tester, _note(30));
        _selectWord(tester, 4);
        await tester.pump();
        expect(_scope(tester).controller.selection, isNotNull);

        await tester.tapAt(_wordPoint(tester, 10));
        // Chiude la finestra del doppio-tap (300 ms) e il riarmo aptico
        // (200 ms) senza lasciare timer in giro.
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          _scope(tester).controller.selection,
          isNull,
          reason: 'un tap breve a vuoto deve annullare la selezione',
        );
      },
    );

    testWidgets(
      'un trascinamento oltre la soglia di tocco non annulla la selezione',
      (tester) async {
        await _pumpNote(tester, _note(30));
        _selectWord(tester, 4);
        await tester.pump();

        final gesture = await tester.startGesture(_wordPoint(tester, 10));
        await gesture.moveBy(const Offset(0, -60));
        await tester.pump();
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          _scope(tester).controller.selection,
          isNotNull,
          reason: 'uno scroll non è un tap',
        );
      },
    );

    testWidgets(
      'annullare la selezione non lascia Timer pendenti allo smontaggio',
      (tester) async {
        await _pumpNote(tester, _note(30));
        _selectWord(tester, 4);
        await tester.pump();

        // Selezione annullata: parte il timer di riarmo aptico (200 ms).
        _scope(tester).clearSelection();
        await tester.pump();
        expect(_scope(tester).controller.selection, isNull);

        // Nessun pump oltre i 200 ms: il timer è ancora in attesa e deve
        // essere annullato da `dispose()` (altrimenti il test fallisce con
        // "A Timer is still pending even after the widget tree was
        // disposed").
      },
    );

    testWidgets(
      'smontando la vista con un puntatore ancora premuto non resta nessun '
      'Timer',
      (tester) async {
        await _pumpNote(tester, _note(30));

        // Nessun `up`/`cancel`: a fine test l'albero viene smontato mentre il
        // timer di scadenza del tap è ancora in corsa; `dispose()` deve
        // annullarlo.
        await tester.startGesture(_wordPoint(tester, 10));
      },
    );
  });
}
