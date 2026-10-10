import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart'
    show
        PointerDeviceKind,
        kLongPressTimeout,
        kPressTimeout,
        kPrimaryButton,
        kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_md/flutter_md.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/features/editor/presentation/markdown_rendered_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Test dello step A: un long-press touch DENTRO una selezione esistente la
// lascia identica e riporta maniglie e menù (vedi
// `_MarkdownRenderedViewState._recallSelectionUi` e
// `_SelectionRecallRecognizer` in markdown_rendered_view.dart).
//
// NOTE SU COME SONO SCRITTI (leggere prima di "aggiustare" un'asserzione):
//  * Il contatore `MarkdownRenderedView.debugSelectionRecallCount` è la prova
//    deterministica che il richiamo è scattato (o NON è scattato): nei casi
//    "fuori dalla selezione", tap e mouse l'effetto visibile coinciderebbe con
//    quello del pacchetto, quindi non basterebbe guardare la selezione.
//  * Le maniglie sono contate per NOME del tipo privato di Flutter
//    (`_SelectionHandleOverlay`): fragile, ma è l'unico modo di vederle da un
//    test. Se Flutter lo rinominasse, il test "Precondizioni" fallisce per
//    primo con un messaggio esplicito (e `_areSelectionHandlesShown` in
//    produzione soffre dello stesso limite: vedi il suo commento).
//  * `debugDefaultTargetPlatformOverride` va ripristinato DENTRO il corpo del
//    test (try/finally in `_withPlatform`): i controlli di fine test del
//    framework girano prima dei callback di `addTearDown`.
//  * L'app misura la durata di un tap con `DateTime.now()` (orologio REALE,
//    non FakeAsync): per far sembrare "lungo" un long-press serve un'attesa
//    reale (`_holdLongPress`), non solo `pump(Duration)`.
//  * Dopo ogni selezione che collassa parte un Timer da 200 ms di
//    `HapticsHelper.reportSelectionState`: ogni test lascia scorrere un
//    secondo a fine corpo, altrimenti il Timer risulterebbe ancora pendente.

const String _note = 'Primo paragrafo con alcune parole.\n\n'
    'Secondo paragrafo di testo qualsiasi.\n\n'
    'Terzo paragrafo, ancora un po di testo.\n\n'
    'Quarto paragrafo da selezionare.\n\n'
    'Quinto paragrafo finale.';

// Blocco della parola selezionata: il QUARTO, non il primo. Il menù compare
// SOPRA la selezione (con la selezione in cima alla vista verrebbe spinto
// sulla riga stessa e coprirebbe il punto che i test toccano), mentre le
// maniglie stanno sotto la riga: la riga del quarto blocco ha spazio libero
// sopra e il punto toccato (centro della riga) non è coperto da nulla.
const int _selectedBlock = 3;
const String _selectedWord = 'Quarto';

// Blocco "altrove": il primo, lontano da selezione, menù e maniglie.
const int _otherBlock = 0;
const String _otherWord = 'Primo';

// Abbastanza blocchi da far uscire dalla `cacheExtent` della ListView quelli
// in cima quando si scorre in fondo (estremo della selezione smontato).
final String _longNote = List<String>.generate(
  80,
  (i) => 'Paragrafo numero $i con del testo di riempimento.',
).join('\n\n');

/// Imposta la piattaforma, esegue [body] e la ripristina SEMPRE.
Future<void> _withPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

class _PlatformLog {
  int vibrations = 0;
}

/// Mock del canale `flutter/platform`: senza handler le chiamate a
/// `HapticFeedback`/`Clipboard` lancerebbero `MissingPluginException`. Conta le
/// vibrazioni, così si può verificare che il richiamo NON faccia vibrare.
void _mockPlatformChannel(WidgetTester tester, _PlatformLog log) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async {
      if (call.method == 'HapticFeedback.vibrate') log.vibrations++;
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
}

Future<void> _pumpView(WidgetTester tester, String content) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
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
          child: MarkdownRenderedView(title: '', content: content),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

MarkdownSelectionScopeState _scope(WidgetTester tester) =>
    tester.state<MarkdownSelectionScopeState>(
      find.byType(MarkdownSelectionScope),
    );

/// Un punto dentro la prima parola del blocco [blockIndex] (il testo parte
/// dall'angolo in alto a sinistra del `MarkdownWidget`, qualunque sia il font).
Offset _wordPoint(WidgetTester tester, int blockIndex) =>
    tester.getTopLeft(find.byType(MarkdownWidget).at(blockIndex)) +
    const Offset(8, 8);

