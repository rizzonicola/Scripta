import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/database/notes_dao.dart';
import '../../folders/providers/folder_provider.dart';
import '../models/note_model.dart';

class NotesState {
  final List<NoteModel> notes;
  final String searchQuery;
  final String? activeNoteId;
  final NoteSortOrder sortOrder;

  const NotesState({
    this.notes = const [],
    this.searchQuery = '',
    this.activeNoteId,
    this.sortOrder = NoteSortOrder.updatedDesc,
  });

  NotesState copyWith({
    List<NoteModel>? notes,
    String? searchQuery,
    String? Function()? activeNoteId,
    NoteSortOrder? sortOrder,
  }) {
    return NotesState(
      notes: notes ?? this.notes,
      searchQuery: searchQuery ?? this.searchQuery,
      activeNoteId: activeNoteId != null ? activeNoteId() : this.activeNoteId,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}

/// Gestisce l'elenco delle note sopra il database locale SQLite ([NotesDao]).
///
/// PRINCIPI ARCHITETTURALI:
///  - Nessuna dipendenza da percorsi: creare, modificare, spostare o
///    cancellare una nota sono sempre operazioni per ID (`UPDATE ... WHERE
///    id = ?`), mai un rename/riscrittura di file.
///  - Zero seeding: al primo avvio, se il database locale è vuoto, l'elenco
///    resta semplicemente vuoto (la UI mostra già un pannello "Nessuna nota,
///    creane una" per questo caso, vedi note_editor_pane.dart). Nessuna nota
///    di benvenuto fittizia viene MAI scritta nel database, quindi non può
///    mai essere spinta per errore sul server durante la prima sync.
///  - "Tutte le note" e "note per cartella" sono entrambe derivate dalla
///    STESSA lista in memoria (`state.notes`, rispecchio 1:1 delle righe
///    attive del DB): la seconda è un filtro `where folder_id == X` della
///    prima, applicato da [filteredNotesProvider] — mai una query separata.
class NotesNotifier extends StateNotifier<NotesState> {
  final NotesDao _dao;
  final _uuid = const Uuid();
  Timer? _saveDebounceTimer;

  /// La nota con modifiche testuali non ancora scritte su SQLite, catturata
  /// ESPLICITAMENTE al momento della battitura (vedi [_debouncedPersist]).
  ///
  /// QUESTA è la vera causa radice del bug di sincronizzazione, residua
  /// anche dopo aver reso `flushPendingSaves()` un `Future<void>` atteso:
  /// la versione precedente di `flushPendingSaves()` non riscriveva QUESTA
  /// nota, ma rileggeva `activeNote`, cioè la deriva a runtime da
  /// `state.activeNoteId`. Questo funziona SOLO quando chi chiama il flush
  /// è la stessa UI dell'editor, che per costruzione flusha PRIMA di
  /// cambiare `activeNoteId` (vedi `selectNote`, `note_editor_pane.dart`).
  ///
  /// `SyncNotifier.triggerSync()`, però, non è la UI dell'editor: vive in un
  /// provider completamente separato e chiama `flushPendingSaves()` da
  /// trigger esterni (pulsante manuale, avvio app, lifecycle, inattività)
  /// che non hanno alcun controllo né alcuna garanzia su cosa sia
  /// `activeNoteId` in quel preciso istante. Se, quando quel flush esterno
  /// arriva, `activeNoteId` è già `null` (nessuna nota aperta in quel
  /// momento) oppure punta a una nota diversa da quella che aveva davvero
  /// una modifica in sospeso, `activeNote` restituisce la nota SBAGLIATA (o
  /// nessuna): l'upsert scrive la nota sbagliata (o non scrive nulla), la
  /// modifica testuale resta sporca solo nel debounce mai committato, e
  /// `listDirtySince` — interrogata subito dopo — non la trova. Risultato
  /// osservato: il pulsante manuale e i trigger automatici mostrano
  /// "successo" (perché tecnicamente hanno contattato o verificato il
  /// server) ma non inviano MAI la modifica realmente pendente; l'unico
  /// caso che funzionava per davvero (chiusura/cambio nota) lo faceva solo
  /// perché quel percorso flusha ESPLICITAMENTE la nota giusta PRIMA di
  /// alterare `activeNoteId`, mascherando il difetto.
  ///
  /// La correzione: tracciare direttamente l'OGGETTO nota in sospeso (non
  /// il suo id derivato da uno stato che può cambiare sotto i piedi), così
  /// `flushPendingSaves()` scrive sempre e solo la modifica realmente in
  /// sospeso, indipendentemente da chi la chiama e da cosa sia
  /// `activeNoteId` in quel momento.
  NoteModel? _pendingNote;

  /// Riferimento alla scrittura più recente avviata (dal debounce naturale
  /// o da un flush esplicito), cosicché un flush concorrente possa
  /// attendere una scrittura già in corso invece di limitarsi a controllare
  /// se un timer esiste ancora.
  Future<void>? _pendingWrite;

  NotesNotifier({NotesDao? dao})
      : _dao = dao ?? NotesDao(),
        super(const NotesState()) {
    _loadFromDb();
  }

  @override
  void dispose() {
    // dispose() non può essere async: qui il flush resta best-effort
    // (fire-and-forget) perché non c'è più alcun chiamante che possa
    // attenderlo in modo sensato. Tutti gli altri chiamanti "vivi"
    // (in particolare SyncNotifier.triggerSync) DEVONO invece attendere
    // realmente il Future restituito da flushPendingSaves, altrimenti la
    // sync rischia di leggere il database PRIMA che questa scrittura sia
    // stata effettivamente committata (vedi flushPendingSaves).
    unawaited(flushPendingSaves());
    super.dispose();
  }

  Future<void> _loadFromDb() async {
    final rows = await _dao.getActive();
    final notes = _sortNotes(rows.map(NoteModel.fromRow).toList(), state.sortOrder);

    final prefs = await SharedPreferences.getInstance();
    final sortStr = prefs.getString(AppConstants.prefSortMode);
    var sortOrder = state.sortOrder;
    if (sortStr != null) {
      for (final val in NoteSortOrder.values) {
        if (val.name == sortStr) {
          sortOrder = val;
          break;
        }
      }
    }

    state = state.copyWith(
      notes: _sortNotes(notes, sortOrder),
      activeNoteId: () => notes.isNotEmpty ? notes.first.id : null,
      sortOrder: sortOrder,
    );
  }

  /// Ricarica l'elenco note dal database locale, preservando la nota
  /// attualmente attiva se ancora presente. Usato dopo una sync (per
  /// riflettere le modifiche remote appena applicate al DB) e dopo una
  /// cascade di cancellazione di una cartella (vedi FolderNotifier.deleteFolder).
  Future<void> refreshFromDb() async {
    final rows = await _dao.getActive();
    final notes = _sortNotes(rows.map(NoteModel.fromRow).toList(), state.sortOrder);
    final activeStillExists = notes.any((n) => n.id == state.activeNoteId);
    state = state.copyWith(
      notes: notes,
      activeNoteId: () => activeStillExists ? state.activeNoteId : (notes.isNotEmpty ? notes.first.id : null),
    );
  }

  /// Cancella il debounce di autosave pendente e scrive IMMEDIATAMENTE (e in
  /// modo realmente atteso) l'ultima versione della nota con modifiche non
  /// ancora salvate su SQLite.
  ///
  /// CRITICO (parte 1, già presente): questo metodo restituisce un
  /// `Future<void>` che i chiamanti DEVONO awaitare quando la scrittura va
  /// garantita prima di un'operazione successiva (in primis
  /// `SyncNotifier.triggerSync`, che subito dopo interroga `listDirtySince`
  /// per decidere cosa inviare al server).
  ///
  /// CRITICO (parte 2, la causa radice reale): la scrittura avviene sempre
  /// sull'oggetto [_pendingNote] catturato esplicitamente al momento della
  /// battitura, MAI su `activeNote`/`state.activeNoteId`. Chi chiama questo
  /// metodo da fuori dal contesto dell'editor (tipicamente
  /// `SyncNotifier.triggerSync`, invocato da pulsante manuale, avvio app,
  /// lifecycle o timer di inattività) non ha alcuna garanzia su cosa sia
  /// `activeNoteId` in quel momento: potrebbe essere già `null`, oppure
  /// puntare a una nota diversa da quella che aveva davvero una modifica
  /// pendente. Derivare la nota da salvare da quello stato mutabile è
  /// esattamente ciò che permetteva alla modifica realmente in sospeso di
  /// non essere mai scritta (quindi mai vista da `listDirtySince`, quindi
  /// mai inviata al server, pur con l'`await` già corretto). Il trigger su
  /// cambio/chiusura nota risultava l'unico affidabile solo perché quel
  /// percorso (`selectNote`) flusha esplicitamente la nota giusta PRIMA di
  /// alterare `activeNoteId`, mascherando per coincidenza il difetto.
  Future<void> flushPendingSaves() async {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;

    final pending = _pendingNote;
    _pendingNote = null;
    if (pending != null) {
      _pendingWrite = _dao.upsert(pending.toRow());
    }

    // Attende anche una scrittura eventualmente già avviata (dal debounce
    // naturale o da un flush precedente) e non ancora completata: senza
    // questo, un flush concorrente potrebbe considerarsi "finito" mentre
    // l'upsert reale è ancora in volo.
    final inFlight = _pendingWrite;
    if (inFlight != null) {
      await inFlight;
      if (identical(_pendingWrite, inFlight)) {
        _pendingWrite = null;
      }
    }
  }

  void _debouncedPersist(NoteModel note) {
    _pendingNote = note;
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _saveDebounceTimer = null;
      final toWrite = _pendingNote;
      _pendingNote = null;
      if (toWrite != null) {
        _pendingWrite = _dao.upsert(toWrite.toRow());
      }
    });
  }

