import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/constants/app_constants.dart';

/// `null` = stato ancora sconosciuto (lettura da SharedPreferences in
/// corso), `true`/`false` = onboarding completato o meno.
///
/// Migrato alla nuova `Notifier` API: l'inizializzazione asincrona (lettura
/// di SharedPreferences) resta "fire-and-forget" avviata da `build()`,
/// proprio come prima veniva avviata dal costruttore — lo stato esposto
/// resta un semplice `bool?` sincrono (non un `AsyncValue<bool>`), per non
/// alterare il contratto pubblico consumato dagli altri widget.
class OnboardingNotifier extends Notifier<bool?> {
  @override
  bool? build() {
    _checkStatus();
    return null;
  }

  Future<void> _checkStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final completed =
        prefs.getBool(AppConstants.prefOnboardingCompleted) ?? false;
    if (!ref.mounted) return;
    state = completed;
  }

  Future<void> completeOnboarding() async {
    state = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefOnboardingCompleted, true);
  }
}

final onboardingProvider = NotifierProvider<OnboardingNotifier, bool?>(
  OnboardingNotifier.new,
);
