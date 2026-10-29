import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/utils/app_commands.dart';
import '../../../core/utils/focus_requests.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/context_menu.dart';
import '../../folders/presentation/folder_dialogs.dart'
    show showAddFolderDialog;
import '../../../core/theme/color_schemes.dart';
import '../../editor/providers/note_search_provider.dart';
import '../../folders/providers/folder_provider.dart';
import '../models/note_model.dart';
import '../providers/notes_provider.dart';
import 'note_card.dart';

class NotesListView extends ConsumerStatefulWidget {
  final void Function(NoteModel note)? onNoteSelected;

  const NotesListView({super.key, this.onNoteSelected});

  @override
  ConsumerState<NotesListView> createState() => _NotesListViewState();
}

class _NotesListViewState extends ConsumerState<NotesListView> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  // Debounce della ricerca: il filtro (filteredNotesProvider) è in-memory e
  // quindi economico anche per singolo carattere, ma su liste di note molto
  // grandi ricalcolarlo e ricostruire l'intera ListView ad OGNI keystroke
  // resta lavoro superfluo se l'utente sta ancora digitando. 200ms sono
  // impercettibili per l'utente ma raggruppano i keystroke di un burst di
  // digitazione in un solo aggiornamento di stato/rebuild.
  Timer? _searchDebounceTimer;

  @override
  void initState() {
    super.initState();
    // La query vive nel provider e sopravvive alla distruzione di questa
    // vista (mobile: lista ↔ editor). Il controller no: senza questo seeding
    // il campo tornava vuoto mentre il filtro restava attivo.
    _searchController.text = ref.read(notesProvider).searchQuery;
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    // Rebuild locale immediato (leggero: aggiorna solo questo widget, es.
    // la visibilità dell'icona "cancella") separato dall'aggiornamento del
    // provider (pesante: ricalcola filteredNotesProvider e ricostruisce
    // l'intera lista), che viene invece debounced.
    setState(() {});
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      ref.read(notesProvider.notifier).setSearchQuery(value);
    });
  }

  /// Apre [note], propagando l'eventuale termine di ricerca globale/per
  /// cartella attualmente digitato (vedi `NotesState.searchQuery`) alla
  /// ricerca interna alla nota: le occorrenze risultano così già
  /// evidenziate non appena l'editor si apre, invece di richiedere
  /// all'utente di riscrivere lo stesso termine una seconda volta.
  ///
  /// Se non c'è alcuna ricerca globale in corso, si limita a selezionare la
  /// nota: un eventuale pannello di ricerca interna già aperto in
  /// precedenza (su un'altra nota) resta semplicemente invariato — si
  /// comporta come un "Trova" persistente, vedi `NoteSearchNotifier.open`.
  void _openNote(NoteModel note) {
    ref.read(notesProvider.notifier).selectNote(note.id);

    final globalQuery = ref.read(notesProvider).searchQuery.trim();
    if (globalQuery.isNotEmpty) {
      ref.read(noteSearchProvider.notifier).open(initialQuery: globalQuery);
    }

    widget.onNoteSelected?.call(note);
  }

  List<({String label, NoteSortOrder order})> _sortEntries(
    AppLocalizations l10n,
  ) {
    return [
      (label: l10n.sortUpdatedDesc, order: NoteSortOrder.updatedDesc),
      (label: l10n.sortUpdatedAsc, order: NoteSortOrder.updatedAsc),
      (label: l10n.sortCreatedDesc, order: NoteSortOrder.createdDesc),
      (label: l10n.sortCreatedAsc, order: NoteSortOrder.createdAsc),
      (label: l10n.sortTitleAsc, order: NoteSortOrder.titleAsc),
      (label: l10n.sortTitleDesc, order: NoteSortOrder.titleDesc),
      (label: l10n.sortCustom, order: NoteSortOrder.custom),
    ];
  }

  IconData _sortIcon(NoteSortOrder order) {
    switch (order) {
      case NoteSortOrder.updatedDesc:
        return Icons.history_rounded;
      case NoteSortOrder.updatedAsc:
        return Icons.update_rounded;
      case NoteSortOrder.createdDesc:
        return Icons.calendar_today_rounded;
      case NoteSortOrder.createdAsc:
        return Icons.event_note_rounded;
      case NoteSortOrder.titleAsc:
      case NoteSortOrder.titleDesc:
        return Icons.sort_by_alpha_rounded;
      case NoteSortOrder.custom:
        return Icons.drag_indicator_rounded;
    }
  }

  Widget _buildSortMenu(
    AppLocalizations l10n,
    ThemeData theme,
    NoteSortOrder activeSort,
  ) {
    final entries = _sortEntries(l10n);

    ContextMenuEntry sortEntry(
      String label,
      IconData icon,
      NoteSortOrder order, {
      String? description,
    }) {
      return ContextMenuEntry(
        label: label,
        icon: icon,
        description: description,
        isChecked: activeSort == order,
        onSelected: () => ref.read(notesProvider.notifier).setSortOrder(order),
      );
    }

    return Builder(
      builder: (buttonContext) => IconButton(
        tooltip: l10n.sortBy,
        visualDensity: VisualDensity.compact,
        icon: Icon(
          Icons.sort_rounded,
          size: 20,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
        ),
        onPressed: () {
          final box = buttonContext.findRenderObject() as RenderBox;
          showContextMenu(
            buttonContext,
            box.localToGlobal(Offset(0, box.size.height + 4)),
            [
              ...entries
                  .where((entry) => entry.order != NoteSortOrder.custom)
                  .map(
                    (entry) => sortEntry(
                      entry.label,
                      _sortIcon(entry.order),
                      entry.order,
                    ),
                  ),
              const ContextMenuEntry.divider(),
              sortEntry(
                l10n.sortCustom,
                Icons.drag_indicator_rounded,
                NoteSortOrder.custom,
                description: 'Trascina le note per riordinarle',
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    // Il provider è la fonte di verità: se la query viene cambiata altrove
    // (es. "cancella ricerca" da un'altra vista), il campo visibile resta
    // allineato invece di mostrare testo vuoto con la lista ancora filtrata.
    ref.listen<String>(notesProvider.select((s) => s.searchQuery), (_, next) {
      if (_searchController.text == next) return;
      _searchController.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    });

    // Ctrl+Shift+F: porta il focus sul campo di ricerca e seleziona il testo
    // già presente, così si può riscrivere subito.
    ref.listen<int>(globalSearchFocusRequestProvider, (_, _) {
      _searchFocusNode.requestFocus();
      _searchController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _searchController.text.length,
      );
    });

    // Fine-grained Riverpod selectors
    final notes = ref.watch(filteredNotesProvider);
    final sortOrder = ref.watch(notesProvider.select((s) => s.sortOrder));
    final activeNoteId = ref.watch(notesProvider.select((s) => s.activeNoteId));
    final selectedFolderId = ref.watch(
      folderProvider.select((s) => s.selectedFolderId),
    );
    final searchQueryEmpty = ref.watch(
      notesProvider.select((s) => s.searchQuery.trim().isEmpty),
    );

    final isCustomReorderActive =
        sortOrder == NoteSortOrder.custom && searchQueryEmpty;

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
              focusNode: _searchFocusNode,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: l10n.searchNotes,
                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.subtleTextColor,
                ),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 18,
                  color: theme.subtleTextColor,
                ),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 16),
                        onPressed: () {
                          // Azione esplicita dell'utente: applica subito,
                          // senza aspettare il debounce del typing.
                          _searchDebounceTimer?.cancel();
                          _searchController.clear();
                          ref.read(notesProvider.notifier).setSearchQuery('');
                        },
                      )
                    : null,
                isDense: true,
                filled: true,
                fillColor: theme.surfaceElevated,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // Header action bar with Note count, Sort menu, and New Note button
          // (tasto destro: stesso menu dello spazio vuoto della lista)
          ContextMenuRegion(
            enabled: isDesktopPlatform,
            behavior: HitTestBehavior.opaque,
            entriesBuilder: (ctx) =>
                _listMenuEntries(ctx, l10n, sortOrder, selectedFolderId),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 12, 8),
              child: Row(
                children: [
                  Text(
                    '${notes.length} ${notes.length == 1 ? "nota" : "note"}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.mutedTextColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  _buildSortMenu(l10n, theme, sortOrder),
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
          ),

          const Divider(height: 1),

          // Notes List: ReorderableListView in custom mode, regular ListView otherwise
          Expanded(
            // Tasto destro sullo spazio vuoto della lista (o sullo stato
            // "nessuna nota"): nuova nota / nuova cartella / ordinamento.
            // Ogni NoteCard ha il proprio menu (regione più interna).
            child: ContextMenuRegion(
              enabled: isDesktopPlatform,
              behavior: HitTestBehavior.opaque,
              entriesBuilder: (ctx) =>
                  _listMenuEntries(ctx, l10n, sortOrder, selectedFolderId),
              child: notes.isEmpty
                  ? _buildEmptyState(context, l10n, theme)
                  : isCustomReorderActive
                  ? ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      proxyDecorator: (child, index, animation) {
                        return AnimatedBuilder(
                          animation: animation,
                          builder: (context, child) {
                            final lift = Curves.easeOutCubic.transform(
                              animation.value,
                            );
                            return Transform.scale(
                              scale: 1 + (0.02 * lift),
                              child: Material(
                                color: Colors.transparent,
                                elevation: 10 * lift,
                                borderRadius: BorderRadius.circular(12),
                                shadowColor: Colors.black.withValues(
                                  alpha: 0.3,
                                ),
                                child: child,
                              ),
                            );
                          },
                          child: child,
                        );
                      },
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: notes.length,
                      onReorderItem: (oldIndex, newIndex) {
                        // onReorderItem fornisce newIndex già corretto per
                        // la rimozione dell'elemento; reorderNotes usa la
                        // semantica classica di onReorder (la correzione
                        // avviene al suo interno), quindi la si ripristina.
                        final legacyNewIndex = newIndex > oldIndex
                            ? newIndex + 1
                            : newIndex;
                        // Gli indici si riferiscono alla lista MOSTRATA
                        // (filtrata per cartella): si passano anche gli id
                        // visibili, così il provider sposta la nota giusta.
                        ref
                            .read(notesProvider.notifier)
                            .reorderNotes(
                              oldIndex,
                              legacyNewIndex,
                              visibleIds: notes.map((n) => n.id).toList(),
                            );
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
                          onTap: () => _openNote(note),
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
                          onTap: () => _openNote(note),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// Menu contestuale dello spazio vuoto della lista note.
  List<ContextMenuEntry> _listMenuEntries(
    BuildContext context,
    AppLocalizations l10n,
    NoteSortOrder activeSort,
    String? selectedFolderId,
  ) {
    ContextMenuEntry sortEntry(String label, NoteSortOrder order) {
      return ContextMenuEntry(
        label: label,
        isChecked: activeSort == order,
        onSelected: () => ref.read(notesProvider.notifier).setSortOrder(order),
      );
    }

    final entries = _sortEntries(l10n);

    return [
      ContextMenuEntry(
        label: l10n.newNote,
        icon: Icons.note_add_outlined,
        shortcut: commandShortcutLabel(AppCommand.newNote),
        onSelected: () {
          final newNote = ref
              .read(notesProvider.notifier)
              .createNote(folderId: selectedFolderId);
          widget.onNoteSelected?.call(newNote);
        },
      ),
      ContextMenuEntry(
        // Con una cartella selezionata la nuova cartella nasce al suo
        // interno, come sottocartella.
        label: selectedFolderId == null ? l10n.newFolder : l10n.newSubfolder,
        icon: Icons.create_new_folder_outlined,
        // La scorciatoia crea sempre una cartella al livello principale.
        shortcut: selectedFolderId == null
            ? commandShortcutLabel(AppCommand.newFolder)
            : null,
        onSelected: () =>
            showAddFolderDialog(context, ref, parentId: selectedFolderId),
      ),
      const ContextMenuEntry.divider(),
      ContextMenuEntry.header(l10n.sortBy),
      ...entries.map((entry) => sortEntry(entry.label, entry.order)),
    ];
  }

  Widget _buildEmptyState(
    BuildContext context,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.note_alt_outlined,
              size: 48,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 12),
            Text(
              _searchController.text.isNotEmpty
                  ? l10n.noNotesFound
                  : l10n.noNotes,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              l10n.createFirstNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.mutedTextColor,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
