import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/color_schemes.dart';
import '../../folders/providers/folder_provider.dart';
import '../models/note_model.dart';
import '../providers/notes_provider.dart';
import 'note_card.dart';

class NotesListView extends ConsumerStatefulWidget {
  final void Function(NoteModel note)? onNoteSelected;

  const NotesListView({
    super.key,
    this.onNoteSelected,
  });

  @override
  ConsumerState<NotesListView> createState() => _NotesListViewState();
}

class _NotesListViewState extends ConsumerState<NotesListView> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Widget _buildSortMenu(BuildContext context, AppLocalizations l10n, ThemeData theme, NoteSortOrder activeSort) {
    return PopupMenuButton<NoteSortOrder>(
      tooltip: l10n.sortBy,
      icon: Icon(
        Icons.sort_rounded,
        size: 20,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
      ),
      initialValue: activeSort,
      onSelected: (order) {
        ref.read(notesProvider.notifier).setSortOrder(order);
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: NoteSortOrder.updatedDesc,
          child: Row(
            children: [
              Icon(Icons.history_rounded, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(l10n.sortUpdatedDesc, style: const TextStyle(fontSize: 13))),
              if (activeSort == NoteSortOrder.updatedDesc)
                Icon(Icons.check_rounded, size: 16, color: theme.colorScheme.primary),
            ],
          ),
        ),
        PopupMenuItem(
          value: NoteSortOrder.updatedAsc,
          child: Row(
            children: [
              Icon(Icons.update_rounded, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(l10n.sortUpdatedAsc, style: const TextStyle(fontSize: 13))),
              if (activeSort == NoteSortOrder.updatedAsc)
                Icon(Icons.check_rounded, size: 16, color: theme.colorScheme.primary),
            ],
          ),
        ),
        PopupMenuItem(
          value: NoteSortOrder.createdDesc,
          child: Row(
            children: [
              Icon(Icons.calendar_today_rounded, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(l10n.sortCreatedDesc, style: const TextStyle(fontSize: 13))),
              if (activeSort == NoteSortOrder.createdDesc)
                Icon(Icons.check_rounded, size: 16, color: theme.colorScheme.primary),
            ],
          ),
        ),
        PopupMenuItem(
          value: NoteSortOrder.createdAsc,
          child: Row(
            children: [
              Icon(Icons.event_note_rounded, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(l10n.sortCreatedAsc, style: const TextStyle(fontSize: 13))),
              if (activeSort == NoteSortOrder.createdAsc)
                Icon(Icons.check_rounded, size: 16, color: theme.colorScheme.primary),
            ],
          ),
        ),
        PopupMenuItem(
          value: NoteSortOrder.titleAsc,
          child: Row(
            children: [
              Icon(Icons.sort_by_alpha_rounded, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(l10n.sortTitleAsc, style: const TextStyle(fontSize: 13))),
              if (activeSort == NoteSortOrder.titleAsc)
                Icon(Icons.check_rounded, size: 16, color: theme.colorScheme.primary),
            ],
          ),
        ),
        PopupMenuItem(
          value: NoteSortOrder.titleDesc,
          child: Row(
            children: [
              Icon(Icons.sort_by_alpha_rounded, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(l10n.sortTitleDesc, style: const TextStyle(fontSize: 13))),
              if (activeSort == NoteSortOrder.titleDesc)
                Icon(Icons.check_rounded, size: 16, color: theme.colorScheme.primary),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: NoteSortOrder.custom,
          child: Row(
            children: [
              Icon(Icons.drag_indicator_rounded, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l10n.sortCustom, style: const TextStyle(fontSize: 13)),
                    Text(
                      'Trascina le note per riordinarle',
                      style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                    ),
                  ],
                ),
              ),
              if (activeSort == NoteSortOrder.custom)
                Icon(Icons.check_rounded, size: 16, color: theme.colorScheme.primary),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    // Fine-grained Riverpod selectors
    final notes = ref.watch(filteredNotesProvider);
    final sortOrder = ref.watch(notesProvider.select((s) => s.sortOrder));
    final activeNoteId = ref.watch(notesProvider.select((s) => s.activeNoteId));
    final selectedFolderId = ref.watch(folderProvider.select((s) => s.selectedFolderId));
    final searchQueryEmpty = ref.watch(notesProvider.select((s) => s.searchQuery.trim().isEmpty));

    final isCustomReorderActive = sortOrder == NoteSortOrder.custom && searchQueryEmpty;

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
          // Search Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: TextField(
              controller: _searchController,
              onChanged: (val) {
                ref.read(notesProvider.notifier).setSearchQuery(val);
              },
              decoration: InputDecoration(
                hintText: l10n.searchNotes,
                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 16),
                        onPressed: () {
                          _searchController.clear();
                          ref.read(notesProvider.notifier).setSearchQuery('');
                        },
                      )
                    : null,
                isDense: true,
                filled: true,
                fillColor: theme.surfaceElevated,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // Header action bar with Note count, Sort menu, and New Note button
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 12, 8),
            child: Row(
              children: [
                Text(
                  '${notes.length} ${notes.length == 1 ? "nota" : "note"}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                _buildSortMenu(context, l10n, theme, sortOrder),
                const Spacer(),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(l10n.newNote),
                  onPressed: () {
                    final newNote = ref
                        .read(notesProvider.notifier)
                        .createNote(folderId: selectedFolderId);
                    widget.onNoteSelected?.call(newNote);
                  },
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Notes List: ReorderableListView in custom mode, regular ListView otherwise
          Expanded(
            child: notes.isEmpty
                ? _buildEmptyState(context, l10n, theme)
                : isCustomReorderActive
                    ? ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        proxyDecorator: (child, index, animation) {
                          return Material(
                            color: Colors.transparent,
                            elevation: 0,
                            child: child,
                          );
                        },
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: notes.length,
                        onReorder: (oldIndex, newIndex) {
                          ref
                              .read(notesProvider.notifier)
                              .reorderNotes(oldIndex, newIndex);
                        },
                        itemBuilder: (context, index) {
                          final note = notes[index];
                          final isSelected = activeNoteId == note.id;

                          return NoteCard(
                            key: ValueKey(note.id),
                            note: note,
                            isSelected: isSelected,
                            showDragHandle: true,
                            dragIndex: index,
                            onTap: () {
                              ref
                                  .read(notesProvider.notifier)
                                  .selectNote(note.id);
                              widget.onNoteSelected?.call(note);
                            },
                          );
                        },
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: notes.length,
                        itemBuilder: (context, index) {
                          final note = notes[index];
                          final isSelected = activeNoteId == note.id;

                          return NoteCard(
                            key: ValueKey(note.id),
                            note: note,
                            isSelected: isSelected,
                            showDragHandle: false,
                            onTap: () {
                              ref.read(notesProvider.notifier).selectNote(note.id);
                              widget.onNoteSelected?.call(note);
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(
      BuildContext context, AppLocalizations l10n, ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.note_alt_outlined,
              size: 48,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
            ),
            const SizedBox(height: 12),
            Text(
              _searchController.text.isNotEmpty
                  ? l10n.noNotesFound
                  : l10n.noNotes,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              l10n.createFirstNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
