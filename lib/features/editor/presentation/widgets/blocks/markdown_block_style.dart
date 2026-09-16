import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// Bundle immutabile di tutto ciò che serve ai renderer di blocco per
/// disegnarsi coerentemente con il tema/le impostazioni correnti
/// (font, dimensione, interlinea, tema chiaro/scuro, colore primario).
///
/// Viene costruito UNA VOLTA da `MarkdownRenderedView` (ri-costruito solo
/// quando tema o impostazioni cambiano davvero, vedi `_ensureStyles`) e
/// passato per riferimento a ogni `MarkdownBlockWidget`: questo è ciò che
/// permette ai singoli blocchi di usare `==` per decidere se rieseguire il
/// proprio lavoro di build, invece di ricalcolare stili ad ogni frame di
/// scroll.
@immutable
class MarkdownBlockStyle {
  final MarkdownStyleSheet styleSheet;
  final TextStyle inlineCodeStyle;
  final TextStyle titleTextStyle;
  final String fontFamily;
  final double fontSize;
  final bool isDark;
  final Color primaryColor;
  final Color onSurfaceColor;
  final Color outlineColor;

  const MarkdownBlockStyle({
    required this.styleSheet,
    required this.inlineCodeStyle,
    required this.titleTextStyle,
    required this.fontFamily,
    required this.fontSize,
    required this.isDark,
    required this.primaryColor,
    required this.onSurfaceColor,
    required this.outlineColor,
  });

  /// FASE 4 — colore di sfondo usato da [BlockSelectionHighlight] per i
  /// blocchi che ricadono per intero nella selezione logica corrente.
  /// Derivato (non memorizzato) da [primaryColor], così da non alterare
  /// `operator ==`/`hashCode` sopra: resta un colore "figlio" dello
  /// stesso tema, coerente con `DefaultSelectionStyle.selectionColor`
  /// usato da `MarkdownRenderedView` per l'evidenziazione nativa
  /// (stessa tinta, alpha più basso per non "raddoppiare" visivamente il
  /// colore nei rari blocchi in cui entrambi i meccanismi dipingono sulla
  /// stessa area, vedi note di test in fondo alla Fase 4).
  Color get blockSelectionHighlightColor => primaryColor.withValues(alpha: 0.16);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MarkdownBlockStyle &&
          other.styleSheet == styleSheet &&
          other.inlineCodeStyle == inlineCodeStyle &&
          other.titleTextStyle == titleTextStyle &&
          other.fontFamily == fontFamily &&
          other.fontSize == fontSize &&
          other.isDark == isDark &&
          other.primaryColor == primaryColor &&
          other.onSurfaceColor == onSurfaceColor &&
          other.outlineColor == outlineColor);

  @override
  int get hashCode => Object.hash(
        styleSheet,
        inlineCodeStyle,
        titleTextStyle,
        fontFamily,
        fontSize,
        isDark,
        primaryColor,
        onSurfaceColor,
        outlineColor,
      );
}
