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
import 'package:scripta/core/theme/app_theme.dart';
import 'package:scripta/features/editor/presentation/markdown_rendered_view.dart';
import 'package:scripta/features/editor/presentation/selection_handle_visibility.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Test del RICHIAMO: un long-press touch DENTRO una selezione esistente la
// lascia identica e riporta maniglie e menù (vedi
// `_MarkdownRenderedViewState._recallSelectionUi` e
// `_SelectionRecallRecognizer` in markdown_rendered_view.dart).
//
// NOTE SU COME SONO SCRITTI (leggere prima di "aggiustare" un'asserzione):
//  * Il contatore `MarkdownRenderedView.debugSelectionRecallCount` è la prova
//    deterministica che il richiamo è scattato (o NON è scattato): nei casi
//    "fuori dalla selezione", tap e mouse l'effetto visibile coinciderebbe con
//    quello del pacchetto, quindi non basterebbe guardare la selezione.
//  * Le maniglie si TROVANO per NOME del tipo privato di Flutter
//    (`_SelectionHandleOverlay`): fragile, ma è l'unico modo di vederle da un
//    test. NON basta che esistano: i test misurano se sono DIPINTE
//    (`_realHandles`: follower collegato, opacità effettiva > 0, nessun
//    Offstage, rettangolo dentro la viewport). Contare solo l'esistenza del
//    widget lasciava i test verdi anche con le maniglie invisibili sul
//    tablet. Se Flutter rinominasse il tipo, il test "Precondizioni"
//    fallisce per primo con un messaggio esplicito.
//  * `debugDefaultTargetPlatformOverride` va ripristinato DENTRO il corpo del
//    test (try/finally in `_withPlatform`): i controlli di fine test del
//    framework girano prima dei callback di `addTearDown`.
//  * L'app misura la durata di un tap con `DateTime.now()` (orologio REALE,
//    non FakeAsync): per far sembrare "lungo" un long-press serve un'attesa
//    reale (`_holdLongPress`), non solo `pump(Duration)`.
//  * Dopo ogni selezione che collassa parte un Timer da 200 ms di
//    `HapticsHelper.reportSelectionState`: ogni test lascia scorrere un
//    secondo a fine corpo, altrimenti il Timer risulterebbe ancora pendente.

const String _note =
    'Primo paragrafo con alcune parole.\n\n'
    'Secondo paragrafo di testo qualsiasi.\n\n'
    'Terzo paragrafo, ancora un po di testo.\n\n'
    'Quarto paragrafo da selezionare.\n\n'
    'Quinto paragrafo finale.';

// Paragrafo (con testo, 0 = il primo) della parola selezionata: il QUARTO, non
// il primo. Il menù compare SOPRA la selezione (con la selezione in cima alla
// vista verrebbe spinto sulla riga stessa e coprirebbe il punto che i test
// toccano), mentre le maniglie stanno sotto la riga: la riga del quarto blocco
// ha spazio libero sopra e il punto toccato (centro della riga) non è coperto
// da nulla.
const int _selectedBlock = 3;
const String _selectedWord = 'Quarto';

// Paragrafo "altrove": il primo, lontano da selezione, menù e maniglie.
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
  await _locateWords(tester);
}

MarkdownSelectionScopeState _scope(WidgetTester tester) => tester
    .state<MarkdownSelectionScopeState>(find.byType(MarkdownSelectionScope));

/// Punti di tocco che colpiscono DAVVERO una parola: uno per paragrafo CON
/// testo, in ordine di lettura (indice 0 = primo paragrafo). Si riempie in
/// `_locateWords` (chiamata da `_pumpView`, PRIMA di qualunque selezione).
///
/// Perché non si usa `find.byType(MarkdownWidget).at(n)`: in CI una nota di 5
/// paragrafi produceva 9 `MarkdownWidget` (tra un paragrafo e l'altro ci sono
/// blocchi vuoti, non selezionabili) e il "blocco 3" era una riga vuota.
final List<Offset> _wordPoints = <Offset>[];

