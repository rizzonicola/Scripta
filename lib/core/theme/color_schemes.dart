import 'package:flutter/material.dart';

class AppThemePalette {
  final String id;
  final String name;
  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color surfaceElevated;
  final Color border;
  final Color primary;
  final Color primaryHover;
  final Color accent;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  const AppThemePalette({
    required this.id,
    required this.name,
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceElevated,
    required this.border,
    required this.primary,
    required this.primaryHover,
    required this.accent,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
  });
}

class AppThemePalettes {
  // 1. Scripta Dark Teal (Default Dark)
  static const darkTeal = AppThemePalette(
    id: 'dark_teal',
    name: 'Scripta Dark Teal',
    brightness: Brightness.dark,
    background: Color(0xFF16191D),
    surface: Color(0xFF20242A),
    surfaceElevated: Color(0xFF282D35),
    border: Color(0xFF323842),
    primary: Color(0xFF2DD4BF),      // Verde Acqua / Teal
    primaryHover: Color(0xFF5EEAD4),
    accent: Color(0xFF0D9488),
    textPrimary: Color(0xFFF1F5F9),
    textSecondary: Color(0xFF94A3B8),
    textMuted: Color(0xFF64748B),
  );

  // 2. OLED Pure Black
  static const oled = AppThemePalette(
    id: 'oled',
    name: 'OLED Pure Black',
    brightness: Brightness.dark,
    background: Color(0xFF000000),   // Pure Black
    surface: Color(0xFF0D0F12),
    surfaceElevated: Color(0xFF16181D),
    border: Color(0xFF252A32),
    primary: Color(0xFF2DD4BF),      // Neon Teal
    primaryHover: Color(0xFF5EEAD4),
    accent: Color(0xFF14B8A6),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFF9CA3AF),
    textMuted: Color(0xFF6B7280),
  );

  // 3. Nord Frost
  static const nord = AppThemePalette(
    id: 'nord',
    name: 'Nord Frost',
    brightness: Brightness.dark,
    background: Color(0xFF242933),
    surface: Color(0xFF2E3440),
    surfaceElevated: Color(0xFF3B4252),
    border: Color(0xFF434C5E),
    primary: Color(0xFF88C0D0),      // Frost Blue
    primaryHover: Color(0xFF81A1C1),
    accent: Color(0xFF8FBCBB),
    textPrimary: Color(0xFFECEFF4),
    textSecondary: Color(0xFFD8DEE9),
    textMuted: Color(0xFF4C566A),
  );

  // 4. Midnight Iris
  static const midnightPurple = AppThemePalette(
    id: 'midnight_purple',
    name: 'Midnight Iris',
    brightness: Brightness.dark,
    background: Color(0xFF13111C),
    surface: Color(0xFF1B1827),
    surfaceElevated: Color(0xFF242034),
    border: Color(0xFF352F4B),
    primary: Color(0xFFA78BFA),      // Iris Purple
    primaryHover: Color(0xFFC4B5FD),
    accent: Color(0xFF818CF8),
    textPrimary: Color(0xFFF5F3FF),
    textSecondary: Color(0xFFA79EC4),
    textMuted: Color(0xFF70678F),
  );

  // 5. Pine & Sage
  static const forest = AppThemePalette(
    id: 'forest',
    name: 'Pine & Sage',
    brightness: Brightness.dark,
    background: Color(0xFF121815),
    surface: Color(0xFF1A221E),
    surfaceElevated: Color(0xFF232D28),
    border: Color(0xFF2E3B34),
    primary: Color(0xFF34D399),      // Emerald Sage
    primaryHover: Color(0xFF6EE7B7),
    accent: Color(0xFF10B981),
    textPrimary: Color(0xFFECFDF5),
    textSecondary: Color(0xFF86A597),
    textMuted: Color(0xFF536D61),
  );

  // 6. Warm Espresso
  static const coffee = AppThemePalette(
    id: 'coffee',
    name: 'Warm Espresso',
    brightness: Brightness.dark,
    background: Color(0xFF181513),
    surface: Color(0xFF211C19),
    surfaceElevated: Color(0xFF2C2622),
    border: Color(0xFF3B342E),
    primary: Color(0xFFF59E0B),      // Amber
    primaryHover: Color(0xFFFBBF24),
    accent: Color(0xFFD97706),
    textPrimary: Color(0xFFFFFBEB),
    textSecondary: Color(0xFFA89F91),
    textMuted: Color(0xFF756C5F),
  );

  // 7. Scripta Clean Light (Default Light)
  static const cleanLight = AppThemePalette(
    id: 'clean_light',
    name: 'Scripta Light',
    brightness: Brightness.light,
    background: Color(0xFFF8FAFC),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFF1F5F9),
    border: Color(0xFFE2E8F0),
    primary: Color(0xFF0D9488),      // Deep Teal
    primaryHover: Color(0xFF0F766E),
    accent: Color(0xFF14B8A6),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF475569),
    textMuted: Color(0xFF94A3B8),
  );

  // 8. Warm Paper / Solarized
  static const solarizedLight = AppThemePalette(
    id: 'solarized_light',
    name: 'Warm Paper',
    brightness: Brightness.light,
    background: Color(0xFFFDF6E3),
    surface: Color(0xFFEEE8D5),
    surfaceElevated: Color(0xFFE4DEC9),
    border: Color(0xFFD3C7AE),
    primary: Color(0xFF2AA198),      // Solarized Teal
    primaryHover: Color(0xFF268BD2),
    accent: Color(0xFFB58900),
    textPrimary: Color(0xFF073642),
    textSecondary: Color(0xFF586E75),
    textMuted: Color(0xFF839496),
  );

  static const List<AppThemePalette> all = [
    darkTeal,
    oled,
    nord,
    midnightPurple,
    forest,
    coffee,
    cleanLight,
    solarizedLight,
  ];

  static AppThemePalette getById(String? id, {required Brightness fallbackBrightness}) {
    if (id != null) {
      for (final p in all) {
        if (p.id == id) return p;
      }
    }
    return fallbackBrightness == Brightness.dark ? darkTeal : cleanLight;
  }
}

extension ScriptaThemeExtension on ThemeData {
  Color get surfaceElevated {
    return colorScheme.surfaceContainerHighest;
  }
}
