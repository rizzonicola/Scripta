import 'dart:async';
import 'dart:convert';

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
import '../../../core/services/session_state_service.dart';
import '../../../core/utils/perf_marks.dart';
import '../../folders/models/folder_node.dart';
import '../../folders/providers/folder_provider.dart';
import '../models/note_model.dart';

/// Nota da inserire in blocco durante un'importazione. I campi opzionali
/// arrivano dal manifest dei backup: senza manifest valgono i default
/// (data/ordine di importazione, nessun metadato).
class ImportedNote {
  final String title;
  final String content;
  final String? folderId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool isFavorite;
  final bool isPinned;
  final int? orderIndex;

  const ImportedNote({
    required this.title,
    required this.content,
    required this.folderId,
    this.createdAt,
    this.updatedAt,
    this.isFavorite = false,
    this.isPinned = false,
    this.orderIndex,
  });
}

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

  /// Nota che era aperta nell'ultima sessione (vedi [sessionSnapshotProvider]),
  /// da riaprire al primo caricamento da DB. Si consuma UNA volta in
  /// [_loadFromDb] e poi resta `null`: è solo un riferimento da validare (la
  /// nota potrebbe essere stata cancellata nel frattempo), non uno stato.
  ///
  /// Volutamente NON messa in `state.activeNoteId` fin dal costruttore: finché
  /// la lista `notes` è vuota, un id attivo farebbe mostrare all'editor un
  /// campo di testo vuoto e modificabile per una nota non ancora caricata. Così
  /// il primo `activeNoteId` non nullo arriva insieme alle note.
  String? _restoreActiveNoteId;

  // ---------------------------------------------------------------------
  // Ordinamento PER VISTA
  // ---------------------------------------------------------------------
  // Ogni vista ("Tutte le note" e ciascuna cartella) ha il PROPRIO criterio
  // di ordinamento e, per le cartelle, il proprio ordine manuale. `state.notes`
  // e `state.sortOrder` rispecchiano sempre la vista corrente ([_scope]);
  // cambiando cartella si ricalcolano con le impostazioni di quella vista
  // (vedi [setScope]).
  //
  //  - "Tutte le note": l'ordine manuale usa `order_index` (sincronizzato).
  //  - Cartella: l'ordine manuale è un elenco di id locale a quella cartella
  //    (SharedPreferences), quindi riordinare lì NON tocca le altre viste né
  //    `updated_at`. Le note non presenti nell'elenco (nuove, spostate o
  //    importate) compaiono in cima.
  static const String _allScope = 'all';
  String _scope = _allScope;
  NoteSortOrder _defaultSort = NoteSortOrder.updatedDesc;
  final Map<String, NoteSortOrder> _sortModes = <String, NoteSortOrder>{};
  final Map<String, List<String>> _folderCustomOrders =
      <String, List<String>>{};

  NoteSortOrder _sortFor(String scope) => _sortModes[scope] ?? _defaultSort;

  static NoteSortOrder? _parseSort(String? name) {
    if (name == null) return null;
    for (final v in NoteSortOrder.values) {
      if (v.name == name) return v;
    }
    return null;
  }

  /// Cambia la vista corrente (null = "Tutte le note", altrimenti l'id della
  /// cartella selezionata) e riordina la lista secondo le impostazioni PROPRIE
  /// di quella vista.
  void setScope(String? folderId) {
    final key = folderId ?? _allScope;
    if (key == _scope) return;
    flushPendingSavesInBackground();
    _scope = key;
    final order = _sortFor(key);
    state = state.copyWith(notes: _sort(state.notes, order), sortOrder: order);
  }

  Future<void> _persistSortModes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      AppConstants.prefSortModeByScope,
      jsonEncode({for (final e in _sortModes.entries) e.key: e.value.name}),
    );
  }

  Future<void> _persistFolderOrders() async {
    final alive = state.notes.map((n) => n.id).toSet();
    // Si scartano gli id di note non più esistenti, così l'elenco non cresce
    // indefinitamente.
    final cleaned = <String, List<String>>{
      for (final e in _folderCustomOrders.entries)
        e.key: e.value.where(alive.contains).toList(),
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        AppConstants.prefCustomOrderByScope, jsonEncode(cleaned));
  }

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
  Future<void> _persist(Future<void> Function() op) =>
      _trackPersist(op, rethrowOnError: false);

  /// Variante per le scritture che il chiamante DEVE poter verificare
  /// (import, flush prima della sync): l'errore viene propagato, così non si
  /// mostra un successo per dati che non sono finiti su SQLite.
  Future<void> _persistStrict(Future<void> Function() op) =>
      _trackPersist(op, rethrowOnError: true);

  Future<void> _trackPersist(
    Future<void> Function() op, {
    required bool rethrowOnError,
  }) {
    final Future<void> f = () async {
      try {
        await op();
      } catch (e, st) {
        debugPrint('NotesNotifier: scrittura su SQLite fallita: $e\n$st');
        if (rethrowOnError) rethrow;
      }
    }();
    _inflightWrites.add(f);
    unawaited(f.then(
      (_) => _inflightWrites.remove(f),
      onError: (_) => _inflightWrites.remove(f),
    ));
    return f;
  }

  NotesNotifier({NotesDao? dao, String? initialActiveNoteId})
      : _dao = dao ?? NotesDao(),
        _restoreActiveNoteId = initialActiveNoteId,
        super(const NotesState()) {
    PerfMarks.timeAsync('notes.load', _loadFromDb);
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
    flushPendingSavesInBackground();
    super.dispose();
  }

  Future<void> _loadFromDb({int attempt = 0}) async {
    final before = state.notes;
    final rows = await _dao.getActive();
    if (!mounted) return;
    final loaded = rows.map(NoteModel.fromRow).toList();

    // Una nota creata mentre la lettura iniziale era in corso vive solo nello
    // stato: senza questo merge la lettura la cancellerebbe appena finita.
    final activeBeforeLoad = state.activeNoteId;
    final loadedIds = loaded.map((n) => n.id).toSet();
    loaded.addAll(state.notes.where((n) => !loadedIds.contains(n.id)));

    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    // Valore globale delle versioni precedenti: resta solo come ripiego per le
    // viste che non hanno ancora un ordinamento proprio.
    _defaultSort = _parseSort(prefs.getString(AppConstants.prefSortMode)) ??
        NoteSortOrder.updatedDesc;

    final rawModes = prefs.getString(AppConstants.prefSortModeByScope);
    if (rawModes != null) {
      try {
        final decoded = jsonDecode(rawModes);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final parsed = _parseSort(v is String ? v : null);
            // Non sovrascrive scelte fatte mentre il caricamento era in corso.
            if (parsed != null) {
              _sortModes.putIfAbsent(k as String, () => parsed);
            }
          });
        }
      } catch (e) {
        debugPrint('NotesNotifier: ordinamenti per vista non leggibili: $e');
      }
    }
    final rawOrders = prefs.getString(AppConstants.prefCustomOrderByScope);
    if (rawOrders != null) {
      try {
        final decoded = jsonDecode(rawOrders);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (v is List) {
              _folderCustomOrders.putIfAbsent(
                  k as String, () => v.whereType<String>().toList());
            }
          });
        }
      } catch (e) {
        debugPrint(
            'NotesNotifier: ordini manuali per cartella non leggibili: $e');
      }
    }

    // Se durante la lettura lo stato è cambiato (creazione, cancellazione,
    // cascade, sync) questa fotografia del DB è obsoleta: rileggerla evita di
    // resuscitare note appena cancellate o di perdere quelle appena create.
    if (!identical(state.notes, before) && attempt < 2) {
      return _loadFromDb(attempt: attempt + 1);
    }

    final sortOrder = _sortFor(_scope);
    // Si ordina UNA sola volta, con l'ordinamento della vista corrente. BUG
    // CORRETTO: la nota attiva iniziale veniva presa dalla lista ordinata con
    // l'ordine di DEFAULT (ultima modifica) invece che da quella mostrata.
    final sorted = _sort(loaded, sortOrder);

    // Ripresa della sessione: si riapre la nota dell'ultima volta, se esiste
    // ancora fra quelle attive; altrimenti (prima installazione, nota
    // cancellata altrove, DB vuoto) si ripiega sulla prima della lista, come
    // sempre.
    final restoreId = _restoreActiveNoteId;
    _restoreActiveNoteId = null;
    final restoredStillExists =
        restoreId != null && sorted.any((n) => n.id == restoreId);
    final loadedActiveStillExists =
        activeBeforeLoad != null && sorted.any((n) => n.id == activeBeforeLoad);
    final String? initialActiveId = loadedActiveStillExists
        ? activeBeforeLoad
        : (restoredStillExists
            ? restoreId
            : (sorted.isNotEmpty ? sorted.first.id : null));

    state = state.copyWith(
      notes: sorted,
      activeNoteId: () => initialActiveId,
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

      notes = _sort(notes, state.sortOrder);
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
    // Se nel frattempo la nota è stata cancellata (direttamente o dalla
    // cascade di una cartella), il timer non deve riscriverla: sarebbe un
    // upsert con `deleted_at = NULL` che fa "risorgere" un tombstone.
    if (pending != null && state.notes.any((n) => n.id == pending.id)) {
      _pendingWrite = _persistStrict(() => _dao.upsert(pending.toRow()));
    }

    // Attende anche una scrittura eventualmente già avviata (dal debounce
    // naturale o da un flush precedente) e non ancora completata: senza
    // questo, un flush concorrente potrebbe considerarsi "finito" mentre
    // l'upsert reale è ancora in volo.
    final inFlight = _pendingWrite;
    if (inFlight != null) {
      try {
        await inFlight;
      } finally {
        if (identical(_pendingWrite, inFlight)) {
          _pendingWrite = null;
        }
      }
    }
  }

  /// Variante fire-and-forget per i chiamanti che non possono attendere
  /// (lifecycle, cambio selezione, dispose). L'errore viene loggato qui: un
  /// `unawaited(flushPendingSaves())` lascerebbe invece un'eccezione
  /// asincrona non gestita se SQLite rifiuta la scrittura.
  void flushPendingSavesInBackground() {
    unawaited(
      flushPendingSaves().then<void>(
        (_) {},
        onError: (Object e, StackTrace st) {
          debugPrint('NotesNotifier: flush in background fallito: $e\n$st');
        },
      ),
    );
  }

  /// Prepara il notifier al cambio account: annulla l'autosave in sospeso e
  /// attende le scritture già in volo, così la cancellazione del database
  /// dell'account precedente non può essere annullata da un upsert tardivo.
  Future<void> prepareForAccountReset() async {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    _pendingNote = null;
    final pendingWrite = _pendingWrite;
    if (pendingWrite != null) {
      try {
        await pendingWrite;
      } catch (_) {
        // Il reset deve procedere comunque: il DB dell'account precedente
        // viene cancellato subito dopo.
      }
    }
    await Future.wait(List<Future<void>>.of(_inflightWrites).map(
      (f) => f.catchError((_) {}),
    ));
    _pendingWrite = null;
    _restoreActiveNoteId = null;
    _folderCustomOrders.clear();
    state = state.copyWith(
      notes: const [],
      activeNoteId: () => null,
      searchQuery: '',
    );
  }

  void _debouncedPersist(NoteModel note) {
    _pendingNote = note;
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _saveDebounceTimer = null;
      final toWrite = _pendingNote;
      _pendingNote = null;
      if (toWrite != null && state.notes.any((n) => n.id == toWrite.id)) {
        _pendingWrite = _persist(() => _dao.upsert(toWrite.toRow()));
      }
    });
  }

  /// Confronto per l'ordine manuale di una cartella: le note presenti
  /// nell'elenco seguono la posizione salvata; quelle assenti (nuove, spostate
  /// o importate) vanno in cima, tra loro per `order_index`.
  static int _compareByFolderPosition(
      NoteModel a, NoteModel b, Map<String, int> pos) {
    final pa = pos[a.id];
    final pb = pos[b.id];
    if (pa != null && pb != null) return pa.compareTo(pb);
    if (pa == null && pb == null) return a.orderIndex.compareTo(b.orderIndex);
    return pa == null ? -1 : 1;
  }

  /// Confronto alfabetico "naturale": le sequenze di cifre sono confrontate
  /// come numeri, quindi "Nota 2" precede "Nota 10". Le stringhe arrivano già
  /// minuscole da [_sort].
  static int _compareNaturalTitles(String a, String b) {
    var i = 0;
    var j = 0;
    while (i < a.length && j < b.length) {
      final aCode = a.codeUnitAt(i);
      final bCode = b.codeUnitAt(j);
      final aIsDigit = _isAsciiDigit(aCode);
      final bIsDigit = _isAsciiDigit(bCode);

      if (aIsDigit && bIsDigit) {
        final aStart = i;
        final bStart = j;
        while (i < a.length && _isAsciiDigit(a.codeUnitAt(i))) {
          i++;
        }
        while (j < b.length && _isAsciiDigit(b.codeUnitAt(j))) {
          j++;
        }
        // Gli zeri iniziali non cambiano il valore ("01" == "1").
        var aSignificant = aStart;
        while (aSignificant < i - 1 && a.codeUnitAt(aSignificant) == 0x30) {
          aSignificant++;
        }
        var bSignificant = bStart;
        while (bSignificant < j - 1 && b.codeUnitAt(bSignificant) == 0x30) {
          bSignificant++;
        }
        final aLength = i - aSignificant;
        final bLength = j - bSignificant;
        if (aLength != bLength) return aLength < bLength ? -1 : 1;
        final numeric = a
            .substring(aSignificant, i)
            .compareTo(b.substring(bSignificant, j));
        if (numeric != 0) return numeric;
        continue;
      }

      if (aCode != bCode) return aCode < bCode ? -1 : 1;
      i++;
      j++;
    }
    return (a.length - i).compareTo(b.length - j);
  }

  static bool _isAsciiDigit(int codeUnit) =>
      codeUnit >= 0x30 && codeUnit <= 0x39;

  List<NoteModel> _sort(List<NoteModel> list, NoteSortOrder order) {
    final sorted = List<NoteModel>.from(list);
    // Posizioni dell'ordine manuale della cartella corrente (null per "Tutte
    // le note", che usa `order_index`, e per gli altri criteri).
    Map<String, int>? folderPos;
    if (order == NoteSortOrder.custom && _scope != _allScope) {
      final ids = _folderCustomOrders[_scope] ?? const <String>[];
      folderPos = <String, int>{for (var i = 0; i < ids.length; i++) ids[i]: i};
    }
    // Ordinamento alfabetico: la chiave minuscola si calcola UNA volta per
    // nota (O(n)) invece che a ogni confronto del comparatore, dove
    // `toLowerCase()` allocava una nuova stringa O(n log n) volte.
    final Map<String, String> titleKeys =
        order == NoteSortOrder.titleAsc || order == NoteSortOrder.titleDesc
            ? <String, String>{for (final n in sorted) n.id: n.titleLower}
            : const <String, String>{};
    sorted.sort((a, b) {
      if (order != NoteSortOrder.custom) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      }

      final int primary = switch (order) {
        NoteSortOrder.updatedDesc => b.updatedAt.compareTo(a.updatedAt),
        NoteSortOrder.updatedAsc => a.updatedAt.compareTo(b.updatedAt),
        NoteSortOrder.createdDesc => b.createdAt.compareTo(a.createdAt),
        NoteSortOrder.createdAsc => a.createdAt.compareTo(b.createdAt),
        NoteSortOrder.titleAsc =>
          _compareNaturalTitles(titleKeys[a.id]!, titleKeys[b.id]!),
        NoteSortOrder.titleDesc =>
          _compareNaturalTitles(titleKeys[b.id]!, titleKeys[a.id]!),
        NoteSortOrder.custom => folderPos == null
            ? a.orderIndex.compareTo(b.orderIndex)
            : _compareByFolderPosition(a, b, folderPos),
      };
      if (primary != 0) return primary;

      // Spareggio DETERMINISTICO. `List.sort` di Dart non è stabile: con
      // `order_index` duplicati (note create prima di questa correzione, o
      // arrivate da altri dispositivi) l'ordine visualizzato cambiava da un
      // avvio all'altro, dando l'impressione che il riordino "tornasse
      // indietro".
      switch (order) {
        case NoteSortOrder.custom:
          final byUpdatedCustom = b.updatedAt.compareTo(a.updatedAt);
          if (byUpdatedCustom != 0) return byUpdatedCustom;
        case NoteSortOrder.createdDesc:
        case NoteSortOrder.createdAsc:
          // Note con la stessa data di creazione (import in blocco, note
          // arrivate da un altro dispositivo con data di ripiego): si usa
          // l'altra data come spareggio, nello stesso verso, prima dell'id.
          final byUpdatedCreated = order == NoteSortOrder.createdDesc
              ? b.updatedAt.compareTo(a.updatedAt)
              : a.updatedAt.compareTo(b.updatedAt);
          if (byUpdatedCreated != 0) return byUpdatedCreated;
        case NoteSortOrder.updatedDesc:
        case NoteSortOrder.updatedAsc:
        case NoteSortOrder.titleAsc:
        case NoteSortOrder.titleDesc:
          break;
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
      flushPendingSavesInBackground();
      final sorted = _sort(state.notes, state.sortOrder);
      state = state.copyWith(notes: sorted, activeNoteId: () => id);
    }
  }

  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  /// Imposta l'ordinamento della vista CORRENTE ("Tutte le note" o la cartella
  /// selezionata): le altre viste mantengono il proprio.
  Future<void> setSortOrder(NoteSortOrder order) async {
    flushPendingSavesInBackground();
    var notes = state.notes;

    if (order == NoteSortOrder.custom &&
        state.sortOrder != NoteSortOrder.custom) {
      // Passando all'ordine manuale si parte dall'ordine che l'utente sta
      // VEDENDO ora, e lo si rende esplicito e senza duplicati.
      final current = _sort(state.notes, state.sortOrder);
      if (_scope == _allScope) {
        // "Tutte le note": `order_index` sincronizzato (persistendo solo le
        // note che cambiano).
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
          unawaited(_persist(
              () => _dao.upsertBatch(changed.map((n) => n.toRow()).toList())));
        }
      } else if ((_folderCustomOrders[_scope] ?? const <String>[]).isEmpty) {
        // Cartella senza ordine manuale salvato: lo si inizializza dall'ordine
        // visibile. Se esiste già, viene RICORDATO e riusato (l'ordine manuale
        // di una cartella sopravvive al passaggio ad altri criteri).
        _folderCustomOrders[_scope] = current.map((n) => n.id).toList();
        unawaited(_persistFolderOrders());
      }
    }

    _sortModes[_scope] = order;
    state = state.copyWith(notes: _sort(notes, order), sortOrder: order);
    await _persistSortModes();
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
    flushPendingSavesInBackground();
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

    final global = _sort(state.notes, NoteSortOrder.custom);
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

    final wasCustom = state.sortOrder == NoteSortOrder.custom;

    if (_scope != _allScope) {
      // Vista di una CARTELLA: l'ordine manuale è un elenco di id locale a
      // questa cartella. Nessuna scrittura su SQLite, nessun `updated_at`
      // modificato e nessun effetto sulle altre viste.
      _folderCustomOrders[_scope] = arranged.map((n) => n.id).toList();
      _sortModes[_scope] = NoteSortOrder.custom;
      state = state.copyWith(notes: arranged, sortOrder: NoteSortOrder.custom);
      unawaited(_persistFolderOrders());
      if (!wasCustom) unawaited(_persistSortModes());
      return;
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
    if (!wasCustom) {
      // Il riordino attiva l'ordine manuale: va ricordato anche dopo il
      // riavvio, altrimenti `order_index` è persistito ma non usato.
      _sortModes[_scope] = NoteSortOrder.custom;
      unawaited(_persistSortModes());
    }
    if (changed.isNotEmpty) {
      unawaited(_persist(
          () => _dao.upsertBatch(changed.map((n) => n.toRow()).toList())));
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
  ) {
    return importNotesBulkDetailed([
      for (final item in items)
        ImportedNote(
          title: item.title,
          content: item.content,
          folderId: item.folderId,
        ),
    ]);
  }

  /// Come [importNotesBulk], ma conserva i metadati del manifest di backup
  /// (date, preferito, pin e ordine manuale). Le note senza metadati ricevono
  /// gli stessi default dell'importazione legacy.
  Future<int> importNotesBulkDetailed(List<ImportedNote> items) async {
    if (items.isEmpty) return 0;

    final now = DateTime.now();
    // Dopo il massimo esistente (non `length`): gli indici possono avere
    // buchi o valori negativi (vedi createNote).
    final baseIndex = state.notes.isEmpty
        ? 0
        : state.notes.map((n) => n.orderIndex).reduce((a, b) => a > b ? a : b) +
            1;
    final newNotes = <NoteModel>[];
    for (var i = 0; i < items.length; i++) {
      // Senza manifest, istanti DISTINTI (1 ms l'uno dall'altro, l'ultimo =
      // now): con un unico `now` tutte le note importate avevano la stessa
      // data di creazione/modifica e il loro ordine reciproco era deciso
      // dall'UUID casuale, diverso a ogni avvio.
      final fallback =
          now.subtract(Duration(milliseconds: items.length - 1 - i));
      // Il manifest è in UTC; il modello di dominio usa sempre DateTime
      // locali (come NoteModel.fromRow). Se manca createdAt si usa updatedAt
      // e, in ogni caso, la creazione non può superare l'ultima modifica.
      final updatedAt =
          (items[i].updatedAt ?? items[i].createdAt ?? fallback).toLocal();
      var createdAt = (items[i].createdAt ?? updatedAt).toLocal();
      if (createdAt.isAfter(updatedAt)) createdAt = updatedAt;

      newNotes.add(NoteModel(
        id: _uuid.v4(),
        title: items[i].title,
        content: items[i].content,
        folderId: items[i].folderId,
        createdAt: createdAt,
        updatedAt: updatedAt,
        isFavorite: items[i].isFavorite,
        isPinned: items[i].isPinned,
        orderIndex: items[i].orderIndex ?? baseIndex + i,
      ));
    }

    final previousNotes = state.notes;
    state = state.copyWith(
      notes: _sort([...state.notes, ...newNotes], state.sortOrder),
    );

    try {
      await _persistStrict(
          () => _dao.upsertBatch(newNotes.map((n) => n.toRow()).toList()));
    } catch (_) {
      // Niente falsi successi: se SQLite non ha accettato il batch, le note
      // non esistono davvero e vanno tolte anche dallo stato in memoria.
      if (mounted) state = state.copyWith(notes: previousNotes);
      rethrow;
    }

    return newNotes.length;
  }

  NoteModel createNote({String? folderId}) {
    flushPendingSavesInBackground();
    final now = DateTime.now();
    // La nuova nota va in cima all'ordine manuale con un indice INFERIORE al
    // minimo esistente, invece di incrementare in memoria l'indice di tutte
    // le altre: quell'incremento non veniva mai scritto su SQLite, quindi
    // in DB restavano molte note con lo stesso `order_index` e, al riavvio,
    // l'ordine manuale risultava scombinato.
    final newOrderIndex = state.notes.isEmpty
        ? 0
        : state.notes.map((n) => n.orderIndex).reduce((a, b) => a < b ? a : b) -
            1;
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
      notes: _sort([newNote, ...state.notes], state.sortOrder),
      activeNoteId: () => newNote.id,
    );
    unawaited(_persist(() => _dao.upsert(newNote.toRow())));
    return newNote;
  }

  void updateNote(String id, {String? title, String? content}) {
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index == -1) return;

    final existing = state.notes[index];
    // BUG CORRETTO: ogni chiamata aggiornava `updatedAt` e marcava la nota
    // "dirty" anche se testo e titolo erano identici (es. callback
    // dell'editor/toolbar senza modifica reale): la nota saliva in cima
    // all'ordinamento per "ultima modifica" e veniva rispedita al server
    // senza motivo.
    final newTitle = title ?? existing.title;
    final newContent = content ?? existing.content;
    if (newTitle == existing.title && newContent == existing.content) return;

    final updatedNote = existing.copyWith(
      title: newTitle,
      content: newContent,
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
  Future<void> moveNote(String id, String? targetFolderId) async {
    // Scrive PRIMA l'eventuale testo ancora in debounce: altrimenti il timer
    // (che tiene una copia VECCHIA della nota, con il vecchio `folder_id`)
    // scatterebbe dopo lo spostamento e, con `ConflictAlgorithm.replace`,
    // riporterebbe la nota nella cartella di origine.
    await flushPendingSaves();
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

    final previousNotes = state.notes;
    state = state.copyWith(notes: _sort(updatedList, state.sortOrder));
    try {
      await _persistStrict(() => _dao.upsert(updatedNote.toRow()));
    } catch (_) {
      if (mounted) state = state.copyWith(notes: previousNotes);
      rethrow;
    }
  }

  Future<void> deleteNote(String id) async {
    // Stessa causa di moveNote: una scrittura in debounce non ancora
    // eseguita sovrascriverebbe il tombstone e la nota "risorgerebbe".
    await flushPendingSaves();
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

    final previousNotes = state.notes;
    final previousActiveId = state.activeNoteId;
    state =
        state.copyWith(notes: updatedList, activeNoteId: () => nextActiveId);
    try {
      await _persistStrict(() => _dao.upsert(tombstoneRow));
    } catch (_) {
      if (mounted) {
        state = state.copyWith(
          notes: previousNotes,
          activeNoteId: () => previousActiveId,
        );
      }
      rethrow;
    }
  }

  /// Crea una copia della nota [id] (stessa cartella, stesso contenuto) e la
  /// rende attiva. Il titolo riceve [copySuffix] se non è vuoto. Restituisce
  /// la nuova nota, o `null` se [id] non esiste.
  NoteModel? duplicateNote(String id, {String copySuffix = ' (copy)'}) {
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index == -1) return null;
    final source = state.notes[index];

    final copy = createNote(folderId: source.folderId);
    final newTitle = source.title.trim().isEmpty
        ? source.title
        : '${source.title}$copySuffix';
    updateNote(copy.id, title: newTitle, content: source.content);
    return state.notes.firstWhere((n) => n.id == copy.id, orElse: () => copy);
  }

  Future<void> togglePin(String id) async {
    await flushPendingSaves(); // vedi moveNote
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index == -1) return;

    final existing = state.notes[index];
    final updatedNote = existing.copyWith(
        isPinned: !existing.isPinned, updatedAt: DateTime.now());

    final updatedList = List<NoteModel>.from(state.notes);
    updatedList[index] = updatedNote;

    state = state.copyWith(notes: _sort(updatedList, state.sortOrder));
    await _persist(() => _dao.upsert(updatedNote.toRow()));
  }

  Future<void> toggleFavorite(String id) async {
    await flushPendingSaves();
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index == -1) return;

    final existing = state.notes[index];
    final updatedNote = existing.copyWith(
      isFavorite: !existing.isFavorite,
      updatedAt: DateTime.now(),
    );

    final updatedList = List<NoteModel>.from(state.notes);
    updatedList[index] = updatedNote;

    state = state.copyWith(notes: _sort(updatedList, state.sortOrder));
    await _persist(() => _dao.upsert(updatedNote.toRow()));
  }

  /// Aggiorna i metadati modificabili dal dialog della nota. Anche
  /// `createdAt` è sincronizzato: una modifica bumpa `updatedAt` e passa dal
  /// normale upsert dirty, così il server applica la stessa risoluzione LWW
  /// degli altri campi.
  Future<void> updateMetadata(
    String id, {
    bool? isFavorite,
    bool? isPinned,
    DateTime? createdAt,
    int? orderIndex,
  }) async {
    await flushPendingSaves();
    final index = state.notes.indexWhere((n) => n.id == id);
    if (index == -1) return;

    final existing = state.notes[index];
    final nextFavorite = isFavorite ?? existing.isFavorite;
    final nextPinned = isPinned ?? existing.isPinned;
    final nextOrder = orderIndex ?? existing.orderIndex;
    final nextCreatedAt = (createdAt ?? existing.createdAt).toLocal();

    final syncChanged = nextFavorite != existing.isFavorite ||
        nextPinned != existing.isPinned ||
        nextOrder != existing.orderIndex ||
        nextCreatedAt != existing.createdAt;
    if (!syncChanged) return;

    final now = DateTime.now();
    final normalizedCreatedAt =
        nextCreatedAt.isAfter(now) ? now : nextCreatedAt;
    final updatedNote = existing.copyWith(
      isFavorite: nextFavorite,
      isPinned: nextPinned,
      orderIndex: nextOrder,
      createdAt: normalizedCreatedAt,
      updatedAt: now,
    );

    final updatedList = List<NoteModel>.from(state.notes);
    updatedList[index] = updatedNote;
    state = state.copyWith(notes: _sort(updatedList, state.sortOrder));

    await _persist(() => _dao.upsert(updatedNote.toRow()));
  }
}

