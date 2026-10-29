// Regressione PERF-01: la vista di lettura deve costruire un solo modello
// `Markdown` per blocco e riusarlo sia per la selezione sia per il rendering,
// anche quando il widget viene ricostruito con lo stesso contenuto.

import 'package:flutter/material.dart';
import 'package:flutter_md/flutter_md.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/features/editor/presentation/markdown_rendered_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _kPhone = Size(400, 800);

List<Markdown> _renderedModels(WidgetTester tester) => tester
    .widgetList<MarkdownWidget>(find.byType(MarkdownWidget))
    .map((widget) => widget.markdown)
    .toList();

Future<void> _pumpView(
  WidgetTester tester,
  String Function() content,
  void Function(StateSetter) onRebuild,
) async {
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
          child: StatefulBuilder(
            builder: (context, setState) {
              onRebuild(setState);
              return MarkdownRenderedView(title: 'Nota', content: content());
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'un rebuild con lo stesso contenuto riusa i modelli dei blocchi',
    (tester) async {
      const content = '# Titolo\n\nPrimo paragrafo.\n\nSecondo paragrafo.';
      late StateSetter rebuild;

      await _pumpView(tester, () => content, (setState) => rebuild = setState);

      final before = _renderedModels(tester);
      expect(before.length, greaterThanOrEqualTo(3));

      rebuild(() {});
      await tester.pumpAndSettle();

      final after = _renderedModels(tester);
      expect(after.length, before.length);
      for (var i = 0; i < before.length; i++) {
        expect(identical(before[i], after[i]), isTrue);
      }
    },
  );

  testWidgets('un contenuto nuovo ricostruisce i modelli dei blocchi', (
    tester,
  ) async {
    var content = '# Titolo\n\nPrimo paragrafo.\n\nSecondo paragrafo.';
    late StateSetter rebuild;

    await _pumpView(tester, () => content, (setState) => rebuild = setState);

    final before = _renderedModels(tester);
    expect(before.length, greaterThanOrEqualTo(3));

    content = '# Titolo\n\nPrimo paragrafo aggiornato.\n\nSecondo paragrafo.';
    rebuild(() {});
    await tester.pumpAndSettle();

    final after = _renderedModels(tester);
    expect(after.length, before.length);
    expect(identical(before[1], after[1]), isFalse);
  });
}
