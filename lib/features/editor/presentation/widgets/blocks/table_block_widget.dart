import 'package:flutter/material.dart';

import '../../../domain/models/markdown_selection_range.dart';
import '../../../models/markdown_ast_nodes.dart';
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

  /// Intersezione tra la selezione del documento e questo blocco.
  ///
  /// L'AST non conserva l'offset di sorgente di ogni singola cella,
  /// quindi quando [SelectionType.full] o [SelectionType.partial]
  /// indicano che la tabella è coinvolta dalla selezione, lo sfondo di
  /// evidenziazione viene applicato a tutte le celle (intestazione e
  /// corpo), senza distinzione a grana fine tra le celle.
  final BlockSelectionIntersection intersection;

  const TableBlockWidget({
    super.key,
    required this.node,
    required this.style,
    this.intersection = BlockSelectionIntersection.none,
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
    final highlighted = intersection.type != SelectionType.none;
    final highlightColor =
        Theme.of(context).colorScheme.primary.withValues(alpha: 0.28);

    Widget buildCell(String text, TextStyle? textStyle, TextAlign align) {
      final cell = Padding(
        padding: cellPadding,
        child: Text(text, style: textStyle, textAlign: align),
      );
      if (!highlighted) return cell;
      return DecoratedBox(
        decoration: BoxDecoration(color: highlightColor),
        child: cell,
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        border: style.styleSheet.tableBorder ??
            TableBorder.all(color: style.outlineColor.withValues(alpha: 0.4)),
        defaultColumnWidth: const IntrinsicColumnWidth(),
        children: [
          TableRow(
            decoration: BoxDecoration(
              color: highlighted
                  ? highlightColor
                  : style.primaryColor.withValues(alpha: 0.06),
            ),
            children: [
              for (var c = 0; c < node.columnCount; c++)
                buildCell(
                  c < node.headers.length ? node.headers[c] : '',
                  headStyle,
                  c < node.alignments.length
                      ? _textAlignFor(node.alignments[c])
                      : TextAlign.left,
                ),
            ],
          ),
          for (final row in node.dataRows)
            TableRow(
              children: [
                for (var c = 0; c < node.columnCount; c++)
                  buildCell(
                    c < row.length ? row[c] : '',
                    bodyStyle,
                    c < node.alignments.length
                        ? _textAlignFor(node.alignments[c])
                        : TextAlign.left,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
