import 'dart:ui' show TextRange;

/// Limite difensivo condiviso da tutte le ricerche nel testo: una query di un
/// solo carattere su una nota enorme non deve produrre decine di migliaia di
/// occorrenze (e di `TextSpan`) da disegnare.
const int maxTextSearchMatches = 2000;

/// Occorrenze di [query] in [text], senza distinzione tra maiuscole e
/// minuscole e senza sovrapposizioni.
///
/// È l'unico motore di ricerca del testo: sia il sorgente Markdown (editor)
/// sia il testo reso (vista di lettura) passano da qui, così limite e
/// semantica non possono divergere tra le due modalità.
List<TextRange> findTextMatches(
  String text,
  String query, {
  int maxMatches = maxTextSearchMatches,
}) {
  if (text.isEmpty) return const [];
  return findTextMatchesInLowercase(
    text.toLowerCase(),
    query,
    maxMatches: maxMatches,
  );
}

/// Variante per i chiamanti che tengono già una copia in minuscolo del testo
/// (es. la cache del contenuto della nota attiva): evita di riconvertire
/// l'intera nota a ogni carattere digitato nella query.
List<TextRange> findTextMatchesInLowercase(
  String lowerText,
  String query, {
  int maxMatches = maxTextSearchMatches,
}) {
  final trimmed = query.trim();
  if (trimmed.isEmpty || lowerText.isEmpty || maxMatches <= 0) {
    return const [];
  }

  final lowerQuery = trimmed.toLowerCase();
  final matches = <TextRange>[];
  var searchStart = 0;
  while (matches.length < maxMatches) {
    final index = lowerText.indexOf(lowerQuery, searchStart);
    if (index < 0) break;
    final end = index + lowerQuery.length;
    matches.add(TextRange(start: index, end: end));
    searchStart = end;
  }
  return matches;
}
