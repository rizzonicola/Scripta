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
}
