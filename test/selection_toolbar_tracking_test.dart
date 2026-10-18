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
import 'package:shared_preferences/shared_preferences.dart';

// Test dell'INSEGUIMENTO: il menù Copia / Seleziona tutto SEGUE la selezione mentre
// la nota scorre, si aggancia ai bordi del viewport e sparisce solo quando la
// selezione finisce (vedi `_MarkdownRenderedViewState._buildSelectionToolbar`
// in markdown_rendered_view.dart).
//
// NOTE SU COME SONO SCRITTI (leggere prima di "aggiustare" un'asserzione):
//  * Si misura il comportamento VISIBILE: la posizione reale del menù, non
//    l'esistenza dei widget (è l'errore che ha nascosto il difetto delle
//    maniglie). Il menù si misura con l'unione dei rettangoli
//    dei SUOI PULSANTI, non con `tester.getRect(find.byType(
//    AdaptiveTextSelectionToolbar))`: il RenderObject di quel widget è il
//    `Padding` che riempie l'intero overlay, quindi il suo rettangolo è lo
//    schermo e non cambierebbe mai (stesso criterio di `_toolbarRect()` in
//    selection_contract_test.dart). Il finder del menù resta
//    `find.byType(AdaptiveTextSelectionToolbar)`: i pulsanti si cercano al
//    suo interno.
//  * "Il menù segue la nota" si esprime come INVARIANTE: la posizione del menù
//    nel CONTENUTO (`rect.top + position.pixels`) non cambia. Vale per ogni
//    tipo di scroll (jumpTo, dito, inerzia, animateTo) perché tutti passano da
//    `ScrollPosition`, e dopo UN SOLO `pump()` dallo scroll: un menù in ritardo
//    di un frame fallirebbe qui. L'invariante vale solo lontano dai bordi
//    (`_farFromEdges`): vicino a un bordo il menù si ferma, per costruzione.
//  * Le costanti numeriche (margine minimo 8 px, tolleranza 1 px) sono quelle
//    della specifica. Le misure interne della toolbar di Flutter (altezza 44,
//    distanza dal contenuto 0 o 8 px sopra e 0 o 20 sotto, a seconda della
//    versione del framework) NON sono assunte: "agganciato al bordo" significa
//    «entro 36 px dal bordo, interamente dentro il viewport, e FERMO se si
//    scorre ancora» (`_expectPinnedTop`/`_expectPinnedBottom`), e lo scatto di
//    un eventuale ribaltamento sopra/sotto è cercato da `_scanForJumps`.
//  * Gli helper `_wordPoint`, `_holdLongPress` & C. sono COPIE di quelli di
//    selection_recall_test.dart: in Dart i membri con `_` sono privati al file
//    e non si possono importare. `_holdLongPress` attende 520 ms
//    REALI (non 560): l'app misura la durata di un tap con `DateTime.now()` e
//    il long-press scatta a 500 ms.
//  * `debugDefaultTargetPlatformOverride` va ripristinato DENTRO il corpo del
//    test (try/finally in `_withPlatform`): i controlli di fine test del
//    framework girano prima dei callback di `addTearDown`.
//  * Dopo ogni selezione che collassa parte un Timer da 200 ms di
//    `HapticsHelper.reportSelectionState`: ogni test lascia scorrere un
//    secondo a fine corpo.
//  * Se un'asserzione fallisce, i messaggi riportano i rettangoli misurati
//    (menù, selezione, viewport) e l'offset: sono la prima cosa da leggere.
//    Cause probabili: nome del tipo dei pulsanti cambiato (`_toolbarButtonTypes`),
//    toolbar dell'SDK diversa dalle due varianti ricordate in
//    `_toolbarReachAbove`/`_toolbarReachBelow` (lo dice `_scanForJumps` con
//    SCATTO), `secondaryAnchor != null` anche per il tasto destro (test 6).

// Nota LUNGA: 160 paragrafi, quindi almeno 160 blocchi (con i blocchi vuoti
// tra un paragrafo e l'altro i `MarkdownWidget` sono circa il doppio). I
// blocchi in cima escono dalla `cacheExtent` della ListView appena si
// scorre di qualche migliaio di pixel: la selezione resta ad estremi smontati.
final String _longNote = List<String>.generate(
  160,
  (i) => 'Paragrafo numero $i con del testo di riempimento.',
).join('\n\n');

// Paragrafo (con testo, 0 = il primo) della parola selezionata di default: il
// QUARTO, che sta abbastanza in basso da avere spazio libero sopra per il menù.
const int _selectedBlock = 3;

// Margine minimo del menù dal bordo del viewport (specchio di
// `_toolbarEdgeMargin` in markdown_rendered_view.dart) e tolleranza.
const double _edgeMargin = 8.0;
const double _tol = 1.0;

// Distanza massima dal bordo entro cui un menù si considera «agganciato».
const double _pinReach = 36.0;

// Nomi dei tipi dei pulsanti della toolbar (Material touch e desktop). Si
// cercano per NOME: così il test non dipende dalle classi esportate.
const Set<String> _toolbarButtonTypes = <String>{
  'TextSelectionToolbarTextButton',
  'DesktopTextSelectionToolbarButton',
};

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
  String? clipboard;
}

