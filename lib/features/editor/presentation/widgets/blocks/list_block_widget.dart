import 'package:flutter/material.dart';

import '../../../domain/models/markdown_selection_range.dart';
import '../../../models/markdown_ast_nodes.dart';
import 'markdown_block_style.dart';
import 'markdown_block_widget.dart';

/// Rendering di un [ListBlockNode] (elenco puntato o numerato).
///
/// Ogni [ListItemNode] disegna il proprio marcatore (bullet o numero
/// progressivo, quest'ultimo a partire da [ListBlockNode.start] se
/// specificato) e delega il rendering del contenuto innestato al
/// dispatcher [MarkdownBlockWidget], così che un item possa contenere
/// qualunque altro tipo di blocco (paragrafi, liste annidate, code
/// block, blockquote, ...) senza che questo widget debba conoscerne la
/// logica di rendering.
class ListBlockWidget extends StatelessWidget {
  final ListBlockNode node;
  final MarkdownBlockStyle style;

  /// Intersezione di blocco intero, richiesta dalla firma comune del
  /// dispatcher [MarkdownBlockWidget]. Il contenuto di ogni item è
  /// renderizzato ricorsivamente dallo stesso dispatcher, che ricalcola
  /// autonomamente l'intersezione dei propri figli dai loro offset: per
  /// ora questo valore non viene ancora consumato qui (es. per
  /// evidenziare i marcatori quando l'intera lista è selezionata), ma è
  /// già disponibile per un'estensione futura senza toccare di nuovo il
  /// dispatcher.
  final BlockSelectionIntersection intersection;

  const ListBlockWidget({
    super.key,
    required this.node,
    required this.style,
    this.intersection = BlockSelectionIntersection.none,
  });

  @override
  Widget build(BuildContext context) {
    final items = node.items;
    final startNumber = node.start ?? 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 6),
            child: _ListItemRow(
              item: items[i],
              marker: node.ordered ? '${startNumber + i}.' : '•',
              style: style,
            ),
          ),
      ],
    );
  }
}

class _ListItemRow extends StatelessWidget {
  final ListItemNode item;
  final String marker;
  final MarkdownBlockStyle style;

  const _ListItemRow({
    required this.item,
    required this.marker,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    final children = item.children.cast<MarkdownBlockNode>();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 24,
          // Il marcatore (bullet/numero) è un elemento decorativo del
          // renderer, non testo del sorgente Markdown: va escluso dalla
          // selezione perché non inquini né la copia "grezza" (Fase 3)
          // né il conteggio caratteri della mappatura logica.
          child: SelectionContainer.disabled(
            child: Text(
              marker,
              style: (style.styleSheet.listBullet ?? style.styleSheet.p)?.copyWith(
                fontWeight: FontWeight.bold,
                color: style.primaryColor,
              ),
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++)
                Padding(
                  padding: EdgeInsets.only(bottom: i == children.length - 1 ? 0 : 6),
                  child: MarkdownBlockWidget(node: children[i], style: style),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