/// Cerca un punto dentro [rect] che selezioni una parola; `null` se non c'è
/// (blocco vuoto). La prova è distruttiva (crea e annulla una selezione): si
/// fa una volta sola, a vista appena montata e senza selezioni.
Future<Offset?> _selectablePointIn(
  WidgetTester tester,
  MarkdownSelectionScopeState scope,
  Rect rect,
) async {
  final controller = scope.controller;
  for (final dy in <double>[8, 12, 4]) {
    for (final dx in <double>[8, 24, 40, 64, 96]) {
      final point = rect.topLeft + Offset(dx, dy);
      if (!rect.contains(point)) continue;
      controller.selectWordAtGlobal(point);
      final selection = controller.selection;
      final hit = selection != null && !selection.isCollapsed;
      scope.clearSelection();
      await tester.pump();
      if (hit) return point;
    }
  }
  return null;
}

/// Riempie [_wordPoints] con i primi paragrafi che hanno testo.
Future<void> _locateWords(WidgetTester tester) async {
  final scope = _scope(tester);
  _wordPoints.clear();
  final widgets = find.byType(MarkdownWidget);
  final count = widgets.evaluate().length;
  for (var i = 0; i < count && _wordPoints.length <= _selectedBlock; i++) {
    final point = await _selectablePointIn(
      tester,
      scope,
      tester.getRect(widgets.at(i)),
    );
    if (point != null) _wordPoints.add(point);
  }
  if (_wordPoints.length <= _selectedBlock) {
    fail(
      'Trovati solo ${_wordPoints.length} paragrafi selezionabili su $count '
      'MarkdownWidget (ne servono ${_selectedBlock + 1}); superfici '
      'montate=${scope.controller.mountedSurfaces.length}',
    );
  }
  // Lascia scadere i Timer da 200 ms di `HapticsHelper` creati dalle prove.
  await tester.pump(const Duration(seconds: 1));
}

/// Punto (già verificato da `_locateWords`) dentro una parola del
/// [paragraph]-esimo paragrafo con testo (0 = il primo).
Offset _wordPoint(int paragraph) {
  if (paragraph >= _wordPoints.length) {
    fail('_locateWords non ha registrato il paragrafo $paragraph');
  }
  return _wordPoints[paragraph];
}

/// Finder per ESISTENZA del widget (per nome del tipo): serve SOLO a
/// confrontare le istanze degli `Element` prima e dopo (test 1). Non dice
/// nulla sulla visibilità: per quella vedi [_realHandles].
Finder get _handles => find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString() == '_SelectionHandleOverlay',
);

/// Stato REALE di ogni maniglia presente nell'overlay radice: dipinta o no.
List<SelectionHandleStatus> _realHandles(WidgetTester tester) =>
    inspectSelectionHandles(tester.element(find.byType(MarkdownRenderedView)));

/// Rettangolo della viewport di scroll (la `ListView` della vista).
Rect _viewport(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('markdown-formatted-listview')));

/// `true` se c'è almeno una maniglia e TUTTE sono dipinte e cadono dentro la
/// viewport. È la condizione che l'utente vede: «le maniglie ci sono».
bool _allHandlesVisible(WidgetTester tester) {
  final handles = _realHandles(tester);
  final viewport = _viewport(tester);
  return handles.isNotEmpty &&
      handles.every((handle) => handle.isVisibleIn(viewport));
}

/// Descrizione testuale per i messaggi di errore.
String _describeHandles(WidgetTester tester) {
  final handles = _realHandles(tester);
  if (handles.isEmpty) return 'nessuna maniglia nell\'overlay radice';
  return handles.map((handle) => handle.toString()).join('; ');
}

/// Lo `Scrollable` della `ListView` della vista.
ScrollableState _listScrollable(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('markdown-formatted-listview')),
        matching: find.byType(Scrollable),
      ),
    );

