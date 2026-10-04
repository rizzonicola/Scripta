import 'package:path/path.dart' as p;

import 'export_archive.dart' show sanitizeFileName, uncatalogedFolderName;

// Traduzione PURA (nessuna UI, nessun I/O, nessun provider) di ciò che
// l'importazione trova — percorsi di voci ZIP o di file su disco, testo dei
// file Markdown — in ciò che l'app mostra: cartelle, titolo e corpo delle
// note.
//
// Sta in un file a sé, accanto a `export_archive.dart`, per due motivi:
//  * condivide con l'esportazione le due convenzioni da cui dipende la
//    simmetria dei due percorsi — il nome della cartella delle note senza
//    cartella ([uncatalogedFolderName]) e la sanitizzazione dei nomi di file
//    ([sanitizeFileName]) — invece di duplicarle: l'importazione le ignorava
//    ed è da lì che nascevano due difetti (vedi [mapZipEntryPath] e
//    [parseNoteFile]);
//  * è testabile su qualunque piattaforma con un semplice `flutter test`,
//    senza interfaccia né database.

/// Estensioni dei file che l'importazione tratta come note.
const List<String> importableExtensions = ['.md', '.markdown', '.txt'];

/// `true` se [fileName] (o un percorso) termina con un'estensione importabile.
bool hasImportableExtension(String fileName) {
  final lower = fileName.toLowerCase();
  return importableExtensions.any(lower.endsWith);
}

/// Voce grezza estratta da un file (ZIP o filesystem) durante l'import,
/// ancora priva di un folderId reale: [folderPathSegments] è il percorso
/// relativo (una cartella per elemento, radice esclusa) che verrà
/// risolto/creato in cartelle vere soltanto al momento del commit, per poter
/// riutilizzare cartelle già esistenti con lo stesso nome invece di
/// duplicarle. Una lista VUOTA significa "radice": la nota non ha cartella
/// e compare soltanto in "Tutte le note".
class ImportEntry {
  final List<String> folderPathSegments;
  final String fileName;
  final String rawContent;

  const ImportEntry({
    required this.folderPathSegments,
    required this.fileName,
    required this.rawContent,
  });
}

/// Posizione di un file importato: cartelle (radice esclusa) e nome del file.
typedef ImportLocation = ({List<String> folders, String fileName});

/// Titolo e corpo di una nota ricavati da un file Markdown.
typedef ParsedNote = ({String title, String content});

// ---------------------------------------------------------------------------
// Percorsi
// ---------------------------------------------------------------------------

final RegExp _driveLetterPrefix = RegExp(r'^[A-Za-z]:');

/// Cartella con cui macOS (Finder / Utility Archivio) affianca le "resource
/// fork" nei suoi ZIP: contiene solo rumore (`._Nota.md`) con estensione
/// `.md` che, importato, diventerebbe una cartella e delle note di
/// spazzatura.
const String _macosResourceDir = '__macosx';

/// `true` se [name] è la cartella con cui l'esportazione raccoglie le note
/// senza cartella. Il confronto ignora maiuscole e spazi ai bordi, come la
/// ricerca delle cartelle già esistenti in fase di commit.
bool isUncatalogedFolderName(String name) =>
    name.trim().toLowerCase() == uncatalogedFolderName.toLowerCase();

