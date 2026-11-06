import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3: StateNotifier/StateNotifierProvider sono "legacy" (spostati
// in questo import separato, non rimossi). La classe resta una
// StateNotifier per preservare 1:1 la logica dell'albero cartelle/cascade
// delete già corretta e testata (vedi test/notes_provider_move_test.dart e
// commenti di classe più sotto).
import 'package:flutter_riverpod/legacy.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/folders_dao.dart';
import '../../../core/database/notes_dao.dart';
import '../../../core/services/session_state_service.dart';
import '../../notes/providers/notes_provider.dart';
import '../../workspace/providers/folder_scope_provider.dart';
import '../models/folder_node.dart';

class FolderState {
  final List<FolderNode> rootFolders;
  final String? selectedFolderId; // null = "All Notes"

  /// Errore dell'ultima scrittura locale non riuscita; `null` se non ce ne
  /// sono in sospeso. La UI mostra un banner non bloccante.
  final String? lastWriteError;

  bool get hasPendingWriteError => lastWriteError != null;

  const FolderState({
    this.rootFolders = const [],
    this.selectedFolderId,
    this.lastWriteError,
  });

  FolderState copyWith({
    List<FolderNode>? rootFolders,
    String? Function()? selectedFolderId,
    String? Function()? lastWriteError,
  }) {
    return FolderState(
      rootFolders: rootFolders ?? this.rootFolders,
      selectedFolderId: selectedFolderId != null
          ? selectedFolderId()
          : this.selectedFolderId,
      lastWriteError: lastWriteError != null
          ? lastWriteError()
          : this.lastWriteError,
    );
  }

  // Uguaglianza per valore (vedi motivazione analoga in `SyncConfig`):
  // evita notifiche/rebuild quando `copyWith` non cambia nulla di
  // osservabile. `rootFolders` è confrontata per riferimento (non in
  // profondità, ricorsivamente, dentro l'albero): è sufficiente per il
  // caso comune — es. `selectFolder`/`toggleExpand`, che tramite
  // `copyWith` senza passare `rootFolders` mantengono automaticamente lo
  // STESSO riferimento di lista — senza pagare il costo di una comparazione
  // ricorsiva profonda dell'intero albero ad ogni confronto di stato.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FolderState &&
        identical(other.rootFolders, rootFolders) &&
        other.selectedFolderId == selectedFolderId &&
        other.lastWriteError == lastWriteError;
  }

  @override
  int get hashCode => Object.hash(
    identityHashCode(rootFolders),
    selectedFolderId,
    lastWriteError,
  );
}

/// Gestisce l'albero delle cartelle sopra il database locale SQLite
/// ([FoldersDao]).
///
/// PRINCIPI ARCHITETTURALI:
///  - Gerarchia ID-based: spostare una cartella ([moveFolder]) è un singolo
///    UPDATE su `parent_id`, mai una ricostruzione di percorsi.
///  - Cancellazione in cascata REALE ([deleteFolder]): tutte le sottocartelle
///    e le note al loro interno vengono soft-deleted ricorsivamente in
///    locale; la propagazione al server (alla prossima sync) è innescata dal
///    chiamante tramite `syncProvider.onFolderStructureChanged()` (vedi
///    `folder_tree_view.dart`, che ora la invoca anche dopo l'eliminazione,
///    colmando una lacuna della generazione precedente in cui la
///    cancellazione di una cartella non veniva mai sincronizzata). Lato
///    server, `internal/handlers/api_sync.go` applica comunque la stessa
///    cascata in modo indipendente, come rete di sicurezza reciproca.
///  - Zero seeding: al primo avvio, se il database locale è vuoto, l'albero
///    resta semplicemente vuoto. Nessuna cartella "Personal/Work/Knowledge
///    Base" fittizia viene creata né, quindi, mai spinta sul server.
///  - Aggiornamenti dello stato in-memory SEMPRE sincroni (i widget e i test
///    leggono `ref.read(folderProvider)` subito dopo aver chiamato un
///    metodo come `addFolder`/`moveFolder` e si aspettano il nuovo stato
///    già applicato): la persistenza su SQLite avviene in background,
///    "fire-and-forget", subito dopo.
class FolderNotifier extends StateNotifier<FolderState> {
  final Ref _ref;
  final FoldersDao _foldersDao;
  final NotesDao _notesDao;
  final _uuid = const Uuid();

