import 'package:flutter/material.dart';

/// Palette delle occorrenze della ricerca interna alla nota, derivata dallo
/// schema del tema attivo. Vive nel core perché la usano sia il controller
/// dell'editor sia la vista di lettura: prima erano due copie di tinte fisse.
abstract final class SearchHighlightColors {
  static bool _isDark(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark;

  /// Occorrenza attiva: ambra calda, distinta dalla selezione manuale.
  static Color active(ColorScheme scheme) {
    final base = _isDark(scheme)
        ? const Color(0xFFFB923C) // Orange 400
        : const Color(0xFFF59E0B); // Amber 500
    return base.withValues(alpha: _isDark(scheme) ? 0.50 : 0.45);
  }

  /// Occorrenze passive: stessa famiglia, meno intense.
  static Color passive(ColorScheme scheme) {
    return (scheme.brightness == Brightness.dark
            ? Colors.amber.shade700
            : Colors.amber.shade300)
        .withValues(alpha: 0.55);
  }

  /// Testo sopra l'occorrenza attiva, leggibile su entrambe le palette.
  static const Color activeForeground = Colors.black;
}