Finder get _handles => find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_SelectionHandleOverlay',
    );

int _handleCount() => _handles.evaluate().length;

/// Tiene premuto [position] oltre la soglia di long-press, poi rilascia.
/// L'attesa reale da 560 ms serve all'orologio `DateTime.now()` dell'app (vedi
/// le note in testa al file); `pump` fa scadere i timer dei recognizer.
Future<void> _holdLongPress(
  WidgetTester tester,
  Offset position, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
  int buttons = kPrimaryButton,
}) async {
  final gesture = await tester.createGesture(kind: kind, buttons: buttons);
  if (kind != PointerDeviceKind.touch) {
    await gesture.addPointer(location: position);
  }
  await gesture.down(position);
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 560)),
  );
  await tester.pump(kLongPressTimeout + kPressTimeout);
  await gesture.up();
  await tester.pump();
  if (kind != PointerDeviceKind.touch) {
    await gesture.removePointer();
  }
}

/// Crea la selezione di partenza col long-press "vero" del pacchetto
/// (parola sotto il dito, maniglie, menù a fine gesto).
Future<MarkdownSelection> _selectWordByLongPress(
  WidgetTester tester,
  int blockIndex,
) async {
  await _holdLongPress(tester, _wordPoint(tester, blockIndex));
  await tester.pumpAndSettle();
  final selection = _scope(tester).controller.selection;
  expect(
    selection,
    isNotNull,
    reason: 'il long-press fuori da ogni selezione deve selezionare la parola',
  );
  expect(selection!.isCollapsed, isFalse);
  return selection;
}

/// Punto al centro del primo rettangolo della selezione corrente.
Offset _insideSelection(WidgetTester tester) {
  final rects = _scope(tester).controller.globalSelectionRects();
  expect(rects, isNotEmpty, reason: 'la selezione deve essere visibile');
  return rects.first.center;
}

Future<void> _drainTimers(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 1));

