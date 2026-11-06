import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../folders/models/folder_node.dart';
import '../../folders/providers/folder_provider.dart';
import '../../notes/models/note_model.dart';
import '../../notes/providers/notes_provider.dart';

/// Esito della ricerca testuale per nota, memorizzato PER ISTANZA di
/// [NoteModel] e valido per UNA query alla volta.
///
/// Perché: `filteredNotesProvider` si ricalcola a ogni battitura nell'editor
/// (ogni modifica produce una nuova lista di note). Con una ricerca attiva,
/// il filtro rifaceva `toLowerCase()` sul contenuto COMPLETO di tutte le
/// note a ogni carattere digitato (O(numero note × lunghezza testo)). Le note
/// sono immutabili e ogni modifica crea una nuova istanza: tenere l'esito
/// per istanza significa rivalutare solo la nota appena modificata. Quando la
/// query cambia la cache si svuota; essendo `Expando`, non trattiene in
/// memoria le note scartate. Le copie minuscole vivono su `NoteModel`
/// (`titleLower`/`contentLower`) e sono calcolate pigramente una volta sola.
class _SearchMatchCache {
  String _query = '';
  Expando<bool> _matches = Expando<bool>('note-search-match');

  bool matches(NoteModel note, String lowerQuery) {
    if (lowerQuery != _query) {
      _query = lowerQuery;
      _matches = Expando<bool>('note-search-match');
    }
    final cached = _matches[note];
    if (cached != null) return cached;
    final result =
        note.titleLower.contains(lowerQuery) ||
        note.contentLower.contains(lowerQuery);
    _matches[note] = result;
    return result;
  }
}

final _searchMatchCacheProvider = Provider<_SearchMatchCache>(
  (ref) => _SearchMatchCache(),
);

/// Provider for filtered notes based on folder and search query.
///
/// Vista puramente derivata: legge la STESSA lista di [notesProvider] e la
/// filtra in memoria. Non esegue mai una query separata sul database, il che
/// garantisce per costruzione che "Tutte le note" e "note della cartella X"
/// non possano mai disallinearsi tra loro.
final filteredNotesProvider = Provider<List<NoteModel>>((ref) {
  final notes = ref.watch(notesProvider.select((s) => s.notes));
  final selectedFolderId = ref.watch(
    folderProvider.select((s) => s.selectedFolderId),
  );
  final searchQuery = ref.watch(notesProvider.select((s) => s.searchQuery));

  var filtered = notes;

  if (selectedFolderId != null) {
    // La ricerca "per cartella" include l'intero sottoalbero (la cartella
    // selezionata più TUTTE le sue sottocartelle, ricorsivamente), non solo
    // le note con `folderId` esattamente uguale a quello selezionato: vedi
    // FolderNode.collectSubtreeIds. Coerente con FolderTreeView, che mostra
    // già le sottocartelle annidate visivamente sotto il genitore, non come
    // sezioni indipendenti.
    final rootFolders = ref.watch(folderProvider.select((s) => s.rootFolders));
    final scopeIds = FolderNode.collectSubtreeIds(
      rootFolders,
      selectedFolderId,
    );
    filtered = filtered
        .where((n) => n.folderId != null && scopeIds.contains(n.folderId))
        .toList();
  }

  if (searchQuery.trim().isNotEmpty) {
    final q = searchQuery.toLowerCase().trim();
    final cache = ref.read(_searchMatchCacheProvider);
    filtered = filtered.where((n) => cache.matches(n, q)).toList();
  }

  return filtered;
});

/// Id della lista filtrata, con uguaglianza per valore.
///
/// `NotesListView` osserva questo provider invece dell'intera lista: modificare
/// il contenuto di una nota produce una nuova `List<NoteModel>` a ogni
/// battitura, ma gli id (e quindi l'ordine della lista) restano gli stessi.
/// Il confronto per valore evita di ricostruire il contenitore e tutte le card
/// visibili; ogni card legge poi la propria nota da [notesByIdProvider].
final class FilteredNoteIds {
  const FilteredNoteIds(this.ids);

  final List<String> ids;

  @override
  bool operator ==(Object other) =>
      other is FilteredNoteIds && listEquals(ids, other.ids);

  @override
  int get hashCode => Object.hashAll(ids);
}

/// Mappa id → nota, ricostruita solo quando cambia la lista delle note.
///
/// Le card usano `select` su questa mappa: la modifica di una nota sostituisce
/// solo la sua istanza, quindi Riverpod notifica solo la card interessata.
final notesByIdProvider = Provider<Map<String, NoteModel>>((ref) {
  final notes = ref.watch(notesProvider.select((s) => s.notes));
  return {for (final note in notes) note.id: note};
});

final filteredNoteIdsProvider = Provider<FilteredNoteIds>((ref) {
  final notes = ref.watch(filteredNotesProvider);
  return FilteredNoteIds([for (final note in notes) note.id]);
});
