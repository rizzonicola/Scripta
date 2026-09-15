// API-CHECK: file scritto e verificato contro l'API pubblica di
// `flutter_quill: ^11.x` e `markdown_quill: ^4.x` (le versioni disponibili
// al momento della stesura). Se `flutter pub get` risolve una versione
// successiva con rename minori (è già capitato in passato con
// `QuillEditorConfigurations` -> `QuillEditorConfig`), i punti da
// controllare per primi sono marcati `// API-CHECK` in questo file e in
// `table_embed.dart` / `divider_embed.dart` — non richiedono di norma di
// toccare la logica, solo il nome di una classe/parametro.
//
// COSA FA QUESTO FILE
// ---------------------------------------------------------------------
// Trasforma il Markdown grezzo di una nota nella struttura dati nativa di
// Quill (`Delta`, poi `Document`) invece che in una lista di widget Flutter
// costruiti a mano. Da questo momento in poi la "verità" del documento è
// quella struttura — non più una `List<String>` di blocchi accoppiata a un
// `_LogicalDocument` fatto in casa (vedi il vecchio
// `markdown_rendered_view.dart` per il confronto) — ed è Quill stesso a
// sapere, per ogni indice di carattere nel documento, a quale riga/blocco
// appartiene e come renderizzarlo: non c'è più bisogno di un motore di
// selezione parallelo.
//
// Il grosso della conversione (paragrafi, titoli, liste puntate/numerate,
// task-list, blockquote, code block, grassetto/corsivo/barrato/codice
// inline, link) è delegato a `markdown_quill` (pacchetto community
// mantenuto proprio per questo scopo, drop-in sul parser `package:markdown`
// che il resto dell'app già usa). Le tabelle GFM e i separatori orizzontali
// (`---`) non hanno una rappresentazione nativa nel modello dati di Quill
// (che è un "flat run" di testo + attributi, non un albero come HTML): li
// pre-estraiamo blocco per blocco e li inseriamo come embed custom atomici
// (vedi `table_embed.dart` / `divider_embed.dart`) — dal punto di vista
// della selezione logica di Quill un embed è un singolo carattere/indice,
// quindi entra nel range di selezione o "Seleziona tutto" esattamente come
// qualunque altro carattere, senza alcun codice speciale nostro.
import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:markdown/markdown.dart' as md;
import 'package:markdown_quill/markdown_quill.dart';

import 'divider_embed.dart';
import 'table_embed.dart';

class MarkdownDeltaConverter {
  const MarkdownDeltaConverter._();

  /// Converte l'intero Markdown di una nota in un [quill.Document] pronto
  /// per essere passato a un [quill.QuillController] in sola lettura.
  static quill.Document toDocument(String markdown) {
    final delta = _toDelta(markdown);
    return quill.Document.fromDelta(delta);
  }

  static quill.Delta _toDelta(String markdown) {
    final content = markdown.trim().isEmpty ? '*Nessun contenuto*' : markdown;
    final blocks = _splitIntoBlocks(content);

    final gfmDocument = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
    // Un solo `MarkdownToDelta` riusato per tutti i blocchi "normali": è lo
    // stesso identico convertitore che si userebbe passandogli l'intero
    // documento in un colpo solo — qui viene invocato un blocco alla volta
    // solo per poter intercalare gli embed di tabelle/hr fra un blocco e
    // l'altro, il risultato testuale/di formattazione è invariato.
    final markdownToDelta = MarkdownToDelta(markdownDocument: gfmDocument);

    final result = quill.Delta();
    for (final block in blocks) {
      final kind = _classify(block);
      switch (kind) {
        case _BlockKind.table:
          final rows = _parseTableRows(block);
          if (rows.isNotEmpty) {
            result.insert({TableEmbed.kType: jsonEncode(rows)});
            result.insert('\n');
          }
          break;
        case _BlockKind.horizontalRule:
          result.insert({DividerEmbed.kType: ''});
          result.insert('\n');
          break;
        case _BlockKind.markdown:
          final blockDelta = markdownToDelta.convert(block);
          for (final op in blockDelta.toList()) {
            result.push(op);
          }
          break;
      }
    }

    // Un Document di Quill deve terminare con un ritorno a capo "finale":
    // se l'ultimo blocco era un embed o comunque non ne ha lasciato uno,
    // lo garantiamo qui (operazione idempotente e innocua altrimenti).
    final ops = result.toList();
    final lastInsert = ops.isNotEmpty && ops.last.isInsert ? ops.last.data : null;
    if (lastInsert is! String || !lastInsert.endsWith('\n')) {
      result.insert('\n');
    }
    return result;
  }

  // -----------------------------------------------------------------
  // Suddivisione in blocchi: stessa logica (righe vuote come separatore,
  // consapevole dei fence ```) già validata nella vecchia implementazione
  // custom — qui serve solo a isolare le tabelle/hr dal resto, non più a
  // pilotare direttamente il rendering o la selezione.
  // -----------------------------------------------------------------
  static List<String> _splitIntoBlocks(String content) {
    final lines = content.split('\n');
    final blocks = <String>[];
    final current = <String>[];
    bool inCodeBlock = false;

    for (final line in lines) {
      if (line.trimLeft().startsWith('```')) {
        inCodeBlock = !inCodeBlock;
        current.add(line);
        if (!inCodeBlock) {
          blocks.add(current.join('\n'));
          current.clear();
        }
        continue;
      }
      if (inCodeBlock) {
        current.add(line);
        continue;
      }
      if (line.trim().isEmpty) {
        if (current.isNotEmpty) {
          blocks.add(current.join('\n'));
          current.clear();
        }
      } else {
        current.add(line);
      }
    }
    if (current.isNotEmpty) {
      blocks.add(current.join('\n'));
    }
    return blocks.isEmpty ? [''] : blocks;
  }

  static _BlockKind _classify(String block) {
    final trimmed = block.trim();
    if (trimmed.isEmpty) return _BlockKind.markdown;

    if (_hrPattern.hasMatch(trimmed)) {
      return _BlockKind.horizontalRule;
    }

    final lines = trimmed.split('\n');
    if (lines.length >= 2 &&
        lines[0].contains('|') &&
        _tableSeparatorPattern.hasMatch(lines[1].trim())) {
      return _BlockKind.table;
    }

    return _BlockKind.markdown;
  }

  static final RegExp _hrPattern = RegExp(r'^([-*_])\s*(\1\s*){2,}$');
  static final RegExp _tableSeparatorPattern =
      RegExp(r'^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?$');

  /// Parsing volutamente minimale delle tabelle GFM: sufficiente per il
  /// caso comune (nessuna gestione di pipe escapate `\|` dentro le celle,
  /// come nel resto dell'app non era gestita nemmeno dallo stile tabella
  /// precedente). La prima riga è l'header, la seconda (separatore) viene
  /// scartata, le successive sono righe di dati.
  static List<List<String>> _parseTableRows(String block) {
    final lines = block.trim().split('\n');
    if (lines.length < 2) return const [];
    final rows = <List<String>>[];
    for (var i = 0; i < lines.length; i++) {
      if (i == 1) continue; // riga separatore |---|---|
      rows.add(_splitTableRow(lines[i]));
    }
    return rows;
  }

  static List<String> _splitTableRow(String line) {
    var trimmed = line.trim();
    if (trimmed.startsWith('|')) trimmed = trimmed.substring(1);
    if (trimmed.endsWith('|')) trimmed = trimmed.substring(0, trimmed.length - 1);
    return trimmed.split('|').map((cell) => cell.trim()).toList();
  }
}

enum _BlockKind { markdown, table, horizontalRule }
