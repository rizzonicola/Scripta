import 'package:flutter/material.dart';

import '../../../models/markdown_ast_nodes.dart';
import '../../../services/markdown_selection_source_mapper.dart';
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
/// ripassare [selectionController] invariato a [MarkdownBlockWidget] per
/// ciascun figlio, che si abbonerà — in modo indipendente, tramite il
/// proprio `ListenableBuilder` — allo stesso controller e ricalcolerà,
/// sempre in O(1) sui propri offset assoluti, il proprio stato di
/// evidenziazione. Questo è ciò che permette a un singolo item di una
/// lista molto lunga (es. selezionata per intero da "Seleziona Tutto" e
/// poi scrollata) di apparire correttamente evidenziato fin dalla sua
/// prima build, anche se l'item non esisteva ancora come widget quando
/// la selezione è stata stabilita — E di restare sincronizzato in tempo
/// reale ad ogni ulteriore variazione (es. un trascinamento che
/// restringe la selezione), senza attendere un `setState` esterno sulla
/// `ListView`.
class ListBlockWidget extends StatelessWidget {
  final ListBlockNode node;
  final MarkdownBlockStyle style;
  final MarkdownSelectionController? selectionController;

  const ListBlockWidget({
    super.key,
    required this.node,
    required this.style,
    this.selectionController,
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
              selectionController: selectionController,
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
  final MarkdownSelectionController? selectionController;

  const _ListItemRow({
    required this.item,
    required this.marker,
    required this.style,
    this.selectionController,
  });

  @override
  Widget build(BuildContext context) {
    final controller = selectionController;
    // FASE 4 — Aggancio Reattivo: il marcatore (bullet/numero) non passa
    // dal dispatcher [MarkdownBlockWidget] (non è un `MarkdownBlockNode`
    // dispatchabile), quindi questo widget deve abbonarsi DIRETTAMENTE al
    // controller per ricalcolare — in isolamento, O(1) — il proprio stato
    // ad ogni notifica, esattamente come fa il dispatcher per gli altri
    // tipi di blocco.
    if (controller == null) {
      return _buildRow(context, BlockVisualSelection.none);
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final itemVisualSelection = resolveBlockVisualSelection(
          item,
          controller.logicalSourceSelection,
        );
        return _buildRow(context, itemVisualSelection);
      },
    );
  }

  Widget _buildRow(BuildContext context, BlockVisualSelection itemVisualSelection) {
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
                    selectionController: selectionController,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
