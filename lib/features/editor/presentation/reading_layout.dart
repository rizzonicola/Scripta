import 'package:flutter/material.dart';

import 'note_layout.dart';

/// Metriche esclusive della vista di lettura. La geometria condivisa con
/// l'editor (larghezza della colonna, padding orizzontale, scala del titolo)
/// vive in [NoteLayout]: qui restano solo i margini verticali della lettura.
abstract final class ReadingLayout {
  static const EdgeInsets readingPadding = EdgeInsets.fromLTRB(
    NoteLayout.horizontalPadding,
    24,
    NoteLayout.horizontalPadding,
    64,
  );

  static const EdgeInsets blockBottomPadding = EdgeInsets.only(bottom: 16);

  /// Sotto questa larghezza i pulsanti flottanti (indice e torna-in-cima)
  /// coprirebbero la colonna di testo: vengono omessi.
  static const double overlayButtonsMinWidth = 700;
}
