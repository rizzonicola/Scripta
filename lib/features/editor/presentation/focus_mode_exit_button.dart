import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_localizations.dart';
import '../providers/editor_provider.dart';

class FocusModeExitButton extends ConsumerStatefulWidget {
  const FocusModeExitButton({super.key});

  @override
  ConsumerState<FocusModeExitButton> createState() =>
      _FocusModeExitButtonState();
}

class _FocusModeExitButtonState extends ConsumerState<FocusModeExitButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        opacity: _isHovered ? 1.0 : 0.35,
        child: Tooltip(
          message: l10n.exitFocusMode,
          child: Material(
            elevation: 4,
            shape: const CircleBorder(),
            color: isDark ? const Color(0xFF222533) : Colors.white,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                ref.read(editorProvider.notifier).exitFocusMode();
              },
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(alpha: 0.4),
                    width: 1,
                  ),
                ),
                child: Icon(
                  Icons.fullscreen_exit_rounded,
                  size: 22,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
