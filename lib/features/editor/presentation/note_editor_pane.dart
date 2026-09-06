import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../notes/providers/notes_provider.dart';
import '../models/editor_state_model.dart';
import '../providers/editor_provider.dart';
import 'focus_mode_exit_button.dart';
import 'markdown_editor_field.dart';
import 'markdown_rendered_view.dart';
import 'markdown_toolbar.dart';
import '../../sync/providers/sync_provider.dart';

class NoteEditorPane extends ConsumerStatefulWidget {
  const NoteEditorPane({super.key});

  @override
  ConsumerState<NoteEditorPane> createState() => _NoteEditorPaneState();
}

class _NoteEditorPaneState extends ConsumerState<NoteEditorPane> {
  late final TextEditingController _titleController;
  late final TextEditingController _contentController;
  late final UndoHistoryController _undoController;

  String? _currentNoteId;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _contentController = TextEditingController();
    _undoController = UndoHistoryController();

    // Initial note load
    final activeNote = ref.read(activeNoteProvider);
    if (activeNote != null) {
      _currentNoteId = activeNote.id;
      _titleController.text = activeNote.title;
      _contentController.text = activeNote.content;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _undoController.dispose();
    super.dispose();
  }

  void _onActiveNoteIdChanged(String? prevId, String? nextId) {
    if (nextId == _currentNoteId) return;

    if (_currentNoteId != null) {
      // flushPendingSaves() ora è awaitato esplicitamente: non è più
      // strettamente necessario per la correttezza della sync (che dal suo
      // canto attende già il proprio flush interno in
      // SyncNotifier.triggerSync), ma resta corretto attendere qui la
      // scrittura su disco prima di considerare la nota "chiusa".
      unawaited(ref.read(notesProvider.notifier).flushPendingSaves());
      ref.read(syncProvider.notifier).onNoteChangedOrClosed();
    }

    _currentNoteId = nextId;
    if (nextId == null) {
      _titleController.text = '';
      _contentController.text = '';
    } else {
      final activeNote = ref.read(activeNoteProvider);
      if (activeNote != null) {
        _titleController.text = activeNote.title;
        _contentController.text = activeNote.content;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Listen to note switching without causing builds on note content changes
    ref.listen<String?>(
      notesProvider.select((s) => s.activeNoteId),
      _onActiveNoteIdChanged,
    );

    final activeNoteId = ref.watch(notesProvider.select((s) => s.activeNoteId));
    final editorMode = ref.watch(editorProvider.select((s) => s.mode));
    final isFocusMode = ref.watch(editorProvider.select((s) => s.isFocusMode));

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    if (activeNoteId == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.draw_outlined,
              size: 56,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.noNotes,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () {
                ref.read(notesProvider.notifier).createNote();
              },
              child: Text(l10n.newNote),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Toolbar (visible only in Edit Mode when NOT in Focus Mode)
            if (editorMode == EditorMode.edit && !isFocusMode) ...[
              MarkdownToolbar(
                contentController: _contentController,
                undoController: _undoController,
              ),
            ],

            // Content Area: Either Rendered View (Read-Only) or Editable Text Field (Edit)
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: editorMode == EditorMode.readOnly
                    ? const KeyedSubtree(
                        key: ValueKey('readOnlyMode'),
                        child: _ReadOnlyNoteView(),
                      )
                    : KeyedSubtree(
                        key: const ValueKey('editMode'),
                        child: MarkdownEditorField(
                          titleController: _titleController,
                          contentController: _contentController,
                          undoController: _undoController,
                          onTitleChanged: (val) {
                            ref.read(notesProvider.notifier).updateNote(
                                  activeNoteId,
                                  title: val,
                                );
                            ref
                                .read(syncProvider.notifier)
                                .notifyEditorActivity();
                          },
                          onContentChanged: (val) {
                            ref.read(notesProvider.notifier).updateNote(
                                  activeNoteId,
                                  content: val,
                                );
                            ref
                                .read(syncProvider.notifier)
                                .notifyEditorActivity();
                          },
                        ),
                      ),
              ),
            ),
          ],
        ),

        // Discrete Floating Exit Button when in Focus Mode
        if (isFocusMode)
          const Positioned(
            top: 24,
            right: 24,
            child: FocusModeExitButton(),
          ),
      ],
    );
  }
}

class _ReadOnlyNoteView extends ConsumerWidget {
  const _ReadOnlyNoteView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeNote = ref.watch(activeNoteProvider);
    if (activeNote == null) return const SizedBox.shrink();
    return MarkdownRenderedView(
      title: activeNote.title,
      content: activeNote.content,
    );
  }
}
