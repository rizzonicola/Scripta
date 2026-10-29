import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/color_schemes.dart';

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

  /// Riga secondaria opzionale sotto l'etichetta.
  final String? description;

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
    this.description,
  }) : isHeader = false,
       isDivider = false;

  const ContextMenuEntry.header(this.label)
    : icon = null,
      onSelected = null,
      shortcut = null,
      isDestructive = false,
      isChecked = false,
      description = null,
      isHeader = true,
      isDivider = false;

  const ContextMenuEntry.divider()
    : label = '',
      icon = null,
      onSelected = null,
      shortcut = null,
      isDestructive = false,
      isChecked = false,
      description = null,
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
      items.add(
        PopupMenuDivider(
          height: 9,
          thickness: 1,
          indent: 8,
          endIndent: 8,
          color: theme.colorScheme.outline.withValues(alpha: 0.45),
        ),
      );
      continue;
    }
    if (e.isHeader) {
      items.add(_ContextMenuHeader(e.label));
      continue;
    }
    items.add(_ContextMenuAction(index: i, entry: e));
  }

  final selected = await showMenu<int>(
    context: context,
    position: position,
    items: items,
    constraints: const BoxConstraints(minWidth: 220, maxWidth: 340),
    menuPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
    clipBehavior: Clip.antiAlias,
    popUpAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 150),
      reverseDuration: Duration(milliseconds: 100),
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ),
  );
  if (selected != null) entries[selected].onSelected?.call();
}

class _ContextMenuHeader extends PopupMenuEntry<int> {
  const _ContextMenuHeader(this.label);

  final String label;

  @override
  double get height => 28;

  @override
  bool represents(int? value) => false;

  @override
  State<_ContextMenuHeader> createState() => _ContextMenuHeaderState();
}

class _ContextMenuHeaderState extends State<_ContextMenuHeader> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 28,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            widget.label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: theme.mutedTextColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _ContextMenuAction extends PopupMenuEntry<int> {
  const _ContextMenuAction({required this.index, required this.entry});

  final int index;
  final ContextMenuEntry entry;

  @override
  double get height => entry.description == null ? 40 : 52;

  @override
  bool represents(int? value) => value == index;

  @override
  State<_ContextMenuAction> createState() => _ContextMenuActionState();
}

class _ContextMenuActionState extends State<_ContextMenuAction> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = widget.entry;
    final enabled = entry.onSelected != null;
    final labelColor = !enabled
        ? theme.subtleTextColor
        : entry.isDestructive
        ? theme.dangerColor
        : theme.colorScheme.onSurface;
    final iconColor = !enabled
        ? theme.subtleTextColor
        : entry.isDestructive
        ? theme.dangerColor
        : theme.colorScheme.primary;
    final radius = BorderRadius.circular(10);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Semantics(
        button: true,
        enabled: enabled,
        selected: entry.isChecked ? true : null,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled
                ? () => Navigator.of(context).pop(widget.index)
                : null,
            borderRadius: radius,
            hoverColor: theme.colorScheme.primary.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.1 : 0.06,
            ),
            focusColor: theme.colorScheme.primary.withValues(alpha: 0.12),
            child: Container(
              height: entry.description == null ? 38 : 50,
              padding: EdgeInsets.fromLTRB(
                10,
                entry.description == null ? 0 : 7,
                8,
                entry.description == null ? 0 : 7,
              ),
              child: Row(
                children: [
                  if (entry.icon != null) ...[
                    Icon(entry.icon, size: 17, color: iconColor),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: labelColor,
                          ),
                        ),
                        if (entry.description != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            entry.description!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.2,
                              color: theme.mutedTextColor,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (entry.isChecked) ...[
                    const SizedBox(width: 10),
                    Icon(
                      Icons.check_rounded,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                  if (entry.shortcut != null) ...[
                    const SizedBox(width: 12),
                    _ShortcutHint(entry.shortcut!),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShortcutHint extends StatelessWidget {
  const _ShortcutHint(this.shortcut);

  final String shortcut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.06 : 0.045,
        ),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.28),
        ),
      ),
      child: Text(
        shortcut,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: theme.mutedTextColor,
        ),
      ),
    );
  }
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

  /// Ultimo puntatore già gestito da una regione. I `Listener` ricevono
  /// l'evento dal più interno al più esterno: la prima regione lo consuma e
  /// quelle che la contengono lo ignorano (altrimenti si aprirebbero più
  /// menu sovrapposti, es. nota + lista o cartella + albero).
  static int? _handledPointer;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Listener(
      behavior: behavior,
      onPointerDown: (event) {
        if ((event.buttons & kSecondaryMouseButton) != 0) {
          if (_handledPointer == event.pointer) return;
          _handledPointer = event.pointer;
          onOpen?.call();
          showContextMenu(context, event.position, entriesBuilder(context));
        }
      },
      child: enableLongPress
          ? GestureDetector(
              behavior: behavior,
              onLongPressStart: (details) {
                onOpen?.call();
                showContextMenu(
                  context,
                  details.globalPosition,
                  entriesBuilder(context),
                );
              },
              child: child,
            )
          : child,
    );
  }
}
