import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/editor_state_model.dart';

/// Stato UI locale dell'editor (modalità, focus mode, undo/redo).
///
/// Migrato dalla legacy `StateNotifier` API alla nuova `Notifier` API di
/// Riverpod 3: nessuna dipendenza asincrona/esterna nello stato iniziale,
/// quindi `build()` può restituire sincronamente lo stato di default,
/// esattamente come faceva il costruttore precedente.
class EditorNotifier extends Notifier<EditorStateModel> {
  @override
  EditorStateModel build() => const EditorStateModel();

  void setMode(EditorMode mode) {
    state = state.copyWith(mode: mode);
  }

  void toggleFocusMode() {
    // Preserves previous mode (edit or readOnly)
    state = state.copyWith(isFocusMode: !state.isFocusMode);
  }

  void exitFocusMode() {
    state = state.copyWith(isFocusMode: false);
  }

  void setUndoRedoState({required bool canUndo, required bool canRedo}) {
    state = state.copyWith(canUndo: canUndo, canRedo: canRedo);
  }
}

final editorProvider = NotifierProvider<EditorNotifier, EditorStateModel>(
  EditorNotifier.new,
);
