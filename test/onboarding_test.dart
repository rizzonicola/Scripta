import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scripta/core/constants/app_constants.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/features/onboarding/presentation/onboarding_dialog.dart';
import 'package:scripta/features/onboarding/providers/onboarding_provider.dart';

class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => OnboardingDialog.show(context),
          child: const Text('open'),
        ),
      ),
    );
  }
}

Future<void> _pumpApp(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: Locale('it'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: _Host(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      AppConstants.prefOnboardingCompleted: false,
    });
  });

  testWidgets('skip chiude la finestra e segna l\'onboarding completato', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pumpApp(tester, container);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingDialog), findsOneWidget);

    await tester.tap(find.text('Salta'));
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingDialog), findsNothing);
    expect(container.read(onboardingProvider), isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppConstants.prefOnboardingCompleted), isTrue);
  });

  testWidgets('le frecce scorrono le slide e l\'ultima conclude', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pumpApp(tester, container);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Benvenuto in Scripta'), findsOneWidget);

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Avanti'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Organizzazione ad Albero'), findsOneWidget);

    await tester.tap(find.text('Inizia Ora'));
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingDialog), findsNothing);
    expect(container.read(onboardingProvider), isTrue);
  });
}
