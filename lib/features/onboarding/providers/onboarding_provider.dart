import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/constants/app_constants.dart';

class OnboardingNotifier extends StateNotifier<bool?> {
  OnboardingNotifier() : super(null) {
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final completed =
        prefs.getBool(AppConstants.prefOnboardingCompleted) ?? false;
    // Stesso rischio di race condition di NotesNotifier/FolderNotifier: il
    // notifier può essere stato smontato mentre l'attesa su
    // SharedPreferences era ancora in corso.
    if (!mounted) return;
    state = completed;
  }

  Future<void> completeOnboarding() async {
    state = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefOnboardingCompleted, true);
  }
}

final onboardingProvider =
    StateNotifierProvider<OnboardingNotifier, bool?>((ref) {
  return OnboardingNotifier();
});