final notesProvider = StateNotifierProvider<NotesNotifier, NotesState>((ref) {
  final notifier = NotesNotifier(
    // Nota aperta nell'ultima sessione (null se nessuna).
    initialActiveNoteId: ref.read(sessionSnapshotProvider).noteId,
  );
  // La cartella selezionata vive in un provider dedicato: notesProvider non
  // dipende da folderProvider (che a sua volta legge notesProvider nella
  // cascade), evitando un ciclo di dipendenze.
  ref.listen<String?>(
    selectedFolderScopeProvider,
    (previous, next) => notifier.setScope(next),
    fireImmediately: true,
  );
  return notifier;
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
    final result = note.titleLower.contains(lowerQuery) ||
        note.contentLower.contains(lowerQuery);
    _matches[note] = result;
    return result;
  }
}

final _searchMatchCacheProvider =
    Provider<_SearchMatchCache>((ref) => _SearchMatchCache());

/// Provider for filtered notes based on folder and search query.
///
/// Vista puramente derivata: legge la STESSA lista di [notesProvider] e la
/// filtra in memoria. Non esegue mai una query separata sul database, il che
/// garantisce per costruzione che "Tutte le note" e "note della cartella X"
/// non possano mai disallinearsi tra loro.
final filteredNotesProvider = Provider<List<NoteModel>>((ref) {
  final notes = ref.watch(notesProvider.select((s) => s.notes));
  final selectedFolderId =
      ref.watch(folderProvider.select((s) => s.selectedFolderId));
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
    final scopeIds =
        FolderNode.collectSubtreeIds(rootFolders, selectedFolderId);
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
