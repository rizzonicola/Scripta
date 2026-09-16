import 'package:flutter/material.dart';

import '../../../models/markdown_ast_nodes.dart';
import '../../../services/markdown_selection_source_mapper.dart';
import 'block_visual_selection.dart';
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
///
/// FASE 4 — Selezione Visiva Virtualizzata (fix sincronizzazione): questo
/// è anche l'UNICO punto che traduce la selezione logica corrente
/// (`selectionController.logicalSourceSelection`, offset nel sorgente
/// Markdown completo) nello stato di evidenziazione LOCALE di [node]
/// (vedi [resolveBlockVisualSelection] — O(1), un pugno di confronti fra
/// interi). Essendo centralizzato qui, ogni nuovo tipo di blocco eredita
/// gratuitamente il comportamento corretto senza dover duplicare la
/// logica di intersezione al suo interno; i renderer concreti ricevono
/// già il risultato pronto ([BlockVisualSelection]) e si limitano a
/// dipingerlo (vedi [BlockSelectionHighlight]). Per i nodi CONTENITORE
/// (lista, blockquote) [selectionController] viene anche ripassato
/// invariato ai figli, così che ciascuno ricalcoli — sempre in O(1), sui
/// propri offset assoluti — il proprio stato indipendentemente da quello
/// del genitore (un item di lista può essere pienamente selezionato
/// anche se la lista che lo contiene, nel suo complesso, è selezionata
/// solo in parte).
///
/// AGGANCIO REATTIVO: a differenza della versione precedente (che
/// riceveva un `TextSelection?` statico, calcolato una tantum
/// dall'`itemBuilder` della `ListView` e quindi "congelato" fino al
/// prossimo `setState` esterno — che non arriva mai ad ogni drag, per
/// design, vedi `MarkdownRenderedView._handleSelectionChanged`), questo
/// widget si abbona DIRETTAMENTE a [selectionController] tramite un
/// [ListenableBuilder] locale. Ogni volta che il controller notifica un
/// cambiamento, SOLO questo singolo `Element` (e i suoi discendenti
/// diretti che leggono lo stesso stato, es. gli item di
/// [ListBlockWidget]) si ricostruisce — mai l'intera `ListView` — e lo fa
/// rileggendo `logicalSourceSelection` "live", quindi anche un blocco
/// montato per la prima volta a metà di un trascinamento (perché appena
/// entrato nel viewport durante lo scroll) riceve lo stato corretto fin
/// dalla sua prima `build`, senza dover attendere alcuna sincronizzazione
/// da parte della selezione nativa di `SelectableRegion`.
class MarkdownBlockWidget extends StatelessWidget {
  final MarkdownNode node;
  final MarkdownBlockStyle style;
  final MarkdownSelectionController? selectionController;

  const MarkdownBlockWidget({
    super.key,
    required this.node,
    required this.style,
    this.selectionController,
  });

  @override
  Widget build(BuildContext context) {
    final controller = selectionController;

    // Nessun controller collegato (es. contesto in cui la selezione
    // logica non è pertinente): si evita del tutto l'iscrizione a un
    // `Listenable` e si renderizza una volta sola, senza evidenziazione.
    if (controller == null) {
      return _dispatch(BlockVisualSelection.none, null);
    }

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final visualSelection = resolveBlockVisualSelection(
          node,
          controller.logicalSourceSelection,
        );
        return _dispatch(visualSelection, controller);
      },
    );
  }

  Widget _dispatch(
    BlockVisualSelection visualSelection,
    MarkdownSelectionController? controller,
  ) {
    switch (node.type) {
      case MarkdownNodeType.heading:
        return HeadingBlockWidget(
          node: node as HeadingNode,
          style: style,
          visualSelection: visualSelection,
        );
      case MarkdownNodeType.paragraph:
        return ParagraphBlockWidget(
          node: node as ParagraphNode,
          style: style,
          visualSelection: visualSelection,
        );
      case MarkdownNodeType.codeBlock:
        return CodeBlockWidget(
          node: node as CodeBlockNode,
          style: style,
          visualSelection: visualSelection,
        );
      case MarkdownNodeType.listBlock:
        return ListBlockWidget(
          node: node as ListBlockNode,
          style: style,
          selectionController: controller,
        );
      case MarkdownNodeType.blockquote:
        return QuoteBlockWidget(
          node: node as BlockquoteNode,
          style: style,
          visualSelection: visualSelection,
          selectionController: controller,
        );
      case MarkdownNodeType.thematicBreak:
        return ThematicBreakBlockWidget(style: style);
      case MarkdownNodeType.tableBlock:
        return TableBlockWidget(
          node: node as TableBlockNode,
          style: style,
          visualSelection: visualSelection,
        );
      case MarkdownNodeType.mathBlock:
        return MathBlockWidget(
          node: node as MathBlockNode,
          style: style,
          visualSelection: visualSelection,
        );
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
