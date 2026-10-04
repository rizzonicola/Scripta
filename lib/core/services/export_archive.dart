import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../features/folders/models/folder_node.dart';

// Costruzione pura (nessuna UI, nessun I/O) degli archivi ZIP di esportazione.
//
// Tutto ciò che attraversa il confine dell'isolate (vedi `compute` in
// `ExportService`) è fatto solo di tipi primitivi e record: niente
// `NoteModel`/`FolderNode`, niente riferimenti a oggetti Flutter. Prima
// veniva copiata nell'isolate l'INTERA collezione di note anche per
// esportare una sola cartella.

/// Dati minimi di una nota per l'archivio.
typedef ExportNote = ({String id, String title, String content, String? folderId});

/// Cartella "appiattita". `parentId` è `null` per la radice dell'esportazione
/// (un backup completo ne ha più d'una, l'export di una cartella una sola).
typedef ExportFolder = ({String id, String name, String? parentId});

/// Cartelle da includere e note da scrivere.
typedef ZipRequest = ({List<ExportFolder> folders, List<ExportNote> notes});

typedef ZipResult = ({Uint8List bytes, int noteCount});

/// Cartella che raccoglie le note senza cartella (o con cartella ignota)
/// nel backup completo.
///
/// È un contenitore dell'ARCHIVIO, non una cartella dell'utente:
/// l'importazione (`import_parser.dart`, che legge questa stessa costante)
/// riporta alla radice le note che stanno direttamente al suo interno. I
/// backup già prodotti conservano il nome com'era quando sono stati creati:
/// cambiarlo qui significherebbe non riconoscerli più all'importazione.
const String uncatalogedFolderName = 'Non_Catalogate';

final RegExp _illegalNameChars = RegExp(r'[\\/:*?"<>|\x00-\x1F]');

/// Rende [name] utilizzabile come nome di file su Windows, macOS e Linux.
String sanitizeFileName(String name) {
  final sanitized = name.replaceAll(_illegalNameChars, '_').trim();
  return sanitized.isEmpty ? 'untitled' : sanitized;
}

/// Come [sanitizeFileName], ma per un segmento di percorso: `.` e `..`
/// (o nomi fatti di soli punti) sono navigazione, non nomi di cartella, e in
/// uno ZIP diventerebbero una voce con path traversal.
String sanitizeFolderName(String name) {
  final sanitized = sanitizeFileName(name);
  return sanitized.replaceAll('.', '').isEmpty ? '_' : sanitized;
}

/// Contenuto Markdown di una nota: se il testo non inizia già con un titolo
/// di primo livello, il titolo della nota viene anteposto.
String noteMarkdownContent(String title, String content) {
  if (!content.startsWith('# ') && title.trim().isNotEmpty) {
    return '# $title\n\n$content';
  }
  return content;
}

/// Appiattisce [roots] in pre-ordine. Le radici hanno `parentId == null`,
/// qualunque sia il loro `parentId` nel nodo: chi esporta un sottoalbero ne
/// ottiene percorsi relativi alla cartella scelta.
List<ExportFolder> flattenFolderTree(List<FolderNode> roots) {
  final result = <ExportFolder>[];
  void visit(FolderNode node, String? parentId) {
    result.add((id: node.id, name: node.name, parentId: parentId));
    for (final child in node.children) {
      visit(child, node.id);
    }
  }

  for (final root in roots) {
    visit(root, null);
  }
  return result;
}

String _shortId(String id) => id.length > 6 ? id.substring(0, 6) : id;

/// Percorso `dir/baseName.md` non ancora usato. Il confronto ignora le
/// maiuscole perché su Windows e macOS `Nota.md` e `nota.md` sono lo stesso
/// file. Collisioni → `baseName (2).md`, `baseName (3).md`, ...
String _uniquePath(Set<String> usedLowercase, String dir, String baseName) {
  var candidate = '$dir/$baseName.md';
  var counter = 2;
  while (!usedLowercase.add(candidate.toLowerCase())) {
    candidate = '$dir/$baseName ($counter).md';
    counter++;
  }
  return candidate;
}

/// Costruisce e codifica lo ZIP. Funzione TOP-LEVEL perché è il requisito di
/// `compute`: la compressione è CPU-bound e sincrona, e sul thread della UI
/// bloccherebbe l'interfaccia per tutta la durata su backup voluminosi.
///
/// A differenza della versione precedente:
///  * due note con lo stesso titolo nella stessa cartella NON si
///    sovrascrivono più (l'ultima sostituiva la prima nell'archivio: una
///    nota spariva in silenzio da un backup);
///  * un id più corto di 6 caratteri non fa più fallire l'intera esportazione;
///  * i nomi delle cartelle sono sanitizzati come quelli delle note;
///  * il percorso di ogni cartella si risolve una volta sola (prima: una
///    scansione di tutte le note per ogni cartella).
ZipResult buildNotesZip(ZipRequest request) {
  final folderById = <String, ExportFolder>{
    for (final folder in request.folders) folder.id: folder,
  };

  final pathCache = <String, String>{};
  String? resolveFolderPath(String folderId) {
    final cached = pathCache[folderId];
    if (cached != null) return cached;

    // Risale da [folderId] alla radice. `seen` rende la risalita sicura anche
    // con riferimenti `parentId` ciclici in dati corrotti.
    final segments = <String>[];
    final seen = <String>{};
    String? current = folderId;
    while (current != null && seen.add(current)) {
      final folder = folderById[current];
      if (folder == null) break;
      segments.add(sanitizeFolderName(folder.name));
      current = folder.parentId;
    }
    if (segments.isEmpty) return null;

    final path = segments.reversed.join('/');
    pathCache[folderId] = path;
    return path;
  }

  final archive = Archive();
  final usedPaths = <String>{};
  var noteCount = 0;

  for (final note in request.notes) {
    final folderId = note.folderId;
    final dir = (folderId == null ? null : resolveFolderPath(folderId)) ??
        uncatalogedFolderName;
    final baseName = sanitizeFileName(
      note.title.trim().isEmpty ? 'Nota_${_shortId(note.id)}' : note.title,
    );
    final path = _uniquePath(usedPaths, dir, baseName);

    final bytes = utf8.encode(noteMarkdownContent(note.title, note.content));
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
    noteCount++;
  }

  final encoded = ZipEncoder().encode(archive);
  return (bytes: Uint8List.fromList(encoded), noteCount: noteCount);
}
