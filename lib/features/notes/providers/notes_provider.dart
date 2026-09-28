import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3: StateNotifier/StateNotifierProvider sono "legacy" (spostati
// in questo import separato, non rimossi). NotesNotifier resta
// deliberatamente una StateNotifier: contiene la logica di autosave/debounce
// (_pendingNote/flushPendingSaves) critica per la correttezza della sync, ed
// è istanziata direttamente (senza ProviderContainer) dai test unitari in
// test/notes_provider_move_test.dart — comportamento che la nuova API
// Notifier non supporta (richiede sempre un container). Riscriverla come
// Notifier/AsyncNotifier è un passo di modernizzazione ulteriore possibile,
// ma va fatto insieme a un riadattamento dei test verso
// ProviderContainer(overrides: [...]) per non perdere copertura.
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/database/notes_dao.dart';
import '../../folders/models/folder_node.dart';
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

  // Uguaglianza per valore (vedi motivazione analoga in `SyncConfig` e
  // `FolderState`). `notes` è confrontata per riferimento: `copyWith` senza
  // passare `notes` mantiene automaticamente lo stesso riferimento di
  // lista, quindi la comparazione per riferimento è già corretta per il
  // caso comune (es. `selectNote`, `setSearchQuery`) senza il costo di un
  // confronto elemento-per-elemento su liste di note potenzialmente grandi.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NotesState &&
        identical(other.notes, notes) &&
        other.searchQuery == searchQuery &&
        other.activeNoteId == activeNoteId &&
        other.sortOrder == sortOrder;
  }

  @override
  int get hashCode => Object.hash(
        identityHashCode(notes),
        searchQuery,
        activeNoteId,
        sortOrder,
      );
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

  /// Tutte le scritture su SQLite avviate dallo stato locale e non ancora
  /// completate. [refreshFromDb] le attende prima di rileggere il DB: senza
  /// questo, una lettura avviata PRIMA di una scrittura locale (es. un
  /// riordino fatto mentre una sync è in corso) restituiva la versione
  /// vecchia e la sovrascriveva allo stato in memoria, facendo "tornare
  /// indietro" la nota appena spostata.
  final Set<Future<void>> _inflightWrites = <Future<void>>{};

  /// Esegue [op] tracciandola in [_inflightWrites]. Il Future restituito non
  /// fallisce mai: un errore di I/O viene loggato invece di diventare
  /// un'eccezione asincrona non gestita.
  Future<void> _persist(Future<void> Function() op) {
    final Future<void> f = () async {
      try {
        await op();
      } catch (e, st) {
        debugPrint('NotesNotifier: scrittura su SQLite fallita: $e\n$st');
      }
    }();
    _inflightWrites.add(f);
    f.whenComplete(() => _inflightWrites.remove(f));
    return f;
  }

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
    if (!mounted) return;
    final notes = _sortNotes(rows.map(NoteModel.fromRow).toList(), state.sortOrder);

    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
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
    // Fino a 3 tentativi: se durante la lettura l'utente ha modificato la
    // lista (riordino, spostamento, pin...), il risultato letto è già
    // obsoleto e applicarlo annullerebbe la modifica appena fatta.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_inflightWrites.isNotEmpty) {
        await Future.wait(List<Future<void>>.of(_inflightWrites));
      }
      if (!mounted) return;
      final before = state.notes;
      final rows = await _dao.getActive();
      if (!mounted) return;
      if (!identical(state.notes, before)) continue; // stato cambiato: rileggi

      var notes = rows.map(NoteModel.fromRow).toList();

      // Una nota con testo ancora in debounce esiste solo in memoria: il DB
      // ha la versione precedente. Va preservata, altrimenti la sync in
      // corso cancellerebbe dalla UI gli ultimi caratteri digitati.
      final pending = _pendingNote;
      if (pending != null) {
        final i = notes.indexWhere((n) => n.id == pending.id);
        if (i != -1 && !pending.updatedAt.isBefore(notes[i].updatedAt)) {
          notes[i] = pending;
        }
      }

      notes = _sortNotes(notes, state.sortOrder);
      final activeStillExists = notes.any((n) => n.id == state.activeNoteId);
      state = state.copyWith(
        notes: notes,
        activeNoteId: () => activeStillExists
            ? state.activeNoteId
            : (notes.isNotEmpty ? notes.first.id : null),
      );
      return;
    }
    // Stato modificato di continuo durante tutti i tentativi: non si applica
    // nulla (le scritture locali sono già in coda); il prossimo refresh
    // riallineerà la lista.
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
      _pendingWrite = _persist(() => _dao.upsert(pending.toRow()));
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
        _pendingWrite = _persist(() => _dao.upsert(toWrite.toRow()));
      }
    });
  }

  static List<NoteModel> _sortNotes(List<NoteModel> list, NoteSortOrder order) {
    final sorted = List<NoteModel>.from(list);
    sorted.sort((a, b) {
      if (order != NoteSortOrder.custom) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      }

      final int primary = switch (order) {
        NoteSortOrder.updatedDesc => b.updatedAt.compareTo(a.updatedAt),
        NoteSortOrder.updatedAsc => a.updatedAt.compareTo(b.updatedAt),
        NoteSortOrder.createdDesc => b.createdAt.compareTo(a.createdAt),
        NoteSortOrder.createdAsc => a.createdAt.compareTo(b.createdAt),
        NoteSortOrder.titleAsc => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        NoteSortOrder.titleDesc => b.title.toLowerCase().compareTo(a.title.toLowerCase()),
        NoteSortOrder.custom => a.orderIndex.compareTo(b.orderIndex),
      };
      if (primary != 0) return primary;

      // Spareggio DETERMINISTICO. `List.sort` di Dart non è stabile: con
      // `order_index` duplicati (note create prima di questa correzione, o
      // arrivate da altri dispositivi) l'ordine visualizzato cambiava da un
      // avvio all'altro, dando l'impressione che il riordino "tornasse
      // indietro".
      if (order == NoteSortOrder.custom) {
        final byUpdated = b.updatedAt.compareTo(a.updatedAt);
        if (byUpdated != 0) return byUpdated;
      }
      return a.id.compareTo(b.id);
    });
    return sorted;
  }

  NoteModel? get activeNote {
    if (state.activeNoteId == null) return null;
    for (final note in state.notes) {
      if (note.id == state.activeNoteId) return note;
    }
    return state.notes.isNotEmpty ? state.notes.first : null;
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
    var notes = state.notes;

    if (order == NoteSortOrder.custom && state.sortOrder != NoteSortOrder.custom) {
      // Passando all'ordine manuale si parte dall'ordine che l'utente sta
      // VEDENDO ora, e lo si rende esplicito e senza duplicati in
      // `order_index` (persistendo solo le note che cambiano). Prima si
      // usavano i vecchi `order_index`, spesso tutti 0 o duplicati, quindi
      // la lista appariva rimescolata e ogni trascinamento partiva da una
      // base incoerente.
      final current = _sortNotes(state.notes, state.sortOrder);
      final now = DateTime.now();
      final changed = <NoteModel>[];
      notes = <NoteModel>[];
      for (var i = 0; i < current.length; i++) {
        final n = current[i];
        if (n.orderIndex != i) {
          final u = n.copyWith(orderIndex: i, updatedAt: now);
          changed.add(u);
          notes.add(u);
        } else {
          notes.add(n);
        }
      }
      if (changed.isNotEmpty) {
        unawaited(_persist(() => _dao.upsertBatch(changed.map((n) => n.toRow()).toList())));
      }
    }

    state = state.copyWith(notes: _sortNotes(notes, order), sortOrder: order);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.prefSortMode, order.name);
  }

  /// Riordina manualmente le note (trascina e rilascia).
  ///
  /// [oldIndex]/[newIndex] sono indici nella lista MOSTRATA all'utente, che
  /// con una cartella selezionata è solo un sottoinsieme di `state.notes`
  /// (vedi `filteredNotesProvider`). [visibleIds] è quindi l'elenco degli id
  /// mostrati, nello stesso ordine: le note visibili vengono ridisposte
  /// negli STESSI slot che già occupavano nella lista globale, mentre le
  /// note non visibili restano dove sono.
  ///
  /// BUG CORRETTO: prima gli indici della lista filtrata venivano applicati
  /// direttamente alla lista globale, quindi con una cartella selezionata si
  /// spostava una nota SBAGLIATA e quella trascinata "tornava indietro".
  ///
  /// Solo le note il cui `order_index` cambia davvero vengono riscritte (e
  /// hanno `updated_at` aggiornato): un riordino non genera più un push di
  /// tutte le note dell'archivio.
  void reorderNotes(int oldIndex, int newIndex, {List<String>? visibleIds}) {
    unawaited(flushPendingSaves());
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

    final global = _sortNotes(state.notes, NoteSortOrder.custom);
    final visible = visibleIds ?? global.map((n) => n.id).toList();
    if (oldIndex < 0 || oldIndex >= visible.length) return;
    newIndex = newIndex.clamp(0, visible.length - 1);
    if (oldIndex == newIndex) return;

    final reorderedVisible = List<String>.from(visible);
    reorderedVisible.insert(newIndex, reorderedVisible.removeAt(oldIndex));

    final visibleSet = visible.toSet();
    final byId = <String, NoteModel>{for (final n in global) n.id: n};
    final slots = <int>[
      for (var i = 0; i < global.length; i++)
        if (visibleSet.contains(global[i].id)) i,
    ];
    // Lista mostrata ormai obsoleta (nota cancellata/sincronizzata nel
    // frattempo): meglio ignorare il gesto che spostare la nota sbagliata.
    if (slots.length != reorderedVisible.length) return;
    if (reorderedVisible.any((id) => !byId.containsKey(id))) return;

    final arranged = List<NoteModel>.from(global);
    for (var k = 0; k < slots.length; k++) {
      arranged[slots[k]] = byId[reorderedVisible[k]]!;
    }

    final now = DateTime.now();
    final changed = <NoteModel>[];
    final result = <NoteModel>[];
    for (var i = 0; i < arranged.length; i++) {
      final n = arranged[i];
      if (n.orderIndex != i) {
        final u = n.copyWith(orderIndex: i, updatedAt: now);
        changed.add(u);
        result.add(u);
      } else {
        result.add(n);
      }
    }

    state = state.copyWith(notes: result, sortOrder: NoteSortOrder.custom);
    if (changed.isNotEmpty) {
      unawaited(_persist(() => _dao.upsertBatch(changed.map((n) => n.toRow()).toList())));
    }
  }

  /// Inserisce in blocco un elenco di note nuove (usato dall'importazione,
  /// vedi `import_service.dart`), es. da un backup ZIP o da una cartella
  /// locale di file Markdown.
  ///
  /// PERCHÉ un metodo dedicato invece di richiamare N volte [createNote] +
  /// [updateNote] in un loop:
  ///  - [updateNote] passa dal debounce di autosave condiviso
  ///    ([_pendingNote]/[_debouncedPersist]), pensato per UNA sola nota
  ///    attiva sotto digitazione dell'utente: chiamarlo in sequenza per N
  ///    note diverse farebbe sì che solo l'ULTIMA di ogni "burst" venga
  ///    davvero scritta su disco dal timer, perdendo silenziosamente il
  ///    contenuto delle altre. Qui ogni nota viene invece scritta subito
  ///    (`_dao.upsert`), esattamente come già fa [createNote] per la singola
  ///    nota vuota creata da UI.
  ///  - Un solo aggiornamento dello stato Riverpod per l'intero batch (non
  ///    uno per nota), per evitare N rebuild della UI durante un import di
  ///    centinaia di note.
  ///  - Non tocca [activeNoteId]: l'utente resta sulla nota che stava
  ///    guardando, l'importazione avviene "in background" rispetto alla UI.
  ///
  /// Non sovrascrive MAI note esistenti: ogni voce importata riceve sempre
  /// un nuovo id (`_uuid.v4()`), quindi il risultato è per costruzione solo
  /// additivo rispetto ai dati già presenti.
  Future<int> importNotesBulk(
    List<({String title, String content, String? folderId})> items,
  ) async {
    if (items.isEmpty) return 0;

    final now = DateTime.now();
    // Dopo il massimo esistente (non `length`): gli indici possono avere
    // buchi o valori negativi (vedi createNote).
    final baseIndex = state.notes.isEmpty
        ? 0
        : state.notes.map((n) => n.orderIndex).reduce((a, b) => a > b ? a : b) + 1;
    final newNotes = <NoteModel>[
      for (var i = 0; i < items.length; i++)
        NoteModel(
          id: _uuid.v4(),
          title: items[i].title,
          content: items[i].content,
          folderId: items[i].folderId,
          createdAt: now,
          updatedAt: now,
          orderIndex: baseIndex + i,
        ),
    ];

    state = state.copyWith(
      notes: _sortNotes([...state.notes, ...newNotes], state.sortOrder),
    );

    unawaited(_persist(() => _dao.upsertBatch(newNotes.map((n) => n.toRow()).toList())));

    return newNotes.length;
  }

  NoteModel createNote({String? folderId}) {
    unawaited(flushPendingSaves());
    final now = DateTime.now();
    // La nuova nota va in cima all'ordine manuale con un indice INFERIORE al
    // minimo esistente, invece di incrementare in memoria l'indice di tutte
    // le altre: quell'incremento non veniva mai scritto su SQLite, quindi
    // in DB restavano molte note con lo stesso `order_index` e, al riavvio,
    // l'ordine manuale risultava scombinato.
    final newOrderIndex = state.notes.isEmpty
        ? 0
        : state.notes.map((n) => n.orderIndex).reduce((a, b) => a < b ? a : b) - 1;
    final newNote = NoteModel(
      id: _uuid.v4(),
      title: '',
      content: '',
      folderId: folderId,
      createdAt: now,
      updatedAt: now,
      orderIndex: newOrderIndex,
    );

    state = state.copyWith(
      notes: _sortNotes([newNote, ...state.notes], state.sortOrder),
      activeNoteId: () => newNote.id,
    );
    unawaited(_persist(() => _dao.upsert(newNote.toRow())));
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
    // Scrive PRIMA l'eventuale testo ancora in debounce: altrimenti il timer
    // (che tiene una copia VECCHIA della nota, con il vecchio `folder_id`)
    // scatterebbe dopo lo spostamento e, con `ConflictAlgorithm.replace`,
    // riporterebbe la nota nella cartella di origine.
    unawaited(flushPendingSaves());
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
    unawaited(_persist(() => _dao.upsert(updatedNote.toRow())));
  }

  void deleteNote(String id) {
    // Stessa causa di moveNote: una scrittura in debounce non ancora
    // eseguita sovrascriverebbe il tombstone e la nota "risorgerebbe".
    unawaited(flushPendingSaves());
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
    unawaited(_persist(() => _dao.upsert(tombstoneRow)));
  }

  void togglePin(String id) {
    unawaited(flushPendingSaves()); // vedi moveNote
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index == -1) return;

    final existing = state.notes[index];
    final updatedNote = existing.copyWith(isPinned: !existing.isPinned, updatedAt: DateTime.now());

    final updatedList = List<NoteModel>.from(state.notes);
    updatedList[index] = updatedNote;

    state = state.copyWith(notes: _sortNotes(updatedList, state.sortOrder));
    unawaited(_persist(() => _dao.upsert(updatedNote.toRow())));
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
  for (final note in notes) {
    if (note.id == activeNoteId) return note;
  }
  return notes.isNotEmpty ? notes.first : null;
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
    // La ricerca "per cartella" include l'intero sottoalbero (la cartella
    // selezionata più TUTTE le sue sottocartelle, ricorsivamente), non solo
    // le note con `folderId` esattamente uguale a quello selezionato: vedi
    // FolderNode.collectSubtreeIds. Coerente con FolderTreeView, che mostra
    // già le sottocartelle annidate visivamente sotto il genitore, non come
    // sezioni indipendenti.
    final rootFolders = ref.watch(folderProvider.select((s) => s.rootFolders));
    final scopeIds = FolderNode.collectSubtreeIds(rootFolders, selectedFolderId);
    filtered = filtered.where((n) => n.folderId != null && scopeIds.contains(n.folderId)).toList();
  }

  if (searchQuery.trim().isNotEmpty) {
    final q = searchQuery.toLowerCase().trim();
    filtered = filtered.where((n) {
      return n.title.toLowerCase().contains(q) || n.content.toLowerCase().contains(q);
    }).toList();
  }

  return filtered;
});
