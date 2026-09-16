import 'package:flutter/material.dart';

import '../../../models/markdown_ast_nodes.dart';
import 'code_block_widget.dart';
import 'heading_block_widget.dart';
import 'list_block_widget.dart';
import 'markdown_block_style.dart';
import 'math_block_widget.dart';
import 'paragraph_block_widget.dart';
import 'quote_block_widget.dart';
import 'table_block_widget.dart';
import 'thematic_break_block_widget.dart';

/// Dispatcher modulare dei blocchi dell'AST Markdown.
///
/// Riceve un qualunque [MarkdownNode] (tipicamente un [MarkdownBlockNode]
/// di primo livello passato da `MarkdownRenderedView`, ma anche un nodo
/// innestato, es. un item di lista o il contenuto di una blockquote,
/// passato ricorsivamente da [ListBlockWidget]/[QuoteBlockWidget]) e
/// istanzia SOLO il renderer concreto corrispondente al suo
/// [MarkdownNode.type], senza costruire né conoscere il resto
/// dell'albero.
///
/// Questo è l'unico punto che conosce la mappatura completa
/// tipo-di-nodo → widget: aggiungere un nuovo tipo di blocco (o
/// sostituire un renderer esistente con un Custom Renderer avanzato nella
/// Fase 4) richiede di toccare solo questo file, non
/// `MarkdownRenderedView` né gli altri renderer.
class MarkdownBlockWidget extends StatelessWidget {
  final MarkdownNode node;
  final MarkdownBlockStyle style;

  const MarkdownBlockWidget({
    super.key,
    required this.node,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    switch (node.type) {
      case MarkdownNodeType.heading:
        return HeadingBlockWidget(node: node as HeadingNode, style: style);
      case MarkdownNodeType.paragraph:
        return ParagraphBlockWidget(node: node as ParagraphNode, style: style);
      case MarkdownNodeType.codeBlock:
        return CodeBlockWidget(node: node as CodeBlockNode, style: style);
      case MarkdownNodeType.listBlock:
        return ListBlockWidget(node: node as ListBlockNode, style: style);
      case MarkdownNodeType.blockquote:
        return QuoteBlockWidget(node: node as BlockquoteNode, style: style);
      case MarkdownNodeType.thematicBreak:
        return ThematicBreakBlockWidget(style: style);
      case MarkdownNodeType.tableBlock:
        return TableBlockWidget(node: node as TableBlockNode, style: style);
      case MarkdownNodeType.mathBlock:
        return MathBlockWidget(node: node as MathBlockNode, style: style);
      // `listItem` e `tableRow` non vengono mai passati direttamente a
      // questo dispatcher: sono consumati internamente da
      // `ListBlockWidget`/`TableBlockWidget` tramite i getter tipizzati
      // `ListBlockNode.items` / `TableBlockNode.rows`.
      case MarkdownNodeType.listItem:
      case MarkdownNodeType.tableRow:
        return const SizedBox.shrink();
    }
  }
}
