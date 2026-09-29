import 'package:flutter/material.dart';

import '../l10n/desktop_strings.dart';
import '../utils/app_commands.dart';

/// Finestra "Scorciatoie da tastiera" (F1).
class ShortcutsHelpDialog extends StatelessWidget {
  const ShortcutsHelpDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const ShortcutsHelpDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = DesktopStrings.of(context);
    final theme = Theme.of(context);

    List<(String, String)> rows(List<AppCommand> commands) => [
          for (final c in commands)
            (ds.command(c.name), commandShortcutLabel(c)),
        ];

    final groups = <(String, List<(String, String)>)>[
      (
        ds.groupNotes,
        rows(const [
          AppCommand.newNote,
          AppCommand.newFolder,
          AppCommand.save,
          AppCommand.pinNote,
          AppCommand.moveNote,
          AppCommand.duplicateNote,
          AppCommand.exportNote,
          AppCommand.deleteNote,
        ]),
      ),
      (
        ds.groupNavigation,
        rows(const [
          AppCommand.nextNote,
          AppCommand.previousNote,
          AppCommand.searchNotes,
          AppCommand.findInNote,
          AppCommand.toggleMode,
          AppCommand.focusMode,
          AppCommand.escape,
        ]),
      ),
      (
        ds.groupEditor,
        [
          for (final c in EditorCommand.values)
            (ds.command(c.name), editorShortcutLabel(c)),
        ],
      ),
      (
        ds.groupApp,
        rows(const [AppCommand.settings, AppCommand.help]),
      ),
    ];

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.keyboard_alt_outlined,
              size: 22, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(ds.keyboardShortcuts)),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (title, items) in groups) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: Text(
                    title,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                for (final (label, keys) in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(child: Text(label)),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            keys,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(ds.close),
        ),
      ],
    );
  }
}
