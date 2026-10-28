import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/l10n/app_localizations.dart';
import 'package:scripta/core/services/secure_storage_service.dart';
import 'package:scripta/features/settings/presentation/account_sync_section.dart';
import 'package:scripta/features/sync/providers/sync_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemorySecureStorage extends SecureStorageService {
  _MemorySecureStorage() : super(null);

  @override
  Future<String?> getAuthToken() async => null;

  @override
  Future<void> saveRefreshToken(String token) async {}

  @override
  Future<String?> getRefreshToken() async => null;

  @override
  Future<String?> getServerUrl() async => null;

  @override
  Future<String?> getUsername() async => null;

  @override
  Future<void> clearAuth() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      'i campi di login sync espongono gli hint per il password manager',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(_MemorySecureStorage()),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(child: AccountSyncSection()),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AutofillGroup), findsOneWidget);
    final fields =
        tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields, hasLength(3));
    expect(fields[0].autofillHints, contains(AutofillHints.url));
    expect(fields[1].autofillHints, contains(AutofillHints.username));
    expect(fields[2].autofillHints, contains(AutofillHints.password));
  });
}
