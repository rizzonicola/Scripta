import 'package:flutter/material.dart';

import '../models/folder_node.dart';

/// Cartella con la propria profondità nell'albero (serve per l'indentazione).
class FolderFlatItem {
  const FolderFlatItem({required this.node, required this.depth});

  final FolderNode node;
  final int depth;
}

/// Appiattisce l'albero delle cartelle in pre-ordine. Con
/// [excludeSubtreeOf] salta quella cartella e tutta la sua discendenza: non
/// ha senso spostare una cartella dentro se stessa o dentro un suo figlio.
List<FolderFlatItem> flattenFolders(
  List<FolderNode> roots, {
  String? excludeSubtreeOf,
}) {
  final result = <FolderFlatItem>[];
  void visit(List<FolderNode> nodes, int depth) {
    for (final node in nodes) {
      if (node.id == excludeSubtreeOf) continue;
      result.add(FolderFlatItem(node: node, depth: depth));
      visit(node.children, depth + 1);
    }
  }

  visit(roots, 0);
  return result;
}

/// Dialog "scegli una cartella di destinazione", condiviso da "Sposta nota"
/// e "Sposta cartella" (prima due copie quasi identiche, ~120 righe l'una).
///
/// Le etichette arrivano dal chiamante; il dialog si occupa solo di
/// elenco, indentazione, evidenziazione della posizione attuale e chiusura.
class FolderPickerDialog extends StatelessWidget {
  const FolderPickerDialog({
    super.key,
    required this.title,
    required this.rootIcon,
    required this.rootLabel,
    required this.emptyLabel,
    required this.cancelLabel,
    required this.destinations,
    required this.currentFolderId,
    required this.onSelected,
  });

  final String title;

  /// Icona e testo della voce "nessuna cartella / radice".
  final IconData rootIcon;
  final String rootLabel;

  /// Testo mostrato quando [destinations] è vuoto.
  final String emptyLabel;
  final String cancelLabel;
  final List<FolderFlatItem> destinations;

  /// Posizione attuale dell'elemento da spostare (`null` = nessuna
  /// cartella/radice): viene evidenziata e scegliere di nuovo la stessa
  /// destinazione chiude il dialog senza fare nulla.
  final String? currentFolderId;

  /// Chiamata DOPO la chiusura del dialog con la cartella scelta (`null` =
  /// nessuna cartella/radice), solo se diversa da [currentFolderId].
  final ValueChanged<String?> onSelected;

  void _choose(BuildContext context, String? folderId) {
    Navigator.of(context).pop();
    if (folderId != currentFolderId) onSelected(folderId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final isAtRoot = currentFolderId == null;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.drive_file_move_outlined, size: 22, color: primary),
          const SizedBox(width: 8),
          Expanded(child: Text(title, overflow: TextOverflow.ellipsis)),
        ],
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                leading: Icon(rootIcon, color: isAtRoot ? primary : muted),
                title: Text(rootLabel),
                trailing: isAtRoot
                    ? Icon(Icons.check_rounded, color: primary, size: 18)
                    : null,
                selected: isAtRoot,
                onTap: () => _choose(context, null),
              ),
              const Divider(height: 1),
              if (destinations.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    emptyLabel,
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                )
              else
                for (final item in destinations)
                  _FolderPickerTile(
                    item: item,
                    isCurrent: item.node.id == currentFolderId,
                    onTap: () => _choose(context, item.node.id),
                  ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(cancelLabel),
        ),
      ],
    );
  }
}

class _FolderPickerTile extends StatelessWidget {
  const _FolderPickerTile({
    required this.item,
    required this.isCurrent,
    required this.onTap,
  });

  final FolderFlatItem item;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return ListTile(
      contentPadding: EdgeInsets.only(
        left: 16.0 + (item.depth * 16.0),
        right: 16,
      ),
      leading: Icon(
        item.node.children.isNotEmpty
            ? Icons.folder_outlined
            : Icons.folder_open_outlined,
        size: 20,
        color: isCurrent
            ? primary
            : theme.colorScheme.onSurface.withValues(alpha: 0.6),
      ),
      title: Text(
        item.node.name,
        style: TextStyle(
          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
          color: isCurrent ? primary : null,
        ),
      ),
      trailing:
          isCurrent ? Icon(Icons.check_rounded, color: primary, size: 18) : null,
      selected: isCurrent,
      onTap: onTap,
    );
  }
}
