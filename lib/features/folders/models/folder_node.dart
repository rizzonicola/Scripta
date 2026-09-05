import 'dart:convert';

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

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'parentId': parentId,
      'children': children.map((x) => x.toMap()).toList(),
      'isExpanded': isExpanded,
    };
  }

  factory FolderNode.fromMap(Map<String, dynamic> map) {
    return FolderNode(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      parentId: map['parentId'],
      children: (map['children'] as List<dynamic>?)
              ?.map((x) => FolderNode.fromMap(x as Map<String, dynamic>))
              .toList() ??
          [],
      isExpanded: map['isExpanded'] ?? true,
    );
  }

  String toJson() => json.encode(toMap());

  factory FolderNode.fromJson(String source) =>
      FolderNode.fromMap(json.decode(source));
}