/// Maniglia FINTA: stesso nome del tipo privato del framework, quindi per la
/// misura di visibilità e per un criterio basato sull'esistenza (per nome) è
/// una maniglia vera;
/// ma il suo `LayerLink` non ha leader, quindi il follower non dipinge nulla.
/// Riproduce in modo DETERMINISTICO lo stato «maniglia esistente ma non
/// visibile» senza dipendere da come `flutter_md` ricollega i leader (test 9).
class _SelectionHandleOverlay extends StatefulWidget {
  const _SelectionHandleOverlay({required this.link});

  final LayerLink link;

  @override
  State<_SelectionHandleOverlay> createState() =>
      _SelectionHandleOverlayState();
}

class _SelectionHandleOverlayState extends State<_SelectionHandleOverlay> {
  @override
  Widget build(BuildContext context) {
    return CompositedTransformFollower(
      link: widget.link,
      showWhenUnlinked: false,
      child: const FadeTransition(
        opacity: AlwaysStoppedAnimation<double>(1.0),
        child: SizedBox(width: 24, height: 24),
      ),
    );
  }
}

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
  final point = _wordPoint(blockIndex);
  await _holdLongPress(tester, point);
  await tester.pumpAndSettle();
  final selection = _scope(tester).controller.selection;
  expect(
    selection,
    isNotNull,
    reason:
        'il long-press fuori da ogni selezione deve selezionare la '
        'parola (punto $point)',
  );
  expect(selection!.isCollapsed, isFalse);
  return selection;
}

/// Punto al centro del primo rettangolo della selezione corrente il cui
/// centro cade DENTRO la viewport (con blocchi montati nella `cacheExtent` il
/// primo rettangolo può stare fuori schermo e non sarebbe toccabile).
Offset _insideSelection(WidgetTester tester) {
  final rects = _scope(tester).controller.globalSelectionRects();
  expect(rects, isNotEmpty, reason: 'la selezione deve essere visibile');
  final viewport = _viewport(tester);
  return rects
      .firstWhere(
        (rect) => viewport.contains(rect.center),
        orElse: () => rects.first,
      )
      .center;
}

Future<void> _drainTimers(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 1));

