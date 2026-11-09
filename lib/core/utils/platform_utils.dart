import 'dart:io' show Platform;

/// `true` su Linux, Windows e macOS (dove ci sono mouse e tastiera fisica).
bool get isDesktopPlatform =>
    Platform.isLinux || Platform.isWindows || Platform.isMacOS;

/// `true` solo su macOS: lì il modificatore "principale" delle scorciatoie
/// è Cmd (meta) invece di Ctrl.
bool get isMacPlatform => Platform.isMacOS;
