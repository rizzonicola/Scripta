import 'package:flutter/material.dart';

import '../../../domain/models/markdown_selection_range.dart';
import '../../../models/markdown_ast_nodes.dart';
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
class QuoteBlockWidget extends StatelessWidget {
  final BlockquoteNode node;
  final MarkdownBlockStyle style;

  /// Intersezione di blocco intero, richiesta dalla firma comune del
  /// dispatcher [MarkdownBlockWidget]. Vale la stessa nota di
  /// [ListBlockWidget]: i figli si ricalcolano da soli la propria
  /// intersezione tramite la ricorsione del dispatcher, questo valore è
  /// disponibile ma non ancora consumato qui.
  final BlockSelectionIntersection intersection;

  const QuoteBlockWidget({
    super.key,
    required this.node,
    required this.style,
    this.intersection = BlockSelectionIntersection.none,
  });

  @override
  Widget build(BuildContext context) {
    final children = node.children.cast<MarkdownBlockNode>();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: style.primaryColor.withValues(alpha: 0.08),
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
                child: MarkdownBlockWidget(node: children[i], style: style),
              ),
          ],
        ),
      ),
    );
  }
}
