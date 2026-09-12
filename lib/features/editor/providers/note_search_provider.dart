import 'package:flutter/services.dart' show TextRange;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notes/providers/notes_provider.dart';
import '../models/note_search_state.dart';

/// Gestisce SOLO lo stato UI della ricerca interna alla nota (aperta/chiusa,
/// termine cercato, indice dell'occorrenza attiva). Non calcola mai da solo
/// le occorrenze: quello è compito dei provider derivati più sotto
/// ([noteSearchMatchesProvider] e affini), che restano sempre sincronizzati
/// col contenuto REALE della nota attiva in quel momento (mai una copia
/// cache-ata che potrebbe disallinearsi durante la digitazione).
class NoteSearchNotifier extends Notifier<NoteSearchState> {
  @override
  NoteSearchState build() => const NoteSearchState();

  /// Apre il pannello di ricerca. Se [initialQuery] è fornito (tipicamente
  /// perché l'utente ha aperto la nota da un risultato della ricerca
  /// globale/per-cartella, vedi `notes_list_view.dart`), sostituisce
  /// immediatamente il termine cercato con quello, così le occorrenze
  /// risultano già evidenziate all'apertura della nota — altrimenti
  /// preserva il termine eventualmente già impostato in precedenza (il
  /// pannello si comporta come un "Trova" persistente tra una nota e
  /// l'altra, non si azzera implicitamente cambiando nota).
  void open({String? initialQuery}) {
    state = NoteSearchState(
      isActive: true,
      query: initialQuery ?? state.query,
      currentMatchIndex: 0,
    );
  }

  /// Chiude il pannello e azzera completamente lo stato (termine cercato
  /// incluso): un successivo [open] senza [initialQuery] riparte da zero.
  void close() {
    state = const NoteSearchState();
  }

  void setQuery(String query) {
    state = state.copyWith(query: query, currentMatchIndex: 0);
  }

  /// Occorrenza successiva, con wraparound. [totalMatches] è passato dal
  /// chiamante (che lo legge da [noteSearchMatchesProvider]) invece di
  /// essere ricalcolato qui: questo notifier non ha accesso al contenuto
  /// della nota e non deve duplicarne la logica di ricerca.
  void nextMatch(int totalMatches) {
    if (totalMatches <= 0) return;
    final current = state.currentMatchIndex < 0 ? 0 : state.currentMatchIndex;
    state = state.copyWith(currentMatchIndex: (current + 1) % totalMatches);
  }

  void previousMatch(int totalMatches) {
    if (totalMatches <= 0) return;
    final current = state.currentMatchIndex < 0 ? 0 : state.currentMatchIndex;
    state = state.copyWith(
      currentMatchIndex: (current - 1 + totalMatches) % totalMatches,
    );
  }
}

final noteSearchProvider =
    NotifierProvider<NoteSearchNotifier, NoteSearchState>(
  NoteSearchNotifier.new,
);

/// Elenco delle occorrenze (case-insensitive, non sovrapposte) del termine
/// cercato all'interno del CONTENUTO della nota attualmente attiva.
///
/// Puramente derivato (come [filteredNotesProvider] in
/// `notes_provider.dart`): nessuno stato proprio, ricalcolato ogni volta che
/// cambia il termine cercato o il contenuto della nota attiva (quindi anche
/// carattere per carattere durante la digitazione, se il pannello di
/// ricerca è aperto mentre si modifica la nota) — non può quindi mai
/// disallinearsi da ciò che l'utente vede realmente a schermo.
///
/// Il campo di ricerca considera solo il CORPO della nota, non il titolo:
/// il titolo è sempre una singola riga già visibile per intero in cima
/// all'editor/alla vista di lettura, evidenziarlo non aggiungerebbe alcun
/// valore di navigazione e complicherebbe la gestione di due sorgenti di
/// offset separate (titolo vs corpo) per un beneficio pressoché nullo.
///
/// Limite di sicurezza [_maxNoteSearchMatches]: una nota enorme combinata con un
/// termine di ricerca di un solo carattere molto comune potrebbe altrimenti
/// produrre decine di migliaia di occorrenze, con un costo di costruzione
/// spans (sia nell'editor sia nella vista di sola lettura) sproporzionato
/// rispetto a qualunque reale utilità di navigazione.
const int _maxNoteSearchMatches = 2000;

final noteSearchMatchesProvider = Provider<List<TextRange>>((ref) {
  final query =
      ref.watch(noteSearchProvider.select((s) => s.query)).trim();
  if (query.isEmpty) return const [];

  final content =
      ref.watch(activeNoteProvider.select((n) => n?.content ?? ''));
  if (content.isEmpty) return const [];

  final lowerContent = content.toLowerCase();
  final lowerQuery = query.toLowerCase();

  final matches = <TextRange>[];
  var searchStart = 0;
  while (matches.length < _maxNoteSearchMatches) {
    final idx = lowerContent.indexOf(lowerQuery, searchStart);
    if (idx == -1) break;
    matches.add(TextRange(start: idx, end: idx + lowerQuery.length));
    searchStart = idx + lowerQuery.length;
  }
  return matches;
});

/// Indice CLAMPATO in modo sicuro dell'occorrenza attiva all'interno di
/// [noteSearchMatchesProvider]. `-1` se non ci sono occorrenze.
///
/// `NoteSearchState.currentMatchIndex` può temporaneamente puntare fuori
/// range (es. l'utente cancella del testo mentre il pannello è aperto e
/// alcune occorrenze spariscono): questo provider è l'UNICO punto da cui gli
/// altri widget devono leggere l'indice attivo, cosicché quel caso limite
/// non richieda mai una gestione ad-hoc ripetuta in ciascun chiamante.
final noteSearchActiveMatchIndexProvider = Provider<int>((ref) {
  final matches = ref.watch(noteSearchMatchesProvider);
  if (matches.isEmpty) return -1;

  final requested =
      ref.watch(noteSearchProvider.select((s) => s.currentMatchIndex));
  if (requested < 0) return 0;
  return requested % matches.length;
});

/// Range di testo (offset di inizio/fine nel contenuto) dell'occorrenza
/// attualmente attiva, o `null` se non ce n'è una. Usato dai widget che
/// devono "portare a schermo" quel punto esatto (vedi
/// `MarkdownEditorField.activeSearchMatch` e `NoteSearchHighlightedView`).
final activeNoteSearchMatchProvider = Provider<TextRange?>((ref) {
  final matches = ref.watch(noteSearchMatchesProvider);
  final index = ref.watch(noteSearchActiveMatchIndexProvider);
  if (index < 0 || index >= matches.length) return null;
  return matches[index];
});

/// Coppia (occorrenze, indice attivo) osservata in un solo colpo da
/// `NoteEditorPane` tramite `ref.listen`, per propagare gli aggiornamenti a
/// `SearchHighlightingTextEditingController.setMatches` con un'unica
/// chiamata invece di due `ref.listen` separati che dovrebbero comunque
/// essere applicati atomicamente insieme.
typedef NoteSearchHighlightData = (List<TextRange>, int);

final noteSearchHighlightDataProvider = Provider<NoteSearchHighlightData>((ref) {
  final matches = ref.watch(noteSearchMatchesProvider);
  final activeIndex = ref.watch(noteSearchActiveMatchIndexProvider);
  return (matches, activeIndex);
});