  /// Specchio in memoria di tutte le righe attive (non cancellate) della
  /// tabella `folders`: è la fonte immediata da cui deriviamo l'albero
  /// mostrato in UI ad ogni mutazione, senza dover rileggere il DB ogni
  /// volta (che sarebbe asincrono e romperebbe le aspettative sincrone dei
  /// metodi pubblici qui sotto).
  List<FolderRow> _activeRows = [];

  /// Il primo caricamento può concludersi DOPO che l'utente ha già creato una
  /// cartella (stato solo in memoria): quelle righe vanno conservate, non
  /// sostituite dalla fotografia del DB scattata prima della scrittura.
  bool _hasLoadedOnce = false;

  /// Id cancellati mentre il primo caricamento era in corso: la fotografia
  /// del DB può essere precedente alla delete e non deve resuscitarli.
  final Set<String> _deletedBeforeLoad = <String>{};

  /// Coda delle scritture su SQLite: mantiene l'ordine UI (crea -> rinomina ->
  /// elimina) e impedisce che un upsert partito prima di una delete la
  /// faccia "risorgere" scrivendo dopo la cascade. Un errore viene ritentato
  /// con backoff PRIMA di far avanzare la coda; dopo l'ultimo tentativo
  /// fallito lo stato espone l'errore e la coda prosegue.
  Future<void> _writeQueue = Future<void>.value();

  /// Una scrittura "normale" fallita viene riparata ri-persistendo lo stato
  /// corrente (righe in memoria), mai rieseguendo la closure originale: una
  /// closure catturata può essere ormai vecchia (es. rename successivo,
  /// cartella cancellata) e riporterebbe indietro i dati.
  bool _needsPersistAllRows = false;

  /// Le cascade di cancellazione non sono ricostruibili dallo stato corrente
  /// (le righe sono già sparite dalla memoria): la loro closure va conservata
  /// e rieseguita, è idempotente.
  final List<Future<void> Function()> _failedDeletes = [];

  bool get _hasFailedWrites =>
      _needsPersistAllRows || _failedDeletes.isNotEmpty;

  final int maxWriteRetries;
  final Duration writeRetryBase;

  bool _initialLoadComplete = false;
  final Completer<void> _readyCompleter = Completer<void>();

  /// Vero quando il primo caricamento (inclusa `repairCycles`) è terminato.
  @visibleForTesting
  bool get initialLoadComplete => _initialLoadComplete;

  /// Completa quando il primo caricamento delle cartelle è terminato.
  ///
  /// Serve a chi deve mostrare un selettore di cartelle appena avviata l'app,
  /// come l'apertura di un file esterno: senza attesa la lista potrebbe
  /// essere ancora vuota.
  Future<void> get ready => _readyCompleter.future;

  void _markWriteError(Object error) {
    if (!mounted) return;
    final message = error.toString();
    if (state.lastWriteError == message) return;
    state = state.copyWith(lastWriteError: () => message);
  }

  void _clearWriteError() {
    if (!mounted || state.lastWriteError == null) return;
    state = state.copyWith(lastWriteError: () => null);
  }

  Future<void> _enqueueWrite(
    Future<void> Function() op, {
    Future<void> Function()? retry,
  }) {
    final next = _writeQueue.then((_) => _runWriteWithRetry(op, retry));
    _writeQueue = next.catchError((Object e, StackTrace st) {
      debugPrint('FolderNotifier: coda scritture fallita: $e\n$st');
    });
    return _writeQueue;
  }

