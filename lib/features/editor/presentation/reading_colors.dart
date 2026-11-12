import 'package:flutter/material.dart';

import '../../../core/theme/search_highlight_colors.dart';

/// Colori derivati dallo schema del tema attivo, invece che da tinte fisse:
/// tutte le palette (chiare e scure) mantengono così il proprio carattere.
abstract final class ReadingColors {
  static bool _isDark(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark;

  /// Sfondo di citazioni, codice e tabelle: una velatura del testo sopra la
  /// superficie, abbastanza lieve da non competere con il contenuto.
  static Color surface(ColorScheme scheme) {
    return Color.alphaBlend(
      scheme.onSurface.withValues(alpha: _isDark(scheme) ? 0.06 : 0.04),
      scheme.surface,
    );
  }

  /// Sfondo del monospace (inline e a blocco): poco più marcato del surface.
  static Color monospaceBackground(ColorScheme scheme) {
    return Color.alphaBlend(
      scheme.onSurface.withValues(alpha: _isDark(scheme) ? 0.10 : 0.06),
      scheme.surface,
    );
  }

  /// Evidenziazione dell'occorrenza di ricerca attiva; la palette è condivisa
  /// con il controller dell'editor.
  static Color searchHighlight(ColorScheme scheme) =>
      SearchHighlightColors.active(scheme);
}
