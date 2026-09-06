import 'dart:io';
import 'package:flutter/services.dart';
import '../theme/color_schemes.dart';

class WindowDecorationService {
  static const MethodChannel _channel = MethodChannel('io.github.scripta/window');

  static String _colorToHex(Color color) {
    final int argb = color.toARGB32();
    final r = ((argb >> 16) & 0xFF).toRadixString(16).padLeft(2, '0');
    final g = ((argb >> 8) & 0xFF).toRadixString(16).padLeft(2, '0');
    final b = (argb & 0xFF).toRadixString(16).padLeft(2, '0');
    return '#$r$g$b';
  }

  static Future<void> updateTitleBarTheme(AppThemePalette palette, Brightness effectiveBrightness) async {
    if (!Platform.isLinux) return;

    final isDark = effectiveBrightness == Brightness.dark;
    final bgHex = _colorToHex(palette.surface);
    final textHex = _colorToHex(palette.textPrimary);
    final borderHex = _colorToHex(palette.border);

    try {
      await _channel.invokeMethod('updateTitleBarTheme', {
        'backgroundColor': bgHex,
        'textColor': textHex,
        'borderColor': borderHex,
        'isDark': isDark,
      });
    } catch (_) {
      // Gracefully ignore if method channel is unavailable
    }
  }
}
