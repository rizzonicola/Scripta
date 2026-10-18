// Test di CONTRATTO sulla selezione della vista di lettura
// (`MarkdownRenderedView`): asserzioni su fatti dell'API pubblica di
// `flutter_md` 0.2.0 (dartdoc dei membri pubblici) e del framework Flutter su
// cui `markdown_rendered_view.dart` si appoggia. Servono da regressione: se
// uno fallisce dopo un aggiornamento del pacchetto o di Flutter, il fatto su
// cui il codice di produzione si basa è cambiato e va ricontrollato (non
// l'asserzione "aggiustata" a caso):
//  * `showToolbar` / `hideToolbar` / `toolbarIsVisible` / `clearSelection`;
//  * `copySelection` nasconde il menù ma NON annulla la selezione (per questo
//    l'app avvolge «Copia» con `clearSelection`);
//  * `contextMenuAnchors`: forma e ancore grezze, che con una selezione
//    scrollata via cadono fuori dal viewport (per questo l'app le ricalcola);
//  * `AdaptiveTextSelectionToolbar` sceglie sopra/sotto rispetto allo SCHERMO,
//    non a un viewport (per questo il modo `following` di
//    `_clampAnchorsToViewport` costruisce ancore coerenti).
//
// Le osservazioni senza asserzioni (sonde) sono state tolte: non
// proteggevano nulla.

import 'dart:async';

import 'package:flutter/foundation.dart';
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

// ---------------------------------------------------------------------------
// Utilita'
// ---------------------------------------------------------------------------

/// Nota di ~200 blocchi: un titolo H1 (`rendered-block-0`) e N paragrafi
/// (`rendered-block-1` ... `rendered-block-N`).
String _note({int paragraphs = 200}) {
  final buffer = StringBuffer('# Contratto selezione\n\n');
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
          child: MarkdownRenderedView(title: 'Contratto', content: _note()),
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

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('selection_contract (Android, touch)', () {
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
                            label: 'Contratto',
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
          expect(above.bottom, lessThanOrEqualTo(310.0));
          expect(above.top, lessThan(300.0));

          // Ancora vicina al bordo ALTO DELLO SCHERMO: non c'e' spazio sopra e
          // la toolbar passa SOTTO l'ancora secondaria.
          final below = await place(const Offset(200, 20), const Offset(200, 70));
          expect(below.top, greaterThanOrEqualTo(70.0));
        });
      },
    );
  });
}
