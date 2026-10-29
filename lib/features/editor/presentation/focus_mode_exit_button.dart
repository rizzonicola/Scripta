import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/utils/platform_utils.dart';
import '../providers/editor_provider.dart';

class FocusModeExitButton extends ConsumerStatefulWidget {
  const FocusModeExitButton({super.key});

  @override
  ConsumerState<FocusModeExitButton> createState() =>
      _FocusModeExitButtonState();
}

class _FocusModeExitButtonState extends ConsumerState<FocusModeExitButton> {
  bool _isHovered = false;
  bool _hasFocus = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isHighlighted = _isHovered || _hasFocus;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      opacity: isHighlighted
          ? 1.0
          : isDesktopPlatform
          ? 0.58
          : 0.82,
      child: Tooltip(
        message: l10n.exitFocusMode,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color:
                (isDark ? const Color(0xFF222533) : theme.colorScheme.surface)
                    .withValues(alpha: isDark ? 0.68 : 0.78),
            border: Border.all(
              color: theme.colorScheme.outline.withValues(
                alpha: isHighlighted ? 0.5 : 0.3,
              ),
              width: 1,
            ),
            boxShadow: isHighlighted
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.28 : 0.12,
                      ),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              focusColor: theme.colorScheme.primary.withValues(alpha: 0.16),
              onHover: (value) => setState(() => _isHovered = value),
              onFocusChange: (value) => setState(() => _hasFocus = value),
              onTap: () {
                ref.read(editorProvider.notifier).exitFocusMode();
              },
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(
                  Icons.fullscreen_exit_rounded,
                  size: 22,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.92),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
