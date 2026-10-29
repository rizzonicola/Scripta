enum EditorMode { edit, readOnly }

class EditorStateModel {
  final EditorMode mode;
  final bool isFocusMode;

  const EditorStateModel({
    this.mode = EditorMode.edit,
    this.isFocusMode = false,
  });

  EditorStateModel copyWith({EditorMode? mode, bool? isFocusMode}) {
    return EditorStateModel(
      mode: mode ?? this.mode,
      isFocusMode: isFocusMode ?? this.isFocusMode,
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
        other.isFocusMode == isFocusMode;
  }

  @override
  int get hashCode => Object.hash(mode, isFocusMode);
}
