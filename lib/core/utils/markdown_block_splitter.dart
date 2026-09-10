/// Suddivide una sorgente Markdown in blocchi indipendenti, ciascuno
/// renderizzabile da un widget separato (vedi `markdown_rendered_view.dart`).
///
/// PERCHÉ: prima di questa suddivisione, l'intero contenuto di una nota
/// veniva passato in un colpo solo a un singolo `MarkdownBody`, che quindi
/// costruiva l'intero albero di widget renderizzati indipendentemente da
/// cosa fosse effettivamente visibile a schermo. Per note grandi/grandissime
/// questo significa parse + layout dell'intero documento prima ancora di
/// mostrare il primo frame. Con questa suddivisione, ogni blocco diventa un
/// "item" di una `ListView.builder`: solo i blocchi vicini al viewport
/// vengono effettivamente costruiti (vedi `cacheExtent` generoso in
/// `MarkdownRenderedView`), realizzando lazy loading/virtualizzazione senza
/// bisogno di riscrivere il motore di rendering Markdown.
///
/// LIMITE NOTO E ACCETTATO: poiché ogni blocco viene poi parsato in modo
/// indipendente dal proprio `MarkdownBody`, i costrutti Markdown che
/// dipendono da un contesto DELL'INTERO documento (link in stile
/// "reference" tipo `[testo][id]` con definizione `[id]: url` altrove nel
/// documento, o note a piè di pagina) non vengono risolti correttamente
/// attraverso i confini di blocco. Sintassi inline "auto-contenuta"
/// (grassetto, corsivo, link con URL esplicito, codice inline, immagini,
/// blocchi di codice, tabelle, liste, citazioni) funziona esattamente come
/// prima: sono costrutti rari in un'app di note e il compromesso è stato
/// giudicato accettabile per il guadagno di prestazioni ottenuto.
class MarkdownBlockSplitter {
  MarkdownBlockSplitter._();

  static final RegExp _listItemPattern =
      RegExp(r'^(\s*)([-*+]|\d+[.)])\s+');
  static final RegExp _indentedContinuationPattern = RegExp(r'^\s+\S');

  /// Divide [content] in blocchi Markdown "sicuri da renderizzare
  /// separatamente". Il confine naturale tra blocchi è la riga vuota, MA:
  ///  - non si spezza mai dentro un blocco di codice delimitato da ``` o ~~~
  ///    (altrimenti il fence verrebbe interpretato come chiuso a metà);
  ///  - non si spezza una lista "loose" (elementi separati da righe vuote)
  ///    se la riga successiva non vuota è ancora un elemento della stessa
  ///    lista o una sua continuazione indentata, per non spezzare la
  ///    numerazione/il markup di liste ordinate o annidate.
  static List<String> split(String content) {
    if (content.trim().isEmpty) return const [];

    final lines = content.split('\n');
    final blocks = <String>[];
    var current = <String>[];

    String? fenceMarker; // ``` o ~~~ correntemente aperto, se presente
    int fenceLength = 0;

    void flushCurrent() {
      if (current.isEmpty) return;
      final block = current.join('\n').trim();
      current = [];
      if (block.isNotEmpty) blocks.add(block);
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmedLine = line.trimLeft();

      // --- Gestione fence di codice (``` o ~~~) ---
      if (fenceMarker == null) {
        final fenceMatch = RegExp(r'^(`{3,}|~{3,})').firstMatch(trimmedLine);
        if (fenceMatch != null) {
          fenceMarker = fenceMatch.group(1)!.substring(0, 1);
          fenceLength = fenceMatch.group(1)!.length;
        }
      } else {
        final escapedMarker = RegExp.escape(fenceMarker);
        final closeMatch =
            RegExp('^($escapedMarker{$fenceLength,})\\s*\$')
                .firstMatch(trimmedLine);
        if (closeMatch != null) {
          fenceMarker = null;
          fenceLength = 0;
        }
      }

      current.add(line);

      final insideFence = fenceMarker != null;
      final isBlankLine = line.trim().isEmpty;

      if (!insideFence && isBlankLine) {
        // Guarda avanti oltre eventuali righe vuote consecutive.
        var next = i + 1;
        while (next < lines.length && lines[next].trim().isEmpty) {
          next++;
        }
        final nextLine = next < lines.length ? lines[next] : null;

        final lastNonBlank = current.reversed.firstWhere(
          (l) => l.trim().isNotEmpty,
          orElse: () => '',
        );

        final continuesList = nextLine != null &&
            lastNonBlank.isNotEmpty &&
            _listItemPattern.hasMatch(lastNonBlank) &&
            (_listItemPattern.hasMatch(nextLine) ||
                _indentedContinuationPattern.hasMatch(nextLine));

        if (!continuesList) {
          flushCurrent();
        }
      }
    }

    flushCurrent();
    return blocks;
  }
}
