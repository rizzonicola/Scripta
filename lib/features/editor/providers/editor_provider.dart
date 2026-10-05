import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/services/session_state_service.dart';
import '../models/editor_state_model.dart';

/// Stato UI locale dell'editor (modalità, focus mode, undo/redo).
///
/// Migrato dalla legacy `StateNotifier` API alla nuova `Notifier` API di
/// Riverpod 3: lo stato iniziale è sincrono (nessun caricamento asincrono),
/// quindi `build()` lo restituisce subito.
///
/// La modalità (Modifica / Sola lettura) è l'unico campo che sopravvive alla
/// chiusura dell'app: parte da quella dell'ultima sessione, letta prima del
/// primo frame (vedi [sessionSnapshotProvider]), e viene risalvata a ogni
/// cambio da `sessionPersistenceProvider` (shell/session_persistence.dart).
/// Focus mode e undo/redo restano volutamente effimeri: ripartire a schermo
/// intero senza barre sarebbe disorientante.
class EditorNotifier extends Notifier<EditorStateModel> {
  @override
  EditorStateModel build() {
    // `read` e non `watch`: l'istantanea è una costante fissata all'avvio,
    // non deve mai far ricostruire (e quindi azzerare) lo stato dell'editor.
    final session = ref.read(sessionSnapshotProvider);
    return EditorStateModel(mode: session.editorMode);
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

final editorProvider = NotifierProvider<EditorNotifier, EditorStateModel>(
  EditorNotifier.new,
);
