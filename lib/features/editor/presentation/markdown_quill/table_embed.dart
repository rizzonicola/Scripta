import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;

/// Dati grezzi di una tabella GFM dentro il [quill.Document]: il tipo
/// dell'embed è la chiave [kType] (vedi [MarkdownDeltaConverter]), il
/// valore è una stringa JSON `List<List<String>>` (prima riga = header).
class TableEmbed {
  const TableEmbed._();
  static const String kType = 'md_table';
}

/// `EmbedBuilder` registrato su [quill.QuillEditorConfig.embedBuilders]:
/// Quill lo invoca per disegnare l'embed quando il suo indice logico
/// rientra nella viewport — stesso identico meccanismo di un `EmbedBuilder`
/// per un'immagine, non è un caso speciale.
class TableEmbedBuilder extends quill.EmbedBuilder {
  final bool isDark;
  final Color primaryColor;
  final Color borderColor;
  final TextStyle headerStyle;
  final TextStyle cellStyle;

  TableEmbedBuilder({
    required this.isDark,
    required this.primaryColor,
    required this.borderColor,
    required this.headerStyle,
    required this.cellStyle,
  });

  @override
  String get key => TableEmbed.kType;

  // API-CHECK: firma di `build` verificata contro flutter_quill ^11.x
  // (parametro unico `EmbedContext`). Su versioni precedenti la firma era
  // `build(BuildContext context, quill.QuillController controller,
  // quill.Embed node, bool readOnly, bool inline, TextStyle textStyle)`:
  // se il compilatore segnala un mismatch qui, è questo l'unico punto da
  // adattare — il corpo del metodo resta invariato, cambia solo da dove si
  // legge `node`/`data`.
  @override
  Widget build(BuildContext context, quill.EmbedContext embedContext) {
    final raw = embedContext.node.value.data as String;
    final rows = (jsonDecode(raw) as List)
        .map((row) => (row as List).map((c) => c.toString()).toList())
        .toList();
    if (rows.isEmpty) return const SizedBox.shrink();

    final header = rows.first;
    final body = rows.skip(1).toList();
    final zebraColor = (isDark ? Colors.white : Colors.black).withValues(alpha: 0.03);

    // `RepaintBoundary`: isola il repaint della tabella da quello del
    // testo circostante — utile perché la tabella è il widget più
    // "pesante" (un `Table` con più celle) fra tutti gli embed, e non
    // deve ridisegnarsi solo perché una riga di testo sopra o sotto lo fa
    // (es. durante lo scroll, l'animazione della selezione, ecc.).
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: borderColor, width: 1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Table(
                // Fix: `FlexColumnWidth` (il default) dentro una
                // `SingleChildScrollView(scrollDirection: horizontal)` —
                // quindi a larghezza non vincolata — può collassare le
                // colonne a pochi pixel, forzando il testo ad andare a
                // capo lettera per lettera (il glitch a colonna verticale
                // segnalato). `IntrinsicColumnWidth` misura la dimensione
                // reale del contenuto di ogni cella e non richiede un
                // genitore vincolato: è la scelta corretta qui.
                defaultColumnWidth: const IntrinsicColumnWidth(),
                border: TableBorder(
                  horizontalInside: BorderSide(color: borderColor, width: 1),
                  verticalInside: BorderSide(color: borderColor, width: 1),
                ),
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                children: [
                  TableRow(
                    decoration:
                        BoxDecoration(color: primaryColor.withValues(alpha: 0.12)),
                    children: [
                      for (final cell in header) _cell(cell, headerStyle),
                    ],
                  ),
                  for (var r = 0; r < body.length; r++)
                    TableRow(
                      // Zebra striping: righe alternate leggermente
                      // tinte, come nella vecchia vista Markdown — aiuta
                      // a seguire l'allineamento orizzontale su tabelle
                      // con molte righe.
                      decoration: BoxDecoration(
                        color: r.isOdd ? zebraColor : null,
                      ),
                      children: [
                        for (var i = 0; i < header.length; i++)
                          _cell(i < body[r].length ? body[r][i] : '', cellStyle),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cell(String text, TextStyle style) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: ConstrainedBox(
          // Larghezza minima: evita colonne troppo strette/schiacciate
          // quando il contenuto della cella è breve (es. "Sì"/"No"),
          // mantenendo comunque `IntrinsicColumnWidth` libero di crescere
          // oltre per celle con testo più lungo.
          constraints: const BoxConstraints(minWidth: 72),
          child: Text(text, style: style, textAlign: TextAlign.left),
        ),
      );
}
