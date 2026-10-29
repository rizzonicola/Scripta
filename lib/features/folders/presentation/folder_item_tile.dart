import 'package:flutter/material.dart';

import '../../../core/l10n/desktop_strings.dart';

/// Riga selezionabile della barra laterale ("Tutte le note", cartelle,
/// Impostazioni): icona, titolo, freccia di espansione e pulsante "...".
class FolderItemTile extends StatelessWidget {
  final String title;
  final IconData icon;
  final int depth;
  final bool isSelected;
  final bool hasChildren;
  final bool isExpanded;
  final VoidCallback onTap;
  final VoidCallback? onToggleExpand;

  /// Riceve la posizione globale (angolo in basso a sinistra del pulsante
  /// "...") a cui ancorare un menu a comparsa.
  final ValueChanged<Offset>? onMoreOptions;

  const FolderItemTile({
    super.key,
    required this.title,
    required this.icon,
    this.depth = 0,
    required this.isSelected,
    this.hasChildren = false,
    this.isExpanded = false,
    required this.onTap,
    this.onToggleExpand,
    this.onMoreOptions,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ds = DesktopStrings.of(context);

    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          focusColor: theme.colorScheme.primary.withValues(alpha: 0.12),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: EdgeInsets.only(left: (depth * 12.0) + 2.0, right: 2),
            child: Row(
              children: [
                if (hasChildren)
                  IconButton(
                    icon: Icon(
                      isExpanded
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.keyboard_arrow_right_rounded,
                      size: 18,
                    ),
                    tooltip: isExpanded ? ds.collapse : ds.expand,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 44,
                      height: 44,
                    ),
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    onPressed: onToggleExpand,
                  )
                else
                  const SizedBox(width: 44),
                Icon(
                  icon,
                  size: 18,
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                if (onMoreOptions != null)
                  Builder(
                    builder: (buttonContext) => IconButton(
                      icon: const Icon(Icons.more_horiz, size: 18),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).showMenuTooltip,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 44,
                        height: 44,
                      ),
                      onPressed: () {
                        final box =
                            buttonContext.findRenderObject() as RenderBox;
                        onMoreOptions!(
                          box.localToGlobal(Offset(0, box.size.height)),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
