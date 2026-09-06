import 'package:flutter/material.dart';

class AppSettings {
  final ThemeMode themeMode;
  final String selectedThemeId;
  final Locale? locale; // null = System default
  final String fontFamily;
  final double fontSize;
  final double lineHeight;

  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.selectedThemeId = 'dark_teal',
    this.locale,
    this.fontFamily = 'Inter',
    this.fontSize = 16.0,
    this.lineHeight = 1.6,
  });

  AppSettings copyWith({
    ThemeMode? themeMode,
    String? selectedThemeId,
    Locale? Function()? locale,
    String? fontFamily,
    double? fontSize,
    double? lineHeight,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      selectedThemeId: selectedThemeId ?? this.selectedThemeId,
      locale: locale != null ? locale() : this.locale,
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
    );
  }
}
