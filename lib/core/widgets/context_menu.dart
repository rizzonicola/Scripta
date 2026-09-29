import 'package:flutter/material.dart';

/// Voce di un menu contestuale (tasto destro / pulsante "...").
class ContextMenuEntry {
  final String label;
  final IconData? icon;
  final VoidCallback? onSelected;

  /// Testo della scorciatoia mostrato a destra (es. "Ctrl+N").
  final String? shortcut;
  final bool isDestructive;

  /// Mostra un segno di spunta (es. ordinamento attivo).
  final bool isChecked;

  /// Voce non selezionabile usata come intestazione di sezione.
  final bool isHeader;
  final bool isDivider;

  const ContextMenuEntry({
    required this.label,
    this.icon,
    this.onSelected,
    this.shortcut,
    this.isDestructive = false,
    this.isChecked = false,
  })  : isHeader = false,
        isDivider = false;

  const ContextMenuEntry.header(this.label)
      : icon = null,
        onSelected = null,
        shortcut = null,
        isDestructive = false,
        isChecked = false,
        isHeader = true,
        isDivider = false;

  const ContextMenuEntry.divider()
      : label = '',
        icon = null,
        onSelected = null,
        shortcut = null,
        isDestructive = false,
        isChecked = false,
        isHeader = false,
        isDivider = true;
}

/// Mostra [entries] come menu a comparsa ancorato a [globalPosition]
/// (coordinate globali, es. `TapDownDetails.globalPosition`). Il menu si
/// riposiziona da solo se uscirebbe dallo schermo. L'azione della voce
/// scelta viene eseguita DOPO la chiusura del menu.
Future<void> showContextMenu(
  BuildContext context,
  Offset globalPosition,
  List<ContextMenuEntry> entries,
) async {
  if (entries.isEmpty) return;
  final overlayBox =
      Overlay.of(context).context.findRenderObject() as RenderBox;
  final position = RelativeRect.fromRect(
    Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
    Offset.zero & overlayBox.size,
  );
  final theme = Theme.of(context);

  final items = <PopupMenuEntry<int>>[];
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    if (e.isDivider) {
      items.add(const PopupMenuDivider(height: 8));
      continue;
    }
    if (e.isHeader) {
      items.add(PopupMenuItem<int>(
        enabled: false,
        height: 28,
        child: Text(
          e.label,
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
      ));
      continue;
    }
    final color = e.isDestructive ? Colors.red.shade400 : null;
    items.add(PopupMenuItem<int>(
      value: i,
      height: 38,
      enabled: e.onSelected != null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 200),
        child: Row(
          children: [
            if (e.icon != null) ...[
              Icon(e.icon, size: 18, color: color),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                e.label,
                style: TextStyle(fontSize: 13, color: color),
              ),
            ),
            if (e.isChecked)
              Icon(Icons.check_rounded,
                  size: 16, color: theme.colorScheme.primary),
            if (e.shortcut != null) ...[
              const SizedBox(width: 24),
              Text(
                e.shortcut!,
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ],
        ),
      ),
    ));
  }

  final selected = await showMenu<int>(
    context: context,
    position: position,
    items: items,
  );
  if (selected != null) entries[selected].onSelected?.call();
}

/// Apre un menu contestuale con il tasto destro del mouse (o pressione
/// prolungata con dito/penna se [enableLongPress]) sul [child].
///
/// Le regioni annidate funzionano "dal più interno": un tasto destro su una
/// nota apre il menu della nota, uno sullo spazio vuoto attorno apre quello
/// della lista.
class ContextMenuRegion extends StatelessWidget {
  final Widget child;
  final List<ContextMenuEntry> Function(BuildContext context) entriesBuilder;
  final bool enabled;
  final bool enableLongPress;

  /// `opaque` per aree vuote (devono ricevere il click anche dove non c'è
  /// nessun figlio), `deferToChild` per elementi già pieni.
  final HitTestBehavior behavior;

  /// Chiamato subito prima dell'apertura (es. per evidenziare l'elemento).
  final VoidCallback? onOpen;

  const ContextMenuRegion({
    super.key,
    required this.child,
    required this.entriesBuilder,
    this.enabled = true,
    this.enableLongPress = false,
    this.behavior = HitTestBehavior.deferToChild,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return GestureDetector(
      behavior: behavior,
      onSecondaryTapDown: (details) {
        onOpen?.call();
        showContextMenu(context, details.globalPosition, entriesBuilder(context));
      },
      onLongPressStart: enableLongPress
          ? (details) {
              onOpen?.call();
              showContextMenu(
                  context, details.globalPosition, entriesBuilder(context));
            }
          : null,
      child: child,
    );
  }
}
