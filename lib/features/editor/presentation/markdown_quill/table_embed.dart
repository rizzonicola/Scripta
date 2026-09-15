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
  final TextStyle headerStyle;
  final TextStyle cellStyle;

  TableEmbedBuilder({
    required this.isDark,
    required this.primaryColor,
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
    final borderColor =
        (isDark ? Colors.white : Colors.black).withValues(alpha: 0.18);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          border: TableBorder.all(color: borderColor, width: 1),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            TableRow(
              decoration: BoxDecoration(color: primaryColor.withValues(alpha: 0.08)),
              children: [
                for (final cell in header) _cell(cell, headerStyle),
              ],
            ),
            for (final row in body)
              TableRow(
                children: [
                  for (var i = 0; i < header.length; i++)
                    _cell(i < row.length ? row[i] : '', cellStyle),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _cell(String text, TextStyle style) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(text, style: style, textAlign: TextAlign.left),
      );
}
