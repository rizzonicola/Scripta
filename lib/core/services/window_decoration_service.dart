import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../theme/color_schemes.dart';

class WindowDecorationService {
  static const MethodChannel _channel = MethodChannel('io.github.scripta/window');

  // Stato del fullscreen tenuto lato Dart: è il canale stesso a fare da
  // sorgente di verità (il nativo non espone un metodo "getFullScreen"),
  // quindi il toggle si basa su questa variabile invece di interrogare il
  // sistema operativo ad ogni pressione di F11.
  static bool _isFullScreen = false;

  // Handler registrato una sola volta su HardwareKeyboard: usiamo questo
  // livello (invece di Shortcuts/Focus legati a un widget) perché F11 deve
  // funzionare indipendentemente da dove si trova il focus della tastiera
  // in quel momento (editor, sidebar, dialog...).
  static bool _listenerRegistered = false;

  static String _colorToHex(Color color) {
    final int argb = color.toARGB32();
    final r = ((argb >> 16) & 0xFF).toRadixString(16).padLeft(2, '0');
    final g = ((argb >> 8) & 0xFF).toRadixString(16).padLeft(2, '0');
    final b = (argb & 0xFF).toRadixString(16).padLeft(2, '0');
    return '#$r$g$b';
  }

  static Future<void> updateTitleBarTheme(AppThemePalette palette, Brightness effectiveBrightness) async {
    // La colorazione nativa della title bar è implementata sia su Linux
    // (GTK headerbar) sia su Windows (DWM caption color). Sulle altre
    // piattaforme il canale nativo non esiste: usciamo subito per evitare
    // una chiamata a vuoto ad ogni build di ScriptaApp.
    if (!Platform.isLinux && !Platform.isWindows) return;

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

  /// Registra il listener globale del tasto F11 per il fullscreen "di
  /// sistema". Va chiamato una sola volta all'avvio (vedi main.dart), prima
  /// di runApp, così funziona anche prima che qualsiasi widget abbia il
  /// focus.
  ///
  /// Su Linux il window manager spesso intercetta già F11 a livello di
  /// sistema operativo (Flutter non riceve nemmeno l'evento), ma non è
  /// garantito: con WM a tiling o desktop minimali F11 potrebbe non essere
  /// bindato affatto. Gestirlo qui esplicitamente copre anche quei casi
  /// senza fare danni dove il WM lo gestisce già a monte.
  static void initializeFullScreenShortcut() {
    if (_listenerRegistered) return;
    if (!Platform.isLinux && !Platform.isWindows) return;

    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    _listenerRegistered = true;
  }

  static bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.f11) {
      return false;
    }

    unawaited(_toggleFullScreen());
    return true;
  }

  static Future<void> _toggleFullScreen() async {
    final bool nextValue = !_isFullScreen;

    try {
      await _channel.invokeMethod('setFullScreen', {'fullscreen': nextValue});
      // Aggiorniamo lo stato solo dopo che il nativo ha confermato, così se
      // la chiamata fallisce (piattaforma non supportata, eccezione) il
      // prossimo F11 riprova con lo stesso stato invece di disallinearsi.
      _isFullScreen = nextValue;
    } catch (_) {
      // Gracefully ignore if method channel is unavailable
    }
  }
}
