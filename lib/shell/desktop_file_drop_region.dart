import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../core/l10n/desktop_strings.dart';
import '../core/services/external_open_service.dart';
import '../core/utils/platform_utils.dart';

/// Accetta file e cartelle trascinati dall'esterno sulla finestra.
///
/// Su mobile restituisce semplicemente [child]: non esiste un drag & drop
/// di file di sistema da intercettare. La consegna passa dallo stesso
/// [ExternalOpenService] usato da "Apri con Scripta", così l'elaborazione (e
/// la coda durante l'avvio) è unica per tutte le sorgenti.
class DesktopFileDropRegion extends StatefulWidget {
  const DesktopFileDropRegion({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopFileDropRegion> createState() => _DesktopFileDropRegionState();
}

class _DesktopFileDropRegionState extends State<DesktopFileDropRegion> {
  bool _dragging = false;

  void _setDragging(bool value) {
    if (_dragging == value) return;
    setState(() => _dragging = value);
  }

  @override
  Widget build(BuildContext context) {
    if (!isDesktopPlatform) return widget.child;

    final theme = Theme.of(context);

    return DropTarget(
      onDragEntered: (_) => _setDragging(true),
      onDragExited: (_) => _setDragging(false),
      onDragDone: (details) {
        _setDragging(false);
        ExternalOpenService.instance.addPaths(
          details.files.map((file) => file.path),
          source: ExternalOpenSource.dragDrop,
        );
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: theme.colorScheme.scrim.withValues(alpha: 0.18),
                  child: Center(
                    child: Card(
                      elevation: 6,
                      margin: const EdgeInsets.all(24),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 20,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.file_open_outlined,
                              size: 36,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              DesktopStrings.of(context).dropToOpen,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
