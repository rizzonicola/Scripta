import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants/app_constants.dart';
import '../core/l10n/app_localizations.dart';
import '../core/theme/color_schemes.dart';
import '../core/utils/responsive_breakpoints.dart';
import '../features/editor/models/editor_state_model.dart';
import '../features/editor/providers/editor_provider.dart';
import '../features/settings/presentation/settings_view.dart';
import '../features/sync/providers/sync_provider.dart';

class TopAppBar extends ConsumerWidget implements PreferredSizeWidget {
  final VoidCallback? onToggleSidebar;
  final bool showBackButton;
  final VoidCallback? onBack;

  const TopAppBar({
    super.key,
    this.onToggleSidebar,
    this.showBackButton = false,
    this.onBack,
  });

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final editorState = ref.watch(editorProvider);
    final isDesktop = ResponsiveBreakpoints.isDesktop(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final compactMode = screenWidth < 520;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.35),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: preferredSize.height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                // Back button (Mobile editor view) or Sidebar toggle
                if (showBackButton)
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, size: 20),
                    tooltip: 'Indietro',
                    visualDensity: VisualDensity.compact,
                    onPressed: onBack,
                  )
                else if (!isDesktop)
                  IconButton(
                    icon: const Icon(Icons.menu_rounded, size: 20),
                    tooltip: l10n.folders,
                    visualDensity: VisualDensity.compact,
                    onPressed: onToggleSidebar,
                  ),

                const SizedBox(width: 4),

                // App Title (without app icon in top left)
                Flexible(
                  child: Text(
                    AppConstants.appName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),

                const Spacer(),

                // Dual Mode Toggle: Edit <-> Read-Only
                Container(
                  height: 34,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: theme.surfaceElevated,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ModeToggleSegment(
                        title: compactMode ? null : l10n.edit,
                        icon: Icons.edit_outlined,
                        tooltip: l10n.edit,
                        isSelected: editorState.mode == EditorMode.edit,
                        onTap: () {
                          ref
                              .read(editorProvider.notifier)
                              .setMode(EditorMode.edit);
                        },
                      ),
                      _ModeToggleSegment(
                        title: compactMode ? null : l10n.readOnly,
                        icon: Icons.visibility_outlined,
                        tooltip: l10n.readOnly,
                        isSelected: editorState.mode == EditorMode.readOnly,
                        onTap: () {
                          ref
                              .read(editorProvider.notifier)
                              .setMode(EditorMode.readOnly);
                        },
                      ),
                    ],
                  ),
                ),

                // Focus Mode Toggle (distraction-free, accessible on both desktop and Android)
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.fullscreen_rounded, size: 20),
                  tooltip: l10n.focusMode,
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    ref.read(editorProvider.notifier).toggleFocusMode();
                  },
                ),

                // Sync status indicator & quick manual sync button
                const SizedBox(width: 2),
                Consumer(
                  builder: (context, ref, _) {
                    final syncConfig = ref.watch(syncProvider);
                    if (!syncConfig.isAuthenticated) {
                      return IconButton(
                        icon: Icon(
                          Icons.cloud_off_outlined,
                          size: 19,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.45),
                        ),
                        tooltip: 'Account non connesso',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => SettingsView.show(context),
                      );
                    }
                    if (syncConfig.isSyncing) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }
                    return IconButton(
                      icon: Icon(
                        syncConfig.isOnline
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_off_outlined,
                        size: 19,
                        color: syncConfig.isOnline
                            ? const Color(0xFF10B981)
                            : Colors.amber,
                      ),
                      tooltip: syncConfig.isOnline
                          ? 'Sincronizzato: Online (Tocca per sincronizzare)'
                          : 'Server non raggiungibile (Offline)',
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        ref.read(syncProvider.notifier).triggerSync();
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeToggleSegment extends StatelessWidget {
  final String? title;
  final IconData icon;
  final String tooltip;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeToggleSegment({
    this.title,
    required this.icon,
    required this.tooltip,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.symmetric(
            horizontal: title != null ? 10 : 8,
            vertical: 4,
          ),
          decoration: BoxDecoration(
            color: isSelected ? theme.colorScheme.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: isSelected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              if (title != null) ...[
                const SizedBox(width: 6),
                Text(
                  title!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    color: isSelected
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
