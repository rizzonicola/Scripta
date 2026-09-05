import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/services/export_service.dart';
import '../../../core/theme/color_schemes.dart';
import '../../../core/utils/markdown_toolbar_actions.dart';
import '../../notes/providers/notes_provider.dart';

class MarkdownToolbar extends ConsumerWidget {
  final TextEditingController contentController;
  final UndoHistoryController? undoController;

  const MarkdownToolbar({
    super.key,
    required this.contentController,
    this.undoController,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: theme.surfaceElevated,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.3),
            width: 1,
          ),
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 4,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            // Undo
            _ToolbarButton(
              icon: Icons.undo_rounded,
              tooltip: l10n.undo,
              onPressed: () {
                undoController?.undo();
              },
            ),

            // Redo
            _ToolbarButton(
              icon: Icons.redo_rounded,
              tooltip: l10n.redo,
              onPressed: () {
                undoController?.redo();
              },
            ),

            _divider(theme),

            // Bold
            _ToolbarButton(
              icon: Icons.format_bold_rounded,
              tooltip: l10n.bold,
              onPressed: () {
                MarkdownToolbarActions.wrapSelection(
                  contentController,
                  '**',
                  '**',
                  defaultText: 'bold text',
                );
              },
            ),

            // Italic
            _ToolbarButton(
              icon: Icons.format_italic_rounded,
              tooltip: l10n.italic,
              onPressed: () {
                MarkdownToolbarActions.wrapSelection(
                  contentController,
                  '*',
                  '*',
                  defaultText: 'italic text',
                );
              },
            ),

            _divider(theme),

            // Headings
            _ToolbarButton(
              label: 'H1',
              tooltip: l10n.heading1,
              onPressed: () {
                MarkdownToolbarActions.prependLine(contentController, '# ');
              },
            ),
            _ToolbarButton(
              label: 'H2',
              tooltip: l10n.heading2,
              onPressed: () {
                MarkdownToolbarActions.prependLine(contentController, '## ');
              },
            ),
            _ToolbarButton(
              label: 'H3',
              tooltip: l10n.heading3,
              onPressed: () {
                MarkdownToolbarActions.prependLine(contentController, '### ');
              },
            ),

            _divider(theme),

            // Bullet list
            _ToolbarButton(
              icon: Icons.format_list_bulleted_rounded,
              tooltip: l10n.bulletList,
              onPressed: () {
                MarkdownToolbarActions.prependLine(contentController, '- ');
              },
            ),

            // Numbered list
            _ToolbarButton(
              icon: Icons.format_list_numbered_rounded,
              tooltip: l10n.numberedList,
              onPressed: () {
                MarkdownToolbarActions.prependLine(contentController, '1. ');
              },
            ),

            // Task list / Checkbox
            _ToolbarButton(
              icon: Icons.check_box_outlined,
              tooltip: l10n.taskList,
              onPressed: () {
                MarkdownToolbarActions.prependLine(
                    contentController, '- [ ] ');
              },
            ),

            _divider(theme),

            // Code Block
            _ToolbarButton(
              icon: Icons.code_rounded,
              tooltip: l10n.codeBlock,
              onPressed: () {
                MarkdownToolbarActions.insertCodeBlock(contentController);
              },
            ),

            // Link
            _ToolbarButton(
              icon: Icons.link_rounded,
              tooltip: l10n.link,
              onPressed: () {
                MarkdownToolbarActions.insertLink(contentController);
              },
            ),

            // Table
            _ToolbarButton(
              icon: Icons.table_chart_outlined,
              tooltip: l10n.table,
              onPressed: () {
                MarkdownToolbarActions.insertTable(contentController);
              },
            ),

            _divider(theme),

            // Export Note as Markdown
            _ToolbarButton(
              icon: Icons.file_download_outlined,
              tooltip: 'Esporta nota (.md)',
              onPressed: () {
                final activeNote = ref.read(activeNoteProvider);
                if (activeNote != null) {
                  ExportService.exportNoteAsMarkdown(context, activeNote);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _divider(ThemeData theme) {
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: theme.colorScheme.outline.withValues(alpha: 0.3),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData? icon;
  final String? label;
  final String tooltip;
  final VoidCallback onPressed;

  const _ToolbarButton({
    this.icon,
    this.label,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            child: icon != null
                ? Icon(
                    icon,
                    size: 18,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                  )
                : Text(
                    label ?? '',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
