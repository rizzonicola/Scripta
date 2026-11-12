import 'package:flutter/material.dart';

/// Geometria e tipografia condivise dalle due modalità della nota (lettura
/// formattata e modifica), così la colonna di testo e il titolo restano
/// coerenti quando si passa dall'una all'altra.
abstract final class NoteLayout {
  static const double maxContentWidth = 840;
  static const double horizontalPadding = 28;

  /// Scala del titolo rispetto al corpo, identica nelle due modalità.
  static const double titleScale = 2.2;

  /// Centra [child] nella colonna della nota, mantenendo l'allineamento in
  /// alto (formule e blocchi non devono essere centrati verticalmente).
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
