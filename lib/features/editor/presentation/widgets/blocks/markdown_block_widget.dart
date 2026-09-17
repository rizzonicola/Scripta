import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/markdown_ast_nodes.dart';
import '../../../domain/models/markdown_selection_range.dart';
import '../../providers/markdown_selection_provider.dart';
import 'code_block_widget.dart';
import 'heading_block_widget.dart';
import 'list_block_widget.dart';
import 'markdown_block_style.dart';
import 'math_block_widget.dart';
import 'paragraph_block_widget.dart';
import 'quote_block_widget.dart';
import 'table_block_widget.dart';
import 'thematic_break_block_widget.dart';

/// Dispatcher modulare dei blocchi dell'AST Markdown, consapevole della
/// selezione basata sugli offset del documento sorgente.
///
/// Riceve un qualunque [MarkdownNode] (tipicamente un [MarkdownBlockNode]
/// di primo livello passato da `MarkdownRenderedView`, ma anche un nodo
/// innestato, es. un item di lista o il contenuto di una blockquote,
/// passato ricorsivamente da [ListBlockWidget]/[QuoteBlockWidget]) e
/// istanzia SOLO il renderer concreto corrispondente al suo
/// [MarkdownNode.type], senza costruire né conoscere il resto
/// dell'albero.
///
/// Questo resta l'unico punto che conosce la mappatura completa
/// tipo-di-nodo → widget: aggiungere un nuovo tipo di blocco (o
/// sostituire un renderer esistente con un Custom Renderer avanzato
/// nella Fase 4) richiede di toccare solo questo file, non
/// `MarkdownRenderedView` né gli altri renderer.
///
/// ## Sistema di selezione: offset AST + Riverpod
///
/// Il widget è un [ConsumerWidget] e non partecipa in alcun modo al
/// motore di selezione nativo di Flutter: nessun `SelectionArea`,
/// `SelectableRegion`, `SelectionContainer` né `TextSelection` attraversa
/// questo file. L'evidenziazione è calcolata a partire dagli offset
/// assoluti del documento mantenuti dall'AST ([MarkdownNode.startOffset]
/// e [MarkdownNode.endOffset]) e dallo stato pubblicato da
/// [markdownSelectionProvider], e arriva ai renderer figli come puro
/// dato: questo widget non legge mai il testo sorgente.
///
/// Ogni istanza del dispatcher sottoscrive il provider e calcola, in
/// forma memoizzata, come la selezione corrente interseca l'intervallo
/// sorgente del proprio nodo:
///
/// ```dart
/// final intersection = ref.watch(
///   markdownSelectionProvider.select(
///     (selection) => calculateBlockIntersection(
///       blockStartOffset: node.startOffset,
///       blockEndOffset: node.endOffset,
///       selection: selection,
///     ),
///   ),
/// );
/// ```
///
/// ## Memoizzazione e costo durante il trascinamento
///
/// `select` rivaluta il selettore a ogni cambio di stato del provider,
/// ma ricostruisce questo widget soltanto se il risultato cambia
/// secondo `==` ([BlockSelectionIntersection] implementa l'uguaglianza
/// per valore). Poiché [calculateBlockIntersection] restituisce
/// l'istanza canonicalizzata [BlockSelectionIntersection.none] per ogni
/// blocco che la selezione non tocca, durante il trascinamento viene
/// ricostruito soltanto il blocco (tipicamente uno o due) la cui
/// intersezione cambia davvero — quelli ai bordi della selezione in
/// movimento — mentre tutti gli altri sottoscrittori pagano al più
/// pochi confronti tra interi e nessuna allocazione.
///
/// ## Propagazione ai renderer specializzati
///
/// L'intersezione è espressa in offset RELATIVI all'inizio del blocco
/// ([BlockSelectionIntersection.localStart] e
/// [BlockSelectionIntersection.localEnd], fine esclusiva): i renderer
/// figli la consumano direttamente — ad esempio
/// `TextRange(start: intersection.localStart, end: intersection.localEnd)`
/// — senza alcuna conversione aggiuntiva.
///
/// Contratto del parametro nominato `intersection`, identico per tutti
/// i renderer che ricevono un nodo:
/// - tipo [BlockSelectionIntersection], parametro opzionale;
/// - valore di default [BlockSelectionIntersection.none], istanza
///   `const`: il default non alloca nulla e ogni call-site pregresso
///   che non passa il parametro resta compilante senza modifiche
///   (retrocompatibilità);
/// - `SelectionType.none` → nessuna evidenziazione;
///   `SelectionType.full` → tutto il testo del blocco;
///   `SelectionType.partial` → soltanto `[localStart, localEnd)`.
///
/// Il renderer di paragrafo e quello di code block — quelli il cui
/// testo viene evidenziato carattere per carattere — sono i consumer
/// primari del parametro; heading, liste, blockquote, tabelle e formule
/// matematiche lo ricevono con la stessa firma, così che ciascuno possa
/// attivare la propria evidenziazione in un momento successivo senza
/// dover toccare di nuovo questo dispatcher. L'unica eccezione è
/// [ThematicBreakBlockWidget]: un separatore orizzontale non espone
/// testo sorgente evidenziabile (e il suo renderer non riceve nemmeno
/// il nodo), quindi non partecipa al contratto.
///
/// ## Ricorsione nei blocchi contenitore
///
/// Liste e blockquote non interrompono la catena della selezione: il
/// loro contenuto è renderizzato da istanze ricorsive di questo stesso
/// widget e ogni istanza ricalcola autonomamente la propria
/// intersezione dagli offset del proprio nodo. La selezione si propaga
/// quindi a qualsiasi profondità senza prop-drilling e senza aritmetica
/// sugli offset nei widget contenitore: l'intersezione di un paragrafo
/// annidato in un item di lista, dentro una blockquote, a sua volta
/// dentro un item di lista, viene derivata esattamente come quella di
/// un blocco di primo livello. I contenitori ricevono comunque la
/// propria intersezione di blocco intero — spendibile, ad esempio, per
/// evidenziare i marcatori degli item quando l'intera lista è
/// selezionata — ma la resa dei figli resta delegata alla ricorsione.
class MarkdownBlockWidget extends ConsumerWidget {
  /// Nodo dell'AST da renderizzare: tipicamente un [MarkdownBlockNode]
  /// di primo livello, oppure un nodo innestato proveniente dalla
  /// ricorsione dei widget contenitore ([ListBlockWidget],
  /// [QuoteBlockWidget]). I suoi offset assoluti —
  /// [MarkdownNode.startOffset] ed [MarkdownNode.endOffset] — sono
  /// l'ancora con cui viene calcolata l'intersezione con la selezione
  /// corrente del documento.
  final MarkdownNode node;

