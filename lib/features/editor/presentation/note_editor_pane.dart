import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../notes/providers/notes_provider.dart';
import '../models/editor_state_model.dart';
import '../models/search_highlighting_text_controller.dart';
import '../providers/editor_provider.dart';
import '../providers/note_search_provider.dart';
import 'focus_mode_exit_button.dart';
import 'markdown_editor_field.dart';
import 'markdown_rendered_view.dart';
import 'markdown_toolbar.dart';
import 'note_search_bar.dart';
import 'note_search_highlighted_view.dart';
import '../../sync/providers/sync_provider.dart';

class NoteEditorPane extends ConsumerStatefulWidget {
  const NoteEditorPane({super.key});

  @override
  ConsumerState<NoteEditorPane> createState() => _NoteEditorPaneState();
}

class _NoteEditorPaneState extends ConsumerState<NoteEditorPane> {
  late final TextEditingController _titleController;

  // Tipizzato sul sottotipo (non sulla classe base `TextEditingController`)
  // così da poter chiamare `.setMatches(...)` qui sotto senza cast: resta
  // comunque un `TextEditingController` a tutti gli effetti per
  // `MarkdownToolbar`/`MarkdownEditorField`/`UndoHistoryController`, che
  // continuano a riceverlo tipizzato sulla classe base (vedi doc di
  // [SearchHighlightingTextEditingController] per il razionale completo).
  late final SearchHighlightingTextEditingController _contentController;
  late final UndoHistoryController _undoController;

  String? _currentNoteId;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _contentController = SearchHighlightingTextEditingController();
    _undoController = UndoHistoryController();

    // Initial note load
    final activeNote = ref.read(activeNoteProvider);
    if (activeNote != null) {
      _currentNoteId = activeNote.id;
      _titleController.text = activeNote.title;
      _contentController.text = activeNote.content;
    }

    // Seed iniziale dell'evidenziazione: `ref.listen` in `build()` (vedi
    // sotto) propaga solo i CAMBIAMENTI successivi alla sua registrazione,
    // non lo stato già presente al momento del mount. Se questo pannello
    // viene montato per la prima volta con una ricerca già attiva (es.
    // navigazione da un risultato della ricerca globale, che imposta
    // `noteSearchProvider` PRIMA che questo widget venga inserito
    // nell'albero — vedi `notes_list_view.dart`), senza questo seed
    // esplicito l'evidenziazione comparirebbe solo al successivo cambio di
    // occorrenza attiva, non subito all'apertura.
    final initialHighlight = ref.read(noteSearchHighlightDataProvider);
    _contentController.setMatches(initialHighlight.$1, initialHighlight.$2);
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

    // Propaga occorrenze + indice attivo della ricerca interna al
    // controller custom del campo di contenuto (vedi
    // `SearchHighlightingTextEditingController`), che se ne occupa per
    // disegnare l'evidenziazione. Fatto tramite `ref.listen` (non
    // `ref.watch` + chiamata diretta durante `build`): `setMatches`
    // notifica i propri listener (il `TextField` sottostante), e farlo
    // sincronamente DURANTE il build di questo widget rischierebbe un
    // "setState durante il build" in quel campo — `ref.listen` esegue
    // invece il callback subito DOPO che il build corrente è completato.
    ref.listen<NoteSearchHighlightData>(noteSearchHighlightDataProvider, (previous, next) {
      _contentController.setMatches(next.$1, next.$2);
    });

    final activeNoteId = ref.watch(notesProvider.select((s) => s.activeNoteId));
    final editorMode = ref.watch(editorProvider.select((s) => s.mode));
    final isFocusMode = ref.watch(editorProvider.select((s) => s.isFocusMode));
    final isNoteSearchActive = ref.watch(noteSearchProvider.select((s) => s.isActive));
    final activeSearchMatch = ref.watch(activeNoteSearchMatchProvider);

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

    // Condivisa tra il campo di editing e la toolbar: entrambi i percorsi
    // devono salvare esattamente allo stesso modo (vedi doc di
    // `MarkdownToolbar.onContentChanged` per il perché è indispensabile
    // anche per i pulsanti della toolbar, non solo per la digitazione).
    void handleContentChanged(String val) {
      ref.read(notesProvider.notifier).updateNote(
            activeNoteId,
            content: val,
          );
      ref.read(syncProvider.notifier).notifyEditorActivity();
    }

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Barra di ricerca interna alla nota (vedi note_search_bar.dart):
            // funziona identicamente sopra a entrambe le modalità sotto,
            // quindi vive qui, fuori dall'AnimatedSwitcher Modifica/Lettura.
            if (isNoteSearchActive) const NoteSearchBar(),

            // Toolbar (visible only in Edit Mode when NOT in Focus Mode)
            if (editorMode == EditorMode.edit && !isFocusMode) ...[
              MarkdownToolbar(
                contentController: _contentController,
                undoController: _undoController,
                onContentChanged: handleContentChanged,
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
                          activeSearchMatch: activeSearchMatch,
                          onTitleChanged: (val) {
                            ref.read(notesProvider.notifier).updateNote(
                                  activeNoteId,
                                  title: val,
                                );
                            ref
                                .read(syncProvider.notifier)
                                .notifyEditorActivity();
                          },
                          onContentChanged: handleContentChanged,
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
    // `.select` su (titolo, contenuto) invece dell'intero `NoteModel`:
    // `activeNoteProvider` restituisce una nuova istanza di `NoteModel` ad
    // OGNI aggiornamento della nota attiva (`NoteModel` non ha `==` per
    // valore, vedi note_model.dart), incluse modifiche a campi che questo
    // widget non usa affatto per il rendering (pin, cartella, ordine...).
    // Un record `(String, String)` ha invece uguaglianza strutturale nativa
    // in Dart: questa vista si ricostruisce quindi solo quando titolo o
    // contenuto della nota attiva cambiano davvero, non per ogni tocco del
    // modello — a valle, `MarkdownRenderedView`/`NoteSearchHighlightedView`
    // restano comunque gli unici responsabili di riparsing/caching pesanti.
    final activeNoteTitleContent = ref.watch(
      activeNoteProvider.select((n) => n == null ? null : (n.title, n.content)),
    );
    if (activeNoteTitleContent == null) return const SizedBox.shrink();
    final (title, content) = activeNoteTitleContent;

    // Mentre la ricerca interna è attiva con un termine non vuoto, si mostra
    // la vista dedicata con le occorrenze evidenziate (vedi doc di classe di
    // `NoteSearchHighlightedView` per il perché non viene invece iniettata
    // l'evidenziazione dentro `MarkdownRenderedView`). Non appena il
    // pannello si chiude, o il termine viene svuotato, si torna
    // trasparentemente al rendering Markdown formattato di sempre.
    final isSearching = ref.watch(
      noteSearchProvider.select((s) => s.isActive && s.query.trim().isNotEmpty),
    );
    if (isSearching) {
      return NoteSearchHighlightedView(
        title: title,
        content: content,
      );
    }

    return MarkdownRenderedView(
      title: title,
      content: content,
    );
  }
}
