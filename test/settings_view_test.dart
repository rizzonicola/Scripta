import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/constants/app_constants.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/features/settings/presentation/settings_view.dart';
import 'package:scripta/features/settings/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('il font globale è attivo di default e il toggle lo disattiva', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SettingsView(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byWidgetPredicate(
      (widget) =>
          widget is SwitchListTile &&
          widget.subtitle is Text &&
          ((widget.subtitle as Text).data?.contains('Inter') ?? false),
    );
    await tester.scrollUntilVisible(
      toggle,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(container.read(settingsProvider).applyFontGlobally, isFalse);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppConstants.prefApplyFontGlobally), isFalse);
  });
}