  static List<NoteModel> _sortNotes(List<NoteModel> list, NoteSortOrder order) {
    final sorted = List<NoteModel>.from(list);
    sorted.sort((a, b) {
      if (order != NoteSortOrder.custom) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      }

      switch (order) {
        case NoteSortOrder.updatedDesc:
          return b.updatedAt.compareTo(a.updatedAt);
        case NoteSortOrder.updatedAsc:
          return a.updatedAt.compareTo(b.updatedAt);
        case NoteSortOrder.createdDesc:
          return b.createdAt.compareTo(a.createdAt);
        case NoteSortOrder.createdAsc:
          return a.createdAt.compareTo(b.createdAt);
        case NoteSortOrder.titleAsc:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case NoteSortOrder.titleDesc:
          return b.title.toLowerCase().compareTo(a.title.toLowerCase());
        case NoteSortOrder.custom:
          return a.orderIndex.compareTo(b.orderIndex);
      }
    });
    return sorted;
  }

  NoteModel? get activeNote {
    if (state.activeNoteId == null) return null;
    try {
      return state.notes.firstWhere((n) => n.id == state.activeNoteId);
    } catch (_) {
      return state.notes.isNotEmpty ? state.notes.first : null;
    }
  }

  void selectNote(String? id) {
    if (state.activeNoteId != id) {
      // Fire-and-forget qui è accettabile: si sta solo cambiando la nota
      // attiva in UI, non si sta per interrogare "cosa è dirty" subito dopo
      // (a differenza di SyncNotifier.triggerSync, che invece DEVE attendere).
      unawaited(flushPendingSaves());
      final sorted = _sortNotes(state.notes, state.sortOrder);
      state = state.copyWith(notes: sorted, activeNoteId: () => id);
    }
  }

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  Future<void> setSortOrder(NoteSortOrder order) async {
    unawaited(flushPendingSaves());
    final sorted = _sortNotes(state.notes, order);
    state = state.copyWith(notes: sorted, sortOrder: order);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefSortMode, order.name);
  }

  void reorderNotes(int oldIndex, int newIndex) {
    unawaited(flushPendingSaves());
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

    final updated = List<NoteModel>.from(state.notes);
    final item = updated.removeAt(oldIndex);
    updated.insert(newIndex, item);

    final now = DateTime.now();
    final reindexed = <NoteModel>[];
    for (var i = 0; i < updated.length; i++) {
      reindexed.add(updated[i].copyWith(orderIndex: i, updatedAt: now));
    }

    state = state.copyWith(notes: reindexed, sortOrder: NoteSortOrder.custom);
    unawaited(_persistAll(reindexed));
  }

  Future<void> _persistAll(List<NoteModel> notes) async {
    for (final n in notes) {
      await _dao.upsert(n.toRow());
    }
  }

  NoteModel createNote({String? folderId}) {
    unawaited(flushPendingSaves());
    final now = DateTime.now();
    final newNote = NoteModel(
      id: _uuid.v4(),
      title: '',
      content: '',
      folderId: folderId,
      createdAt: now,
      updatedAt: now,
      orderIndex: 0,
    );

    final updated = [
      newNote,
      ...state.notes.map((n) => n.copyWith(orderIndex: n.orderIndex + 1)),
    ];

    state = state.copyWith(
      notes: _sortNotes(updated, state.sortOrder),
      activeNoteId: () => newNote.id,
    );
    unawaited(_dao.upsert(newNote.toRow()));
    return newNote;
  }

  void updateNote(String id, {String? title, String? content}) {
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index == -1) return;

    final existing = state.notes[index];
    final updatedNote = existing.copyWith(
      title: title ?? existing.title,
      content: content ?? existing.content,
      updatedAt: DateTime.now(),
    );

    final updatedList = List<NoteModel>.from(state.notes);
    updatedList[index] = updatedNote;

    state = state.copyWith(notes: updatedList);
    _debouncedPersist(updatedNote);
  }

  /// Sposta una nota in un'altra cartella (o fuori da ogni cartella, se
  /// `targetFolderId` è null). Semplice aggiornamento di `folder_id`: nessun
  /// "vecchio percorso / nuovo percorso" da tenere in giro per la sync, a
  /// differenza della generazione precedente basata su file.
  void moveNote(String id, String? targetFolderId) {
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index == -1) return;

    final existing = state.notes[index];
    if (existing.folderId == targetFolderId) return;

    final updatedNote = existing.copyWith(
      folderId: () => targetFolderId,
      updatedAt: DateTime.now(),
    );

    final updatedList = List<NoteModel>.from(state.notes);
    updatedList[index] = updatedNote;

    state = state.copyWith(notes: _sortNotes(updatedList, state.sortOrder));
    unawaited(_dao.upsert(updatedNote.toRow()));
  }

  void deleteNote(String id) {
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index == -1) return;

    final nowMillis = DateTime.now().toUtc().millisecondsSinceEpoch;
    final tombstoneRow = state.notes[index]
        .toRow(deletedAt: nowMillis)
        .copyWith(updatedAt: nowMillis);

    final updatedList = state.notes.where((n) => n.id != id).toList();
    String? nextActiveId;
    if (state.activeNoteId == id) {
      nextActiveId = updatedList.isNotEmpty ? updatedList.first.id : null;
    } else {
      nextActiveId = state.activeNoteId;
    }

    state = state.copyWith(notes: updatedList, activeNoteId: () => nextActiveId);
    unawaited(_dao.upsert(tombstoneRow));
  }

  void togglePin(String id) {
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index == -1) return;

    final existing = state.notes[index];
    final updatedNote = existing.copyWith(isPinned: !existing.isPinned, updatedAt: DateTime.now());

    final updatedList = List<NoteModel>.from(state.notes);
    updatedList[index] = updatedNote;

    state = state.copyWith(notes: _sortNotes(updatedList, state.sortOrder));
    unawaited(_dao.upsert(updatedNote.toRow()));
  }

  void toggleFavorite(String id) {
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index == -1) return;

    final existing = state.notes[index];
    final updatedNote = existing.copyWith(isFavorite: !existing.isFavorite, updatedAt: DateTime.now());
    final updatedList = List<NoteModel>.from(state.notes);
    updatedList[index] = updatedNote;

    state = state.copyWith(notes: updatedList);
    unawaited(_dao.upsert(updatedNote.toRow()));
  }
}

