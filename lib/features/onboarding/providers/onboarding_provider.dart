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
    state = completed;
  }

  Future<void> completeOnboarding() async {
    state = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefOnboardingCompleted, true);
  }

  Future<void> resetOnboarding() async {
    state = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.prefOnboardingCompleted, false);
  }
}

final onboardingProvider =
    StateNotifierProvider<OnboardingNotifier, bool?>((ref) {
  return OnboardingNotifier();
});
