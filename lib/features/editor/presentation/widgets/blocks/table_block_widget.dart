import 'package:flutter/material.dart';

import '../../../models/markdown_ast_nodes.dart';
import 'block_visual_selection.dart';
import 'markdown_block_style.dart';

/// Rendering di un [TableBlockNode] (tabella GFM).
///
/// A differenza degli altri blocchi testuali, non delega a
/// `flutter_markdown_plus`: i dati (intestazioni, righe, allineamenti)
/// sono già stati estratti dal parser durante la costruzione dell'AST,
/// quindi vengono disegnati direttamente in una `Table`, senza dover
/// ri-analizzare il testo sorgente della tabella.
class TableBlockWidget extends StatelessWidget {
  final TableBlockNode node;
  final MarkdownBlockStyle style;

  /// FASE 4 — vedi `ParagraphBlockWidget.visualSelection`. Le tabelle
  /// sono trattate come blocco ATOMICO anche dal motore di selezione
  /// logica (Fase 3, vedi `MarkdownSelectionSourceMapper`): coerentemente,
  /// qui non esiste un'evidenziazione "parziale" per singola cella, solo
  /// l'evidenziazione dell'intera tabella quando `visualSelection.isFull`.
  final BlockVisualSelection visualSelection;

  const TableBlockWidget({
    super.key,
    required this.node,
    required this.style,
    this.visualSelection = BlockVisualSelection.none,
  });

  TextAlign _textAlignFor(TableColumnAlignment alignment) {
    switch (alignment) {
      case TableColumnAlignment.left:
        return TextAlign.left;
      case TableColumnAlignment.center:
        return TextAlign.center;
      case TableColumnAlignment.right:
        return TextAlign.right;
      case TableColumnAlignment.none:
        return TextAlign.left;
    }
  }

  @override
  Widget build(BuildContext context) {
    final headStyle = style.styleSheet.tableHead ??
        style.styleSheet.p?.copyWith(fontWeight: FontWeight.bold);
    final bodyStyle = style.styleSheet.tableBody ?? style.styleSheet.p;
    final cellPadding = style.styleSheet.tableCellsPadding ??
        const EdgeInsets.symmetric(horizontal: 12, vertical: 8);

    return BlockSelectionHighlight(
      visualSelection: visualSelection,
      color: style.blockSelectionHighlightColor,
      child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        border: style.styleSheet.tableBorder ??
            TableBorder.all(color: style.outlineColor.withValues(alpha: 0.4)),
        defaultColumnWidth: const IntrinsicColumnWidth(),
        children: [
          TableRow(
            decoration: BoxDecoration(
              color: style.primaryColor.withValues(alpha: 0.06),
            ),
            children: [
              for (var c = 0; c < node.columnCount; c++)
                Padding(
                  padding: cellPadding,
                  child: Text(
                    c < node.headers.length ? node.headers[c] : '',
                    style: headStyle,
                    textAlign: c < node.alignments.length
                        ? _textAlignFor(node.alignments[c])
                        : TextAlign.left,
                  ),
                ),
            ],
          ),
          for (final row in node.dataRows)
            TableRow(
              children: [
                for (var c = 0; c < node.columnCount; c++)
                  Padding(
                    padding: cellPadding,
                    child: Text(
                      c < row.length ? row[c] : '',
                      style: bodyStyle,
                      textAlign: c < node.alignments.length
                          ? _textAlignFor(node.alignments[c])
                          : TextAlign.left,
                    ),
                  ),
              ],
            ),
        ],
      ),
      ),
    );
  }
}
