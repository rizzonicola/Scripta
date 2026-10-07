import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderFollowerLayer;
import 'package:flutter_md/flutter_md.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/features/editor/presentation/markdown_rendered_view.dart';

// Regressione: nella vista di lettura le maniglie di selezione non
// ricomparivano dopo aver scrollato lontano (oltre la `cacheExtent`) e
// essere tornati. Vedi `_KeepAliveWhileSelectionEdge` in
// `markdown_rendered_view.dart` per la causa.
//
// Come si osservano le maniglie: sono `OverlayEntry` il cui contenuto è un
// `CompositedTransformFollower` con `showWhenUnlinked: false`, quindi una
// maniglia è VISIBILE solo se il suo `LayerLink` ha un leader nel layer
// tree (lo disegna il blocco che contiene l'estremo). Non si dipende da API
// private del pacchetto: si contano i follower con `link.leader != null`.
//
// Mappa sugli scenari richiesti: (a) scroll piccolo con estremi visibili ->
// test "scroll minimi"; (b) scroll oltre la `cacheExtent` e ritorno ->
// test "oltre la cacheExtent" (+ quelli sul keep-alive); (c) trascinamento
// di una maniglia con auto-scroll NON è riprodotto qui (richiede di
// agganciare la maniglia con un gesto reale, troppo fragile): resta coperto
// da `selection_auto_scroller_test.dart` per l'auto-scroll e dalla
// checklist manuale.

/// Chiave della `ListView` della vista di lettura (vedi `_buildFormattedView`).
const _listKey = ValueKey<String>('markdown-formatted-listview');

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

/// Item della lista per indice (chiave assegnata da `_buildItem`).
Finder _item(int index, {bool skipOffstage = true}) => find.byKey(
      ValueKey<String>('rendered-block-$index'),
      skipOffstage: skipOffstage,
    );

/// Quanti `MarkdownWidget` sono MONTATI (anche fuori viewport: cacheExtent o
/// tenuti vivi), a differenza del default di `find`, che salta gli offstage.
int _mountedBlocks(WidgetTester tester) =>
    tester.widgetList(find.byType(MarkdownWidget, skipOffstage: false)).length;

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

/// Maniglie attualmente DISEGNATE: follower dell'overlay con un leader.
int _linkedHandles(WidgetTester tester) => tester
    .renderObjectList<RenderFollowerLayer>(
      find.byType(CompositedTransformFollower, skipOffstage: false),
    )
    .where((follower) => follower.link.leader != null)
    .length;

/// Seleziona via controller dalla prima parola dell'item [from] fino dentro
/// l'item [to]. Gli item devono essere paragrafi di testo: nella nota di
/// prova gli indici PARI lo sono anche se il parser interponesse blocchi
/// spaziatori fra un paragrafo e l'altro.
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
  final selection = controller.selection;
  expect(selection, isNotNull);
  expect(selection!.isCollapsed, isFalse);
  expect(
    <Object>[selection.base.documentId, selection.extent.documentId],
    unorderedEquals(<String>['block-$from', 'block-$to']),
    reason: 'gli estremi devono stare negli item $from e $to',
  );
}

/// Selezione "vera" da touch: long-press su una parola dell'item [index].
Future<void> _longPressItem(WidgetTester tester, int index) async {
  await tester.longPressAt(tester.getTopLeft(_item(index)) + const Offset(8, 8));
  await tester.pumpAndSettle();
}

