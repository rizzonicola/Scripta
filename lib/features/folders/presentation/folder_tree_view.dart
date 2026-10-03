import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/l10n/desktop_strings.dart';
import '../../../core/services/export_service.dart';
import '../../../core/services/import_service.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/context_menu.dart';
import '../../../core/widgets/shortcuts_help_dialog.dart';
import '../../settings/presentation/settings_view.dart';
import '../models/folder_node.dart';
import '../providers/folder_provider.dart';
import 'folder_dialogs.dart';
import 'folder_item_tile.dart';
import 'folder_menus.dart';

class FolderTreeView extends ConsumerWidget {
  const FolderTreeView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Due `.select` mirati invece di un `ref.watch(folderProvider)` pieno:
    // questo widget NON deve ricostruirsi per un semplice
    // espandi/comprimi o una selezione di un nodo (quello lo gestisce ora
    // il singolo `_FolderNodeView`, vedi sotto), solo quando cambia
    // l'insieme delle cartelle radice o si passa a/da "Tutte le note".
    final rootFolders = ref.watch(folderProvider.select((s) => s.rootFolders));
    final isAllNotesSelected =
        ref.watch(folderProvider.select((s) => s.selectedFolderId == null));
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          right: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.4),
            width: 1,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header (tasto destro: stesso menu di "Tutte le note")
          ContextMenuRegion(
            enabled: isDesktopPlatform,
            behavior: HitTestBehavior.opaque,
            entriesBuilder: (ctx) => workspaceMenuEntries(ctx, ref),
            child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
            child: Row(
              children: [
                Icon(
                  Icons.folder_copy_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.folders,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                  tooltip: l10n.newFolder,
                  onPressed: () => showAddFolderDialog(context, ref),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                  tooltip: 'Altro',
                  onSelected: (val) {
                    if (val == 'export_all') {
                      ExportService.exportAllAsZip(context, ref);
                    } else if (val == 'import') {
                      ImportService.showImportOptions(context, ref);
                    } else if (val == 'shortcuts') {
                      ShortcutsHelpDialog.show(context);
                    }
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(
                      value: 'export_all',
                      child: Row(
                        children: [
                          Icon(Icons.archive_outlined, size: 18),
                          SizedBox(width: 8),
                          Text('Esporta tutte le note (ZIP)'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'import',
                      child: Row(
                        children: [
                          Icon(Icons.file_upload_outlined, size: 18),
                          SizedBox(width: 8),
                          Text('Importa'),
                        ],
                      ),
                    ),
                    if (isDesktopPlatform)
                      PopupMenuItem(
                        value: 'shortcuts',
                        child: Row(
                          children: [
                            const Icon(Icons.keyboard_alt_outlined, size: 18),
                            const SizedBox(width: 8),
                            Text(DesktopStrings.of(ctx).keyboardShortcuts),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          ),
          const Divider(height: 1),

          // "All Notes" item (l'intera riga, margini compresi, risponde)
          ContextMenuRegion(
            enabled: isDesktopPlatform,
            behavior: HitTestBehavior.opaque,
            entriesBuilder: (ctx) => workspaceMenuEntries(ctx, ref),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: FolderItemTile(
                title: l10n.allNotes,
                icon: Icons.notes_rounded,
                isSelected: isAllNotesSelected,
                onTap: () =>
                    ref.read(folderProvider.notifier).selectFolder(null),
              ),
            ),
          ),

          ContextMenuRegion(
            enabled: isDesktopPlatform,
            behavior: HitTestBehavior.opaque,
            entriesBuilder: (ctx) => workspaceMenuEntries(ctx, ref),
            // Nessun padding verticale: il riquadro di "Tutte le note" ha
            // già 4 px sopra e sotto, così dista 4 px sia dalla linea
            // sopra sia da quella sotto (prima: 4 px sopra, 10 sotto).
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Divider(height: 1),
            ),
          ),

          // Folders Tree
          Expanded(
            // Tasto destro sullo spazio vuoto sotto/tra le cartelle: stesso
            // menu di "Tutte le note". Le cartelle hanno il proprio menu
            // (regione più interna, ha la precedenza).
            child: ContextMenuRegion(
              enabled: isDesktopPlatform,
              behavior: HitTestBehavior.opaque,
              entriesBuilder: (ctx) => workspaceMenuEntries(ctx, ref),
              // ListView.builder: i nodi radice fuori schermo non vengono
              // nemmeno istanziati (prima `ListView(children: ...map...)`
              // creava subito un widget per ogni cartella radice).
              child: ListView.builder(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                itemCount: rootFolders.length,
                itemBuilder: (context, index) {
                  final node = rootFolders[index];
                  return _FolderNodeView(
                    key: ValueKey(node.id),
                    node: node,
                    depth: 0,
                  );
                },
              ),
            ),
          ),

          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: FolderItemTile(
              title: l10n.settings,
              icon: Icons.settings_outlined,
              isSelected: false,
              onTap: () {
                SettingsView.show(context);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Nodo dell'albero cartelle come widget indipendente (con `key` stabile
/// per identità), invece di un metodo ricorsivo che ricostruiva l'intero
/// sottoalbero visibile ad ogni cambiamento di stato. Osserva SOLO se
/// QUESTO specifico nodo è selezionato (`.select`), quindi selezionare una
/// cartella o espanderne un'altra non fa più ricostruire l'intero albero:
/// solo i due nodi effettivamente coinvolti (quello deselezionato e quello
/// selezionato) si ricostruiscono.
class _FolderNodeView extends ConsumerWidget {
  final FolderNode node;
  final int depth;

  const _FolderNodeView({
    super.key,
    required this.node,
    required this.depth,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSelected = ref.watch(
      folderProvider.select((s) => s.selectedFolderId == node.id),
    );
    final hasChildren = node.children.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ContextMenuRegion(
          enabled: isDesktopPlatform,
          entriesBuilder: (ctx) => folderMenuEntries(ctx, ref, node),
          child: FolderItemTile(
            title: node.name,
            icon: node.isExpanded
                ? Icons.folder_open_outlined
                : Icons.folder_outlined,
            depth: depth,
            isSelected: isSelected,
            hasChildren: hasChildren,
            isExpanded: node.isExpanded,
            onToggleExpand: () =>
                ref.read(folderProvider.notifier).toggleExpand(node.id),
            onTap: () =>
                ref.read(folderProvider.notifier).selectFolder(node.id),
            // Desktop: menu a comparsa ancorato al pulsante "..." (identico
            // al tasto destro). Mobile/tablet: bottom sheet come prima.
            onMoreOptions: (buttonPosition) {
              if (isDesktopPlatform) {
                showContextMenu(
                  context,
                  buttonPosition,
                  folderMenuEntries(context, ref, node),
                );
              } else {
                showFolderOptionsSheet(context, ref, node);
              }
            },
          ),
        ),
        if (hasChildren && node.isExpanded)
          ...node.children.map(
            (child) => _FolderNodeView(
              key: ValueKey(child.id),
              node: child,
              depth: depth + 1,
            ),
          ),
      ],
    );
  }
}
