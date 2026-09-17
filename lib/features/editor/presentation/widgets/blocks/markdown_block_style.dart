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
