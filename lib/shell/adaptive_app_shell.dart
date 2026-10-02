import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants/app_constants.dart';
import '../core/utils/responsive_breakpoints.dart';
import '../features/editor/presentation/note_editor_pane.dart';
import '../features/editor/providers/editor_provider.dart';
import '../features/folders/presentation/folder_tree_view.dart';
import '../features/notes/presentation/notes_list_view.dart';
import '../features/notes/providers/notes_provider.dart';
import '../features/onboarding/presentation/onboarding_dialog.dart';
import '../features/onboarding/providers/onboarding_provider.dart';
import '../features/sync/providers/sync_provider.dart';
import 'app_shortcuts_scope.dart';
import 'top_app_bar.dart';

enum MobileActiveView {
  notesList,
  editor,
}

class AdaptiveAppShell extends ConsumerStatefulWidget {
  const AdaptiveAppShell({super.key});

  @override
  ConsumerState<AdaptiveAppShell> createState() => _AdaptiveAppShellState();
}

class _AdaptiveAppShellState extends ConsumerState<AdaptiveAppShell>
    with WidgetsBindingObserver {
  /// Pannello cartelle a scomparsa, identico su tablet e mobile.
  static const Widget _folderDrawer = Drawer(
    child: SafeArea(
      child: FolderTreeView(),
    ),
  );

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  MobileActiveView _mobileActiveView = MobileActiveView.notesList;
  bool _hasCheckedOnboarding = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // Prima di tutto: scrive subito la nota con modifiche ancora nel
      // debounce di salvataggio (500 ms). La sync lo faceva già, ma solo con
      // account connesso e "sync al cambio di stato dell'app" attiva: un
      // utente solo-locale che mandava l'app in background subito dopo aver
      // digitato rischiava di perdere gli ultimi caratteri se l'OS
      // terminava il processo. È idempotente e quasi sempre un no-op.
      unawaited(ref.read(notesProvider.notifier).flushPendingSaves());
      ref.read(syncProvider.notifier).onAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      // Re-validate connectivity as soon as the app comes back to the
      // foreground, so the online/offline indicator doesn't show stale
      // information (e.g. the network changed while the app was backgrounded).
      ref.read(syncProvider.notifier).onAppResumed();
    }
  }

  void _openFolderDrawer() => _scaffoldKey.currentState?.openDrawer();

  void _showMobileEditor() {
    if (_mobileActiveView != MobileActiveView.editor) {
      setState(() => _mobileActiveView = MobileActiveView.editor);
    }
  }

  /// Torna alla lista note (layout mobile). Chiude la nota aperta, quindi
  /// notifica la sync (vedi `SyncNotifier.onNoteChangedOrClosed`).
  void _showMobileNotesList() {
    ref.read(syncProvider.notifier).onNoteChangedOrClosed();
    setState(() => _mobileActiveView = MobileActiveView.notesList);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(
      notesProvider.select((s) => s.activeNoteId),
      (previous, next) {
        if (previous != null && next != null && previous != next) {
          ref.read(syncProvider.notifier).onNoteChangedOrClosed();
        }
      },
    );

    ref.listen<bool?>(onboardingProvider, (previous, next) {
      if (next == false && !_hasCheckedOnboarding) {
        _hasCheckedOnboarding = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && context.mounted) {
            OnboardingDialog.show(context);
          }
        });
      }
    });

    final editorFocusMode = ref.watch(editorProvider.select((s) => s.isFocusMode));
    final screenType = ResponsiveBreakpoints.getScreenType(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final systemOverlay = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: theme.colorScheme.surface,
      systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    );

    // Il focus mode ha la precedenza su qualunque layout: scrittura o lettura
    // a tutto schermo, senza barre né pannelli.
    final Widget shellContent = editorFocusMode
        ? _buildFocusLayout()
        : switch (screenType) {
            DeviceScreenType.desktop => _buildDesktopLayout(),
            DeviceScreenType.tablet => _buildTabletLayout(),
            DeviceScreenType.mobile => _buildMobileLayout(),
          };

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemOverlay,
      // Scorciatoie da tastiera globali (Ctrl/Cmd+N, +F, F1...): vedi
      // core/utils/app_commands.dart per l'elenco completo.
      child: AppShortcutsScope(
        // Layout mobile a pannello singolo: mostra l'editor quando un
        // comando crea o duplica una nota.
        onEditorRequested: _showMobileEditor,
        child: shellContent,
      ),
    );
  }

  /// Focus mode: scrittura o lettura a tutto schermo, senza distrazioni.
  Widget _buildFocusLayout() {
    return const Scaffold(
      body: SafeArea(
        child: NoteEditorPane(),
      ),
    );
  }

  /// Desktop: 3 colonne (cartelle + lista note + editor).
  Widget _buildDesktopLayout() {
    return Scaffold(
      key: _scaffoldKey,
      appBar: const TopAppBar(),
      body: const Row(
        children: [
          SizedBox(
            width: AppConstants.folderSidebarWidth,
            child: FolderTreeView(),
          ),
          SizedBox(
            width: AppConstants.notesListWidth,
            child: NotesListView(),
          ),
          Expanded(
            child: NoteEditorPane(),
          ),
        ],
      ),
    );
  }

  /// Tablet: 2 colonne (lista note + editor), cartelle nel drawer.
  Widget _buildTabletLayout() {
    return Scaffold(
      key: _scaffoldKey,
      appBar: TopAppBar(onToggleSidebar: _openFolderDrawer),
      drawer: _folderDrawer,
      body: const Row(
        children: [
          SizedBox(
            width: AppConstants.notesListWidth,
            child: NotesListView(),
          ),
          Expanded(
            child: NoteEditorPane(),
          ),
        ],
      ),
    );
  }

  /// Mobile: pannello singolo (lista note oppure editor), cartelle nel drawer.
  Widget _buildMobileLayout() {
    final isEditorVisible = _mobileActiveView == MobileActiveView.editor;

    return PopScope(
      canPop: !isEditorVisible,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && isEditorVisible) _showMobileNotesList();
      },
      child: Scaffold(
        key: _scaffoldKey,
        appBar: TopAppBar(
          showBackButton: isEditorVisible,
          onBack: _showMobileNotesList,
          onToggleSidebar: _openFolderDrawer,
        ),
        drawer: _folderDrawer,
        body: SafeArea(
          top: false,
          bottom: true,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: isEditorVisible
                ? const NoteEditorPane(key: ValueKey('mobile_editor_pane'))
                : NotesListView(
                    key: const ValueKey('mobile_notes_list'),
                    onNoteSelected: (_) => _showMobileEditor(),
                  ),
          ),
        ),
      ),
    );
  }
}