  /// Stile condiviso dell'editor Markdown renderizzato (tipografia,
  /// colori, spaziature), propagato invariato a tutti i renderer figli.
  final MarkdownBlockStyle style;

  /// Crea il dispatcher per [node], renderizzato con [style].
  ///
  /// La selezione NON è un parametro del costruttore: viene letta
  /// autonomamente da [markdownSelectionProvider] dentro [build]. È
  /// questa scelta a rendere la ricorsione gratuita — le istanze
  /// annidate create da [ListBlockWidget]/[QuoteBlockWidget] non hanno
  /// bisogno di alcun dato aggiuntivo — e a mantenere immutata la
  /// firma pubblica usata da `MarkdownRenderedView`.
  const MarkdownBlockWidget({
    super.key,
    required this.node,
    required this.style,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Intersezione memoizzata tra la selezione del documento e
    // l'intervallo sorgente `[node.startOffset, node.endOffset)`.
    //
    // Il `select` fa sì che questo widget venga ricostruito soltanto
    // quando cambia il VALORE dell'intersezione (uguaglianza per valore
    // di `BlockSelectionIntersection`); per i blocchi fuori selezione
    // il selettore restituisce sempre l'istanza const canonicalizzata
    // `BlockSelectionIntersection.none`, quindi il trascinamento non
    // produce per loro né rebuild né allocazioni.
    final BlockSelectionIntersection intersection = ref.watch(
      markdownSelectionProvider.select(
        (selection) => calculateBlockIntersection(
          blockStartOffset: node.startOffset,
          blockEndOffset: node.endOffset,
          selection: selection,
        ),
      ),
    );

    // Dispatch puro tipo-di-nodo → renderer: nessun figlio conosce il
    // provider, l'intersezione arriva come puro dato tramite il
    // parametro nominato `intersection` (contratto documentato sulla
    // classe).
    switch (node.type) {
      case MarkdownNodeType.heading:
        return HeadingBlockWidget(
          node: node as HeadingNode,
          style: style,
          intersection: intersection,
        );
      case MarkdownNodeType.paragraph:
        return ParagraphBlockWidget(
          node: node as ParagraphNode,
          style: style,
          intersection: intersection,
        );
      case MarkdownNodeType.codeBlock:
        return CodeBlockWidget(
          node: node as CodeBlockNode,
          style: style,
          intersection: intersection,
        );
      case MarkdownNodeType.listBlock:
        return ListBlockWidget(
          node: node as ListBlockNode,
          style: style,
          intersection: intersection,
        );
      case MarkdownNodeType.blockquote:
        return QuoteBlockWidget(
          node: node as BlockquoteNode,
          style: style,
          intersection: intersection,
        );
      case MarkdownNodeType.thematicBreak:
        // Nessuna intersezione: il separatore orizzontale non espone
        // testo sorgente evidenziabile e il suo renderer non riceve
        // nemmeno il nodo.
        return ThematicBreakBlockWidget(style: style);
      case MarkdownNodeType.tableBlock:
        return TableBlockWidget(
          node: node as TableBlockNode,
          style: style,
          intersection: intersection,
        );
      case MarkdownNodeType.mathBlock:
        return MathBlockWidget(
          node: node as MathBlockNode,
          style: style,
          intersection: intersection,
        );
      // `listItem` e `tableRow` non vengono mai passati direttamente a
      // questo dispatcher: sono consumati internamente da
      // `ListBlockWidget`/`TableBlockWidget` tramite i getter tipizzati
      // `ListBlockNode.items` / `TableBlockNode.rows`. Il contenuto
      // degli item di lista (paragrafi, code block, liste annidate, ...)
      // torna però in gioco attraverso istanze ricorsive di questo
      // stesso widget, che ricalcolano la propria intersezione dai
      // propri offset: la selezione attraversa l'annidamento senza
      // prop-drilling.
      case MarkdownNodeType.listItem:
      case MarkdownNodeType.tableRow:
        return const SizedBox.shrink();
    }
  }
}