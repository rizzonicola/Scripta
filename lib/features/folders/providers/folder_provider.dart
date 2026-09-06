import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/folders_dao.dart';
import '../../../core/database/notes_dao.dart';
import '../../notes/providers/notes_provider.dart';
import '../models/folder_node.dart';

class FolderState {
  final List<FolderNode> rootFolders;
  final String? selectedFolderId; // null = "All Notes"

  const FolderState({
    this.rootFolders = const [],
    this.selectedFolderId,
  });

  FolderState copyWith({
    List<FolderNode>? rootFolders,
    String? Function()? selectedFolderId,
  }) {
    return FolderState(
      rootFolders: rootFolders ?? this.rootFolders,
      selectedFolderId: selectedFolderId != null
          ? selectedFolderId()
          : this.selectedFolderId,
    );
  }
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

  FolderNotifier(this._ref, {FoldersDao? foldersDao, NotesDao? notesDao})
      : _foldersDao = foldersDao ?? FoldersDao(),
        _notesDao = notesDao ?? NotesDao(),
        super(const FolderState()) {
    _loadFromDb();
  }

  Future<void> _loadFromDb() async {
    final rows = await _foldersDao.getActive();
    _activeRows = rows;
    state = state.copyWith(rootFolders: FolderNode.buildForest(rows));
  }

  /// Ricarica l'albero dal database locale. Esposto principalmente per la
  /// sync (dopo aver applicato le entità ricevute dal server) e per i test.
  Future<void> refreshFromDb() => _loadFromDb();

  void _publishState() {
    state = state.copyWith(rootFolders: FolderNode.buildForest(_activeRows));
  }

  void selectFolder(String? folderId) {
    state = state.copyWith(selectedFolderId: () => folderId);
  }

  FolderNode? findByName(String name) {
    FolderNode? search(List<FolderNode> list) {
      for (final n in list) {
        if (n.name.toLowerCase() == name.toLowerCase()) return n;
        final c = search(n.children);
        if (c != null) return c;
      }
      return null;
    }

    return search(state.rootFolders);
  }

  FolderNode addFolder(String name, {String? parentId}) {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final row = FolderRow(
      id: _uuid.v4(),
      name: name.trim(),
      parentId: parentId,
      isExpanded: true,
      updatedAt: now,
      deletedAt: null,
    );

    _activeRows = [..._activeRows, row];
    _publishState();
    unawaited(_foldersDao.upsert(row));

    return FolderNode(
      id: row.id,
      name: row.name,
      parentId: row.parentId,
      isExpanded: row.isExpanded,
      children: const [],
    );
  }

  void renameFolder(String id, String newName) {
    final idx = _activeRows.indexWhere((r) => r.id == id);
    if (idx == -1) return;

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final updated = _activeRows[idx].copyWith(name: newName.trim(), updatedAt: now);
    _activeRows = [..._activeRows]..[idx] = updated;
    _publishState();
    unawaited(_foldersDao.upsert(updated));
  }

  /// Espandi/comprimi: puro stato UI locale, non tocca `updated_at` e quindi
  /// non genera alcun traffico di sync.
  void toggleExpand(String id) {
    final idx = _activeRows.indexWhere((r) => r.id == id);
    if (idx == -1) return;

    final updated = _activeRows[idx].copyWith(isExpanded: !_activeRows[idx].isExpanded);
    _activeRows = [..._activeRows]..[idx] = updated;
    _publishState();
    unawaited(_foldersDao.setExpanded(id, updated.isExpanded));
  }

  /// Cancella una cartella e, ricorsivamente, tutte le sue sottocartelle e
  /// tutte le note al loro interno (cascade soft-delete). Vedi il commento
  /// di classe per il razionale architetturale.
  void deleteFolder(String id) {
    final idsToDelete = _collectSubtreeIds(id);
    if (idsToDelete.isEmpty) return;

    if (state.selectedFolderId != null && idsToDelete.contains(state.selectedFolderId)) {
      state = state.copyWith(selectedFolderId: () => null);
    }

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    _activeRows = _activeRows.where((r) => !idsToDelete.contains(r.id)).toList();
    _publishState();

    unawaited(() async {
      await _foldersDao.cascadeSoftDelete(
        id,
        now,
        deleteNotesInFolder: (folderIdInSubtree, cascadeNow) =>
            _notesDao.softDeleteByFolder(folderIdInSubtree, cascadeNow),
      );
      // Le note della cartella cancellata sono sparite anche dal DB locale:
      // la vista "Tutte le note"/per-cartella deve rifletterlo subito.
      await _ref.read(notesProvider.notifier).refreshFromDb();
    }());
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

  FolderNode? findNode(String id) => _findNode(state.rootFolders, id);

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
  /// `newParentId` è null). A differenza della generazione basata su
  /// percorsi, questo è ESATTAMENTE un aggiornamento del campo `parent_id`:
  /// nessun rename, nessuna riscrittura ricorsiva dei figli (che restano
  /// collegati tramite il proprio `parent_id`, invariato).
  bool moveFolder(String folderId, String? newParentId) {
    if (folderId == newParentId) return false;
    if (newParentId != null && isDescendantOf(folderId, newParentId)) return false;

    final idx = _activeRows.indexWhere((r) => r.id == folderId);
    if (idx == -1) return false;

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final updated = _activeRows[idx].copyWith(parentId: newParentId, updatedAt: now);
    _activeRows = [..._activeRows]..[idx] = updated;
    _publishState();
    unawaited(_foldersDao.upsert(updated));
    return true;
  }
}

final folderProvider = StateNotifierProvider<FolderNotifier, FolderState>((ref) {
  return FolderNotifier(ref);
});
