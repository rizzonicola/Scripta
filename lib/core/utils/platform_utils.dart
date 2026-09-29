import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// `true` su Linux, Windows e macOS (dove ci sono mouse e tastiera fisica).
bool get isDesktopPlatform =>
    !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

/// `true` solo su macOS: lì il modificatore "principale" delle scorciatoie
/// è Cmd (meta) invece di Ctrl.
bool get isMacPlatform => !kIsWeb && Platform.isMacOS;
