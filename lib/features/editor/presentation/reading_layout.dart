import 'package:flutter/material.dart';

/// Geometria condivisa dalla vista di lettura e dal campo di modifica, così
/// le due modalità hanno la stessa colonna di testo (larghezza massima e
/// margini orizzontali). I margini verticali restano specifici: l'editor ha
/// più spazio sotto per la tastiera, la lettura chiude con il footer.
abstract final class ReadingLayout {
  static const double maxContentWidth = 840;
  static const double horizontalPadding = 28;

  static const EdgeInsets readingPadding = EdgeInsets.fromLTRB(
    horizontalPadding,
    24,
    horizontalPadding,
    64,
  );

  static const EdgeInsets blockBottomPadding = EdgeInsets.only(bottom: 16);

  /// Centra [child] nella colonna di lettura, mantenendo l'allineamento in
  /// alto (le formule e i blocchi non devono essere centrati verticalmente).
  static Widget centered(Widget child, {Key? key}) {
    return Align(
      key: key,
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxContentWidth),
        child: child,
      ),
    );
  }
}
