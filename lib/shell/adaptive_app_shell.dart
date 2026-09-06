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
      ref.read(syncProvider.notifier).onAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      // Re-validate connectivity as soon as the app comes back to the
      // foreground, so the online/offline indicator doesn't show stale
      // information (e.g. the network changed while the app was backgrounded).
      ref.read(syncProvider.notifier).onAppResumed();
    }
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

    final editorState = ref.watch(editorProvider);
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

    Widget shellContent;

    // 1. FOCUS MODE: Distraction-free full-screen writing or reading
    if (editorState.isFocusMode) {
      shellContent = const Scaffold(
        body: SafeArea(
          child: NoteEditorPane(),
        ),
      );
    } else if (screenType == DeviceScreenType.desktop) {
      // 2. DESKTOP LAYOUT (3 Columns: Folders + Notes List + Editor)
      shellContent = Scaffold(
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
    } else if (screenType == DeviceScreenType.tablet) {
      // 3. TABLET LAYOUT (2 Columns: Notes List + Editor, Folders in Drawer)
      shellContent = Scaffold(
        key: _scaffoldKey,
        appBar: TopAppBar(
          onToggleSidebar: () {
            _scaffoldKey.currentState?.openDrawer();
          },
        ),
        drawer: const Drawer(
          child: SafeArea(
            child: FolderTreeView(),
          ),
        ),
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
    } else {
      // 4. MOBILE LAYOUT (Single Pane Navigation + Drawer for Folders)
      shellContent = PopScope(
        canPop: _mobileActiveView == MobileActiveView.notesList,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && _mobileActiveView == MobileActiveView.editor) {
            ref.read(syncProvider.notifier).onNoteChangedOrClosed();
            setState(() {
              _mobileActiveView = MobileActiveView.notesList;
            });
          }
        },
        child: Scaffold(
          key: _scaffoldKey,
          appBar: TopAppBar(
            showBackButton: _mobileActiveView == MobileActiveView.editor,
            onBack: () {
              ref.read(syncProvider.notifier).onNoteChangedOrClosed();
              setState(() {
                _mobileActiveView = MobileActiveView.notesList;
              });
            },
            onToggleSidebar: () {
              _scaffoldKey.currentState?.openDrawer();
            },
          ),
          drawer: const Drawer(
            child: SafeArea(
              child: FolderTreeView(),
            ),
          ),
          body: SafeArea(
            top: false,
            bottom: true,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _mobileActiveView == MobileActiveView.notesList
                  ? NotesListView(
                      key: const ValueKey('mobile_notes_list'),
                      onNoteSelected: (note) {
                        setState(() {
                          _mobileActiveView = MobileActiveView.editor;
                        });
                      },
                    )
                  : const NoteEditorPane(
                      key: ValueKey('mobile_editor_pane'),
                    ),
            ),
          ),
        ),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemOverlay,
      child: shellContent,
    );
  }
}
