import 'package:flutter/material.dart';
import '../../../core/utils/haptics_helper.dart';

class AppSettings {
  final ThemeMode themeMode;
  final String selectedThemeId;
  final Locale? locale; // null = System default
  final String fontFamily;
  final double fontSize;
  final double lineHeight;
  final HapticIntensity hapticIntensity;

  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.selectedThemeId = 'dark_teal',
    this.locale,
    this.fontFamily = 'Inter',
    this.fontSize = 16.0,
    this.lineHeight = 1.6,
    this.hapticIntensity = HapticIntensity.light,
  });

  AppSettings copyWith({
    ThemeMode? themeMode,
    String? selectedThemeId,
    Locale? Function()? locale,
    String? fontFamily,
    double? fontSize,
    double? lineHeight,
    HapticIntensity? hapticIntensity,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      selectedThemeId: selectedThemeId ?? this.selectedThemeId,
      locale: locale != null ? locale() : this.locale,
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      hapticIntensity: hapticIntensity ?? this.hapticIntensity,
    );
  }

  // Uguaglianza per valore (vedi motivazione analoga in `SyncConfig`).
  // `Locale` implementa già `==`/`hashCode` per valore nel SDK Flutter.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppSettings &&
        other.themeMode == themeMode &&
        other.selectedThemeId == selectedThemeId &&
        other.locale == locale &&
        other.fontFamily == fontFamily &&
        other.fontSize == fontSize &&
        other.lineHeight == lineHeight &&
        other.hapticIntensity == hapticIntensity;
  }

  @override
  int get hashCode => Object.hash(
        themeMode,
        selectedThemeId,
        locale,
        fontFamily,
        fontSize,
        lineHeight,
        hapticIntensity,
      );
}
