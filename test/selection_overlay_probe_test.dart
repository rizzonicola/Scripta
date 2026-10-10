// SONDE sulla selezione della vista di lettura (MarkdownRenderedView).
// Step 1 dell'indagine: NESSUNA modifica a lib/.
//
// ATTENZIONE - STATO DI QUESTO FILE
// Scritto in un ambiente SENZA Flutter/Dart e SENZA rete: non e' mai stato
// compilato ne' eseguito. Il primo compito del passo successivo e' eseguirlo
// (vedi HANDOFF_selection.md, sezione 3):
//
//   flutter test test/selection_overlay_probe_test.dart --reporter expanded
//
// Due famiglie di test:
//  * [CONTRATTO]: asserzioni su fatti letti nel sorgente PUBBLICATO di
//    flutter_md 0.2.0 (sezioni "Implementation" del dartdoc dei membri
//    pubblici) o nella documentazione del framework Flutter. Pensati come
//    regressione. Se uno fallisce al primo run, il fatto sul quale si basa va
//    ricontrollato (vedi la sezione 1 del HANDOFF), non "aggiustato" a caso.
//  * [SONDA]: nessuna asserzione sul comportamento incerto. Scrivono su stdout
//    righe `PROBE|<id>|<passo>|<stato>` da incollare nel HANDOFF. Se compare
//    `HARNESS_WARNING` la geometria/le gesture del test non hanno prodotto la
//    selezione attesa: il problema e' nel test, non nel pacchetto.
//
// PERCHE' I LONG-PRESS HANNO UN'ATTESA "REALE" (runAsync)
// `_handleBackgroundPointerUp` dell'app misura la durata del tocco con
// `DateTime.now()` (markdown_rendered_view.dart, riga ~577), che NON e'
// controllato da FakeAsync. Un long-press simulato solo con `pump(500 ms)`
// dura ~0 ms REALI: al pointer-up l'app lo scambierebbe per un tap breve e
// chiamerebbe `clearSelection()` (riga ~581), falsando ogni osservazione.
// `_holdLongPress` fa quindi trascorrere anche ~520 ms di orologio reale.
//
// RILEVAMENTO DELLE MANIGLIE
// Non esiste un'API pubblica: le conto per nome del tipo privato
// `_SelectionHandleOverlay` (Flutter) e, come controllo, per numero di
// `CompositedTransformFollower`. E' fragile di proposito: serve solo a
// osservare, non va copiato in codice di produzione.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_md/flutter_md.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/features/editor/presentation/markdown_rendered_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _kPhone = Size(400, 800);
const ValueKey<String> _kListKey =
    ValueKey<String>('markdown-formatted-listview');
const String _kFocusLabel = 'markdown-selection';

// ---------------------------------------------------------------------------
// Utilita'
// ---------------------------------------------------------------------------

/// Nota di ~200 blocchi: un titolo H1 (`rendered-block-0`) e N paragrafi
/// (`rendered-block-1` ... `rendered-block-N`).
String _note({int paragraphs = 200}) {
  final buffer = StringBuffer('# Sonda selezione\n\n');
  for (var i = 1; i <= paragraphs; i++) {
    buffer.write(
      'Blocco $i alfa beta gamma delta epsilon zeta eta theta iota kappa.\n\n',
    );
  }
  return buffer.toString();
}

/// Piattaforma Android con ripristino GARANTITO (il binding di test fallisce se
/// `debugDefaultTargetPlatformOverride` resta impostato a fine test).
Future<void> _withAndroid(Future<void> Function() body) async {
  final previous = debugDefaultTargetPlatformOverride;
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = previous;
  }
}

class _PlatformCalls {
  final List<String> methods = <String>[];
  String? clipboardText;
}

/// Mock del canale `flutter/platform` (clipboard, haptics...), con registro
/// delle chiamate. Ripristinato a fine test.
_PlatformCalls _mockPlatform(WidgetTester tester) {
  final calls = _PlatformCalls();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall methodCall) async {
      calls.methods.add(methodCall.method);
      if (methodCall.method == 'Clipboard.setData') {
        calls.clipboardText = (methodCall.arguments as Map)['text'] as String?;
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return calls;
}

Future<void> _pumpView(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tester.view.physicalSize = _kPhone;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ProviderScope(
          child: MarkdownRenderedView(title: 'Sonda', content: _note()),
        ),
      ),
    ),
  );
  // Un frame per l'impianto + uno per i callback post-frame (registrazione dei
  // documenti nel controller di selezione).
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

