import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/editor_state_model.dart';

class EditorNotifier extends StateNotifier<EditorStateModel> {
  EditorNotifier() : super(const EditorStateModel());

  void toggleMode() {
    state = state.copyWith(
      mode: state.mode == EditorMode.edit
          ? EditorMode.readOnly
          : EditorMode.edit,
    );
  }

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

final editorProvider =
    StateNotifierProvider<EditorNotifier, EditorStateModel>((ref) {
  return EditorNotifier();
});
