import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'platform_utils.dart';

/// Comandi da tastiera dell'app (desktop). Unica fonte di verità: la stessa
/// definizione alimenta il dispatcher globale, le etichette nei menu
/// contestuali e la finestra "Scorciatoie da tastiera".
enum AppCommand {
  // Note e cartelle
  newNote,
  newFolder,
  save,
  pinNote,
  moveNote,
  duplicateNote,
  exportNote,
  deleteNote,
  // Navigazione e ricerca
  nextNote,
  previousNote,
  findInNote,
  searchNotes,
  toggleMode,
  focusMode,
  escape,
  // Applicazione
  settings,
  help,
}

/// Comandi che agiscono solo nel campo di testo dell'editor (gestiti da
/// `CallbackShortcuts` nel pannello editor, non dal dispatcher globale).
enum EditorCommand { bold, italic, link, heading1, heading2, heading3 }

SingleActivator _primary(
  LogicalKeyboardKey key, {
  bool shift = false,
  bool alt = false,
}) {
  final mac = isMacPlatform;
  return SingleActivator(
    key,
    control: !mac,
    meta: mac,
    shift: shift,
    alt: alt,
  );
}

/// Attivatori di [command]; il primo è quello mostrato nelle etichette.
List<SingleActivator> activatorsFor(AppCommand command) {
  switch (command) {
    case AppCommand.newNote:
      return [_primary(LogicalKeyboardKey.keyN)];
    case AppCommand.newFolder:
      return [_primary(LogicalKeyboardKey.keyN, shift: true)];
    case AppCommand.save:
      return [_primary(LogicalKeyboardKey.keyS)];
    case AppCommand.pinNote:
      return [_primary(LogicalKeyboardKey.keyP, shift: true)];
    case AppCommand.moveNote:
      return [_primary(LogicalKeyboardKey.keyM, shift: true)];
    case AppCommand.duplicateNote:
      return [_primary(LogicalKeyboardKey.keyD, shift: true)];
    case AppCommand.exportNote:
      return [_primary(LogicalKeyboardKey.keyE, shift: true)];
    case AppCommand.deleteNote:
      // Su Mac il tasto "elimina" è Backspace; si accettano entrambi.
      return [
        _primary(LogicalKeyboardKey.delete, shift: true),
        _primary(LogicalKeyboardKey.backspace, shift: true),
      ];
    case AppCommand.nextNote:
      return [_primary(LogicalKeyboardKey.pageDown)];
    case AppCommand.previousNote:
      return [_primary(LogicalKeyboardKey.pageUp)];
    case AppCommand.findInNote:
      return [_primary(LogicalKeyboardKey.keyF)];
    case AppCommand.searchNotes:
      return [_primary(LogicalKeyboardKey.keyF, shift: true)];
    case AppCommand.toggleMode:
      return [_primary(LogicalKeyboardKey.keyE)];
    case AppCommand.focusMode:
      return [_primary(LogicalKeyboardKey.enter, shift: true)];
    case AppCommand.escape:
      return const [SingleActivator(LogicalKeyboardKey.escape)];
    case AppCommand.settings:
      return [_primary(LogicalKeyboardKey.comma)];
    case AppCommand.help:
      return const [SingleActivator(LogicalKeyboardKey.f1)];
  }
}

SingleActivator editorActivatorFor(EditorCommand command) {
  switch (command) {
    case EditorCommand.bold:
      return _primary(LogicalKeyboardKey.keyB);
    case EditorCommand.italic:
      return _primary(LogicalKeyboardKey.keyI);
    case EditorCommand.link:
      return _primary(LogicalKeyboardKey.keyK);
    case EditorCommand.heading1:
      return _primary(LogicalKeyboardKey.digit1);
    case EditorCommand.heading2:
      return _primary(LogicalKeyboardKey.digit2);
    case EditorCommand.heading3:
      return _primary(LogicalKeyboardKey.digit3);
  }
}

/// Restituisce il comando associato a [event], oppure `null`.
AppCommand? matchAppCommand(KeyEvent event, HardwareKeyboard keyboard) {
  if (event is! KeyDownEvent) return null;
  for (final command in AppCommand.values) {
    for (final activator in activatorsFor(command)) {
      if (activator.accepts(event, keyboard)) return command;
    }
  }
  return null;
}

/// Etichetta leggibile: "Ctrl+Shift+N" (Windows/Linux) o "⌘⇧N" (macOS).
String shortcutLabel(SingleActivator a) {
  final mac = isMacPlatform;
  final key = _keyName(a.trigger);
  if (mac) {
    return '${a.control ? '⌃' : ''}${a.alt ? '⌥' : ''}'
        '${a.shift ? '⇧' : ''}${a.meta ? '⌘' : ''}$key';
  }
  return [
    if (a.control) 'Ctrl',
    if (a.alt) 'Alt',
    if (a.shift) 'Shift',
    if (a.meta) 'Meta',
    key,
  ].join('+');
}

String commandShortcutLabel(AppCommand command) =>
    shortcutLabel(activatorsFor(command).first);

String editorShortcutLabel(EditorCommand command) =>
    shortcutLabel(editorActivatorFor(command));

String _keyName(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.delete) return isMacPlatform ? '⌫' : 'Del';
  if (key == LogicalKeyboardKey.backspace) return '⌫';
  if (key == LogicalKeyboardKey.pageDown) return 'PgDn';
  if (key == LogicalKeyboardKey.pageUp) return 'PgUp';
  if (key == LogicalKeyboardKey.enter) return isMacPlatform ? '↩' : 'Enter';
  if (key == LogicalKeyboardKey.escape) return 'Esc';
  if (key == LogicalKeyboardKey.comma) return ',';
  final label = key.keyLabel;
  return label.isEmpty ? key.debugName ?? '?' : label.toUpperCase();
}