MarkdownSelectionScopeState _scope(WidgetTester tester) =>
    tester.state<MarkdownSelectionScopeState>(
      find.byType(MarkdownSelectionScope),
    );

/// Scrollable della ListView esterna (il primo in ordine di albero: il titolo,
/// un SelectableText, ne contiene un altro al suo interno).
ScrollableState _scrollable(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(_kListKey),
            matching: find.byType(Scrollable),
          )
          .first,
    );

int _countByTypeName(String typeName) => find
    .byWidgetPredicate((Widget w) => w.runtimeType.toString() == typeName)
    .evaluate()
    .length;

String _o(Offset? o) => o == null
    ? 'null'
    : '(${o.dx.toStringAsFixed(0)},${o.dy.toStringAsFixed(0)})';

String _r(Rect? r) => r == null
    ? 'null'
    : '[${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)},'
        '${r.right.toStringAsFixed(0)},${r.bottom.toStringAsFixed(0)}]';

/// Unione dei rettangoli dei pulsanti della toolbar Material (null se la
/// toolbar non e' nell'albero).
Rect? _toolbarRect() {
  Rect? result;
  for (final element
      in find.byType(TextSelectionToolbarTextButton).evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    result = result == null ? rect : result.expandToInclude(rect);
  }
  return result;
}

/// Istanza corrente del widget `AdaptiveTextSelectionToolbar`: ogni chiamata
/// del `contextMenuBuilder` ne costruisce una NUOVA, quindi un cambio di
/// identita' fra due campionamenti prova che il builder e' stato rieseguito.
Widget? _toolbarWidget() {
  final elements = find.byType(AdaptiveTextSelectionToolbar).evaluate();
  return elements.isEmpty ? null : elements.first.widget;
}

String _anch(MarkdownSelectionScopeState state) {
  final anchors = state.contextMenuAnchors;
  return 'anchors(prim=${_o(anchors.primaryAnchor)} '
      'sec=${_o(anchors.secondaryAnchor)})';
}

/// Istantanea compatta di tutto cio' che interessa (selezione, toolbar,
/// maniglie, geometria, focus, scroll).
String _snap(WidgetTester tester, MarkdownSelectionScopeState state) {
  final controller = state.controller;
  final selection = controller.selection;
  final kind = selection == null
      ? 'null'
      : (selection.isCollapsed ? 'collapsed' : 'range');
  var text = controller.getText().replaceAll('\n', '\\n');
  if (text.length > 30) {
    text = '${text.substring(0, 30)}...(${text.length}ch)';
  }
  final endpoints = controller.selectionHandleEndpoints() != null;
  return 'sel=$kind text="$text" toolbar=${state.toolbarIsVisible} '
      'toolbarWidgets=${find.byType(AdaptiveTextSelectionToolbar).evaluate().length} '
      'toolbarRect=${_r(_toolbarRect())} '
      'handles=${_countByTypeName('_SelectionHandleOverlay')} '
      'followers=${find.byType(CompositedTransformFollower).evaluate().length} '
      'endpoints=$endpoints rects=${controller.globalSelectionRects().length} '
      'mounted=${controller.mountedSurfaces.length} '
      'focus=${FocusManager.instance.primaryFocus?.debugLabel == _kFocusLabel} '
      'offset=${_scrollable(tester).position.pixels.toStringAsFixed(0)}';
}

class _ProbeLog {
  _ProbeLog(this.id);

  final String id;
  final List<String> _lines = <String>[];

  void add(String step, String data) => _lines.add('PROBE|$id|$step|$data');

  void flush() {
    for (final line in _lines) {
      debugPrint(line);
    }
  }
}

/// Dito giu' + attesa di un long-press completo (fake time per il recognizer,
/// ~520 ms di tempo REALE per il `DateTime.now()` dell'app). Restituisce la
/// gesture ancora premuta.
Future<TestGesture> _holdLongPress(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(at, kind: PointerDeviceKind.touch);
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  await tester.runAsync<void>(
    () => Future<void>.delayed(const Duration(milliseconds: 520)),
  );
  await tester.pump();
  return gesture;
}

