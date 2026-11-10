import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Colori derivati dallo schema del tema attivo, invece che da tinte fisse:
/// tutte le palette (chiare e scure) mantengono così il proprio carattere.
abstract final class ReadingColors {
  static bool _isDark(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark;

  /// Sfondo di citazioni, codice e tabelle: una velatura del testo sopra la
  /// superficie, abbastanza lieve da non competere col contenuto.
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

  /// Evidenziazione calda dell'occorrenza di ricerca attiva; distinta dal
  /// colore (freddo) della selezione manuale.
  static Color searchHighlight(ColorScheme scheme) {
    final base = _isDark(scheme)
        ? const Color(0xFFFB923C) // Orange 400
        : const Color(0xFFF59E0B); // Amber 500
    return base.withValues(alpha: _isDark(scheme) ? 0.50 : 0.45);
  }

  /// Contrasto WCAG tra due colori opachi (1..21).
  static double contrastRatio(Color foreground, Color background) {
    final lighter = math.max(
      foreground.computeLuminance(),
      background.computeLuminance(),
    );
    final darker = math.min(
      foreground.computeLuminance(),
      background.computeLuminance(),
    );
    return (lighter + 0.05) / (darker + 0.05);
  }
}
