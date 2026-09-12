import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/color_schemes.dart';
import '../providers/note_search_provider.dart';

/// Barra di ricerca INTERNA alla nota ("Trova nel documento"), mostrata in
/// cima al pannello editor quando `noteSearchProvider.isActive` è vero (vedi
/// `note_editor_pane.dart`). Funziona identicamente in modalità Modifica e
/// Sola Lettura: entrambe le viste leggono le stesse occorrenze da
/// `noteSearchMatchesProvider`/`noteSearchActiveMatchIndexProvider`, questa
/// barra si limita a pilotare [noteSearchProvider] e a mostrare il
/// contatore "N/M".
class NoteSearchBar extends ConsumerStatefulWidget {
  const NoteSearchBar({super.key});

  @override
  ConsumerState<NoteSearchBar> createState() => _NoteSearchBarState();
}

class _NoteSearchBarState extends ConsumerState<NoteSearchBar> {
  late final TextEditingController _queryController;
  final FocusNode _focusNode = FocusNode();

  // Stesso pattern di debounce già usato per la ricerca globale (vedi
  // `notes_list_view.dart`): il ricalcolo delle occorrenze è economico, ma
  // su note molto lunghe ricostruire l'evidenziazione ad OGNI carattere
  // digitato resta lavoro superfluo mentre l'utente sta ancora scrivendo il
  // termine di ricerca.
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: ref.read(noteSearchProvider).query);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    // Rebuild locale immediato e leggero (es. visibilità del pulsante
    // "cancella"), separato dall'aggiornamento — debounced — del provider
    // che ricalcola le occorrenze e ricostruisce l'evidenziazione.
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      ref.read(noteSearchProvider.notifier).setQuery(value);
    });
  }

  void _applyImmediately() {
    _debounce?.cancel();
    ref.read(noteSearchProvider.notifier).setQuery(_queryController.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    final matches = ref.watch(noteSearchMatchesProvider);
    final activeIndex = ref.watch(noteSearchActiveMatchIndexProvider);
    final total = matches.length;
    final hasQuery = _queryController.text.trim().isNotEmpty;

    // Se il termine cercato è stato modificato altrove (es. aprendo la nota
    // da un risultato della ricerca globale, che imposta `initialQuery` su
    // `noteSearchProvider` DOPO che questa barra è già montata — vedi
    // `notes_list_view.dart`), riallinea il campo locale senza però
    // interferire con la digitazione dell'utente quando è lui/lei a
    // scrivere (in quel caso il valore combacia già, per costruzione, non
    // appena il debounce applica la stessa stringa al provider).
    ref.listen<String>(noteSearchProvider.select((s) => s.query), (previous, next) {
      if (next != _queryController.text) {
        _queryController.value = _queryController.value.copyWith(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        );
      }
    });

    return Material(
      color: theme.colorScheme.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: theme.colorScheme.outline.withValues(alpha: 0.35),
              width: 1,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Icon(
              Icons.search_rounded,
              size: 18,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: theme.surfaceElevated,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.centerLeft,
                child: TextField(
                  controller: _queryController,
                  focusNode: _focusNode,
                  autofocus: true,
                  onChanged: _onChanged,
                  onSubmitted: (_) {
                    _applyImmediately();
                    if (total > 0) {
                      ref.read(noteSearchProvider.notifier).nextMatch(total);
                    }
                  },
                  style: theme.textTheme.bodyMedium,
                  decoration: InputDecoration(
                    isDense: true,
                    isCollapsed: true,
                    border: InputBorder.none,
                    hintText: l10n.searchInNote,
                    hintStyle: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 52,
              child: Text(
                hasQuery ? (total == 0 ? l10n.noMatchesFound : '${activeIndex + 1}/$total') : '',
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 20),
              tooltip: l10n.previousMatch,
              visualDensity: VisualDensity.compact,
              onPressed: total > 0
                  ? () => ref.read(noteSearchProvider.notifier).previousMatch(total)
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
              tooltip: l10n.nextMatch,
              visualDensity: VisualDensity.compact,
              onPressed: total > 0
                  ? () => ref.read(noteSearchProvider.notifier).nextMatch(total)
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              tooltip: l10n.closeSearch,
              visualDensity: VisualDensity.compact,
              onPressed: () => ref.read(noteSearchProvider.notifier).close(),
            ),
          ],
        ),
      ),
    );
  }
}
