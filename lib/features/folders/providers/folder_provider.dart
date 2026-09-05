import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
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

class FolderNotifier extends StateNotifier<FolderState> {
  static const String _prefKey = 'inkflow_folders_tree';
  final _uuid = const Uuid();

  FolderNotifier() : super(const FolderState()) {
    _loadFromPrefs();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final rawJson = prefs.getString(_prefKey);

    if (rawJson != null && rawJson.isNotEmpty) {
      try {
        final List<dynamic> decoded = json.decode(rawJson);
        final folders = decoded
            .map((item) => FolderNode.fromMap(item as Map<String, dynamic>))
            .toList();
        state = state.copyWith(rootFolders: folders);
        return;
      } catch (_) {
        // Fallback to default folders below
      }
    }

    // Default folders structure if empty
    final workId = _uuid.v4();
    final defaultFolders = [
      FolderNode(
        id: _uuid.v4(),
        name: 'Personal',
        children: const [],
      ),
      FolderNode(
        id: workId,
        name: 'Work',
        children: [
          FolderNode(
            id: _uuid.v4(),
            name: 'Scripta Dev',
            parentId: workId,
            children: const [],
          ),
        ],
      ),
      FolderNode(
        id: _uuid.v4(),
        name: 'Knowledge Base',
        children: const [],
      ),
    ];

    state = state.copyWith(rootFolders: defaultFolders);
    _saveToPrefs();
  }

  Future<void> _saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final rawJson = json.encode(state.rootFolders.map((f) => f.toMap()).toList());
    await prefs.setString(_prefKey, rawJson);
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
    final newFolder = FolderNode(
      id: _uuid.v4(),
      name: name.trim(),
      parentId: parentId,
      children: const [],
    );

    if (parentId == null) {
      state = state.copyWith(rootFolders: [...state.rootFolders, newFolder]);
    } else {
      state = state.copyWith(
        rootFolders: _insertIntoTree(state.rootFolders, parentId, newFolder),
      );
    }
    _saveToPrefs();
    return newFolder;
  }

  List<FolderNode> _insertIntoTree(
      List<FolderNode> list, String parentId, FolderNode newNode) {
    return list.map((node) {
      if (node.id == parentId) {
        return node.copyWith(
          children: [...node.children, newNode],
          isExpanded: true,
        );
      }
      return node.copyWith(
        children: _insertIntoTree(node.children, parentId, newNode),
      );
    }).toList();
  }

  void renameFolder(String id, String newName) {
    state = state.copyWith(
      rootFolders: _updateNodeInTree(
        state.rootFolders,
        id,
        (node) => node.copyWith(name: newName.trim()),
      ),
    );
    _saveToPrefs();
  }

  void toggleExpand(String id) {
    state = state.copyWith(
      rootFolders: _updateNodeInTree(
        state.rootFolders,
        id,
        (node) => node.copyWith(isExpanded: !node.isExpanded),
      ),
    );
    _saveToPrefs();
  }

  void deleteFolder(String id) {
    // If selected folder is the one being deleted or child of it, reset selection
    if (state.selectedFolderId == id) {
      state = state.copyWith(selectedFolderId: () => null);
    }

    state = state.copyWith(
      rootFolders: _deleteFromTree(state.rootFolders, id),
    );
    _saveToPrefs();
  }

  List<FolderNode> _updateNodeInTree(
    List<FolderNode> list,
    String targetId,
    FolderNode Function(FolderNode) transform,
  ) {
    return list.map((node) {
      if (node.id == targetId) {
        return transform(node);
      }
      return node.copyWith(
        children: _updateNodeInTree(node.children, targetId, transform),
      );
    }).toList();
  }

  List<FolderNode> _deleteFromTree(List<FolderNode> list, String targetId) {
    final result = <FolderNode>[];
    for (final node in list) {
      if (node.id == targetId) {
        continue;
      }
      result.add(
        node.copyWith(children: _deleteFromTree(node.children, targetId)),
      );
    }
    return result;
  }

  FolderNode? findNode(String id) {
    return _findNode(state.rootFolders, id);
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

  bool moveFolder(String folderId, String? newParentId) {
    if (folderId == newParentId) return false;

    // Prevent circular reference if newParentId is descendant of folderId
    if (newParentId != null && isDescendantOf(folderId, newParentId)) {
      return false;
    }

    final nodeToMove = _findNode(state.rootFolders, folderId);
    if (nodeToMove == null) return false;

    // Remove from current position
    final treeWithoutNode = _deleteFromTree(state.rootFolders, folderId);

    // Update parentId
    final updatedNode = FolderNode(
      id: nodeToMove.id,
      name: nodeToMove.name,
      parentId: newParentId,
      children: nodeToMove.children,
      isExpanded: nodeToMove.isExpanded,
    );

    List<FolderNode> newRoots;
    if (newParentId == null) {
      newRoots = [...treeWithoutNode, updatedNode];
    } else {
      newRoots = _insertIntoTree(treeWithoutNode, newParentId, updatedNode);
    }

    state = state.copyWith(rootFolders: newRoots);
    _saveToPrefs();
    return true;
  }
}

final folderProvider =
    StateNotifierProvider<FolderNotifier, FolderState>((ref) {
  return FolderNotifier();
});