// Pausa fra due gesti distinti: più di `kDoubleTapTimeout` (300 ms).
const Duration _betweenGestures = Duration(milliseconds: 500);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // `AppTheme.getTextStyleForFont` passa sempre da google_fonts: nei test non
  // c'è rete né font negli asset, e google_fonts lancia un'eccezione asincrona
  // NON gestita che, cadendo durante l'attesa REALE di `_holdLongPress`, fa
  // fallire il test ("Failed to load font" / "allowRuntimeFetching is false
  // but font ... was not found"). `GoogleFonts.config.allowRuntimeFetching =
  // false` NON basta (verificato in CI): si esclude google_fonts dal punto
  // unico da cui passa la vista.
  setUpAll(() {
    AppTheme.debugSkipGoogleFonts = true;
  });
  tearDownAll(() {
    AppTheme.debugSkipGoogleFonts = false;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MarkdownRenderedView.debugSelectionRecallCount = 0;
  });

  group('Step A: richiamo di maniglie e menù con long-press sulla selezione', () {
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
            _allHandlesVisible(tester),
            isTrue,
            reason:
                'su Android il pacchetto mostra le maniglie e devono '
                'essere DIPINTE, non solo presenti. Se fallisce: o il nome '
                'del tipo privato di Flutter è cambiato (nessuna maniglia '
                'trovata), o `inspectSelectionHandles` non riconosce la '
                'struttura della maniglia vera, o il pacchetto non le '
                'collega. Stato: ${_describeHandles(tester)}',
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
          final toolbarBefore = find
              .byType(AdaptiveTextSelectionToolbar)
              .evaluate()
              .single;
          final handlesBefore = _handles.evaluate().toList();
          expect(handlesBefore, isNotEmpty);
          expect(
            _allHandlesVisible(tester),
            isTrue,
            reason:
                'precondizione: subito dopo la selezione TUTTE le maniglie '
                'devono essere dipinte e dentro la viewport (se non lo sono, '
                'il richiamo le ricostruirebbe e questo test non misurerebbe '
                'l\'idempotenza). Stato: ${_describeHandles(tester)}',
          );

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
            _allHandlesVisible(tester),
            isTrue,
            reason:
                'dopo il richiamo le maniglie sono ancora tutte dipinte. '
                'Stato: ${_describeHandles(tester)}',
          );
          expect(
            log.vibrations,
            0,
            reason:
                'il gestore del long-press del pacchetto non deve partire '
                '(farebbe vibrare); un ripristino programmatico non vibra',
          );
          expect(MarkdownRenderedView.debugSelectionRecallCount, 1);

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '2. stato "maniglie/menù scomparsi" (menù nascosto, estremo smontato e rimontato, focus perso): il long-press li ripristina',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          final log = _PlatformLog();
          _mockPlatformChannel(tester, log);
          await _pumpView(tester, _longNote);

          final scope = _scope(tester);
          final controller = scope.controller;
          final initial = await _selectWordByLongPress(tester, _selectedBlock);
          expect(
            _allHandlesVisible(tester),
            isTrue,
            reason:
                'precondizione: dopo la selezione le maniglie sono '
                'dipinte. Stato: ${_describeHandles(tester)}',
          );

          // Condizione 6: l'estremo esce dalla cacheExtent (blocco smontato) e
          // poi torna. Se le maniglie tornino da sole al rimontaggio non è
          // verificato sul codice del pacchetto, quindi non lo si assume (né
          // si asserisce che il blocco sia davvero smontato: dipende dalla
          // ListView); conta lo stato finale dopo il richiamo.
          final scrollable = _listScrollable(tester);
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
            _allHandlesVisible(tester),
            isTrue,
            reason:
                'le maniglie devono essere tornate DIPINTE e dentro la '
                'viewport (se questa asserzione fallisce, o il richiamo non '
                'ha ricostruito l\'overlay, o l\'espediente '
                '_rebuildSelectionOverlay non basta con questa versione del '
                'pacchetto). Stato: ${_describeHandles(tester)}',
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
          await _holdLongPress(tester, _wordPoint(_otherBlock));
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
            reason:
                'fuori dalla selezione agisce il pacchetto, non il richiamo',
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
          final wordPoint = _wordPoint(_selectedBlock);
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
          final wordPoint = _wordPoint(_selectedBlock);

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
          controller.selectWordAtGlobal(_wordPoint(_selectedBlock));
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
          controller.selectWordAtGlobal(_wordPoint(_selectedBlock));
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

    // ------------------------------------------------------------------
    // Le maniglie devono essere VISIBILI, non solo presenti.
    // ------------------------------------------------------------------

    testWidgets(
      '7. SINTOMO: la selezione esce dal rendering e rientra; dopo il long-press le maniglie sono DIPINTE (non solo presenti)',
      (tester) async {
        // Scenario dell'utente sul tablet: seleziono, scorro finché la
        // selezione esce dalla vista o dal rendering (le maniglie spariscono),
        // torno sulla selezione e tengo premuto.
        //
        // COME LEGGERE IL RISULTATO. Un richiamo che guardasse solo se il
        // widget della maniglia ESISTE, nello stato del sintomo (maniglia
        // montata ma non collegata all'estremo rimontato) risponderebbe «ci
        // sono» e non farebbe nulla: l'ultima asserzione qui sotto sarebbe
        // ROSSA. Se invece il pacchetto ricollega da solo le maniglie al
        // rimontaggio (`backVisible` vero prima del richiamo), il test è verde
        // anche con quel criterio e la causa del sintomo NON è provata qui:
        // resta da verificare sul dispositivo.
        await _withPlatform(TargetPlatform.android, () async {
          final log = _PlatformLog();
          _mockPlatformChannel(tester, log);
          await _pumpView(tester, _longNote);

          final scope = _scope(tester);
          final controller = scope.controller;
          final initial = await _selectWordByLongPress(tester, _selectedBlock);
          expect(
            _allHandlesVisible(tester),
            isTrue,
            reason:
                'precondizione: subito dopo la selezione le maniglie sono '
                'dipinte. Stato: ${_describeHandles(tester)}',
          );

          // 1) La selezione esce dal rendering (blocco fuori da viewport e
          //    cacheExtent): nessun estremo montato.
          final scrollable = _listScrollable(tester);
          scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(controller.selection, initial);

          // 2) Torna in vista.
          scrollable.position.jumpTo(0);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(controller.selection, initial);
          final backVisible = _allHandlesVisible(tester);

          // 3) Long-press sulla selezione.
          log.vibrations = 0;
          MarkdownRenderedView.debugSelectionRecallCount = 0;
          await _holdLongPress(tester, _insideSelection(tester));
          await tester.pumpAndSettle();

          expect(
            controller.selection,
            initial,
            reason:
                'la selezione deve restare identica (valore) dopo il '
                'richiamo',
          );
          expect(MarkdownRenderedView.debugSelectionRecallCount, 1);
          expect(
            _allHandlesVisible(tester),
            isTrue,
            reason:
                'dopo il long-press le maniglie devono essere DIPINTE e '
                'dentro la viewport. Prima del richiamo erano visibili: '
                '$backVisible. Stato dopo: ${_describeHandles(tester)}; '
                'estremi-montati=${controller.selectionHandleEndpoints() != null}',
          );
          expect(
            log.vibrations,
            0,
            reason: 'il ripristino programmatico non deve far vibrare',
          );

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '8. selezione lunga con gli estremi LONTANI dalla viewport (caso (b)): il richiamo segue la politica B\' e mostra il menù',
      (tester) async {
        // «Seleziona tutto» su una nota lunga e scroll a metà: inizio e fine
        // della selezione (primo e ultimo blocco) sono lontani dalla viewport,
        // in vista c'è solo il centro evidenziato.
        //
        // OSSERVATO IN CI: in questo stato
        // `selectionHandleEndpoints()` NON era null, contro la documentazione
        // del pacchetto. Il caso (b) «nessun estremo montato» quindi non si
        // riesce a produrre con «Seleziona tutto» in questo banco di prova, e
        // una versione precedente di questo test (che lo pretendeva) falliva
        // sulla precondizione. Ora il test non assume nulla sul pacchetto:
        // ricalcola la politica B' di `_selectionHandlesNeedRebuild` con le
        // sole API pubbliche (`expectRebuild`) e verifica che il richiamo la
        // rispetti, cioè che NON ricostruisca (selezione mai null) quando non
        // c'è nulla da ricostruire e ricostruisca quando serve.
        await _withPlatform(TargetPlatform.android, () async {
          final log = _PlatformLog();
          _mockPlatformChannel(tester, log);
          await _pumpView(tester, _longNote);

          final scope = _scope(tester);
          final controller = scope.controller;
          scope.selectAll();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          final initial = controller.selection;
          expect(initial, isNotNull);
          expect(initial!.isCollapsed, isFalse);

          final scrollable = _listScrollable(tester);
          scrollable.position.jumpTo(scrollable.position.maxScrollExtent / 2);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));

          expect(
            controller.globalSelectionRects(),
            isNotEmpty,
            reason: 'precondizione: il centro della selezione è in vista',
          );

          scope.hideToolbar();
          await tester.pump();
          expect(scope.toolbarIsVisible, isFalse);

          // La politica B' riscritta qui con le sole API pubbliche: si
          // ricostruisce solo se almeno un estremo è montato E non tutte le
          // maniglie esistenti sono dipinte.
          final endpointsMounted =
              controller.selectionHandleEndpoints() != null;
          final handlesBefore = _realHandles(tester);
          final expectRebuild =
              endpointsMounted &&
              (handlesBefore.isEmpty ||
                  handlesBefore.any((handle) => !handle.isPainted));

          // Ogni valore della selezione diverso da quello iniziale (`null`,
          // se si ricostruisce) finisce qui.
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
            deviations.isNotEmpty,
            expectRebuild,
            reason: expectRebuild
                ? 'almeno un estremo è montato e non tutte le maniglie sono '
                      'dipinte: il richiamo deve ricostruire (selezione per null)'
                : 'nessun estremo montato (caso (b)) oppure tutte le maniglie '
                      'sono dipinte: non c\'è nulla da ricostruire, quindi '
                      'nessun clear()/riassegnazione. Valori visti: $deviations',
          );
          expect(controller.selection, initial);
          expect(MarkdownRenderedView.debugSelectionRecallCount, 1);
          expect(
            scope.toolbarIsVisible,
            isTrue,
            reason: 'il menù compare comunque sul richiamo',
          );
          expect(log.vibrations, 0);

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '9. maniglia ESISTENTE ma NON dipinta: il richiamo ricostruisce l\'overlay (si guarda la visibilità, non l\'esistenza)',
      (tester) async {
        // Regressione DETERMINISTICA di un difetto passato: un criterio che
        // contasse l'esistenza di un `_SelectionHandleOverlay` con una
        // maniglia montata-ma-invisibile non faceva nulla. Qui la
        // maniglia invisibile è una FINTA con lo stesso nome del tipo del
        // framework e un `LayerLink` senza leader (vedi `_SelectionHandleOverlay`
        // in questo file): non dipende da come `flutter_md` ricollega i
        // leader. Col vecchio criterio le maniglie vere (dipinte) più la
        // finta davano «ci sono» e la selezione non passava mai per `null`:
        // questo test sarebbe ROSSO. Con la politica B' (ricostruisci se
        // NON TUTTE sono dipinte) il richiamo ricostruisce.
        await _withPlatform(TargetPlatform.android, () async {
          final log = _PlatformLog();
          _mockPlatformChannel(tester, log);
          await _pumpView(tester, _note);

          final scope = _scope(tester);
          final controller = scope.controller;
          final initial = await _selectWordByLongPress(tester, _selectedBlock);
          expect(
            _allHandlesVisible(tester),
            isTrue,
            reason:
                'precondizione: maniglie vere dipinte. Stato: '
                '${_describeHandles(tester)}',
          );

          final overlay = Overlay.of(
            tester.element(find.byType(Scaffold)),
            rootOverlay: true,
          );
          final fake = OverlayEntry(
            builder: (_) => _SelectionHandleOverlay(link: LayerLink()),
          );
          overlay.insert(fake);
          try {
            await tester.pump();
            expect(
              _realHandles(tester).where((handle) => !handle.isPainted),
              hasLength(1),
              reason:
                  'precondizione: la maniglia finta esiste ed è NON '
                  'dipinta. Stato: ${_describeHandles(tester)}',
            );

            final sequence = <MarkdownSelection?>[];
            void record() => sequence.add(controller.selection);
            controller.addListener(record);
            addTearDown(() => controller.removeListener(record));

            log.vibrations = 0;
            MarkdownRenderedView.debugSelectionRecallCount = 0;

            await _holdLongPress(tester, _insideSelection(tester));
            await tester.pumpAndSettle();

            expect(
              sequence,
              contains(isNull),
              reason:
                  'una maniglia esistente ma non dipinta deve far '
                  'ricostruire l\'overlay (la selezione passa per null); col '
                  'criterio per esistenza non succedeva',
            );
            expect(
              controller.selection,
              initial,
              reason: 'a ricostruzione finita la selezione è identica',
            );
            expect(sequence.last, initial);
            expect(MarkdownRenderedView.debugSelectionRecallCount, 1);
            expect(
              log.vibrations,
              0,
              reason: 'il ripristino programmatico non deve far vibrare',
            );
          } finally {
            fake.remove();
            fake.dispose();
          }

          await tester.pump();
          await _drainTimers(tester);
        });
      },
    );
  });
}