/// Mock del canale `flutter/platform`: senza handler le chiamate a
/// `HapticFeedback`/`Clipboard` lancerebbero `MissingPluginException`.
/// Registra anche il testo copiato negli appunti.
void _mockPlatformChannel(WidgetTester tester, _PlatformLog log) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async {
      if (call.method == 'HapticFeedback.vibrate') log.vibrations++;
      if (call.method == 'Clipboard.setData') {
        final arguments = call.arguments;
        if (arguments is Map) log.clipboard = arguments['text'] as String?;
      }
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

MarkdownSelectionScopeState _scope(WidgetTester tester) =>
    tester.state<MarkdownSelectionScopeState>(
      find.byType(MarkdownSelectionScope),
    );

/// Punti di tocco che colpiscono DAVVERO una parola: uno per paragrafo CON
/// testo, in ordine di lettura (indice 0 = primo paragrafo). Si riempie in
/// `_locateWords` (chiamata da `_pumpView`, PRIMA di qualunque selezione).
final List<Offset> _wordPoints = <Offset>[];

/// Cerca un punto dentro [rect] che selezioni una parola; `null` se non c'è
/// (blocco vuoto). La prova è distruttiva (crea e annulla una selezione): va
/// fatta prima di creare la selezione vera.
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
/// [paragraph]-esimo paragrafo con testo (0 = il primo), a scroll 0.
Offset _wordPoint(int paragraph) {
  if (paragraph >= _wordPoints.length) {
    fail('_locateWords non ha registrato il paragrafo $paragraph');
  }
  return _wordPoints[paragraph];
}

/// Come [_selectablePointIn], ma dopo uno scroll: cerca tra i `MarkdownWidget`
/// montati il primo paragrafo con testo che sta INTERAMENTE dentro [area]
/// (coordinate globali) e ne restituisce un punto che seleziona una parola;
/// `null` se non ce n'è (il chiamante lo asserisce, con il messaggio giusto).
Future<Offset?> _wordPointWithin(WidgetTester tester, Rect area) async {
  final scope = _scope(tester);
  final widgets = find.byType(MarkdownWidget);
  final count = widgets.evaluate().length;
  for (var i = 0; i < count; i++) {
    final rect = tester.getRect(widgets.at(i));
    if (rect.top < area.top || rect.bottom > area.bottom) continue;
    final point = await _selectablePointIn(tester, scope, rect);
    if (point != null) {
      await tester.pump(const Duration(seconds: 1));
      return point;
    }
  }
  return null;
}

/// Rettangolo della viewport di scroll (la `ListView` della vista).
Rect _viewport(WidgetTester tester) => tester.getRect(
      find.byKey(const ValueKey('markdown-formatted-listview')),
    );

/// Lo `Scrollable` della `ListView` della vista.
ScrollableState _listScrollable(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('markdown-formatted-listview')),
        matching: find.byType(Scrollable),
      ),
    );

double _pixels(WidgetTester tester) => _listScrollable(tester).position.pixels;

/// Scorre di colpo a [pixels] e fa girare UN SOLO frame: quello che l'utente
/// vedrebbe. Se il menù è in ritardo di un frame, le asserzioni che seguono
/// lo vedono. Il bersaglio è limitato all'estensione scorribile: un `jumpTo`
/// oltre il fondo lascerebbe la lista in overscroll, con una molla che la
/// riporta indietro nei frame successivi.
Future<void> _scrollTo(WidgetTester tester, double pixels) async {
  final position = _listScrollable(tester).position;
  position.jumpTo(
    pixels.clamp(position.minScrollExtent, position.maxScrollExtent).toDouble(),
  );
  await tester.pump();
}

/// Posizione REALE del menù: unione dei rettangoli dei suoi pulsanti (vedi le
/// note in testa al file). `null` se il menù non c'è.
Rect? _toolbarRect(WidgetTester tester) {
  final toolbar = find.byType(AdaptiveTextSelectionToolbar);
  if (toolbar.evaluate().isEmpty) return null;
  final buttons = find.descendant(
    of: toolbar,
    matching: find.byWidgetPredicate(
      (widget) => _toolbarButtonTypes.contains(widget.runtimeType.toString()),
    ),
  );
  Rect? union;
  for (final element in buttons.evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    union = union == null ? rect : union.expandToInclude(rect);
  }
  return union;
}

/// Bounding box della selezione VIVA (rettangoli montati), o `null` se nessun
/// blocco della selezione è montato.
Rect? _selectionBox(WidgetTester tester) {
  Rect? box;
  for (final rect in _scope(tester).controller.globalSelectionRects()) {
    box = box == null ? rect : box.expandToInclude(rect);
  }
  return box;
}

/// Il menù è lontano dai bordi (zona "naturale"): vicino a un bordo si ferma
/// per costruzione, e l'invariante "segue la nota" non vale più.
bool _farFromEdges(Rect toolbar, Rect viewport) =>
    toolbar.top >= viewport.top + _edgeMargin + 24 &&
    toolbar.bottom <= viewport.bottom - _edgeMargin - 24;

/// Il menù sta INTERAMENTE dentro il viewport, con almeno `_edgeMargin` dal
/// bordo (tolleranza 1 px).
void _expectInside(Rect toolbar, Rect viewport, String when) {
  expect(
    toolbar.top,
    greaterThanOrEqualTo(viewport.top + _edgeMargin - _tol),
    reason: '$when: il menù esce dal bordo SUPERIORE del viewport '
        '(menù=$toolbar viewport=$viewport)',
  );
  expect(
    toolbar.bottom,
    lessThanOrEqualTo(viewport.bottom - _edgeMargin + _tol),
    reason: '$when: il menù esce dal bordo INFERIORE del viewport '
        '(menù=$toolbar viewport=$viewport)',
  );
  expect(
    toolbar.left,
    greaterThanOrEqualTo(viewport.left - _tol),
    reason: '$when: il menù esce dal bordo sinistro (menù=$toolbar)',
  );
  expect(
    toolbar.right,
    lessThanOrEqualTo(viewport.right + _tol),
    reason: '$when: il menù esce dal bordo destro (menù=$toolbar)',
  );
}

