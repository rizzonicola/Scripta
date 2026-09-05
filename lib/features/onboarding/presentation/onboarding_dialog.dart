import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_localizations.dart';
import '../providers/onboarding_provider.dart';

class OnboardingDialog extends ConsumerStatefulWidget {
  const OnboardingDialog({super.key});

  static Future<void> show(BuildContext context) {
    if (!context.mounted) return Future.value();
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const OnboardingDialog(),
    );
  }

  @override
  ConsumerState<OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends ConsumerState<OnboardingDialog> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    final slides = [
      _SlideData(
        icon: Icons.edit_note_rounded,
        title: l10n.onboardingWelcomeTitle,
        description: l10n.onboardingWelcomeDesc,
        accentColor: theme.colorScheme.primary,
      ),
      _SlideData(
        icon: Icons.chrome_reader_mode_outlined,
        title: l10n.onboardingDualTitle,
        description: l10n.onboardingDualDesc,
        accentColor: const Color(0xFF06B6D4),
      ),
      _SlideData(
        icon: Icons.fullscreen_rounded,
        title: l10n.onboardingFocusTitle,
        description: l10n.onboardingFocusDesc,
        accentColor: const Color(0xFF8B5CF6),
      ),
      _SlideData(
        icon: Icons.account_tree_outlined,
        title: l10n.onboardingFoldersTitle,
        description: l10n.onboardingFoldersDesc,
        accentColor: const Color(0xFF10B981),
      ),
    ];

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.all(28.0),
          child: Column(
            children: [
              // Carousel
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: slides.length,
                  onPageChanged: (index) {
                    setState(() => _currentPage = index);
                  },
                  itemBuilder: (context, index) {
                    final slide = slides[index];
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 84,
                          height: 84,
                          decoration: BoxDecoration(
                            color: slide.accentColor.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: slide.accentColor.withValues(alpha: 0.3),
                              width: 2,
                            ),
                          ),
                          child: Icon(
                            slide.icon,
                            size: 42,
                            color: slide.accentColor,
                          ),
                        ),
                        const SizedBox(height: 28),
                        Text(
                          slide.title,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          slide.description,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                            height: 1.45,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),

              // Page Indicator Dots
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  slides.length,
                  (index) => AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: _currentPage == index ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _currentPage == index
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 28),

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (_currentPage < slides.length - 1)
                    TextButton(
                      onPressed: () {
                        ref
                            .read(onboardingProvider.notifier)
                            .completeOnboarding();
                        Navigator.of(context).pop();
                      },
                      child: Text(l10n.skip),
                    )
                  else
                    const SizedBox(width: 64),
                  FilledButton(
                    onPressed: () {
                      if (_currentPage < slides.length - 1) {
                        _pageController.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        );
                      } else {
                        ref
                            .read(onboardingProvider.notifier)
                            .completeOnboarding();
                        Navigator.of(context).pop();
                      }
                    },
                    child: Text(
                      _currentPage == slides.length - 1
                          ? l10n.getStarted
                          : l10n.next,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SlideData {
  final IconData icon;
  final String title;
  final String description;
  final Color accentColor;

  const _SlideData({
    required this.icon,
    required this.title,
    required this.description,
    required this.accentColor,
  });
}