void main() {
  group('Maniglie di selezione e virtualizzazione (flutter_md 0.2.0)', () {
    testWidgets(
      'oltre la cacheExtent le maniglie tornano agli estremi al ritorno',
      (tester) async {
        await _pumpNote(tester, _longNote(600));

        await _longPressItem(tester, 4);
        expect(_scope(tester).controller.selection, isNotNull);
        expect(
          _linkedHandles(tester),
          2,
          reason: 'precondizione: dopo il long-press ci sono 2 maniglie '
              'disegnate (se fallisce, è il test a non riprodurre la selezione)',
        );

        // Lontanissimo: l'estremo è fuori viewport, nessuna maniglia (né in
        // posizione sbagliata né sopra la top bar).
        await _scrollTo(tester, 12000);
        expect(_linkedHandles(tester), 0);

        // Ritorno: l'evidenziazione c'è sempre stata, ora devono esserci
        // anche le maniglie (prima del fix restavano a 0).
        await _scrollTo(tester, 0);
        await tester.pumpAndSettle();
        expect(_item(4), findsOneWidget);
        expect(
          _linkedHandles(tester),
          2,
          reason: 'le maniglie devono ricomparire dopo il ritorno',
        );
      },
    );

    testWidgets(
      'con scroll minimi (estremi ancora visibili) le maniglie restano disegnate',
      (tester) async {
        await _pumpNote(tester, _longNote(600));

        await _longPressItem(tester, 4);
        expect(
          _linkedHandles(tester),
          2,
          reason: 'precondizione: dopo il long-press ci sono 2 maniglie',
        );

        for (final offset in <double>[30, 60, 100, 40, 0]) {
          await _scrollTo(tester, offset);
          expect(
            _linkedHandles(tester),
            2,
            reason: 'scroll a $offset px: estremi visibili, maniglie attese',
          );
        }
      },
    );

    testWidgets(
      'i blocchi con gli estremi restano montati lontano, gli altri no',
      (tester) async {
        await _pumpNote(tester, _longNote(600));
        _selectBetween(tester, from: 4, to: 8);
        await tester.pump();

        await _scrollTo(tester, 12000);

        // Estremi: tenuti vivi anche se lontanissimi...
        expect(_item(4, skipOffstage: false), findsOneWidget);
        expect(_item(8, skipOffstage: false), findsOneWidget);
        // ...mentre un blocco in mezzo alla selezione, che non è un estremo,
        // viene smontato come sempre (virtualizzazione intatta).
        expect(_item(6, skipOffstage: false), findsNothing);
      },
    );

    testWidgets(
      'senza selezione nessun blocco lontano resta montato',
      (tester) async {
        await _pumpNote(tester, _longNote(600));
        await _scrollTo(tester, 12000);

        expect(_item(4, skipOffstage: false), findsNothing);
        expect(_item(8, skipOffstage: false), findsNothing);
      },
    );

    testWidgets(
      'annullando la selezione i blocchi tenuti vivi vengono rilasciati',
      (tester) async {
        await _pumpNote(tester, _longNote(600));
        _selectBetween(tester, from: 4, to: 8);
        await tester.pump();
        await _scrollTo(tester, 12000);
        expect(_item(4, skipOffstage: false), findsOneWidget);
        final withSelection = _mountedBlocks(tester);

        _scope(tester).clearSelection();
        await tester.pump();
        await tester.pump();

        expect(_item(4, skipOffstage: false), findsNothing);
        expect(_item(8, skipOffstage: false), findsNothing);
        expect(_mountedBlocks(tester), withSelection - 2);
      },
    );

    testWidgets(
      '2000 blocchi: selezione + scroll + ritorno montano al massimo 2 blocchi in più',
      (tester) async {
        await _pumpNote(tester, _longNote(2000));

        // Riferimento: stesse posizioni di scroll, nessuna selezione.
        final baselineTop = _mountedBlocks(tester);
        await _scrollTo(tester, 30000);
        final baselineFar = _mountedBlocks(tester);
        await _scrollTo(tester, 0);

        _selectBetween(tester, from: 4, to: 8);
        await tester.pump();
        await _scrollTo(tester, 30000);
        final selectedFar = _mountedBlocks(tester);
        await _scrollTo(tester, 0);
        final selectedTop = _mountedBlocks(tester);

        expect(selectedFar, lessThanOrEqualTo(baselineFar + 2));
        expect(selectedTop, lessThanOrEqualTo(baselineTop + 2));
        // La nota resta davvero virtualizzata: pochi item su 2000.
        expect(selectedFar, lessThan(100));
      },
    );

    testWidgets(
      '"Seleziona tutto" su 2000 blocchi non rompe la virtualizzazione',
      (tester) async {
        await _pumpNote(tester, _longNote(2000));
        await _scrollTo(tester, 30000);
        final baselineFar = _mountedBlocks(tester);
        await _scrollTo(tester, 0);

        _scope(tester).selectAll();
        await tester.pumpAndSettle();
        await _scrollTo(tester, 30000);

        // Estremi: primo e ultimo blocco; solo quelli montati possono essere
        // tenuti vivi (qui il primo, già montato in cima).
        expect(_mountedBlocks(tester), lessThanOrEqualTo(baselineFar + 2));

        _scope(tester).clearSelection();
        await tester.pump();
        await tester.pump();
        expect(_mountedBlocks(tester), baselineFar);
      },
    );
  });
}
