import 'dart:math' as math;

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
///
/// ## Selezione a grana fine cella per cella
///
/// Se [intersection.type] è diverso da [SelectionType.none], la tabella NON
/// viene evidenziata come un blocco unico. Ciascuna cella calcola la propria
/// finestra di offset rispetto alla riga e al blocco tabella:
/// solo il testo che ricade nell'intervallo `[intersection.localStart, intersection.localEnd)`
/// riceve lo sfondo azzurro di selezione (`backgroundColor: highlightColor`),
/// mentre le celle non toccate rimangono con il loro stile e sfondo originale invariato.
class TableBlockWidget extends StatelessWidget {
  final TableBlockNode node;
  final MarkdownBlockStyle style;

  /// Intersezione tra la selezione del documento e questo blocco tabella.
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
    final highlightColor =
        Theme.of(context).colorScheme.primary.withValues(alpha: 0.28);

    final int colCount = math.max(1, node.columnCount);
    final int totalRows = 1 + node.dataRows.length;
    final int blockLength = math.max(1, node.length);

    (int, int) getRowOffsets(int r) {
      if (r < node.rows.length) {
        final rowNode = node.rows[r];
        final start =
            (rowNode.startOffset - node.startOffset).clamp(0, blockLength);
        final end =
            (rowNode.endOffset - node.startOffset).clamp(start, blockLength);
        return (start, end);
      }
      final double fraction = blockLength / totalRows;
      final start = (r * fraction).round().clamp(0, blockLength);
      final end = ((r + 1) * fraction).round().clamp(start, blockLength);
      return (start, end);
    }

    Widget buildCell({
      required String text,
      required TextStyle? textStyle,
      required TextAlign align,
      required int rowIndex,
      required int colIndex,
    }) {
      final (rowStart, rowEnd) = getRowOffsets(rowIndex);
      final int rowSpan = math.max(1, rowEnd - rowStart);
      final double colWidth = rowSpan / colCount;
      final int cellStart = rowStart + (colIndex * colWidth).round();
      final int cellEnd = (colIndex == colCount - 1)
          ? rowEnd
          : rowStart + ((colIndex + 1) * colWidth).round();

      final bool hasIntersection =
          intersection.type != SelectionType.none &&
          intersection.localEnd > cellStart &&
          intersection.localStart < cellEnd &&
          text.isNotEmpty;

      Widget textWidget;
      if (!hasIntersection) {
        textWidget = Text(text, style: textStyle, textAlign: align);
      } else {
        final int cellLen = math.max(1, cellEnd - cellStart);
        final int selStartInCell =
            ((intersection.localStart - cellStart) * text.length / cellLen)
                .round()
                .clamp(0, text.length);
        final int selEndInCell =
            ((intersection.localEnd - cellStart) * text.length / cellLen)
                .round()
                .clamp(0, text.length);

        if (selStartInCell >= selEndInCell) {
          textWidget = Text(text, style: textStyle, textAlign: align);
        } else {
          textWidget = Text.rich(
            TextSpan(
              style: textStyle,
              children: [
                if (selStartInCell > 0)
                  TextSpan(text: text.substring(0, selStartInCell)),
                TextSpan(
                  text: text.substring(selStartInCell, selEndInCell),
                  style: (textStyle ?? const TextStyle()).copyWith(
                    backgroundColor: highlightColor,
                  ),
                ),
                if (selEndInCell < text.length)
                  TextSpan(text: text.substring(selEndInCell)),
              ],
            ),
            textAlign: align,
          );
        }
      }

      return Padding(
        padding: cellPadding,
        child: textWidget,
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
              color: style.primaryColor.withValues(alpha: 0.06),
            ),
            children: [
              for (var c = 0; c < node.columnCount; c++)
                buildCell(
                  text: c < node.headers.length ? node.headers[c] : '',
                  textStyle: headStyle,
                  align: c < node.alignments.length
                      ? _textAlignFor(node.alignments[c])
                      : TextAlign.left,
                  rowIndex: 0,
                  colIndex: c,
                ),
            ],
          ),
          for (var r = 0; r < node.dataRows.length; r++)
            TableRow(
              children: [
                for (var c = 0; c < node.columnCount; c++)
                  buildCell(
                    text: c < node.dataRows[r].length ? node.dataRows[r][c] : '',
                    textStyle: bodyStyle,
                    align: c < node.alignments.length
                        ? _textAlignFor(node.alignments[c])
                        : TextAlign.left,
                    rowIndex: r + 1,
                    colIndex: c,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
