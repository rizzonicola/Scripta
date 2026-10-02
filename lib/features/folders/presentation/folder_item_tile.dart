import 'package:flutter/material.dart';

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

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.only(
          left: (depth * 14.0) + 6.0,
          right: 4,
          top: 6,
          bottom: 6,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            if (hasChildren)
              GestureDetector(
                onTap: onToggleExpand,
                child: Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_right_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              )
            else
              const SizedBox(width: 18),
            const SizedBox(width: 4),
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
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
              ),
            ),
            if (onMoreOptions != null)
              Builder(
                builder: (buttonContext) => IconButton(
                  icon: const Icon(Icons.more_horiz, size: 16),
                  visualDensity: VisualDensity.compact,
                  splashRadius: 16,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    final box = buttonContext.findRenderObject() as RenderBox;
                    onMoreOptions!(
                      box.localToGlobal(Offset(0, box.size.height)),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
