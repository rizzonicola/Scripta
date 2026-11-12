import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants/app_constants.dart';
import '../core/l10n/app_localizations.dart';
import '../core/l10n/desktop_strings.dart';
import '../features/external_open/services/external_open_processor.dart';
import '../core/services/external_open_service.dart';
import '../core/services/session_state_service.dart';
import '../core/utils/responsive_breakpoints.dart';
import '../features/editor/presentation/note_editor_pane.dart';
import '../features/editor/providers/editor_provider.dart';
import '../features/folders/models/external_open_destination.dart';
import '../features/folders/presentation/folder_import_picker.dart';
import '../features/folders/presentation/folder_tree_view.dart';
import '../features/folders/providers/folder_provider.dart';
import '../features/notes/presentation/notes_list_view.dart';
import '../features/notes/providers/notes_provider.dart';
import '../features/onboarding/presentation/onboarding_dialog.dart';
import '../features/onboarding/providers/onboarding_provider.dart';
import '../features/sync/providers/sync_provider.dart';
import 'app_shortcuts_scope.dart';
import 'top_app_bar.dart';

class _SaveErrorBanner extends StatelessWidget {
  const _SaveErrorBanner({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final foreground = theme.colorScheme.onErrorContainer;

    return Material(
      color: theme.colorScheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.error_outline_rounded, color: foreground),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.saveErrorTitle,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      l10n.saveErrorBody,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: foreground,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(foregroundColor: foreground),
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum MobileActiveView { notesList, editor }

class AdaptiveAppShell extends ConsumerStatefulWidget {
  const AdaptiveAppShell({super.key});

  @override
  ConsumerState<AdaptiveAppShell> createState() => _AdaptiveAppShellState();
}

class _AdaptiveAppShellState extends ConsumerState<AdaptiveAppShell>
    with WidgetsBindingObserver {
  /// Pannello cartelle a scomparsa, identico su tablet e mobile.
  static const Widget _folderDrawer = Drawer(
    child: SafeArea(child: FolderTreeView()),
  );

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  MobileActiveView _mobileActiveView = MobileActiveView.notesList;
  bool _hasCheckedOnboarding = false;

  /// File/cartelle ricevuti da "Apri con Scripta" o dal drag & drop. La coda
  /// esiste perché più eventi possono arrivare mentre una cartella viene
  /// importata: vanno elaborati uno alla volta, senza aprire più finestre di
  /// avanzamento o sovrapporre scritture. Ogni richiesta conserva la propria
  /// provenienza: il drag & drop usa la cartella corrente, "Apri con" chiede
  /// dove aprire il file.
  final List<ExternalOpenRequest> _pendingExternalOpenRequests =
      <ExternalOpenRequest>[];
  bool _processingExternalOpenPaths = false;
  ExternalOpenListener? _externalOpenListener;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _externalOpenListener = _onExternalOpenRequest;
    ExternalOpenService.instance.attach(_externalOpenListener!);

    // Ripresa dell'ultima posizione (layout mobile a pannello singolo): se
    // l'app era stata chiusa sull'editor si riparte dall'editor, non dalla
    // lista. Serve anche una nota salvata: senza (ultima nota cancellata) non
    // c'è nulla da mostrare nell'editor e si parte dalla lista. Sugli altri
    // layout il valore non ha effetto. `read` e non `watch`: è un'istantanea
    // fissata all'avvio (vedi sessionSnapshotProvider).
    final session = ref.read(sessionSnapshotProvider);
    if (session.mobileEditorOpen && session.noteId != null) {
      _mobileActiveView = MobileActiveView.editor;
    }
  }

  @override
  void dispose() {
    final listener = _externalOpenListener;
    if (listener != null) {
      ExternalOpenService.instance.detach(listener);
    }
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
      ref.read(notesProvider.notifier).flushPendingSavesInBackground();
      ref.read(syncProvider.notifier).onAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      // Re-validate connectivity as soon as the app comes back to the
      // foreground, so the online/offline indicator doesn't show stale
      // information (e.g. the network changed while the app was backgrounded).
      ref.read(syncProvider.notifier).onAppResumed();
    }
  }

  void _openFolderDrawer() => _scaffoldKey.currentState?.openDrawer();

  /// Tutti i percorsi che mostrano l'editor su mobile (tocco su una nota,
  /// nuova nota, duplica) passano da qui; tutti quelli che tornano alla lista
  /// (freccia indietro, gesto/tasto Indietro) da [_showMobileNotesList]. Sono
  /// quindi gli unici due punti in cui salvare il pannello visibile.
  void _showMobileEditor() {
    if (_mobileActiveView != MobileActiveView.editor) {
      setState(() => _mobileActiveView = MobileActiveView.editor);
      unawaited(SessionStateService.saveMobileEditorOpen(true));
    }
  }

  /// Torna alla lista note (layout mobile). Mostrare la lista è anche l'unico
  /// modo per uscire dal focus: altrimenti il pannello visibile resterebbe
  /// l'editor e la lista non verrebbe mai montata (perdendo, tra l'altro, la
  /// richiesta di focus della ricerca globale).
  void _showMobileNotesList() {
    if (ref.read(editorProvider).isFocusMode) {
      ref.read(editorProvider.notifier).exitFocusMode();
    }
    if (_mobileActiveView != MobileActiveView.notesList) {
      setState(() => _mobileActiveView = MobileActiveView.notesList);
      unawaited(SessionStateService.saveMobileEditorOpen(false));
    }
  }

  void _retryPendingWrites() {
    unawaited(ref.read(notesProvider.notifier).retryFailedWrites());
    unawaited(ref.read(folderProvider.notifier).retryPendingWrites());
  }

  void _onExternalOpenRequest(ExternalOpenRequest request) {
    if (request.paths.isEmpty) return;
    _pendingExternalOpenRequests.add(request);
    unawaited(_drainExternalOpenPaths());
  }

  Future<void> _drainExternalOpenPaths() async {
    if (_processingExternalOpenPaths) return;
    _processingExternalOpenPaths = true;
    try {
      // Il selettore di destinazione e la cartella corrente leggono lo stato
      // in memoria: all'avvio (file passato sulla riga di comando) il primo
      // caricamento dal DB può non essere ancora terminato.
      await ref.read(folderProvider.notifier).ready;
      if (!mounted) return;

      while (mounted && _pendingExternalOpenRequests.isNotEmpty) {
        final request = _pendingExternalOpenRequests.removeAt(0);
        final fromDragAndDrop = request.source == ExternalOpenSource.dragDrop;

        ExternalOpenOutcome outcome;
        try {
          outcome = await ExternalOpenProcessor.openPaths(
            request.paths,
            notes: ref.read(notesProvider.notifier),
            folders: ref.read(folderProvider.notifier),
            chooseFolderDestination: _chooseFolderImportDestination,
            // Un file trascinato non deve chiedere la destinazione: va nella
            // cartella attualmente aperta nell'app. "Apri con Scripta" invece
            // la chiede, come per l'importazione di una cartella.
            chooseFileDestination: fromDragAndDrop
                ? null
                : _chooseFileImportDestination,
            defaultFileFolderId: fromDragAndDrop
                ? ref.read(folderProvider).selectedFolderId
                : null,
          );
        } catch (_) {
          outcome = ExternalOpenOutcome(failedPaths: request.paths);
        }
        if (!mounted) return;
        if (outcome.importedNotes > 0 || outcome.importedFolders > 0) {
          // Apertura esterna = mutazione locale in blocco, senza i call site
          // UI che normalmente notificano la sync.
          ref.read(syncProvider.notifier).onFolderStructureChanged();
        }
        _showExternalOpenOutcome(outcome);
      }
    } finally {
      _processingExternalOpenPaths = false;
    }
  }

  Future<ExternalOpenDestination?> _chooseFolderImportDestination(
    String folderName,
  ) {
    if (!mounted) return Future.value(null);
    return showExternalOpenDestinationPicker(
      context,
      ref,
      targetName: folderName,
      isFolder: true,
    );
  }

  Future<ExternalOpenDestination?> _chooseFileImportDestination(
    String fileName,
  ) {
    if (!mounted) return Future.value(null);
    return showExternalOpenDestinationPicker(
      context,
      ref,
      targetName: fileName,
      isFolder: false,
    );
  }

  void _showExternalOpenOutcome(ExternalOpenOutcome outcome) {
    final ds = DesktopStrings.of(context);
    String? message;
    var isError = false;

    if (outcome.failedPaths.isNotEmpty) {
      message = ds.openFailed;
      isError = true;
    } else if (outcome.ignoredPaths.isNotEmpty) {
      message = ds.openUnsupported;
      isError = true;
    } else if (outcome.openedFolders > 0) {
      message = outcome.importedNotes == 0
          ? ds.openFolderEmpty
          : ds.openFolderDone(outcome.importedNotes, outcome.importedFolders);
    } else if (outcome.openedFiles > 1) {
      message = ds.openNotesDone(outcome.openedFiles);
    }

    if (message == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade800 : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Unico punto che traduce un cambio di nota (incluse le transizioni
    // da/verso `null`) in un trigger di sync. L'editor non lo fa più: quando
    // è smontato (lista mobile) non vedrebbe comunque il cambio.
    ref.listen<String?>(notesProvider.select((s) => s.activeNoteId), (
      previous,
      next,
    ) {
      if (previous != next) {
        ref.read(syncProvider.notifier).onNoteChangedOrClosed();
      }
    });

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

    // Avviso UNA volta per transizione "quota superata" (non a ogni retry):
    // il contatore cambia solo quando lo stato passa da normale a esaurito.
    ref.listen<int>(syncProvider.select((s) => s.quotaWarningTick), (
      previous,
      next,
    ) {
      if (next <= 0) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !context.mounted) return;
        final messenger = ScaffoldMessenger.maybeOf(context);
        if (messenger == null) return;
        messenger.showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).quotaExceededSnack),
            backgroundColor: Colors.orange.shade800,
            behavior: SnackBarBehavior.floating,
          ),
        );
      });
    });

    final editorFocusMode = ref.watch(
      editorProvider.select((s) => s.isFocusMode),
    );
    final screenType = ResponsiveBreakpoints.getScreenType(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasSaveError =
        ref.watch(notesProvider.select((s) => s.hasPendingWriteError)) ||
        ref.watch(folderProvider.select((s) => s.hasPendingWriteError));

    final systemOverlay = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: theme.colorScheme.surface,
      systemNavigationBarIconBrightness: isDark
          ? Brightness.light
          : Brightness.dark,
    );

    // Un solo stato derivato decide cosa è visibile su mobile: il focus è una
    // modalità che forza l'editor, non una seconda verità sul pannello.
    final isMobileEditorVisible =
        editorFocusMode || _mobileActiveView == MobileActiveView.editor;
    final isMobile = screenType == DeviceScreenType.mobile;

    // Il focus mode NON sostituisce il pannello editor: toglie soltanto la
    // chrome attorno (app bar, drawer, pannelli laterali). `NoteEditorPane`
    // resta nello stesso punto dell'albero, quindi conserva controller,
    // scroll e posizione senza reparenting né GlobalKey.
    final PreferredSizeWidget? appBar = editorFocusMode
        ? null
        : switch (screenType) {
            DeviceScreenType.desktop => const TopAppBar(isEditorVisible: true),
            DeviceScreenType.tablet => TopAppBar(
              isEditorVisible: true,
              onToggleSidebar: _openFolderDrawer,
            ),
            DeviceScreenType.mobile => TopAppBar(
              isEditorVisible: isMobileEditorVisible,
              showBackButton: isMobileEditorVisible,
              onBack: _showMobileNotesList,
              onToggleSidebar: _openFolderDrawer,
            ),
          };
    final showDrawer =
        !editorFocusMode && screenType != DeviceScreenType.desktop;
    final body = switch (screenType) {
      DeviceScreenType.desktop => _buildDesktopBody(
        isFocusMode: editorFocusMode,
      ),
      DeviceScreenType.tablet => _buildTabletBody(isFocusMode: editorFocusMode),
      DeviceScreenType.mobile => _buildMobileBody(
        isFocusMode: editorFocusMode,
        isEditorVisible: isMobileEditorVisible,
      ),
    };

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemOverlay,
      // Scorciatoie da tastiera globali (Ctrl/Cmd+N, +F, F1...): vedi
      // core/utils/app_commands.dart per l'elenco completo.
      child: AppShortcutsScope(
        // Solo il layout mobile ha un pannello da cambiare: su desktop e
        // tablet l'editor è già visibile e non esiste uno stato da persistere.
        onEditorRequested: isMobile ? _showMobileEditor : null,
        onNotesListRequested: isMobile ? _showMobileNotesList : null,
        child: Column(
          children: [
            if (hasSaveError) _SaveErrorBanner(onRetry: _retryPendingWrites),
            Expanded(
              child: Scaffold(
                key: _scaffoldKey,
                appBar: appBar,
                drawer: showDrawer ? _folderDrawer : null,
                body: SafeArea(
                  // Senza app bar la status bar non è già compensata dal
                  // Material: in focus il body deve evitare la notch.
                  top:
                      editorFocusMode && screenType != DeviceScreenType.desktop,
                  bottom: screenType == DeviceScreenType.mobile,
                  left: false,
                  right: false,
                  child: body,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Desktop: 3 colonne (cartelle + lista note + editor).
  ///
  /// In focus mode i due pannelli laterali hanno larghezza zero ma restano
  /// nello stesso slot: così l'`Expanded` con `NoteEditorPane` non cambia
  /// posizione nell'albero e il pannello non viene rimontato.
  Widget _buildDesktopBody({required bool isFocusMode}) {
    return Row(
      children: [
        SizedBox(
          width: isFocusMode ? 0 : AppConstants.folderSidebarWidth,
          child: isFocusMode ? const SizedBox.shrink() : const FolderTreeView(),
        ),
        SizedBox(
          width: isFocusMode ? 0 : AppConstants.notesListWidth,
          child: isFocusMode ? const SizedBox.shrink() : const NotesListView(),
        ),
        const Expanded(child: NoteEditorPane()),
      ],
    );
  }

  /// Tablet: 2 colonne (lista note + editor), cartelle nel drawer. In focus
  /// la lista si azzera, ma l'editor resta nello stesso slot.
  Widget _buildTabletBody({required bool isFocusMode}) {
    return Row(
      children: [
        SizedBox(
          width: isFocusMode ? 0 : AppConstants.notesListWidth,
          child: isFocusMode ? const SizedBox.shrink() : const NotesListView(),
        ),
        const Expanded(child: NoteEditorPane()),
      ],
    );
  }

  /// Mobile: pannello singolo (lista note oppure editor), cartelle nel drawer.
  /// In focus l'`AnimatedSwitcher` resta lo stesso widget con la stessa chiave
  /// dell'editor, quindi `NoteEditorPane` non viene ricreato.
  Widget _buildMobileBody({
    required bool isFocusMode,
    required bool isEditorVisible,
  }) {
    return PopScope(
      canPop: !isEditorVisible,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (isFocusMode) {
          // In focus la nota resta aperta: Indietro toglie solo la modalità
          // a tutto schermo.
          ref.read(editorProvider.notifier).exitFocusMode();
        } else if (isEditorVisible) {
          _showMobileNotesList();
        }
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        reverseDuration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final isEditor = child.key == const ValueKey('mobile_editor_pane');
          final begin = isEditor
              ? const Offset(0.08, 0)
              : const Offset(-0.08, 0);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: begin,
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          );
        },
        child: isEditorVisible
            ? const NoteEditorPane(key: ValueKey('mobile_editor_pane'))
            : NotesListView(
                key: const ValueKey('mobile_notes_list'),
                onNoteSelected: (_) => _showMobileEditor(),
              ),
      ),
    );
  }
}