/// Il menù è ATTACCATO alla selezione: la sua posizione nel CONTENUTO
/// (`rect.top + pixels`) è quella misurata appena dopo la creazione
/// ([reference]), entro 1 px. Se è in ritardo di un frame, lo scarto è
/// l'ultimo spostamento di scroll.
void _expectFollowing(WidgetTester tester, double reference, String when) {
  final rect = _toolbarRect(tester);
  expect(rect, isNotNull, reason: '$when: il menù deve restare visibile');
  final pixels = _pixels(tester);
  final content = rect!.top + pixels;
  expect(
    content,
    closeTo(reference, _tol),
    reason: '$when: il menù non segue la nota (posizione nel contenuto '
        '$content, attesa $reference, scarto ${content - reference}; '
        'menù=$rect offset=$pixels). Uno scarto uguale all\'ultimo '
        'spostamento di scroll significa un frame di RITARDO.',
  );
}

/// Il menù è fermo sul bordo SUPERIORE: tra `_edgeMargin` e `_pinReach` px dal
/// bordo alto del viewport (l'ampiezza tiene conto delle varianti della
/// toolbar di Flutter, vedi le note in testa).
void _expectPinnedTop(Rect toolbar, Rect viewport, String when) {
  expect(
    toolbar.top - viewport.top,
    inInclusiveRange(_edgeMargin - _tol, _pinReach),
    reason: '$when: il menù dovrebbe essere agganciato al bordo SUPERIORE '
        '(menù=$toolbar viewport=$viewport)',
  );
}

/// Il menù è fermo sul bordo INFERIORE.
void _expectPinnedBottom(Rect toolbar, Rect viewport, String when) {
  expect(
    viewport.bottom - toolbar.bottom,
    inInclusiveRange(_edgeMargin - _tol, _pinReach),
    reason: '$when: il menù dovrebbe essere agganciato al bordo INFERIORE '
        '(menù=$toolbar viewport=$viewport)',
  );
}

/// Tiene premuto [position] oltre la soglia di long-press, poi rilascia.
/// L'attesa reale da 520 ms serve all'orologio `DateTime.now()` dell'app; `pump`
/// fa scadere i timer dei recognizer.
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
    () => Future<void>.delayed(const Duration(milliseconds: 520)),
  );
  await tester.pump(kLongPressTimeout + kPressTimeout);
  await gesture.up();
  await tester.pump();
  if (kind != PointerDeviceKind.touch) {
    await gesture.removePointer();
  }
}

/// Crea la selezione col long-press "vero" del pacchetto e attende che il menù
/// si assesti.
Future<MarkdownSelection> _selectWordAt(
  WidgetTester tester,
  Offset point,
) async {
  await _holdLongPress(tester, point);
  await tester.pumpAndSettle();
  final selection = _scope(tester).controller.selection;
  expect(
    selection,
    isNotNull,
    reason: 'il long-press fuori da ogni selezione deve selezionare la '
        'parola (punto $point)',
  );
  expect(selection!.isCollapsed, isFalse);
  expect(
    _scope(tester).toolbarIsVisible,
    isTrue,
    reason: 'il long-press mobile mostra il menù (README flutter_md)',
  );
  return selection;
}

/// Punto al centro del primo rettangolo della selezione corrente il cui
/// centro cade DENTRO la viewport.
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

/// Scorre da [from] a [to] a passi di [step] px (un frame per passo) e verifica
/// che il menù non si muova MAI più della nota (+1 px) e resti nel viewport.
/// Serve a prendere gli scatti che i salti grossi non vedono: in particolare il
/// ribaltamento sopra/sotto che Flutter fa vicino al bordo, se le ancore non
/// sono costruite per evitarlo.
Future<void> _scanForJumps(
  WidgetTester tester,
  Rect viewport, {
  required double from,
  required double to,
  required double step,
  required String when,
}) async {
  await _scrollTo(tester, from);
  var previous = _toolbarRect(tester);
  expect(previous, isNotNull, reason: '$when: menù sparito a offset=$from');
  var previousPixels = _pixels(tester);
  final direction = to >= from ? 1.0 : -1.0;
  var offset = from;
  var steps = 0;
  while ((to - offset) * direction > 0) {
    offset += step * direction;
    await _scrollTo(tester, offset);
    final rect = _toolbarRect(tester);
    expect(rect, isNotNull, reason: '$when: menù sparito a offset=$offset');
    _expectInside(rect!, viewport, '$when, offset=$offset');
    final scrolled = (_pixels(tester) - previousPixels).abs();
    expect(
      (rect.top - previous!.top).abs(),
      lessThanOrEqualTo(scrolled + _tol),
      reason: '$when: SCATTO a offset=$offset (prima=$previous dopo=$rect, '
          'scroll=$scrolled)',
    );
    previous = rect;
    previousPixels = _pixels(tester);
    steps++;
  }
  expect(steps, greaterThan(5), reason: '$when: scansione troppo corta');
}

