import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'color_schemes.dart';

class AppTheme {
  static TextStyle getTextStyleForFont(
    String fontFamily, {
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
  }) {
    switch (fontFamily.toLowerCase()) {
      case 'jetbrains mono':
        return GoogleFonts.jetBrainsMono(
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color,
          height: height,
        );
      case 'merriweather':
        return GoogleFonts.merriweather(
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color,
          height: height,
        );
      case 'fira code':
        return GoogleFonts.firaCode(
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color,
          height: height,
        );
      case 'roboto':
        return GoogleFonts.roboto(
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color,
          height: height,
        );
      case 'inter':
      default:
        return GoogleFonts.inter(
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color,
          height: height,
        );
    }
  }

  static ThemeData fromPalette(
    AppThemePalette palette, {
    String fontFamily = 'Inter',
  }) {
    final baseTheme = palette.brightness == Brightness.dark
        ? ThemeData.dark()
        : ThemeData.light();
    final textTheme = GoogleFonts.interTextTheme(baseTheme.textTheme);

    return ThemeData(
      useMaterial3: true,
      brightness: palette.brightness,
      scaffoldBackgroundColor: palette.background,
      colorScheme: ColorScheme(
        brightness: palette.brightness,
        primary: palette.primary,
        onPrimary: palette.brightness == Brightness.dark
            ? const Color(0xFF0F172A)
            : Colors.white,
        secondary: palette.accent,
        onSecondary: Colors.white,
        error: const Color(0xFFEF4444),
        onError: Colors.white,
        surface: palette.surface,
        onSurface: palette.textPrimary,
        surfaceContainerHighest: palette.surfaceElevated,
        outline: palette.border,
        outlineVariant: palette.border.withValues(alpha: 0.6),
      ),
      textTheme: textTheme,
      cardTheme: CardThemeData(
        color: palette.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: palette.border, width: 1),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: palette.border,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: palette.surface,
        foregroundColor: palette.textPrimary,
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        shape: Border(
          bottom: BorderSide(color: palette.border, width: 1),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surfaceElevated,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: palette.border, width: 1),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: palette.surfaceElevated,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: palette.border),
        ),
        textStyle: TextStyle(
          color: palette.textPrimary,
          fontSize: 12,
        ),
      ),
    );
  }

  static ThemeData lightTheme({
    String? themeId,
    String fontFamily = 'Inter',
  }) {
    final palette = AppThemePalettes.getById(
      themeId,
      fallbackBrightness: Brightness.light,
    );
    return fromPalette(palette, fontFamily: fontFamily);
  }

  static ThemeData darkTheme({
    String? themeId,
    String fontFamily = 'Inter',
  }) {
    final palette = AppThemePalettes.getById(
      themeId,
      fallbackBrightness: Brightness.dark,
    );
    return fromPalette(palette, fontFamily: fontFamily);
  }
}