  Future<void> _runWriteWithRetry(
    Future<void> Function() op,
    Future<void> Function()? retry,
  ) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt <= maxWriteRetries; attempt++) {
      try {
        await op();
        // Un successo su una scrittura diversa non prova che quella fallita
        // sia arrivata su disco: si pulisce il banner solo quando non resta
        // nulla da recuperare.
        if (!_hasFailedWrites) _clearWriteError();
        return;
      } catch (e, st) {
        lastError = e;
        lastStackTrace = st;
      }
      if (attempt < maxWriteRetries) {
        await Future<void>.delayed(writeRetryBase * (1 << attempt));
        if (!mounted) return;
      }
    }

    debugPrint(
      'FolderNotifier: scrittura su SQLite fallita: $lastError\n$lastStackTrace',
    );
    if (!mounted) return;
    if (retry == null) {
      _needsPersistAllRows = true;
    } else if (!_failedDeletes.any((f) => identical(f, retry))) {
      _failedDeletes.add(retry);
    }
    _markWriteError(lastError!);
  }

  /// Ripersiste tutte le righe attualmente in memoria. È il retry sicuro per
  /// add/rename/expand/move: lo stato corrente è già la verità più recente,
  /// quindi il replay non può resuscitare una cartella cancellata né
  /// sovrascrivere una rinomina successiva.
  Future<void> _persistCurrentRows() async {
    for (final row in List<FolderRow>.of(_activeRows)) {
      await _foldersDao.upsert(row);
    }
  }

  /// Ritenta le scritture fallite. Le righe correnti vengono salvate prima
  /// delle cascade di cancellazione, così un upsert non può far riapparire
  /// una cartella che una delete pendente deve ancora rimuovere.
  Future<void> retryPendingWrites() async {
    if (!mounted || !_hasFailedWrites) return;
    final persistRows = _needsPersistAllRows;
    final deletes = List<Future<void> Function()>.of(_failedDeletes);
    _needsPersistAllRows = false;
    _failedDeletes.clear();

    if (persistRows) await _enqueueWrite(_persistCurrentRows);
    for (final op in deletes) {
      await _enqueueWrite(op, retry: op);
    }
  }

  /// Attende che tutte le mutazioni già richieste siano state scritte.
  Future<void> flushPendingWrites() => _writeQueue;

  /// [initialSelectedFolderId] è la cartella selezionata nell'ultima sessione
  /// (vedi [sessionSnapshotProvider]): parte già selezionata fin dal primo
  /// frame, senza passare per "Tutte le note". È solo un riferimento da
  /// validare: se la cartella non esiste più, il primo caricamento da DB
  /// ripiega su "Tutte le note" (vedi [_loadFromDb]).
  FolderNotifier(
    this._ref, {
    FoldersDao? foldersDao,
    NotesDao? notesDao,
    String? initialSelectedFolderId,
    this.writeRetryBase = const Duration(milliseconds: 250),
    this.maxWriteRetries = 3,
  }) : _foldersDao = foldersDao ?? FoldersDao(),
       _notesDao = notesDao ?? NotesDao(),
       super(FolderState(selectedFolderId: initialSelectedFolderId)) {
    _runInitialLoad();
    // Non si può notificare un altro provider durante il build di questo:
    // lo scope iniziale viene pubblicato appena il microtask lo consente.
    Future.microtask(() {
      if (mounted) _publishScope(state.selectedFolderId);
    });
  }

  Future<void> _runInitialLoad() async {
    try {
      await _loadFromDb(validateSelection: true);
    } finally {
      _initialLoadComplete = true;
      if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    }
  }

  /// Carica le cartelle attive dal DB e ricostruisce l'albero.
  ///
  /// Con [validateSelection] (solo il primo caricamento, all'avvio) una
  /// cartella selezionata che non è fra quelle caricate viene azzerata:
  /// altrimenti, se l'ultima sessione si era chiusa su una cartella poi
  /// cancellata da un altro dispositivo, l'utente resterebbe bloccato su una
  /// vista vuota di una cartella inesistente. I caricamenti successivi (dopo
  /// una sync) NON toccano la selezione, esattamente come prima.
  ///
  /// La selezione si rilegge DOPO l'await: se l'utente ne ha scelta un'altra
  /// mentre il DB veniva letto, si valida quella, non quella iniziale.
  Future<void> _loadFromDb({bool validateSelection = false}) async {
    if (!_hasLoadedOnce) {
      await _foldersDao.repairCycles(
        DateTime.now().toUtc().millisecondsSinceEpoch,
      );
    }
    var rows = [...await _foldersDao.getActive()];
    if (!mounted) return;
    if (!_hasLoadedOnce) {
      // Le righe toccate in memoria prima che la lettura finisse vincono sulla
      // fotografia del DB; quelle cancellate nel frattempo non risorgono.
      final byId = {for (final row in rows) row.id: row};
      for (final local in _activeRows) {
        if (!_deletedBeforeLoad.contains(local.id)) byId[local.id] = local;
      }
      rows = byId.values
          .where((row) => !_deletedBeforeLoad.contains(row.id))
          .toList();
      _deletedBeforeLoad.clear();
      _hasLoadedOnce = true;
    }
    _activeRows = rows;

    var next = state.copyWith(rootFolders: FolderNode.buildForest(rows));
    final selected = state.selectedFolderId;
    if (validateSelection &&
        selected != null &&
        !rows.any((r) => r.id == selected)) {
      next = next.copyWith(selectedFolderId: () => null);
    }
    state = next;
    _publishScope(state.selectedFolderId);
  }

  /// Ricarica l'albero dal database locale. Esposto principalmente per la
  /// sync (dopo aver applicato le entità ricevute dal server) e per i test.
  Future<void> refreshFromDb() => _loadFromDb();

  void _publishState() {
    state = state.copyWith(rootFolders: FolderNode.buildForest(_activeRows));
  }

  void selectFolder(String? folderId) {
    state = state.copyWith(selectedFolderId: () => folderId);
    _publishScope(folderId);
  }

  void _publishScope(String? folderId) {
    final scope = _ref.read(selectedFolderScopeProvider.notifier);
    if (scope.state != folderId) scope.state = folderId;
  }

  FolderNode addFolder(String name, {String? parentId}) {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    var maxOrder = 0;
    var hasManualOrder = false;
    for (final sibling in _activeRows) {
      if (sibling.parentId != parentId) continue;
      if (sibling.orderIndex > 0) hasManualOrder = true;
      if (sibling.orderIndex > maxOrder) maxOrder = sibling.orderIndex;
    }
    final row = FolderRow(
      id: _uuid.v4(),
      name: name.trim(),
      parentId: parentId,
      isExpanded: true,
      // Con un ordine manuale già attivo, la nuova cartella va in fondo;
      // altrimenti resta "non ordinata" (0) e si inserisce alfabeticamente.
      orderIndex: hasManualOrder ? maxOrder + 1 : 0,
      updatedAt: now,
      deletedAt: null,
    );

    _activeRows = [..._activeRows, row];
    _publishState();
    unawaited(_enqueueWrite(() => _foldersDao.upsert(row)));

    return FolderNode(
      id: row.id,
      name: row.name,
      parentId: row.parentId,
      isExpanded: row.isExpanded,
      orderIndex: row.orderIndex,
      children: const [],
    );
  }

  void renameFolder(String id, String newName) {
    final idx = _activeRows.indexWhere((r) => r.id == id);
    if (idx == -1) return;

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final updated = _activeRows[idx].copyWith(
      name: newName.trim(),
      updatedAt: now,
    );
    _activeRows = [..._activeRows]..[idx] = updated;
    _publishState();
    unawaited(_enqueueWrite(() => _foldersDao.upsert(updated)));
  }

  /// Espandi/comprimi: puro stato UI locale, non tocca `updated_at` e quindi
  /// non genera alcun traffico di sync.
  void toggleExpand(String id) {
    final idx = _activeRows.indexWhere((r) => r.id == id);
    if (idx == -1) return;

    final updated = _activeRows[idx].copyWith(
      isExpanded: !_activeRows[idx].isExpanded,
    );
    _activeRows = [..._activeRows]..[idx] = updated;
    _publishState();
    unawaited(
      _enqueueWrite(() => _foldersDao.setExpanded(id, updated.isExpanded)),
    );
  }

  /// Cancella una cartella e, ricorsivamente, tutte le sue sottocartelle e
  /// tutte le note al loro interno (cascade soft-delete). Vedi il commento
  /// di classe per il razionale architetturale.
  void deleteFolder(String id) {
    final idsToDelete = _collectSubtreeIds(id);
    if (idsToDelete.isEmpty) return;
    if (!_hasLoadedOnce) _deletedBeforeLoad.addAll(idsToDelete);

    if (state.selectedFolderId != null &&
        idsToDelete.contains(state.selectedFolderId)) {
      state = state.copyWith(selectedFolderId: () => null);
      _publishScope(null);
    }

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    _activeRows = _activeRows
        .where((r) => !idsToDelete.contains(r.id))
        .toList();
    _publishState();

    Future<void> deleteOp() async {
      // Prima di far sparire le note dal DB, scrive l'eventuale testo ancora
      // nel debounce dell'editor: altrimenti il timer successivo riscriverebbe
      // la nota con la vecchia cartella, annullando il tombstone appena
      // creato dalla cascade.
      await _ref.read(notesProvider.notifier).flushPendingSaves();
      await _foldersDao.cascadeSoftDelete(
        id,
        now,
        deleteNotesInFolder: (folderIdInSubtree, cascadeNow) =>
            _notesDao.softDeleteByFolder(folderIdInSubtree, cascadeNow),
      );
      // Le note della cartella cancellata sono sparite anche dal DB locale:
      // la vista "Tutte le note"/per-cartella deve rifletterlo subito.
      await _ref.read(notesProvider.notifier).refreshFromDb();
    }

    unawaited(_enqueueWrite(deleteOp, retry: deleteOp));
  }

  /// Raccoglie, a partire dallo specchio in memoria [_activeRows], l'ID
  /// della cartella indicata e di ogni sua sottocartella (ricorsivamente).
  /// Usato per aggiornare lo stato in-memory in modo sincrono, PRIMA che la
  /// cascade asincrona sul database locale sia completata.
  Set<String> _collectSubtreeIds(String rootId) {
    final byParent = <String?, List<String>>{};
    for (final r in _activeRows) {
      byParent.putIfAbsent(r.parentId, () => []).add(r.id);
    }
    final result = <String>{};
    if (!_activeRows.any((r) => r.id == rootId)) return result;

    final queue = [rootId];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (!result.add(current)) continue;
      queue.addAll(byParent[current] ?? const []);
    }
    return result;
  }

  /// Cartelle radice correnti (lettura sincrona dello stato in memoria).
  /// `state` è protetto: chi non è una sottoclasse, come l'importazione
  /// (`ImportService.commitEntries`), passa da qui.
  List<FolderNode> get rootFolders => state.rootFolders;

  FolderNode? findNode(String id) => _findNode(state.rootFolders, id);

  /// Percorso dei nomi dalla radice fino a [folderId] (radice esclusa).
  ///
  /// Restituisce una lista vuota per `null` o per una cartella inesistente.
  /// Serve a chi deve ricreare un albero partendo da un percorso di nomi,
  /// come l'importazione di una cartella esterna sotto una destinazione.
  List<String> folderPathSegments(String? folderId) {
    if (folderId == null) return const [];
    final rowsById = {for (final row in _activeRows) row.id: row};
    final path = <String>[];
    final visited = <String>{};
    String? currentId = folderId;
    while (currentId != null) {
      // Difesa da righe corrotte con un ciclo di parent_id.
      if (!visited.add(currentId)) return const [];
      final row = rowsById[currentId];
      if (row == null) return const [];
      path.insert(0, row.name);
      currentId = row.parentId;
    }
    return path;
  }

  FolderNode? _findNode(List<FolderNode> list, String id) {
    for (final node in list) {
      if (node.id == id) return node;
      final childFound = _findNode(node.children, id);
      if (childFound != null) return childFound;
    }
    return null;
  }

  bool isDescendantOf(String parentId, String childId) {
    final parent = _findNode(state.rootFolders, parentId);
    if (parent == null) return false;
    return _checkDescendant(parent, childId);
  }

  bool _checkDescendant(FolderNode node, String targetId) {
    for (final child in node.children) {
      if (child.id == targetId) return true;
      if (_checkDescendant(child, targetId)) return true;
    }
    return false;
  }

  /// Sposta una cartella sotto un nuovo genitore (o in radice se
  /// `newParentId` è null), in coda ai fratelli. A differenza della
  /// generazione basata su percorsi, questo è ESATTAMENTE un aggiornamento del
  /// campo `parent_id`: nessun rename, nessuna riscrittura ricorsiva dei figli
  /// (che restano collegati tramite il proprio `parent_id`, invariato).
  bool moveFolder(String folderId, String? newParentId) {
    final siblings = _orderedSiblings(newParentId, excludeId: folderId);
    return _moveFolderToIndex(folderId, newParentId, siblings.length);
  }

  /// Sposta [folderId] rispetto alla cartella [targetId], secondo la zona di
  /// rilascio scelta nella UI:
  ///  * [FolderDropPosition.before] -> sorella prima del bersaglio;
  ///  * [FolderDropPosition.inside] -> ultima figlia del bersaglio;
  ///  * [FolderDropPosition.after] -> sorella dopo il bersaglio; se il
  ///    bersaglio è espanso e ha figli, diventa la PRIMA figlia (il "buco"
  ///    visivo subito sotto la riga del genitore).
  ///
  /// Restituisce `false` se lo spostamento è vietato (se stessa o un proprio
  /// discendente) o se non cambierebbe nulla.
  bool moveFolderRelative(
    String folderId,
    String targetId,
    FolderDropPosition position,
  ) {
    if (folderId == targetId) return false;
    final target = _activeRows.where((r) => r.id == targetId).firstOrNull;
    if (target == null) return false;

    final String? newParentId;
    final int insertAt;
    switch (position) {
      case FolderDropPosition.before:
        newParentId = target.parentId;
        insertAt = _orderedSiblings(
          newParentId,
          excludeId: folderId,
        ).indexWhere((r) => r.id == targetId);
        if (insertAt < 0) return false;
      case FolderDropPosition.inside:
        newParentId = targetId;
        insertAt = _orderedSiblings(newParentId, excludeId: folderId).length;
      case FolderDropPosition.after:
        final targetNode = findNode(targetId);
        final hasVisibleChildren =
            targetNode != null &&
            targetNode.isExpanded &&
            targetNode.children.isNotEmpty;
        if (hasVisibleChildren) {
          newParentId = targetId;
          insertAt = 0;
        } else {
          newParentId = target.parentId;
          insertAt =
              _orderedSiblings(
                newParentId,
                excludeId: folderId,
              ).indexWhere((r) => r.id == targetId) +
              1;
        }
    }

    return _moveFolderToIndex(folderId, newParentId, insertAt);
  }

  /// Vero se [folderId] può essere trascinata su [targetId] (non su se
  /// stessa né dentro un proprio discendente). Usato dalla UI per rifiutare
  /// in anticipo i bersagli non validi, senza mostrare indicatori ingannevoli.
  bool canMoveFolder(String folderId, String targetId) {
    if (folderId == targetId) return false;
    return !isDescendantOf(folderId, targetId);
  }

  static int _compareSiblings(FolderRow a, FolderRow b) =>
      FolderNode.compareSiblingValues(
        a.orderIndex,
        a.name,
        b.orderIndex,
        b.name,
      );

  /// Righe attive figlie di [parentId], ordinate come in [FolderNode]
  /// (ordine manuale, poi nome). Con [excludeId] si esclude la cartella in
  /// movimento, così gli indici di inserimento sono già "senza di lei".
  List<FolderRow> _orderedSiblings(String? parentId, {String? excludeId}) {
    return _activeRows
        .where((r) => r.parentId == parentId && r.id != excludeId)
        .toList()
      ..sort(_compareSiblings);
  }

  /// Nucleo comune di tutti gli spostamenti: aggiorna `parent_id` (solo se
  /// cambia, con bump di `updated_at` per la sync) e riscrive le posizioni
  /// manuali dei fratelli coinvolti. L'ordine non tocca `updated_at` né
  /// `dirty`; il genitore nuovo invece sì, perché è una modifica strutturale.
  bool _moveFolderToIndex(String folderId, String? newParentId, int insertAt) {
    if (folderId == newParentId) return false;
    if (newParentId != null && isDescendantOf(folderId, newParentId)) {
      return false;
    }

    final dragged = _activeRows.where((r) => r.id == folderId).firstOrNull;
    if (dragged == null) return false;

    final oldParentId = dragged.parentId;
    final newSiblings = _orderedSiblings(newParentId, excludeId: folderId);
    final clamped = insertAt.clamp(0, newSiblings.length);

    // Nessun cambiamento reale: evita riscritture e notifiche inutili.
    if (oldParentId == newParentId) {
      final currentIds = _orderedSiblings(
        oldParentId,
      ).map((r) => r.id).toList(growable: false);
      final proposed = [...newSiblings];
      proposed.insert(clamped, dragged);
      var same = true;
      for (var i = 0; i < currentIds.length; i++) {
        if (currentIds[i] != proposed[i].id) {
          same = false;
          break;
        }
      }
      if (same) return false;
    }

    final parentChanged = oldParentId != newParentId;
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;

    // Ordine manuale 1-based: 0 resta riservato a "nessun ordine manuale".
    newSiblings.insert(clamped, dragged);
    final newOrder = <String, int>{};
    for (var i = 0; i < newSiblings.length; i++) {
      newOrder[newSiblings[i].id] = i + 1;
    }
    if (parentChanged) {
      final oldSiblings = _orderedSiblings(oldParentId, excludeId: folderId);
      for (var i = 0; i < oldSiblings.length; i++) {
        newOrder[oldSiblings[i].id] = i + 1;
      }
    }

    final updatedRows = <FolderRow>[];
    for (final row in _activeRows) {
      if (row.id == folderId) {
        updatedRows.add(
          row.copyWith(
            parentId: newParentId,
            orderIndex: newOrder[folderId],
            updatedAt: parentChanged ? now : row.updatedAt,
          ),
        );
        continue;
      }
      final order = newOrder[row.id];
      updatedRows.add(order == null ? row : row.copyWith(orderIndex: order));
    }
    _activeRows = updatedRows;
    _publishState();

    final movedRow = _activeRows.firstWhere((r) => r.id == folderId);
    unawaited(
      _enqueueWrite(() async {
        if (parentChanged) await _foldersDao.upsert(movedRow);
        await _foldersDao.setOrderIndexes(newOrder);
      }),
    );
    return true;
  }
}

final folderProvider = StateNotifierProvider<FolderNotifier, FolderState>((
  ref,
) {
  return FolderNotifier(
    ref,
    // Cartella dell'ultima sessione (null = "Tutte le note" o nessuna sessione).
    initialSelectedFolderId: ref.read(sessionSnapshotProvider).folderId,
  );
});
