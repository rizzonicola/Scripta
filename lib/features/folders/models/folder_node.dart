import '../../../core/database/folders_dao.dart';

/// Nodo dell'albero delle cartelle mostrato in UI.
///
/// IMPORTANTE: FolderNode non è più la rappresentazione persistita (niente
/// più `toJson`/`fromJson` salvati come blob in SharedPreferences). È una
/// vista ad albero costruita IN MEMORIA, ad ogni cambiamento, a partire
/// dall'elenco piatto delle righe attive nella tabella locale `folders`
/// (vedi [FolderNode.buildForest]): la vera fonte di verità resta sempre e
/// solo il database locale (righe [FolderRow] con `parent_id`), coerente col
/// principio "Local-First, UI unicamente reattiva al DB locale".
class FolderNode {
  final String id;
  final String name;
  final String? parentId;
  final List<FolderNode> children;
  final bool isExpanded;

  const FolderNode({
    required this.id,
    required this.name,
    this.parentId,
    this.children = const [],
    this.isExpanded = true,
  });

  FolderNode copyWith({
    String? id,
    String? name,
    String? parentId,
    List<FolderNode>? children,
    bool? isExpanded,
  }) {
    return FolderNode(
      id: id ?? this.id,
      name: name ?? this.name,
      parentId: parentId ?? this.parentId,
      children: children ?? this.children,
      isExpanded: isExpanded ?? this.isExpanded,
    );
  }

  /// Costruisce la foresta di alberi (le cartelle radice, ciascuna con i
  /// propri figli annidati ricorsivamente) a partire dall'elenco piatto delle
  /// righe attive del database locale. Puramente ID-based: usa solo
  /// `id`/`parent_id`, senza mai costruire o confrontare stringhe di percorso.
  static List<FolderNode> buildForest(List<FolderRow> activeRows) {
    final childrenOf = <String?, List<FolderRow>>{};
    for (final row in activeRows) {
      childrenOf.putIfAbsent(row.parentId, () => []).add(row);
    }
    for (final list in childrenOf.values) {
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }

    FolderNode build(FolderRow row) {
      final childRows = childrenOf[row.id] ?? const [];
      return FolderNode(
        id: row.id,
        name: row.name,
        parentId: row.parentId,
        isExpanded: row.isExpanded,
        children: childRows.map(build).toList(),
      );
    }

    final roots = childrenOf[null] ?? const [];
    return roots.map(build).toList();
  }

  /// Trova il nodo con [id] nell'albero [roots] (radici o un qualunque
  /// discendente, a qualsiasi profondità), oppure `null` se non esiste.
  /// Usato da [collectSubtreeIds] per calcolare lo "scope" di una ricerca
  /// per cartella.
  static FolderNode? findNode(List<FolderNode> roots, String id) {
    for (final node in roots) {
      if (node.id == id) return node;
      final found = findNode(node.children, id);
      if (found != null) return found;
    }
    return null;
  }

  /// ID di [folderId] insieme a quelli di TUTTE le sue sottocartelle
  /// (ricorsivamente), calcolati a partire dall'albero [roots] già
  /// costruito in stato.
  ///
  /// Usato da `filteredNotesProvider` per far sì che selezionare una
  /// cartella mostri anche le note dei relativi sottoalberi, non solo
  /// quelle con `folderId` esattamente uguale alla cartella selezionata:
  /// coerente con come [FolderTreeView] presenta le sottocartelle come
  /// contenuto annidato della cartella genitore, non come sezioni separate.
  ///
  /// Se [folderId] non esiste più nell'albero (es. race con una
  /// cancellazione), restituisce un insieme con il solo [folderId]
  /// richiesto: il chiamante filtrerà semplicemente a zero risultati invece
  /// di andare in errore.
  static Set<String> collectSubtreeIds(List<FolderNode> roots, String folderId) {
    final result = <String>{folderId};
    final start = findNode(roots, folderId);
    if (start == null) return result;

    void collect(FolderNode node) {
      for (final child in node.children) {
        result.add(child.id);
        collect(child);
      }
    }

    collect(start);
    return result;
  }
}