/// Scorre a [offset] e seleziona (long-press vero) una parola di un paragrafo
/// che sta interamente nella fascia 300..520 della viewport: il menù ha spazio
/// sopra e la selezione può muoversi di qualche centinaio di px in entrambe le
/// direzioni. Indipendente da dove cadano i paragrafi con i font di test.
Future<MarkdownSelection> _selectMidNoteWord(
  WidgetTester tester, {
  double offset = 6000,
}) async {
  final viewport = _viewport(tester);
  await _scrollTo(tester, offset);
  final point = await _wordPointWithin(
    tester,
    Rect.fromLTRB(
      viewport.left,
      viewport.top + 300,
      viewport.right,
      viewport.top + 520,
    ),
  );
  expect(
    point,
    isNotNull,
    reason: 'nessun paragrafo con testo interamente nella fascia 300..520 '
        'dopo lo scroll a $offset',
  );
  return _selectWordAt(tester, point!);
}

/// Tocca il pulsante del menù con l'etichetta [label] (localizzata da Material).
Future<void> _tapToolbarButton(
  WidgetTester tester,
  String Function(MaterialLocalizations localizations) label,
) async {
  final toolbar = find.byType(AdaptiveTextSelectionToolbar);
  final text = label(MaterialLocalizations.of(tester.element(toolbar)));
  final button = find.descendant(of: toolbar, matching: find.text(text));
  expect(button, findsOneWidget, reason: 'pulsante "$text" nel menù');
  await tester.tap(button);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // `AppTheme.getTextStyleForFont` passa sempre da google_fonts: nei test non
  // c'è rete né font negli asset, e google_fonts lancia un'eccezione asincrona
  // NON gestita che, cadendo durante l'attesa REALE di `_holdLongPress`, fa
  // fallire il test. Si esclude google_fonts dal punto unico da cui passa la
  // vista (stessa soluzione di selection_recall_test.dart).
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

  group('Il menù Copia / Seleziona tutto segue la selezione', () {
    testWidgets(
      '0. Precondizioni: nota lunga, menù misurabile e attaccato SOPRA la selezione',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          _mockPlatformChannel(tester, _PlatformLog());
          await _pumpView(tester, _longNote);

          final viewport = _viewport(tester);
          expect(
            _listScrollable(tester).position.maxScrollExtent,
            greaterThan(viewport.height * 10),
            reason: 'la nota deve essere molto più lunga della viewport, '
                'altrimenti i blocchi non escono dalla cacheExtent e i test '
                'sugli estremi smontati non misurano nulla',
          );

          await _selectMidNoteWord(tester);

          expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
          final toolbar = _toolbarRect(tester);
          final box = _selectionBox(tester);
          expect(
            toolbar,
            isNotNull,
            reason: 'nessun pulsante del menù trovato per nome del tipo '
                '($_toolbarButtonTypes): la struttura della toolbar è cambiata?',
          );
          expect(box, isNotNull, reason: 'la selezione deve avere rettangoli');

          // Sopra il bordo superiore della selezione, e attaccato ad esso.
          expect(
            toolbar!.bottom,
            lessThanOrEqualTo(box!.top + 2),
            reason: 'il menù deve stare SOPRA la selezione',
          );
          expect(
            box.top - toolbar.bottom,
            lessThan(40),
            reason: 'il menù deve essere attaccato al bordo superiore della '
                'selezione',
          );
          _expectInside(toolbar, viewport, 'subito dopo la selezione');

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '1. Scroll di Δ (programmatico, dito, inerzia, animateTo): il menù si sposta di Δ ±1 px nello stesso frame',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          _mockPlatformChannel(tester, _PlatformLog());
          await _pumpView(tester, _longNote);

          final scope = _scope(tester);
          final controller = scope.controller;
          final viewport = _viewport(tester);

          final initial = await _selectMidNoteWord(tester);

          final start = _pixels(tester);
          final rect0 = _toolbarRect(tester);
          expect(rect0, isNotNull, reason: 'menù non misurabile');
          expect(
            _farFromEdges(rect0!, viewport),
            isTrue,
            reason: 'precondizione: il menù appena creato deve stare lontano '
                'dai bordi (menù=$rect0 viewport=$viewport)',
          );
          final reference = rect0.top + start;
          final toolbarElement =
              find.byType(AdaptiveTextSelectionToolbar).evaluate().single;
          var checked = 0;

          // (a) Scroll programmatico di Δ, un solo frame per volta.
          for (final delta in <double>[37, -37, 120, -120, 61, -122]) {
            final before = _toolbarRect(tester)!;
            final pixelsBefore = _pixels(tester);
            await _scrollTo(tester, pixelsBefore + delta);
            final moved = _pixels(tester) - pixelsBefore;
            expect(moved, closeTo(delta, 0.01), reason: 'jumpTo di $delta');
            final after = _toolbarRect(tester);
            expect(after, isNotNull, reason: 'Δ=$delta: menù sparito');
            expect(
              before.top - after!.top,
              closeTo(moved, _tol),
              reason: 'Δ=$delta: il menù deve spostarsi di -Δ nello STESSO '
                  'frame (prima=$before dopo=$after)',
            );
            expect(
              after.left,
              closeTo(before.left, _tol),
              reason: 'Δ=$delta: lo scroll è verticale, il menù non deve '
                  'muoversi di lato',
            );
            _expectFollowing(tester, reference, 'Δ=$delta');
            checked++;
          }

          // (b) Trascinamento col dito, un frame per movimento. Il punto di
          // partenza è nel margine destro: lontano da selezione, menù e
          // maniglie.
          await _scrollTo(tester, start);
          _expectFollowing(tester, reference, 'ritorno alla posizione iniziale');
          final gesture = await tester.startGesture(const Offset(392, 700));
          for (var i = 0; i < 10; i++) {
            await gesture.moveBy(const Offset(0, -12));
            await tester.pump();
            _expectFollowing(tester, reference, 'trascinamento, passo $i');
            checked++;
          }
          await gesture.up();
          await tester.pump();
          expect(
            _pixels(tester),
            greaterThan(start + 20),
            reason: 'il trascinamento deve aver scorso la nota',
          );
          expect(controller.selection, initial, reason: 'selezione cambiata');

          // (c) Inerzia: dopo il lancio si guarda ogni frame finché la lista
          // si muove. Si asserisce solo in zona naturale (il lancio può
          // portare il menù vicino a un bordo).
          await _scrollTo(tester, start);
          await tester.pumpAndSettle();
          await tester.flingFrom(
            const Offset(392, 700),
            const Offset(0, -120),
            700,
          );
          var frames = 0;
          while (_listScrollable(tester).position.isScrollingNotifier.value &&
              frames < 150) {
            await tester.pump(const Duration(milliseconds: 16));
            frames++;
            final rect = _toolbarRect(tester);
            expect(rect, isNotNull, reason: 'inerzia, frame $frames: sparito');
            if (_farFromEdges(rect!, viewport)) {
              _expectFollowing(tester, reference, 'inerzia, frame $frames');
              checked++;
            }
          }

          // (d) animateTo, un frame da 16 ms alla volta.
          await _scrollTo(tester, start);
          final animation = _listScrollable(tester).position.animateTo(
                start + 200,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
          for (var i = 0; i < 24; i++) {
            await tester.pump(const Duration(milliseconds: 16));
            final rect = _toolbarRect(tester);
            expect(rect, isNotNull, reason: 'animateTo, frame $i: sparito');
            if (_farFromEdges(rect!, viewport)) {
              _expectFollowing(tester, reference, 'animateTo, frame $i');
              checked++;
            }
          }
          await animation;
          await tester.pump();
          _expectFollowing(tester, reference, 'fine di animateTo');

          expect(
            checked,
            greaterThan(30),
            reason: 'troppe poche verifiche eseguite ($checked): il test '
                'non misura abbastanza frame',
          );
          expect(controller.selection, initial, reason: 'selezione cambiata');
          expect(scope.toolbarIsVisible, isTrue);
          // Né `showToolbar()` né altro ha ricreato il menù durante lo
          // scroll: è lo stesso Element dall'inizio alla fine.
          expect(
            find.byType(AdaptiveTextSelectionToolbar).evaluate().single,
            same(toolbarElement),
            reason: 'il menù è stato ricreato durante lo scroll: deve '
                'aggiornarsi da solo, senza showToolbar() per frame',
          );

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '2. Fino al bordo superiore il menù si ferma dentro il viewport, anche a selezione smontata, senza scatti',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          _mockPlatformChannel(tester, _PlatformLog());
          await _pumpView(tester, _longNote);

          final scope = _scope(tester);
          final controller = scope.controller;
          final viewport = _viewport(tester);
          final initial = await _selectMidNoteWord(tester);

          final start = _pixels(tester);
          final rect0 = _toolbarRect(tester);
          expect(rect0, isNotNull, reason: 'menù non misurabile');
          final reference = rect0!.top + start;

          // `room` = di quanto il menù può ancora salire prima di fermarsi sul
          // bordo (MISURATO, non assunto). I primi due passi restano in zona
          // naturale; poi la selezione esce dal bordo superiore e, dopo
          // qualche migliaio di pixel, i suoi blocchi vengono smontati.
          final room = rect0.top - (viewport.top + 28);
          expect(
            room,
            greaterThan(120),
            reason: 'precondizione: il menù deve avere spazio per salire '
                '(menù=$rect0 viewport=$viewport)',
          );

          var previous = rect0;
          var previousPixels = start;
          var sawFollowing = false;
          final steps = <double>[
            start + room * 0.4,
            start + room * 0.8,
            start + room + 60,
            start + room + 500,
            start + room + 1500,
            start + room + 4000,
          ];
          for (final offset in steps) {
            await _scrollTo(tester, offset);
            final rect = _toolbarRect(tester);
            expect(rect, isNotNull, reason: 'offset=$offset: menù sparito');
            _expectInside(rect!, viewport, 'offset=$offset');
            final scrolled = (_pixels(tester) - previousPixels).abs();
            expect(
              (rect.top - previous.top).abs(),
              lessThanOrEqualTo(scrolled + _tol),
              reason: 'offset=$offset: SCATTO, il menù si è mosso più della '
                  'nota (prima=$previous dopo=$rect, scroll=$scrolled)',
            );
            if (_farFromEdges(rect, viewport)) {
              _expectFollowing(tester, reference, 'offset=$offset');
              sawFollowing = true;
            }
            previous = rect;
            previousPixels = _pixels(tester);
          }
          expect(
            sawFollowing,
            isTrue,
            reason: 'nessun passo in zona naturale: il test non ha verificato '
                'che il menù seguisse la nota prima di fermarsi',
          );

          // La selezione è ormai molto sopra il viewport: il menù è fermo sul
          // bordo superiore e ulteriori scroll non lo spostano.
          final pinned = _toolbarRect(tester)!;
          _expectPinnedTop(pinned, viewport, 'selezione uscita dall\'alto');
          for (final extra in <double>[4700, 9000]) {
            final offset = start + room + extra;
            await _scrollTo(tester, offset);
            final rect = _toolbarRect(tester);
            expect(rect, isNotNull, reason: 'offset=$offset: menù sparito');
            expect(
              rect!.top,
              closeTo(pinned.top, _tol),
              reason: 'offset=$offset: il menù agganciato al bordo non deve '
                  'muoversi (agganciato=$pinned ora=$rect)',
            );
            expect(rect.left, closeTo(pinned.left, _tol));
          }

          // Scansione FINE attorno al punto di aggancio, in salita e in
          // discesa: nessuno scatto, nemmeno dove Flutter potrebbe ribaltare
          // il menù da sopra a sotto la selezione.
          await _scanForJumps(
            tester,
            viewport,
            from: start + room - 120,
            to: start + room + 120,
            step: 4,
            when: 'salita verso il bordo superiore',
          );
          await _scanForJumps(
            tester,
            viewport,
            from: start + room + 120,
            to: start + room - 120,
            step: 4,
            when: 'ritorno dal bordo superiore',
          );

          expect(scope.toolbarIsVisible, isTrue);
          expect(controller.selection, initial, reason: 'selezione cambiata');
          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '2b. Selezione in cima alla nota (sopra non c\'è spazio): il menù sta SOTTO, poi si aggancia in alto e torna identico',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          _mockPlatformChannel(tester, _PlatformLog());
          await _pumpView(tester, _longNote);

          final scope = _scope(tester);
          final viewport = _viewport(tester);
          await _selectWordAt(tester, _wordPoint(0));

          final box0 = _selectionBox(tester);
          final rect0 = _toolbarRect(tester);
          expect(rect0, isNotNull, reason: 'menù non misurabile');
          expect(box0, isNotNull);
          // Il primo paragrafo parte a ~24 px dal bordo alto: sopra non c'è
          // spazio per la toolbar, quindi (flip nativo) sta sotto la riga.
          expect(
            rect0!.top,
            greaterThanOrEqualTo(box0!.bottom - 2),
            reason: 'con la selezione vicina al bordo alto il menù deve stare '
                'SOTTO il bordo inferiore della selezione',
          );
          _expectInside(rect0, viewport, 'selezione in cima');

          // La nota scorre e la selezione esce dall'alto: il menù si ferma
          // sul bordo superiore, non salta sopra la selezione. Scansione fine
          // per accorgersi di uno scatto.
          await _scanForJumps(
            tester,
            viewport,
            from: 0,
            to: 160,
            step: 4,
            when: 'selezione in cima che esce dall\'alto',
          );
          final scrolledOut = _toolbarRect(tester)!;
          _expectPinnedTop(scrolledOut, viewport, 'selezione uscita dall\'alto');
          await _scrollTo(tester, 4000);
          final pinned = _toolbarRect(tester)!;
          _expectPinnedTop(pinned, viewport, 'selezione smontata, sopra');
          expect(
            pinned.top,
            closeTo(scrolledOut.top, _tol),
            reason: 'il menù agganciato non deve cambiare posizione quando i '
                'blocchi della selezione vengono smontati',
          );

          // Ritorno in cima: la memoria in coordinate di contenuto deve dare
          // la posizione di partenza, identica.
          await _scrollTo(tester, 0);
          final back = _toolbarRect(tester);
          expect(back, isNotNull, reason: 'dopo il ritorno: menù sparito');
          expect(
            back!.top,
            closeTo(rect0.top, 1.5),
            reason: 'dopo il ritorno in cima il menù deve tornare dov\'era '
                '(prima=$rect0 dopo=$back)',
          );
          expect(back.left, closeTo(rect0.left, 1.5));
          expect(scope.toolbarIsVisible, isTrue);

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '3. Selezione SOTTO il viewport (blocchi smontati): il menù si aggancia al bordo inferiore e, risalendo, torna naturale senza scatti',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          _mockPlatformChannel(tester, _PlatformLog());
          await _pumpView(tester, _longNote);

          final scope = _scope(tester);
          final controller = scope.controller;
          final viewport = _viewport(tester);

          // Selezione a ~4000 px dall'inizio, poi si torna in cima: la
          // selezione resta sotto il viewport, lontanissima dalla cacheExtent.
          final initial = await _selectMidNoteWord(tester, offset: 4000);
          final selectedAt = _pixels(tester);
          final rect0 = _toolbarRect(tester);
          expect(rect0, isNotNull, reason: 'menù non misurabile');
          final reference = rect0!.top + selectedAt;

          await _scrollTo(tester, 0);
          final pinned = _toolbarRect(tester);
          expect(
            pinned,
            isNotNull,
            reason: 'con la selezione sotto il viewport il menù deve '
                'restare visibile',
          );
          _expectInside(pinned!, viewport, 'selezione sotto');
          _expectPinnedBottom(pinned, viewport, 'selezione sotto');
          await _scrollTo(tester, 300);
          final stillPinned = _toolbarRect(tester)!;
          expect(
            stillPinned.top,
            closeTo(pinned.top, _tol),
            reason: 'agganciato al bordo inferiore non deve muoversi '
                '(prima=$pinned dopo=$stillPinned)',
          );

          // Risalita verso la selezione: il menù esce dal bordo inferiore e
          // riprende a seguire la nota, senza scatti.
          var previous = stillPinned;
          var previousPixels = _pixels(tester);
          var sawFollowing = false;
          for (final offset in <double>[
            selectedAt - 900,
            selectedAt - 700,
            selectedAt - 500,
            selectedAt - 300,
            selectedAt - 150,
            selectedAt - 50,
            selectedAt,
          ]) {
            await _scrollTo(tester, offset);
            final rect = _toolbarRect(tester);
            expect(rect, isNotNull, reason: 'offset=$offset: menù sparito');
            _expectInside(rect!, viewport, 'offset=$offset');
            final scrolled = (_pixels(tester) - previousPixels).abs();
            expect(
              (rect.top - previous.top).abs(),
              lessThanOrEqualTo(scrolled + _tol),
              reason: 'offset=$offset: SCATTO (prima=$previous dopo=$rect, '
                  'scroll=$scrolled)',
            );
            if (_farFromEdges(rect, viewport)) {
              _expectFollowing(tester, reference, 'offset=$offset');
              sawFollowing = true;
            }
            previous = rect;
            previousPixels = _pixels(tester);
          }
          expect(sawFollowing, isTrue);

          // Scansione fine attorno al punto in cui il menù lascia il bordo
          // inferiore, in entrambe le direzioni.
          await _scanForJumps(
            tester,
            viewport,
            from: selectedAt - 420,
            to: selectedAt - 60,
            step: 4,
            when: 'risalita dal bordo inferiore',
          );
          await _scanForJumps(
            tester,
            viewport,
            from: selectedAt - 60,
            to: selectedAt - 420,
            step: 4,
            when: 'discesa verso il bordo inferiore',
          );

          // Tornati dov'era la selezione: stesso rettangolo di partenza. È la
          // prova che le coordinate di contenuto memorizzate coincidono con la
          // geometria viva dopo lo smontaggio e il rimontaggio dei blocchi.
          await _scrollTo(tester, selectedAt);
          final back = _toolbarRect(tester)!;
          expect(
            back.top,
            closeTo(rect0.top, 1.5),
            reason: 'dopo il ritorno il menù deve tornare dov\'era '
                '(prima=$rect0 dopo=$back)',
          );
          expect(controller.selection, initial, reason: 'selezione cambiata');
          expect(scope.toolbarIsVisible, isTrue);

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '4. Seleziona tutto con la selezione di partenza fuori schermo: il menù resta visibile e agganciato',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          _mockPlatformChannel(tester, _PlatformLog());
          await _pumpView(tester, _longNote);

          final scope = _scope(tester);
          final controller = scope.controller;
          final viewport = _viewport(tester);
          final initial = await _selectMidNoteWord(tester);
          final initialText = controller.getText();

          // Qualche migliaio di px più giù la parola di partenza è lontana e
          // smontata: il menù è agganciato al bordo superiore.
          final middle = _pixels(tester) + 4000;
          await _scrollTo(tester, middle);
          final before = _toolbarRect(tester);
          expect(before, isNotNull, reason: 'menù sparito dopo lo scroll');
          _expectInside(before!, viewport, 'prima di Seleziona tutto');
          _expectPinnedTop(before, viewport, 'prima di Seleziona tutto');

          await _tapToolbarButton(
            tester,
            (localizations) => localizations.selectAllButtonLabel,
          );
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pumpAndSettle();

          final selection = controller.selection;
          expect(
            selection,
            isNot(equals(initial)),
            reason: 'Seleziona tutto deve cambiare la selezione',
          );
          expect(selection, isNotNull);
          expect(selection!.isCollapsed, isFalse);
          expect(
            controller.getText().length,
            greaterThan(initialText.length),
            reason: 'la selezione deve ora coprire molto più testo',
          );

          // VISIBILE: il menù deve esserci, anche se la selezione di partenza
          // era fuori schermo (`_afterSelectAll` ri-mostra il menù se sparisce).
          expect(
            scope.toolbarIsVisible,
            isTrue,
            reason: 'Seleziona tutto con partenza fuori schermo: il menù non '
                'deve sparire',
          );
          final after = _toolbarRect(tester);
          expect(after, isNotNull, reason: 'menù non misurabile dopo il tap');
          _expectInside(after!, viewport, 'dopo Seleziona tutto');
          // E AGGANCIATO: la selezione parte sopra il viewport e prosegue
          // sotto, quindi il menù sta fermo sul bordo superiore.
          _expectPinnedTop(after, viewport, 'dopo Seleziona tutto');

          // Resta agganciato scorrendo in entrambe le direzioni.
          for (final offset in <double>[middle + 500, middle - 700, 0]) {
            await _scrollTo(tester, offset);
            final rect = _toolbarRect(tester);
            expect(rect, isNotNull, reason: 'offset=$offset: menù sparito');
            _expectInside(rect!, viewport, 'offset=$offset');
            expect(scope.toolbarIsVisible, isTrue);
          }

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '5a. Copia: il menù sparisce con la selezione e scrollando non ricompare',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          final log = _PlatformLog();
          _mockPlatformChannel(tester, log);
          await _pumpView(tester, _longNote);

          final scope = _scope(tester);
          final controller = scope.controller;
          await _selectWordAt(tester, _wordPoint(_selectedBlock));
          final selectedText = controller.getText();
          expect(selectedText, isNotEmpty);

          // Con l'inseguimento già in corso.
          await _scrollTo(tester, 80);
          expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

          await _tapToolbarButton(
            tester,
            (localizations) => localizations.copyButtonLabel,
          );
          await tester.pump();
          await tester.pumpAndSettle();

          expect(
            find.byType(AdaptiveTextSelectionToolbar),
            findsNothing,
            reason: 'Copia chiude la selezione: il menù deve sparire',
          );
          expect(scope.toolbarIsVisible, isFalse);
          expect(
            controller.selection == null || controller.selection!.isCollapsed,
            isTrue,
            reason: 'Copia annulla la selezione',
          );
          expect(log.clipboard, selectedText, reason: 'testo negli appunti');

          // Il menù non va ri-mostrato da nessun ricalcolo.
          for (final offset in <double>[400, 3000, 0]) {
            await _scrollTo(tester, offset);
            await tester.pump(const Duration(milliseconds: 50));
            expect(
              find.byType(AdaptiveTextSelectionToolbar),
              findsNothing,
              reason: 'offset=$offset: il menù è ricomparso dopo Copia',
            );
          }

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '5b. Tap a vuoto: il menù sparisce con la selezione e scrollando non ricompare',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          _mockPlatformChannel(tester, _PlatformLog());
          await _pumpView(tester, _longNote);

          final scope = _scope(tester);
          final controller = scope.controller;
          await _selectWordAt(tester, _wordPoint(_selectedBlock));
          await _scrollTo(tester, 80);
          expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

          // Margine sinistro, in basso: lontano da selezione, menù, maniglie.
          await tester.tapAt(const Offset(4, 700));
          await tester.pumpAndSettle();

          expect(
            controller.selection == null || controller.selection!.isCollapsed,
            isTrue,
            reason: 'un tap a vuoto annulla la selezione',
          );
          expect(
            find.byType(AdaptiveTextSelectionToolbar),
            findsNothing,
            reason: 'finita la selezione il menù deve sparire',
          );
          expect(scope.toolbarIsVisible, isFalse);

          for (final offset in <double>[400, 3000, 0]) {
            await _scrollTo(tester, offset);
            await tester.pump(const Duration(milliseconds: 50));
            expect(
              find.byType(AdaptiveTextSelectionToolbar),
              findsNothing,
              reason: 'offset=$offset: il menù è ricomparso dopo il tap',
            );
          }

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '6. Tasto destro (desktop): il menù posizionale resta com\'è, fermo mentre la nota scorre',
      (tester) async {
        await _withPlatform(TargetPlatform.linux, () async {
          _mockPlatformChannel(tester, _PlatformLog());
          await _pumpView(tester, _longNote);

          final scope = _scope(tester);
          final viewport = _viewport(tester);
          final point = _wordPoint(_selectedBlock);

          final gesture = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryButton,
          );
          await gesture.addPointer(location: point);
          await gesture.down(point);
          await tester.pump();
          await gesture.up();
          await tester.pump();
          await gesture.removePointer();
          await tester.pumpAndSettle();

          expect(
            scope.toolbarIsVisible,
            isTrue,
            reason: 'il tasto destro apre il menù contestuale (Copia / '
                'Seleziona tutto): è il comportamento di sempre',
          );
          final before = _toolbarRect(tester);
          expect(
            before,
            isNotNull,
            reason: 'nessun pulsante del menù trovato per nome del tipo '
                '($_toolbarButtonTypes)',
          );
          expect(
            viewport.inflate(_tol).contains(before!.center),
            isTrue,
            reason: 'il menù deve stare dentro la viewport (menù=$before)',
          );

          // Il menù aperto con il tasto destro NON insegue la nota.
          for (final offset in <double>[100, 3000]) {
            await _scrollTo(tester, offset);
            final after = _toolbarRect(tester);
            expect(after, isNotNull, reason: 'offset=$offset: menù sparito');
            expect(
              after!.top,
              closeTo(before.top, 0.5),
              reason: 'offset=$offset: il menù posizionale (tasto destro) '
                  'deve restare fermo, non seguire la nota '
                  '(prima=$before dopo=$after)',
            );
            expect(after.left, closeTo(before.left, 0.5));
          }

          await _drainTimers(tester);
        });
      },
    );

    testWidgets(
      '7. Richiamo (long-press sulla selezione) con il menù inseguito: stesso widget, posizione naturale, e dopo hideToolbar() torna al suo posto',
      (tester) async {
        await _withPlatform(TargetPlatform.android, () async {
          _mockPlatformChannel(tester, _PlatformLog());
          await _pumpView(tester, _longNote);

          final scope = _scope(tester);
          final controller = scope.controller;

          final initial = await _selectMidNoteWord(tester);
          final start = _pixels(tester);
          final rect0 = _toolbarRect(tester);
          expect(rect0, isNotNull, reason: 'menù non misurabile');
          final reference = rect0!.top + start;

          // Il menù già inseguito, poi il richiamo: nessun menù ricreato.
          await _scrollTo(tester, start + 120);
          _expectFollowing(tester, reference, 'prima del richiamo');
          final toolbarBefore =
              find.byType(AdaptiveTextSelectionToolbar).evaluate().single;

          await _holdLongPress(tester, _insideSelection(tester));
          await tester.pumpAndSettle();

          expect(
            MarkdownRenderedView.debugSelectionRecallCount,
            1,
            reason: 'il long-press sulla selezione deve far scattare il '
                'richiamo',
          );
          expect(controller.selection, initial, reason: 'selezione cambiata');
          expect(
            find.byType(AdaptiveTextSelectionToolbar).evaluate().single,
            same(toolbarBefore),
            reason: 'il richiamo non deve ricreare il menù già visibile',
          );
          _expectFollowing(tester, reference, 'dopo il richiamo');

          // Menù nascosto (come dopo il trascinamento di una maniglia) e
          // richiamo: torna al suo posto naturale, attaccato alla selezione.
          scope.hideToolbar();
          await tester.pumpAndSettle();
          expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
          await _holdLongPress(tester, _insideSelection(tester));
          await tester.pumpAndSettle();
          expect(
            MarkdownRenderedView.debugSelectionRecallCount,
            2,
            reason: 'secondo richiamo',
          );
          expect(scope.toolbarIsVisible, isTrue);
          _expectFollowing(tester, reference, 'dopo il secondo richiamo');
          expect(controller.selection, initial, reason: 'selezione cambiata');

          // E continua a seguire.
          await _scrollTo(tester, _pixels(tester) - 60);
          _expectFollowing(tester, reference, 'scroll dopo il richiamo');

          await _drainTimers(tester);
        });
      },
    );
  });
}
