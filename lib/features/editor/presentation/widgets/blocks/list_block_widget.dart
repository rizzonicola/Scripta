import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextSelection;

import '../../../models/markdown_ast_nodes.dart';
import 'block_visual_selection.dart';
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
///
/// FASE 4 — questo widget non disegna testo proprio (il marcatore è
/// decorativo ed escluso dalla selezione, vedi sotto), quindi non
/// riceve/calcola un proprio [BlockVisualSelection]: si limita a
/// ripassare [logicalSelection] invariato a [MarkdownBlockWidget] per
/// ciascun figlio, che ricalcolerà — sempre in O(1), sui propri offset
/// assoluti nel documento — il proprio stato di evidenziazione. Questo è
/// ciò che permette a un singolo item di una lista molto lunga (es.
/// selezionata per intero da "Seleziona Tutto" e poi scrollata) di
/// apparire correttamente evidenziato fin dalla sua prima build, anche
/// se l'item non esisteva ancora come widget quando la selezione è
/// stata stabilita.
class ListBlockWidget extends StatelessWidget {
  final ListBlockNode node;
  final MarkdownBlockStyle style;
  final TextSelection? logicalSelection;

  const ListBlockWidget({
    super.key,
    required this.node,
    required this.style,
    this.logicalSelection,
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
              logicalSelection: logicalSelection,
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
  final TextSelection? logicalSelection;

  const _ListItemRow({
    required this.item,
    required this.marker,
    required this.style,
    this.logicalSelection,
  });

  @override
  Widget build(BuildContext context) {
    final children = item.children.cast<MarkdownBlockNode>();
    // FASE 4 — O(1): il marcatore si evidenzia insieme al resto
    // dell'item quando quest'ultimo ricade per intero nella selezione,
    // cosi che bullet/numero seguano visivamente il testo pur restando
    // esclusi dalla selezione LOGICA/testuale (vedi commento sotto).
    final itemVisualSelection =
        resolveBlockVisualSelection(item, logicalSelection);

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
            child: BlockSelectionHighlight(
              visualSelection: itemVisualSelection,
              color: style.blockSelectionHighlightColor,
              child: Text(
                marker,
                style: (style.styleSheet.listBullet ?? style.styleSheet.p)?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: style.primaryColor,
                ),
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
                  child: MarkdownBlockWidget(
                    node: children[i],
                    style: style,
                    logicalSelection: logicalSelection,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
