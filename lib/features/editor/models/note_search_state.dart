/// Stato UI della ricerca INTERNA a una nota (il "Find in note", distinto
/// dalla ricerca globale/per-cartella già gestita da
/// `NotesState.searchQuery` in `notes_provider.dart`).
///
/// Deliberatamente minimale e persistito indipendentemente dalla nota
/// attiva: [isActive]/[query] restano invariati quando l'utente passa da una
/// nota all'altra (si comporta come un pannello "Trova" che resta aperto),
/// mentre gli effettivi risultati (elenco delle occorrenze, indice di quella
/// attiva) sono SEMPRE derivati altrove (vedi `note_search_provider.dart`,
/// `noteSearchMatchesProvider`) a partire da [query] + contenuto della nota
/// correntemente attiva — mai memorizzati qui, per costruzione non possono
/// quindi disallinearsi dal contenuto reale della nota.
class NoteSearchState {
  final bool isActive;
  final String query;

  /// Indice "richiesto" dall'utente (via Avanti/Indietro) all'interno
  /// dell'elenco di occorrenze corrente. Può restare temporaneamente fuori
  /// range (es. subito dopo una modifica del testo che fa sparire alcune
  /// occorrenze): i provider derivati lo clampano sempre in modo sicuro
  /// prima di usarlo, questo campo non deve mai essere letto direttamente
  /// senza passare da lì.
  final int currentMatchIndex;

  const NoteSearchState({
    this.isActive = false,
    this.query = '',
    this.currentMatchIndex = -1,
  });

  NoteSearchState copyWith({
    bool? isActive,
    String? query,
    int? currentMatchIndex,
  }) {
    return NoteSearchState(
      isActive: isActive ?? this.isActive,
      query: query ?? this.query,
      currentMatchIndex: currentMatchIndex ?? this.currentMatchIndex,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NoteSearchState &&
        other.isActive == isActive &&
        other.query == query &&
        other.currentMatchIndex == currentMatchIndex;
  }

  @override
  int get hashCode => Object.hash(isActive, query, currentMatchIndex);
}