/// Traduce il nome di una voce ZIP in cartelle + nome file, oppure `null` se
/// la voce va ignorata (non è una nota, è rumore del sistema operativo o
/// punta fuori dalla gerarchia che si sta costruendo).
///
/// RADICE: l'esportazione scrive le note senza cartella (o con cartella
/// ignota) in `Non_Catalogate/`. È un contenitore dell'ARCHIVIO, non una
/// cartella dell'utente: le note che stanno direttamente al suo interno
/// tornano alla radice (`folders` vuoto → "Tutte le note"). Prima veniva
/// trattata come una cartella qualunque e ricreata in sidebar a ogni
/// importazione. Solo il livello più alto è speciale: `Lavoro/Non_Catalogate/`
/// o `Non_Catalogate/Sotto/` non possono essere stati prodotti dal
/// contenitore, quindi sono cartelle vere e restano tali.
///
/// MULTI-PIATTAFORMA: gli ZIP dovrebbero usare `/`, ma alcuni strumenti
/// Windows (Compress-Archive di PowerShell 5, vecchie versioni di .NET)
/// scrivono `\`; i due separatori sono equivalenti. Percorsi assoluti, UNC
/// (`\\server\share`), lettere di unità (`C:`) e `..` sono rifiutati
/// (path traversal).
ImportLocation? mapZipEntryPath(String entryName) {
  final normalized = entryName.replaceAll('\\', '/');
  if (normalized.startsWith('/') || _driveLetterPrefix.hasMatch(normalized)) {
    return null;
  }
  return _mapSegments(normalized.split('/'));
}

/// Come [mapZipEntryPath], ma per un file trovato scegliendo una CARTELLA sul
/// filesystem: [filePath] è il percorso del file, [rootPath] quello della
/// cartella scelta.
///
/// Il percorso relativo si calcola e si spezza con le regole del [context]
/// (di default quelle NATIVE della piattaforma, `package:path`): su Windows
/// `\` separa i segmenti e `C:` è un'unità; su Linux, macOS, Android e
/// iOS `\` è un carattere legale di un nome di file, non un separatore.
/// Il parametro esiste perché i test verifichino entrambe le convenzioni su
/// qualunque sistema.
ImportLocation? mapFilePath(
  String filePath, {
  required String rootPath,
  p.Context? context,
}) {
  final c = context ?? p.context;
  return mapFileSystemPath(c.split(c.relative(filePath, from: rootPath)));
}

/// Parte pura di [mapFilePath]: [segments] è già il percorso RELATIVO alla
/// cartella scelta, spezzato con le regole della piattaforma.
ImportLocation? mapFileSystemPath(List<String> segments) =>
    _mapSegments(segments);

ImportLocation? _mapSegments(List<String> rawSegments) {
  final segments = <String>[];
  for (final segment in rawSegments) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') return null;
    segments.add(segment);
  }
  if (segments.isEmpty) return null;

  final fileName = segments.removeLast();
  if (!hasImportableExtension(fileName)) return null;

  if (segments.isNotEmpty && segments.first.toLowerCase() == _macosResourceDir) {
    return null;
  }
  // AppleDouble: `._Nota.md` accompagna `Nota.md` e ne contiene i metadati.
  if (fileName.startsWith('._')) return null;

  return (folders: _withoutUncatalogedBucket(segments), fileName: fileName);
}

List<String> _withoutUncatalogedBucket(List<String> folders) {
  if (folders.length == 1 && isUncatalogedFolderName(folders.first)) {
    return const <String>[];
  }
  return folders;
}

// ---------------------------------------------------------------------------
// Titolo e contenuto
// ---------------------------------------------------------------------------

final RegExp _extension = RegExp(r'\.(md|markdown|txt)$', caseSensitive: false);

/// Suffisso con cui l'esportazione distingue due note con lo stesso titolo
/// nella stessa cartella: `Riunione.md`, `Riunione (2).md`, ...
final RegExp _collisionSuffix = RegExp(r'^ \(\d+\)$');

/// Nomi che l'esportazione inventa quando la nota NON ha un titolo
/// (`Nota_<primi 6 caratteri dell'id>`, `Nota_senza_titolo`) o che altri
/// programmi usano per un file senza nome. Non dicono nulla sulla nota.
final RegExp _generatedName = RegExp(
  r'^(?:Nota_[0-9a-f]{6}|Nota_senza_titolo|untitled)(?: \(\d+\))?$',
  caseSensitive: false,
);

