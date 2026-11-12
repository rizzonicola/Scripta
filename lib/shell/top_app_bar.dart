import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants/app_constants.dart';
import '../core/l10n/app_localizations.dart';
import '../core/theme/color_schemes.dart';
import '../core/utils/responsive_breakpoints.dart';
import '../features/editor/models/editor_state_model.dart';
import '../features/editor/providers/editor_provider.dart';
import '../features/editor/providers/note_search_provider.dart';
import '../features/notes/providers/notes_provider.dart';
import '../features/settings/presentation/settings_view.dart';
import '../features/sync/providers/sync_provider.dart';

class TopAppBar extends ConsumerWidget implements PreferredSizeWidget {
  final VoidCallback? onToggleSidebar;
  final bool showBackButton;

  /// `true` quando il pannello editor è realmente a schermo. È distinto da
  /// [showBackButton], che riguarda solo la navigazione mobile: un parametro
  /// di navigazione non deve decidere se mostrare le azioni dell'editor.
  final bool isEditorVisible;
  final VoidCallback? onBack;

  const TopAppBar({
    super.key,
    this.onToggleSidebar,
    this.showBackButton = false,
    this.isEditorVisible = false,
    this.onBack,
  });

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // Solo il campo effettivamente usato (mode): evita di ricostruire
    // l'intera TopAppBar per cambi di editorProvider che non riguardano
    // questo widget (es. isFocusMode).
    final editorMode = ref.watch(editorProvider.select((s) => s.mode));
    final screenType = ResponsiveBreakpoints.getScreenType(context);
    final isDesktop = screenType == DeviceScreenType.desktop;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final compactMode = screenWidth < 520;

    // Le azioni dell'editor (modalità, ricerca interna, focus) esistono solo
    // quando l'editor è a schermo e c'è una nota da mostrare. La ricerca
    // globale/per-cartella vive invece in `NotesListView` ed è indipendente.
    final activeNoteId = ref.watch(notesProvider.select((s) => s.activeNoteId));
    final isNoteSearchActive = ref.watch(
      noteSearchProvider.select((s) => s.isActive),
    );
    final showEditorActions = isEditorVisible && activeNoteId != null;
    // Senza una nota aperta le azioni dell'editor spariscono. Su mobile e
    // tablet le Impostazioni vivono nel drawer: mostrare qui una scorciatoia
    // evita che la barra resti vuota a destra e risparmia un passaggio.
    // Su desktop la voce è già sempre visibile nella barra delle cartelle.
    final showSettingsShortcut = !showEditorActions && !isDesktop;

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
                    tooltip: l10n.back,
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

                // App Title (without app icon in top left). `Expanded`, non
                // `Flexible` + `Spacer`: con due figli flex lo spazio libero
                // viene diviso a metà e la parte non usata dal testo resta
                // DOPO le icone, lasciandole staccate dal bordo destro.
                Expanded(
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

                if (showEditorActions) ...[
                  // Dual Mode Toggle: Edit <-> Read-Only
                  Container(
                    height: 36,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: theme.surfaceElevated,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ModeToggleSegment(
                          title: compactMode ? null : l10n.edit,
                          icon: Icons.edit_outlined,
                          tooltip: l10n.edit,
                          isSelected: editorMode == EditorMode.edit,
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
                          isSelected: editorMode == EditorMode.readOnly,
                          onTap: () {
                            ref
                                .read(editorProvider.notifier)
                                .setMode(EditorMode.readOnly);
                          },
                        ),
                      ],
                    ),
                  ),

                  // In-Note Search Toggle (find/highlight occurrences within the open note)
                  const SizedBox(width: 2),
                  IconButton(
                    icon: Icon(
                      isNoteSearchActive
                          ? Icons.search_off_rounded
                          : Icons.search_rounded,
                      size: 20,
                    ),
                    tooltip: l10n.searchInNote,
                    visualDensity: VisualDensity.compact,
                    color: isNoteSearchActive
                        ? theme.colorScheme.primary
                        : null,
                    onPressed: () {
                      if (isNoteSearchActive) {
                        ref.read(noteSearchProvider.notifier).close();
                      } else {
                        ref.read(noteSearchProvider.notifier).open();
                      }
                    },
                  ),

                  // Focus Mode Toggle (distraction-free, desktop and Android)
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.fullscreen_rounded, size: 20),
                    tooltip: l10n.focusMode,
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      ref.read(editorProvider.notifier).toggleFocusMode();
                    },
                  ),
                ],

                // Sync status indicator & quick manual sync button
                const SizedBox(width: 2),
                const _SyncStatusButton(),

                // Scorciatoia Impostazioni: ultimo elemento a destra, con la
                // sync subito alla sua sinistra. Compare solo quando le azioni
                // dell'editor sono nascoste (nessuna nota aperta su mobile e
                // tablet).
                if (showSettingsShortcut) ...[
                  const SizedBox(width: 2),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined, size: 19),
                    tooltip: l10n.settings,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => SettingsView.show(context),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SyncStatusButton extends ConsumerWidget {
  const _SyncStatusButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Solo i campi usati da questo indicatore, invece dell'intero SyncConfig:
    // con l'uguaglianza per valore ora presente su SyncConfig, `.select` qui
    // evita anche il rebuild "silenzioso" che il poll di connettività
    // periodico altrimenti causerebbe ad ogni ciclo.
    final isAuthenticated = ref.watch(
      syncProvider.select((s) => s.isAuthenticated),
    );
    final isSyncing = ref.watch(syncProvider.select((s) => s.isSyncing));
    final isOnline = ref.watch(syncProvider.select((s) => s.isOnline));
    final quotaExceeded = ref.watch(
      syncProvider.select((s) => s.quotaExceeded),
    );

    if (!isAuthenticated) {
      return IconButton(
        icon: Icon(
          Icons.cloud_off_outlined,
          size: 19,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
        tooltip: 'Account non connesso',
        visualDensity: VisualDensity.compact,
        onPressed: () => SettingsView.show(context),
      );
    }
    if (isSyncing) {
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
        isOnline ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
        size: 19,
        color: quotaExceeded
            ? theme.warningColor
            : isOnline
            ? theme.successColor
            : theme.warningColor,
      ),
      tooltip: quotaExceeded
          ? 'Sincronizzazione sospesa: quota di archiviazione esaurita'
          : isOnline
          ? 'Sincronizzato: Online (Tocca per sincronizzare)'
          : 'Server non raggiungibile (Offline)',
      visualDensity: VisualDensity.compact,
      onPressed: () {
        ref.read(syncProvider.notifier).triggerSync();
      },
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

    final selectedColor = theme.colorScheme.primary;

    return SizedBox(
      height: 30,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: Semantics(
          button: true,
          selected: isSelected,
          label: tooltip,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: isSelected
                  ? selectedColor.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(7),
                focusColor: selectedColor.withValues(alpha: 0.12),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: title != null ? 11 : 9,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        icon,
                        size: 15,
                        color: isSelected
                            ? selectedColor
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.65,
                              ),
                      ),
                      if (title != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          title!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: isSelected
                                ? selectedColor
                                : theme.colorScheme.onSurface.withValues(
                                    alpha: 0.65,
                                  ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