final notesProvider = StateNotifierProvider<NotesNotifier, NotesState>((ref) {
  return NotesNotifier();
});

/// Provider for the currently active note
final activeNoteProvider = Provider<NoteModel?>((ref) {
  final activeNoteId = ref.watch(notesProvider.select((s) => s.activeNoteId));
  if (activeNoteId == null) return null;
  final notes = ref.watch(notesProvider.select((s) => s.notes));
  try {
    return notes.firstWhere((n) => n.id == activeNoteId);
  } catch (_) {
    return notes.isNotEmpty ? notes.first : null;
  }
});

/// Provider for filtered notes based on folder and search query.
///
/// Vista puramente derivata: legge la STESSA lista di [notesProvider] e la
/// filtra in memoria. Non esegue mai una query separata sul database, il che
/// garantisce per costruzione che "Tutte le note" e "note della cartella X"
/// non possano mai disallinearsi tra loro.
final filteredNotesProvider = Provider<List<NoteModel>>((ref) {
  final notes = ref.watch(notesProvider.select((s) => s.notes));
  final selectedFolderId = ref.watch(folderProvider.select((s) => s.selectedFolderId));
  final searchQuery = ref.watch(notesProvider.select((s) => s.searchQuery));

  var filtered = notes;

  if (selectedFolderId != null) {
    filtered = filtered.where((n) => n.folderId == selectedFolderId).toList();
  }

  if (searchQuery.trim().isNotEmpty) {
    final q = searchQuery.toLowerCase().trim();
    filtered = filtered.where((n) {
      return n.title.toLowerCase().contains(q) || n.content.toLowerCase().contains(q);
    }).toList();
  }

  return filtered;
});
