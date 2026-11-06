/// Modalità dell'editor condivisa da sessione e shell. Vive in `core` perché
/// la persistenza della sessione (anch'essa in `core`) non deve importare un
/// modello di una feature.
enum EditorMode { edit, readOnly }