/// Toglie il BOM UTF-8 (Blocco Note di Windows lo scrive) e porta a capo
/// `\r\n` / `\r` a `\n`: un `\r` residuo finirebbe dentro al corpo della nota.
String normalizeImportedText(String raw) {
  var text = raw;
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  if (text.contains('\r')) {
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }
  return text;
}

/// Ricava titolo e corpo da un file Markdown importato.
///
/// CHI DETTA IL TITOLO. Il titolo di una nota è il NOME DEL FILE: è ciò che
/// scrive `buildNotesZip` ed è ciò che usano tutte le app basate su file. La
/// riga `# Titolo` in testa è invece, di norma, solo l'ECO del titolo che
/// l'esportazione antepone (`noteMarkdownContent`) quando il testo non
/// inizia già con un titolo di primo livello. Quando però il testo della
/// nota inizia con un proprio `# ...`, l'esportazione NON antepone nulla e il
/// titolo vero sopravvive solo nel nome del file. Dare la precedenza alla
/// riga `# ...` (come si faceva) significava sostituire `1 - Nome Nota` con
/// `Nome Nota` e cancellare l'intestazione dal corpo. Regole:
///
///  1. nessun titolo di primo livello in testa → titolo = nome del file,
///     corpo = testo invariato;
///  2. il titolo in testa è l'eco del nome del file (stesso testo, a meno dei
///     caratteri illegali nei nomi di file e dell'eventuale suffisso
///     ` (2)` delle collisioni) → titolo = quello della riga, che conserva i
///     caratteri originali (`1/2`, `:`), e la riga esce dal corpo per non
///     duplicarlo nell'editor, che mostra titolo e corpo in campi separati;
///  3. il nome del file è solo un segnaposto (`Nota_ab12cd`, `untitled`...) →
///     il titolo in testa è la sola informazione disponibile: come in 2;
///  4. in ogni altro caso l'intestazione fa parte del TESTO: titolo = nome del
///     file, corpo = testo invariato.
ParsedNote parseNoteFile(String raw, String fileName) {
  final text = normalizeImportedText(raw);
  final baseName = fileName.replaceAll(_extension, '').trim();
  final fileTitle = baseName.isEmpty ? 'Nota importata' : baseName;

  final lines = text.split('\n');
  var idx = 0;
  while (idx < lines.length && lines[idx].trim().isEmpty) {
    idx++;
  }

  final heading = idx < lines.length ? _firstLevelHeading(lines[idx]) : null;
  if (heading == null) return (title: fileTitle, content: text);

  final isTitleEcho = heading.isEmpty ||
      _echoesFileName(heading, baseName) ||
      _generatedName.hasMatch(baseName);
  if (!isTitleEcho) return (title: fileTitle, content: text);

  var contentStart = idx + 1;
  if (contentStart < lines.length && lines[contentStart].trim().isEmpty) {
    contentStart++;
  }
  return (
    title: heading.isEmpty ? fileTitle : heading,
    content: lines.sublist(contentStart).join('\n'),
  );
}

/// Testo di una riga `# Titolo`, oppure `null` se la riga non lo è.
String? _firstLevelHeading(String line) {
  final trimmed = line.trimLeft();
  if (!trimmed.startsWith('# ')) return null;
  return trimmed.substring(2).trim();
}

/// `true` se [baseName] è il nome di file che l'esportazione avrebbe dato a
/// una nota intitolata [heading]: stessa sanitizzazione e, se serve, il suffisso
/// delle collisioni. Il confronto ignora le maiuscole (Windows e macOS non le
/// distinguono nei nomi di file).
bool _echoesFileName(String heading, String baseName) {
  final expected = sanitizeFileName(heading).toLowerCase();
  final actual = baseName.toLowerCase();
  if (!actual.startsWith(expected)) return false;
  return actual.length == expected.length ||
      _collisionSuffix.hasMatch(actual.substring(expected.length));
}
