import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n/app_localizations.dart';
import '../core/l10n/desktop_strings.dart';
import '../core/services/export_service.dart';
import '../core/utils/app_commands.dart';
import '../core/utils/focus_requests.dart';
import '../core/widgets/shortcuts_help_dialog.dart';
import '../features/editor/models/editor_state_model.dart';
import '../features/editor/providers/editor_provider.dart';
import '../features/editor/providers/note_search_provider.dart';
import '../features/folders/presentation/folder_dialogs.dart'
    show showAddFolderDialog;
import '../features/folders/providers/folder_provider.dart';
import '../features/notes/presentation/note_card.dart';
import '../features/notes/providers/notes_provider.dart';
import '../features/settings/presentation/settings_view.dart';
import '../features/sync/providers/sync_provider.dart';

/// Registra le scorciatoie globali dell'app (vedi [AppCommand]).
///
/// Usa un handler su [HardwareKeyboard] (come F11 in
/// `WindowDecorationService`) invece di `Shortcuts`/`Focus`: funziona anche
/// quando nessun widget ha il focus (es. dopo un click su un'area vuota, che
/// su desktop toglie il focus al campo di testo). Per non interferire con
/// dialog, menu e schermate secondarie, le scorciatoie sono attive SOLO
/// quando la route della shell è quella in primo piano.
class AppShortcutsScope extends ConsumerStatefulWidget {
  final Widget child;

  /// Chiamato quando un comando crea/apre una nota e l'editor deve
  /// diventare visibile (layout mobile a pannello singolo).
  final VoidCallback? onEditorRequested;

  const AppShortcutsScope({
    super.key,
    required this.child,
    this.onEditorRequested,
  });

  @override
  ConsumerState<AppShortcutsScope> createState() => _AppShortcutsScopeState();
}

class _AppShortcutsScopeState extends ConsumerState<AppShortcutsScope> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    if (!mounted) return false;
    // Dialog, popup menu e schermate (es. Impostazioni) sono route sopra la
    // shell: in quel caso le scorciatoie globali restano spente.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;

    final command = matchAppCommand(event, HardwareKeyboard.instance);
    if (command == null) return false;
    return _run(command);
  }

  /// Esegue [command]. Restituisce `true` se l'evento è stato gestito (e non
  /// deve proseguire verso il campo di testo).
  bool _run(AppCommand command) {
    final notes = ref.read(notesProvider.notifier);
    final activeNote = ref.read(activeNoteProvider);

    switch (command) {
      case AppCommand.newNote:
        notes.createNote(folderId: ref.read(folderProvider).selectedFolderId);
        widget.onEditorRequested?.call();
        return true;

      case AppCommand.newFolder:
        showAddFolderDialog(context, ref);
        return true;

      case AppCommand.save:
        // Il salvataggio è già automatico (debounce): questo lo forza subito
        // e, se l'account è connesso, avvia anche la sincronizzazione.
        unawaited(notes.flushPendingSaves());
        if (ref.read(syncProvider).isAuthenticated) {
          unawaited(ref.read(syncProvider.notifier).triggerSync());
        }
        return true;

      case AppCommand.pinNote:
        if (activeNote == null) return false;
        notes.togglePin(activeNote.id);
        return true;

      case AppCommand.moveNote:
        if (activeNote == null) return false;
        NoteCard.showMoveNoteDialog(context, ref, activeNote);
        return true;

      case AppCommand.duplicateNote:
        if (activeNote == null) return false;
        notes.duplicateNote(
          activeNote.id,
          copySuffix: DesktopStrings.of(context).copySuffix,
        );
        widget.onEditorRequested?.call();
        return true;

      case AppCommand.exportNote:
        if (activeNote == null) return false;
        unawaited(ExportService.exportNoteAsMarkdown(context, activeNote));
        return true;

      case AppCommand.deleteNote:
        if (activeNote == null) return false;
        NoteCard.confirmDelete(
          context,
          ref,
          AppLocalizations.of(context),
          activeNote,
        );
        return true;

      case AppCommand.nextNote:
      case AppCommand.previousNote:
        final list = ref.read(filteredNotesProvider);
        if (list.isEmpty) return false;
        final activeId = ref.read(notesProvider).activeNoteId;
        final current = list.indexWhere((n) => n.id == activeId);
        final int target;
        if (current == -1) {
          target = 0;
        } else if (command == AppCommand.nextNote) {
          target = current + 1 < list.length ? current + 1 : current;
        } else {
          target = current > 0 ? current - 1 : 0;
        }
        notes.selectNote(list[target].id);
        return true;

      case AppCommand.findInNote:
        if (activeNote == null) return false;
        if (ref.read(noteSearchProvider).isActive) {
          ref.read(noteSearchFocusRequestProvider.notifier).request();
        } else {
          ref.read(noteSearchProvider.notifier).open();
        }
        return true;

      case AppCommand.searchNotes:
        ref.read(globalSearchFocusRequestProvider.notifier).request();
        return true;

      case AppCommand.toggleMode:
        final editor = ref.read(editorProvider.notifier);
        final mode = ref.read(editorProvider).mode;
        editor.setMode(
          mode == EditorMode.edit ? EditorMode.readOnly : EditorMode.edit,
        );
        return true;

      case AppCommand.focusMode:
        ref.read(editorProvider.notifier).toggleFocusMode();
        return true;

      case AppCommand.escape:
        // Esc "a cascata": prima esce dal focus mode, poi chiude la ricerca
        // nella nota. Se non c'è nulla da chiudere lascia passare il tasto.
        if (ref.read(editorProvider).isFocusMode) {
          ref.read(editorProvider.notifier).exitFocusMode();
          return true;
        }
        if (ref.read(noteSearchProvider).isActive) {
          ref.read(noteSearchProvider.notifier).close();
          return true;
        }
        return false;

      case AppCommand.settings:
        SettingsView.show(context);
        return true;

      case AppCommand.help:
        unawaited(ShortcutsHelpDialog.show(context));
        return true;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
