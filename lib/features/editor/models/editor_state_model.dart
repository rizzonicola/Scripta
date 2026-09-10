enum EditorMode {
  edit,
  readOnly,
}

class EditorStateModel {
  final EditorMode mode;
  final bool isFocusMode;
  final bool canUndo;
  final bool canRedo;

  const EditorStateModel({
    this.mode = EditorMode.edit,
    this.isFocusMode = false,
    this.canUndo = false,
    this.canRedo = false,
  });

  EditorStateModel copyWith({
    EditorMode? mode,
    bool? isFocusMode,
    bool? canUndo,
    bool? canRedo,
  }) {
    return EditorStateModel(
      mode: mode ?? this.mode,
      isFocusMode: isFocusMode ?? this.isFocusMode,
      canUndo: canUndo ?? this.canUndo,
      canRedo: canRedo ?? this.canRedo,
    );
  }

  // Uguaglianza per valore (vedi motivazione analoga in `SyncConfig`): tutti
  // i campi sono primitivi, quindi un confronto per valore completo è
  // economico ed evita rebuild dei widget che osservano l'intero provider
  // (es. `AdaptiveAppShell`, `TopAppBar`) quando nulla è realmente cambiato.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EditorStateModel &&
        other.mode == mode &&
        other.isFocusMode == isFocusMode &&
        other.canUndo == canUndo &&
        other.canRedo == canRedo;
  }

  @override
  int get hashCode => Object.hash(mode, isFocusMode, canUndo, canRedo);
}