// Pausa fra due gesti distinti: più di `kDoubleTapTimeout` (300 ms).
const Duration _betweenGestures = Duration(milliseconds: 500);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MarkdownRenderedView.debugSelectionRecallCount = 0;
  });

  group('Step A: richiamo di maniglie e menù con long-press sulla selezione',
      () {
    testWidgets(
      '0. Precondizioni: il long-press fuori da ogni selezione crea selezione, menù e maniglie',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          _mockPlatformChannel(tester, _PlatformLog());
          await _pumpView(tester, _note);

          await _selectWordByLongPress(tester, _selectedBlock);

          expect(
            _scope(tester).toolbarIsVisible,
            isTrue,
            reason: 'README flutter_md: il long-press mobile mostra il menù',
          );
          expect(
            _handleCount(),
            greaterThan(0),
            reason: 'su Android il pacchetto mostra le maniglie; se questa '
                'asserzione fallisce il nome del tipo privato di Flutter è '
                'cambiato (vedi note in testa al file)',
          );
          expect(MarkdownRenderedView.debugSelectionRecallCount, 0);

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '1. long-press DENTRO la selezione: selezione identica, nessun frame intermedio, maniglie e menù presenti e non ricreati',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          final log = _PlatformLog();
          _mockPlatformChannel(tester, log);
          await _pumpView(tester, _note);

          final scope = _scope(tester);
          final controller = scope.controller;
          final initial = await _selectWordByLongPress(tester, _selectedBlock);

          // Maniglie e menù sono già visibili: il richiamo non deve
          // ricrearli (niente lampeggio, niente toggle). Si confrontano le
          // ISTANZE degli Element, non solo il conteggio.
          final toolbarBefore =
              find.byType(AdaptiveTextSelectionToolbar).evaluate().single;
          final handlesBefore = _handles.evaluate().toList();
          expect(handlesBefore, isNotEmpty);

          // "Nessun frame intermedio": il controller notifica in modo
          // SINCRONO a ogni cambio, quindi se la parola sotto il dito fosse
          // stata selezionata anche solo per un istante, qui la vedremmo.
          final deviations = <MarkdownSelection?>[];
          void record() {
            if (controller.selection != initial) {
              deviations.add(controller.selection);
            }
          }

          controller.addListener(record);
          addTearDown(() => controller.removeListener(record));

          log.vibrations = 0;
          MarkdownRenderedView.debugSelectionRecallCount = 0;

          await _holdLongPress(tester, _insideSelection(tester));
          await tester.pumpAndSettle();

          expect(
            deviations,
            isEmpty,
            reason: 'la selezione non deve mai assumere un valore diverso',
          );
          expect(controller.selection, initial);
          expect(scope.toolbarIsVisible, isTrue);
          expect(
            find.byType(AdaptiveTextSelectionToolbar).evaluate().single,
            same(toolbarBefore),
            reason: 'il menù era già visibile: non va ricreato',
          );
          final handlesAfter = _handles.evaluate().toList();
          expect(handlesAfter.length, handlesBefore.length);
          for (var i = 0; i < handlesAfter.length; i++) {
            expect(
              handlesAfter[i],
              same(handlesBefore[i]),
              reason: 'le maniglie erano già visibili: non vanno ricostruite',
            );
          }
          expect(
            log.vibrations,
            0,
            reason: 'il gestore del long-press del pacchetto non deve partire '
                '(farebbe vibrare); un ripristino programmatico non vibra',
          );
          expect(MarkdownRenderedView.debugSelectionRecallCount, 1);

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '2. stato "maniglie/menù scomparsi" (HANDOFF, Punto 3, condizioni 2, 6 e 8: hideToolbar, estremo smontato e rimontato, focus perso): il long-press li ripristina',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          final log = _PlatformLog();
          _mockPlatformChannel(tester, log);
          await _pumpView(tester, _longNote);

          final scope = _scope(tester);
          final controller = scope.controller;
          final initial = await _selectWordByLongPress(tester, _selectedBlock);
          expect(_handleCount(), greaterThan(0));

          // Condizione 6: l'estremo esce dalla cacheExtent (blocco smontato) e
          // poi torna. Se le maniglie tornino da sole al rimontaggio non è
          // verificato sul codice del pacchetto, quindi non lo si assume (né
          // si asserisce che il blocco sia davvero smontato: dipende dalla
          // ListView); conta lo stato finale dopo il richiamo.
          final scrollable = tester.state<ScrollableState>(
            find.descendant(
              of: find.byKey(const ValueKey('markdown-formatted-listview')),
              matching: find.byType(Scrollable),
            ),
          );
          scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
          await tester.pump();
          scrollable.position.jumpTo(0);
          await tester.pumpAndSettle();
          expect(controller.selection, initial);

          // Condizioni 2 e 8: menù nascosto da codice e focus perso.
          scope.hideToolbar();
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pump();
          expect(scope.toolbarIsVisible, isFalse);

          log.vibrations = 0;
          MarkdownRenderedView.debugSelectionRecallCount = 0;

          await _holdLongPress(tester, _insideSelection(tester));
          await tester.pumpAndSettle();

          expect(controller.selection, initial);
          expect(scope.toolbarIsVisible, isTrue);
          expect(
            _handleCount(),
            greaterThan(0),
            reason: 'le maniglie devono essere tornate (se questa asserzione '
                'fallisce, l\'espediente _rebuildSelectionOverlay non basta '
                'con questa versione del pacchetto: vedi HANDOFF, Step A)',
          );
          expect(log.vibrations, 0);
          expect(MarkdownRenderedView.debugSelectionRecallCount, 1);

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '3. long-press FUORI dalla selezione: nuova selezione per parola, come prima (nessun richiamo)',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          _mockPlatformChannel(tester, _PlatformLog());
          await _pumpView(tester, _note);

          final controller = _scope(tester).controller;
          final first = await _selectWordByLongPress(tester, _selectedBlock);
          expect(controller.getText(), _selectedWord);

          // Primo blocco: ben oltre i 10px di tolleranza dalla selezione.
          await _holdLongPress(tester, _wordPoint(tester, _otherBlock));
          await tester.pumpAndSettle();

          expect(controller.selection, isNot(first));
          expect(
            controller.getText(),
            _otherWord,
            reason: 'il long-press fuori dalla selezione seleziona la parola',
          );
          expect(
            MarkdownRenderedView.debugSelectionRecallCount,
            0,
            reason: 'fuori dalla selezione agisce il pacchetto, non il richiamo',
          );

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '4. tap (a vuoto e sulla selezione) e double-tap: invariati e senza ritardi',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          _mockPlatformChannel(tester, _PlatformLog());
          await _pumpView(tester, _note);

          final scope = _scope(tester);
          final controller = scope.controller;
          await _selectWordByLongPress(tester, _selectedBlock);

          // Tap breve a vuoto (margine sinistro): la selezione si annulla
          // subito, senza far avanzare il tempo.
          await tester.tapAt(const Offset(4, 300));
          await tester.pump();
          expect(
            controller.selection == null || controller.selection!.isCollapsed,
            isTrue,
            reason: 'un tap a vuoto annulla la selezione, come prima',
          );
          // Fra un gesto e il successivo si lascia scadere il timeout del
          // double-tap (300 ms): due tap ravvicinati verrebbero fusi in uno.
          await tester.pump(_betweenGestures);

          // Tap breve SULLA selezione: l'app lo tratta come un tap (annulla);
          // il recognizer di richiamo non deve inghiottirlo.
          final wordPoint = _wordPoint(tester, _selectedBlock);
          controller.selectWordAtGlobal(wordPoint);
          await tester.pump();
          expect(controller.selection!.isCollapsed, isFalse);
          await tester.tapAt(_insideSelection(tester));
          await tester.pump();
          expect(
            controller.selection == null || controller.selection!.isCollapsed,
            isTrue,
            reason: 'un tap sulla selezione la annulla, come prima',
          );
          await tester.pump(_betweenGestures);

          // Double-tap sulla parola: seleziona la parola (README flutter_md).
          await tester.tapAt(wordPoint);
          await tester.pump(const Duration(milliseconds: 50));
          await tester.tapAt(wordPoint);
          await tester.pumpAndSettle();
          expect(controller.getText(), _selectedWord);

          expect(
            MarkdownRenderedView.debugSelectionRecallCount,
            0,
            reason: 'tap e double-tap non sono long-press: nessun richiamo',
          );

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '5. mouse, penna e tasto destro: nessun richiamo (supportedDevices = solo touch)',
      (tester) async {
        await _withPlatform(TargetPlatform.linux, () async {
          _mockPlatformChannel(tester, _PlatformLog());
          await _pumpView(tester, _note);

          final controller = _scope(tester).controller;
          final wordPoint = _wordPoint(tester, _selectedBlock);

          for (final kind in <PointerDeviceKind>[
            PointerDeviceKind.mouse,
            PointerDeviceKind.stylus,
          ]) {
            // Tasto primario tenuto premuto sulla selezione.
            controller.selectWordAtGlobal(wordPoint);
            await tester.pump();
            await _holdLongPress(tester, _insideSelection(tester), kind: kind);
            expect(
              MarkdownRenderedView.debugSelectionRecallCount,
              0,
              reason: 'long-press con $kind: il richiamo è solo per il touch',
            );

            // Tasto destro (menu contestuale) sulla selezione.
            controller.selectWordAtGlobal(wordPoint);
            await tester.pump();
            await _holdLongPress(
              tester,
              _insideSelection(tester),
              kind: kind,
              buttons: kSecondaryButton,
            );
            expect(
              MarkdownRenderedView.debugSelectionRecallCount,
              0,
              reason: 'tasto destro con $kind: il richiamo è solo per il touch',
            );
          }

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '6. multi-touch e spostamento oltre kTouchSlop: nessun richiamo',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          _mockPlatformChannel(tester, _PlatformLog());
          await _pumpView(tester, _note);

          final controller = _scope(tester).controller;
          controller.selectWordAtGlobal(_wordPoint(tester, _selectedBlock));
          await tester.pump();
          final inside = _insideSelection(tester);

          // Due dita: una sulla selezione, una altrove.
          final first = await tester.startGesture(inside, pointer: 1);
          final second = await tester.startGesture(
            const Offset(300, 600),
            pointer: 2,
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 560)),
          );
          await tester.pump(kLongPressTimeout + kPressTimeout);
          await first.up();
          await second.up();
          await tester.pump();
          expect(
            MarkdownRenderedView.debugSelectionRecallCount,
            0,
            reason: 'multi-touch: il richiamo non scatta',
          );

          // Un dito che si sposta oltre la soglia: è uno scroll, non un
          // long-press.
          controller.selectWordAtGlobal(_wordPoint(tester, _selectedBlock));
          await tester.pump();
          final moving = await tester.startGesture(
            _insideSelection(tester),
            pointer: 3,
          );
          await moving.moveBy(const Offset(0, 40));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 560)),
          );
          await tester.pump(kLongPressTimeout + kPressTimeout);
          await moving.up();
          await tester.pump();
          expect(
            MarkdownRenderedView.debugSelectionRecallCount,
            0,
            reason: 'spostamento oltre kTouchSlop: il richiamo non scatta',
          );

          await _drainTimers(tester);
        });
      },
    );
  });
}
