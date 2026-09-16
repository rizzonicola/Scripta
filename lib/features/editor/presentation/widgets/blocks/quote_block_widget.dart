import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextSelection;

import '../../../models/markdown_ast_nodes.dart';
import 'block_visual_selection.dart';
import 'markdown_block_style.dart';
import 'markdown_block_widget.dart';

/// Rendering di un [BlockquoteNode] (`> ...`).
///
/// Il contenuto è già stato ri-parsato ricorsivamente dal parser
/// (`BlockquoteNode.children`, tipicamente paragrafi ma potenzialmente
/// qualunque altro blocco, incluse blockquote annidate): questo widget si
/// limita a disegnare la cornice tipografica e a delegare ogni figlio al
/// dispatcher [MarkdownBlockWidget], che a sua volta sceglierà il
/// renderer concreto giusto per ciascuno — la stessa strada percorsa dal
/// livello superiore in `MarkdownRenderedView`, così che una blockquote
/// annidata o una lista dentro una citazione si comportino esattamente
/// come farebbero a livello di documento.
///
/// FASE 4 — [visualSelection] (già risolto dal dispatcher per il nodo
/// blockquote nel suo complesso) intensifica leggermente la cornice
/// stessa quando l'INTERA citazione è selezionata; [logicalSelection]
/// viene comunque ripassato invariato ai figli, che ricalcolano il
/// proprio stato in modo indipendente (una blockquote può essere
/// selezionata solo in parte pur avendo, al suo interno, uno o più
/// paragrafi interamente selezionati).
class QuoteBlockWidget extends StatelessWidget {
  final BlockquoteNode node;
  final MarkdownBlockStyle style;
  final BlockVisualSelection visualSelection;
  final TextSelection? logicalSelection;

  const QuoteBlockWidget({
    super.key,
    required this.node,
    required this.style,
    this.visualSelection = BlockVisualSelection.none,
    this.logicalSelection,
  });

  @override
  Widget build(BuildContext context) {
    final children = node.children.cast<MarkdownBlockNode>();
    final highlightAlpha = visualSelection.isFull ? 0.16 : 0.08;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: style.primaryColor.withValues(alpha: highlightAlpha),
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(color: style.primaryColor, width: 4),
        ),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(
          fontStyle: FontStyle.italic,
          color: style.onSurfaceColor.withValues(alpha: 0.75),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++)
              Padding(
                padding: EdgeInsets.only(bottom: i == children.length - 1 ? 0 : 8),
                child: MarkdownBlockWidget(
                  node: children[i],
                  style: style,
                  logicalSelection: logicalSelection,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