/// Crea una selezione a intervallo sulla prima riga del paragrafo 1:
/// long-press su una parola + trascinamento verso destra. Restituisce la
/// selezione, o null (con HARNESS_WARNING nel log) se non e' nata.
Future<MarkdownSelection?> _selectByLongPressDrag(
  WidgetTester tester,
  MarkdownSelectionScopeState state,
  _ProbeLog log,
  String label,
) async {
  final block = tester.getRect(find.byKey(const ValueKey('rendered-block-1')));
  final gesture =
      await _holdLongPress(tester, block.topLeft + const Offset(40, 8));
  log.add('$label.hold', _snap(tester, state));
  for (var i = 0; i < 5; i++) {
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }
  log.add('$label.drag', _snap(tester, state));
  await gesture.up();
  await tester.pump();
  log.add('$label.up', _snap(tester, state));
  await tester.pump(const Duration(seconds: 1));
  log.add('$label.settled', _snap(tester, state));

  final selection = state.controller.selection;
  if (selection == null || selection.isCollapsed) {
    log.add(
      'HARNESS_WARNING',
      'long-press+drag non ha creato una selezione a intervallo: '
          'geometria/gesture del test da rivedere',
    );
    return null;
  }
  return selection;
}

/// Test "sonda": monta la vista (Android, touch), esegue [body], poi chiude in
/// modo pulito (annulla la selezione e lascia scadere i Timer, come quello da
/// 200 ms di `HapticsHelper.reportSelectionState`) e stampa il log anche se il
/// corpo lancia un'eccezione.
void _probeTest(
  String description,
  String id,
  Future<void> Function(
    WidgetTester tester,
    MarkdownSelectionScopeState state,
    _ProbeLog log,
  ) body,
) {
  testWidgets(description, (tester) async {
    final log = _ProbeLog(id);
    _mockPlatform(tester);
    await _withAndroid(() async {
      try {
        await _pumpView(tester);
        final state = _scope(tester);
        await body(tester, state, log);
        state.clearSelection();
        await tester.pump(const Duration(seconds: 1));
      } finally {
        log.flush();
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('selection_overlay_probe (Android, touch)', () {
    // ------------------------------------------------------------------
    // [CONTRATTO] - fatti verificati sul sorgente pubblicato
    // ------------------------------------------------------------------

    testWidgets(
      '[CONTRATTO flutter_md 0.2.0] showToolbar/hideToolbar/toolbarIsVisible e '
      'clearSelection',
      (tester) async {
        _mockPlatform(tester);
        await _withAndroid(() async {
          await _pumpView(tester);
          final state = _scope(tester);

          state.selectAll();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          final selection = state.controller.selection;
          expect(selection, isNotNull);
          expect(selection!.isCollapsed, isFalse);
          expect(state.controller.getText(), isNotEmpty);

          // `hideToolbar` e' `_contextMenuController.remove()`: idempotente.
          state.hideToolbar();
          await tester.pump();
          expect(state.toolbarIsVisible, isFalse);
          expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);

          // `showToolbar` inserisce un OverlayEntry (ContextMenuController)
          // che invoca il `contextMenuBuilder` dell'app.
          state.showToolbar();
          await tester.pump();
          expect(state.toolbarIsVisible, isTrue);
          expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

          state.hideToolbar();
          await tester.pump();
          expect(state.toolbarIsVisible, isFalse);
          expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);

          // `clearSelection` = `controller.clear()` + `hideToolbar()`.
          state.showToolbar();
          await tester.pump();
          state.clearSelection();
          await tester.pump(const Duration(seconds: 1));
          final after = state.controller.selection;
          expect(after == null || after.isCollapsed, isTrue);
          expect(state.toolbarIsVisible, isFalse);
          expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
        });
      },
    );

    testWidgets(
      '[CONTRATTO flutter_md 0.2.0] copySelection nasconde la toolbar ma NON '
      'annulla la selezione',
      (tester) async {
        final calls = _mockPlatform(tester);
        await _withAndroid(() async {
          await _pumpView(tester);
          final state = _scope(tester);

          state.selectAll();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          state.showToolbar();
          await tester.pump();
          expect(state.toolbarIsVisible, isTrue);

          // E' asincrona (await Clipboard.setData, poi hideToolbar).
          unawaited(state.copySelection());
          await tester.pump(const Duration(milliseconds: 50));
          await tester.pump(const Duration(milliseconds: 50));

          expect(calls.clipboardText, isNotNull);
          expect(calls.clipboardText, isNotEmpty);
          expect(state.toolbarIsVisible, isFalse);
          final selection = state.controller.selection;
          expect(selection, isNotNull);
          expect(selection!.isCollapsed, isFalse);

          state.clearSelection();
          await tester.pump(const Duration(seconds: 1));
        });
      },
    );

    testWidgets(
      '[CONTRATTO flutter_md 0.2.0] contextMenuAnchors: forma e ancore grezze '
      'che possono cadere fuori dal viewport',
      (tester) async {
        _mockPlatform(tester);
        await _withAndroid(() async {
          await _pumpView(tester);
          final state = _scope(tester);

          state.selectAll();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));

          // Senza `showToolbar(Offset)` non c'e' `_lastSecondaryTapDown`:
          // primaria = topCenter, secondaria = bottomCenter dello stesso
          // rettangolo (unione dei rect montati, oppure box dello scope).
          final a0 = state.contextMenuAnchors;
          expect(a0.secondaryAnchor, isNotNull);
          expect(a0.primaryAnchor.dx, closeTo(a0.secondaryAnchor!.dx, 0.01));
          expect(
            a0.primaryAnchor.dy,
            lessThanOrEqualTo(a0.secondaryAnchor!.dy),
          );

          // Scroll lontano: i blocchi montati sono quelli del viewport +
          // cacheExtent (250 px), quindi l'unione dei rect (o, se vuota, il
          // box dello scope) sborda dal viewport su entrambi i lati.
          final scrollable = _scrollable(tester);
          scrollable.position.jumpTo(8000);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));

          final viewport = tester.getRect(find.byKey(_kListKey));
          final a1 = state.contextMenuAnchors;
          expect(a1.secondaryAnchor, isNotNull);
          expect(a1.primaryAnchor.dy, lessThanOrEqualTo(viewport.top + 0.5));
          expect(
            a1.secondaryAnchor!.dy,
            greaterThanOrEqualTo(viewport.bottom - 0.5),
          );
          debugPrint(
            'PROBE|C3|raw|viewport=${_r(viewport)} ${_anch(state)} '
            'rects=${state.controller.globalSelectionRects().length} '
            'mounted=${state.controller.mountedSurfaces.length}',
          );

          state.clearSelection();
          await tester.pump(const Duration(seconds: 1));
        });
      },
    );

    testWidgets(
      '[CONTRATTO Flutter] AdaptiveTextSelectionToolbar sceglie sopra/sotto '
      'rispetto allo SCHERMO, non rispetto a un viewport',
      (tester) async {
        await _withAndroid(() async {
          tester.view.physicalSize = _kPhone;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          Future<Rect> place(Offset primary, Offset? secondary) async {
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(platform: TargetPlatform.android),
                home: Scaffold(
                  body: Stack(
                    children: <Widget>[
                      // "Viewport di una lista" che inizia a y=300: non deve
                      // influire sulla scelta sopra/sotto.
                      const Positioned(
                        left: 0,
                        right: 0,
                        top: 300,
                        bottom: 0,
                        child: ColoredBox(color: Color(0x11000000)),
                      ),
                      AdaptiveTextSelectionToolbar.buttonItems(
                        anchors: TextSelectionToolbarAnchors(
                          primaryAnchor: primary,
                          secondaryAnchor: secondary,
                        ),
                        buttonItems: <ContextMenuButtonItem>[
                          ContextMenuButtonItem(
                            onPressed: () {},
                            label: 'Sonda',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
            await tester.pump();
            final rect = _toolbarRect();
            expect(rect, isNotNull);
            return rect!;
          }

          // Molto spazio sopra l'ancora (rispetto allo schermo): la toolbar sta
          // SOPRA l'ancora primaria, anche se cosi' esce dal "viewport" (y<300).
          final above = await place(const Offset(200, 310), const Offset(200, 360));
          debugPrint('PROBE|Q5|sopra|rect=${_r(above)}');
          expect(above.bottom, lessThanOrEqualTo(310.0));
          expect(above.top, lessThan(300.0));

          // Ancora vicina al bordo ALTO DELLO SCHERMO: non c'e' spazio sopra e
          // la toolbar passa SOTTO l'ancora secondaria.
          final below = await place(const Offset(200, 20), const Offset(200, 70));
          debugPrint('PROBE|Q5|sotto|rect=${_r(below)}');
          expect(below.top, greaterThanOrEqualTo(70.0));
        });
      },
    );

    // ------------------------------------------------------------------
    // [SONDA] - osservazioni, nessuna asserzione sul comportamento incerto
    // ------------------------------------------------------------------

    _probeTest(
      '[SONDA Q2] long-press DENTRO e FUORI una selezione esistente',
      'Q2',
      (tester, state, log) async {
        final s1 = await _selectByLongPressDrag(tester, state, log, '1.crea');
        if (s1 == null) return;
        final text1 = state.controller.getText();
        final block1 =
            tester.getRect(find.byKey(const ValueKey('rendered-block-1')));

        // 2) long-press DENTRO la selezione, su un punto diverso da quello di
        // partenza.
        var gesture =
            await _holdLongPress(tester, block1.topLeft + const Offset(110, 8));
        log.add('2.dentro.hold', _snap(tester, state));
        await gesture.up();
        await tester.pump();
        log.add('2.dentro.up', _snap(tester, state));
        await tester.pump(const Duration(seconds: 1));
        log.add('2.dentro.settled', _snap(tester, state));
        log.add(
          '2.verdetto',
          'selezioneInvariata=${state.controller.selection == s1} '
              'testoInvariato=${state.controller.getText() == text1}',
        );

        // 3) long-press FUORI dalla selezione (paragrafo 3).
        final selectionBefore3 = state.controller.selection;
        final block3 =
            tester.getRect(find.byKey(const ValueKey('rendered-block-3')));
        gesture =
            await _holdLongPress(tester, block3.topLeft + const Offset(40, 8));
        log.add('3.fuori.hold', _snap(tester, state));
        await gesture.up();
        await tester.pump();
        log.add('3.fuori.up', _snap(tester, state));
        await tester.pump(const Duration(seconds: 1));
        log.add('3.fuori.settled', _snap(tester, state));
        log.add(
          '3.verdetto',
          'selezioneCambiata=${state.controller.selection != selectionBefore3}',
        );
      },
    );

    _probeTest(
      '[SONDA Q3/Q4] scroll con selezione e toolbar; estremi smontati e rimontati',
      'Q3Q4-scroll',
      (tester, state, log) async {
        final s1 = await _selectByLongPressDrag(tester, state, log, '1.crea');
        if (s1 == null) return;
        if (!state.toolbarIsVisible) {
          log.add(
            '2.nota',
            'toolbar NON visibile dopo il long-press: la mostro con showToolbar()',
          );
          state.showToolbar();
          await tester.pump();
        }
        log.add('2.base', '${_snap(tester, state)} ${_anch(state)}');

        final scrollable = _scrollable(tester);
        final baseRect = _toolbarRect();

        // 3) scroll graduale (60 px per frame): la toolbar si nasconde da sola?
        // il builder viene rieseguito (nuova istanza del widget)? la toolbar si
        // sposta insieme alla selezione?
        var last = _toolbarWidget();
        var rebuilds = 0;
        var hiddenFrames = 0;
        for (var i = 0; i < 12; i++) {
          scrollable.position.jumpTo(scrollable.position.pixels + 60);
          await tester.pump(const Duration(milliseconds: 16));
          final current = _toolbarWidget();
          if (current != null && last != null && !identical(current, last)) {
            rebuilds++;
          }
          if (!state.toolbarIsVisible) hiddenFrames++;
          last = current ?? last;
          if (i == 0 || i == 5 || i == 11) {
            log.add('3.scroll[$i]', '${_snap(tester, state)} ${_anch(state)}');
          }
        }
        log.add(
          '3.riepilogo',
          'ricostruzioniWidgetToolbar=$rebuilds (0 => builder non rieseguito '
              'durante lo scroll) frameConToolbarNascosta=$hiddenFrames '
              'toolbarRectBase=${_r(baseRect)} toolbarRectOra=${_r(_toolbarRect())}',
        );

        // 4) estremi smontati: scroll ben oltre la cacheExtent.
        scrollable.position.jumpTo(9000);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        log.add('4.smontati', '${_snap(tester, state)} ${_anch(state)}');

        // 5) ritorno in cima: estremi rimontati. Maniglie/toolbar tornano da sole?
        scrollable.position.jumpTo(0);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        log.add('5.rimontati', '${_snap(tester, state)} ${_anch(state)}');
        await tester.pump(const Duration(seconds: 1));
        log.add('5.rimontati+1s', _snap(tester, state));

        // 6) scroll REALE con il dito (non jumpTo): la selezione sopravvive?
        final before = scrollable.position.pixels;
        final drag = await tester.startGesture(
          const Offset(200, 600),
          kind: PointerDeviceKind.touch,
        );
        for (var i = 0; i < 6; i++) {
          await drag.moveBy(const Offset(0, -40));
          await tester.pump(const Duration(milliseconds: 16));
        }
        log.add('6.dragScroll.durante', _snap(tester, state));
        await drag.up();
        await tester.pump(const Duration(seconds: 1));
        log.add(
          '6.dragScroll.fine',
          'offset $before -> ${scrollable.position.pixels.toStringAsFixed(0)} '
              '${_snap(tester, state)}',
        );
      },
    );

    _probeTest(
      '[SONDA Q3] perdita di focus con selezione attiva',
      'Q3-focus',
      (tester, state, log) async {
        final s1 = await _selectByLongPressDrag(tester, state, log, '1.crea');
        if (s1 == null) return;
        if (!state.toolbarIsVisible) {
          state.showToolbar();
          await tester.pump();
        }
        log.add('2.prima', _snap(tester, state));
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        log.add('3.dopoUnfocus', _snap(tester, state));
        log.add(
          '3.verdetto',
          'selezioneSopravvissuta=${state.controller.selection == s1}',
        );
      },
    );

    _probeTest(
      '[SONDA Q3/A] ripristino programmatico: le maniglie tornano?',
      'A-restore',
      (tester, state, log) async {
        final s1 = await _selectByLongPressDrag(tester, state, log, '1.crea');
        if (s1 == null) return;
        log.add('2.base', _snap(tester, state));

        // (a) clear + ripristino nello stesso frame.
        state.controller.clear();
        state.controller.selection = s1;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        log.add('3.clearPoiS1.stessoFrame', _snap(tester, state));

        // (b) clear, un frame, ripristino.
        state.controller.clear();
        await tester.pump();
        log.add('4.clear.frame', _snap(tester, state));
        state.controller.selection = s1;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        log.add('5.ripristinata', _snap(tester, state));

        // (c) showToolbar() dopo il ripristino.
        state.showToolbar();
        await tester.pump();
        log.add('6.showToolbar', _snap(tester, state));
      },
    );

    _probeTest(
      '[SONDA Q3] "Seleziona tutto" con selezione di partenza fuori schermo',
      'Q3-selectall',
      (tester, state, log) async {
        final s1 = await _selectByLongPressDrag(tester, state, log, '1.crea');
        if (s1 == null) return;
        if (!state.toolbarIsVisible) {
          state.showToolbar();
          await tester.pump();
        }
        log.add('2.base', _snap(tester, state));

        _scrollable(tester).position.jumpTo(9000);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        log.add('3.scrollLontano', '${_snap(tester, state)} ${_anch(state)}');

        // Tocca "Seleziona tutto" come farebbe l'utente (etichetta Material in
        // inglese; in alternativa l'ultimo pulsante della toolbar).
        final byLabel = find.text('Select all');
        final buttons = find.byType(TextSelectionToolbarTextButton);
        if (byLabel.evaluate().isNotEmpty) {
          await tester.tap(byLabel.first, warnIfMissed: false);
        } else if (buttons.evaluate().isNotEmpty) {
          log.add('4.nota', 'etichetta non trovata: tocco l\'ultimo pulsante');
          await tester.tap(buttons.last, warnIfMissed: false);
        } else {
          log.add('4.nota', 'nessun pulsante toolbar: uso state.selectAll()');
          state.selectAll();
        }
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          log.add('5.frame[$i]', '${_snap(tester, state)} ${_anch(state)}');
        }
        await tester.pump(const Duration(seconds: 1));
        log.add('6.settled', '${_snap(tester, state)} ${_anch(state)}');
      },
    );

    _probeTest(
      '[SONDA Q3] tap breve sulla selezione e a vuoto (listener dell\'app)',
      'Q3-tap',
      (tester, state, log) async {
        final s1 = await _selectByLongPressDrag(tester, state, log, '1.crea');
        if (s1 == null) return;
        if (!state.toolbarIsVisible) {
          state.showToolbar();
          await tester.pump();
        }
        log.add('2.base', _snap(tester, state));

        final block1 =
            tester.getRect(find.byKey(const ValueKey('rendered-block-1')));
        await tester.tapAt(block1.topLeft + const Offset(110, 8));
        await tester.pump();
        log.add('3.tapSullaSelezione', _snap(tester, state));
        await tester.pump(const Duration(seconds: 1));
        log.add('3.settled', _snap(tester, state));

        final s2 = await _selectByLongPressDrag(tester, state, log, '4.ricrea');
        if (s2 == null) return;
        await tester.tapAt(const Offset(10, 400)); // margine sinistro, a vuoto
        await tester.pump();
        log.add('5.tapAVuoto', _snap(tester, state));
        await tester.pump(const Duration(seconds: 1));
        log.add('5.settled', _snap(tester, state));
      },
    );
  });
}
