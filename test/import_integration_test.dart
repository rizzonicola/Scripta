import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/database/folders_dao.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:scripta/core/services/export_archive.dart';
import 'package:scripta/core/services/import_parser.dart';
import 'package:scripta/core/services/import_service.dart';
import 'package:scripta/features/folders/providers/folder_provider.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Integrazione: esportazione → archivio (o cartella su disco) → importazione,
// con i veri `FolderNotifier` / `NotesNotifier` e DAO IN MEMORIA al posto di
// SQLite. Si verifica ciò che l'utente vede dopo l'importazione:
//  * le note che l'esportazione mette in `Non_Catalogate/` stanno alla radice
//    ("Tutte le note"), e nessuna cartella con quel nome compare in sidebar;
//  * il titolo di ogni nota è quello originale, prefisso numerico compreso.
//
// Le asserzioni leggono le righe che i notifier hanno scritto nei DAO: è ciò
// che SQLite conserverebbe, e la fonte di verità dell'app (UI reattiva al DB).

// ---------------------------------------------------------------------------
// DAO in memoria
// ---------------------------------------------------------------------------

class _MemoryNotesDao implements NotesDao {
  final Map<String, NoteRow> rows = {};

  @override
  Future<List<NoteRow>> getActive() async =>
      rows.values.where((r) => !r.isDeleted).toList();

  @override
  Future<void> upsert(NoteRow row) async => rows[row.id] = row;

  @override
  Future<void> upsertBatch(List<NoteRow> list) async {
    for (final r in list) {
      rows[r.id] = r;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _MemoryFoldersDao implements FoldersDao {
  final Map<String, FolderRow> rows = {};

  @override
  Future<List<FolderRow>> getActive() async =>
      rows.values.where((r) => !r.isDeleted).toList();

  @override
  Future<void> upsert(FolderRow row) async => rows[row.id] = row;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

/// `FolderNotifier` vuole un `Ref`: lo si ottiene da un provider banale.
final Provider<Ref> _refProvider = Provider<Ref>((ref) => ref);

/// Lascia che le operazioni asincrone in coda (caricamento iniziale dei
/// notifier, scritture "fire and forget" nei DAO) si concludano, senza
/// ritardi fissi: ogni giro cede il controllo all'event loop.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

// ---------------------------------------------------------------------------
// Dati di esempio: un backup completo con tutti i casi che contano
// ---------------------------------------------------------------------------

final List<ExportFolder> _folders = [
  (id: 'f-lavoro', name: 'Lavoro', parentId: null),
  (id: 'f-prog', name: '2 - Progetti', parentId: 'f-lavoro'),
  (id: 'f-pers', name: 'Personale', parentId: null),
];

final List<ExportNote> _notes = [
  // Senza cartella e con cartella sconosciuta: finiscono in Non_Catalogate/.
  (id: '11111111-0000', title: '1 - Nome Nota', content: 'corpo A', folderId: null),
  (id: '22222222-0000', title: '10 cose da fare', content: 'corpo B', folderId: 'cartella-fantasma'),
  // Il testo inizia con un proprio "# Nome Nota": l'esportazione non antepone
  // il titolo, che sopravvive solo nel nome del file ("1 - Nome Nota.md").
  (id: '33333333-0000', title: '1 - Nome Nota', content: '# Nome Nota\n\ncorpo C', folderId: 'f-lavoro'),
  // Stesso titolo nella stessa cartella: "Riunione.md" e "Riunione (2).md".
  (id: '44444444-0000', title: 'Riunione', content: 'uno', folderId: 'f-lavoro'),
  (id: '55555555-0000', title: 'Riunione', content: 'due', folderId: 'f-lavoro'),
  (id: '66666666-0000', title: '01. Introduzione', content: 'intro', folderId: 'f-prog'),
  (id: '77777777-0000', title: '2024-01-05 Diario', content: '# Oggi\n\nsole', folderId: 'f-pers'),
  // Caratteri illegali nei nomi di file: il titolo vero sta nell'intestazione.
  (id: '88888888-0000', title: 'Capitolo 1/2: "Intro"', content: 'x', folderId: 'f-pers'),
];

/// "cartella|titolo|testo" di ciò che l'utente deve ritrovarsi dopo l'import.
const List<String> _expectedImported = [
  'radice|1 - Nome Nota|corpo A',
  'radice|10 cose da fare|corpo B',
  'Lavoro|1 - Nome Nota|# Nome Nota\n\ncorpo C',
  'Lavoro|Riunione|uno',
  'Lavoro|Riunione|due',
  'Lavoro/2 - Progetti|01. Introduzione|intro',
  'Personale|2024-01-05 Diario|# Oggi\n\nsole',
  'Personale|Capitolo 1/2: "Intro"|x',
];

const int _expectedFolderCount = 3;

ZipResult _exportBackup() =>
    buildNotesZip((folders: _folders, notes: _notes));

List<String> _zipNames(Uint8List bytes) => [
      for (final f in ZipDecoder().decodeBytes(bytes).files)
        if (f.isFile) f.name,
    ];

/// ZIP "fatto da altri strumenti": nomi e contenuti a piacere.
Uint8List _zipOf(Map<String, String> files) {
  final archive = Archive();
  files.forEach((name, text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Forma confrontabile (e ordinata) delle voci estratte.
List<String> _describe(List<ImportEntry> entries) => [
      for (final e in entries)
        '${e.folderPathSegments.join('/')}|${e.fileName}|${e.rawContent}',
    ]..sort();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late _MemoryNotesDao notesDao;
  late _MemoryFoldersDao foldersDao;
  late FolderNotifier folders;
  late NotesNotifier notes;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    notesDao = _MemoryNotesDao();
    foldersDao = _MemoryFoldersDao();
    container = ProviderContainer();
    folders = FolderNotifier(
      container.read(_refProvider),
      foldersDao: foldersDao,
      notesDao: notesDao,
    );
    notes = NotesNotifier(dao: notesDao);
    // Il caricamento iniziale (DAO vuoti) sostituisce lo stato: va concluso
    // PRIMA di importare, altrimenti potrebbe sovrascrivere le note appena
    // inserite. Nell'app l'import è sempre molto successivo all'avvio.
    await _settle();
  });

  tearDown(() async {
    await _settle();
    notes.dispose();
    folders.dispose();
    container.dispose();
  });

  /// Percorso "A/B/C" della cartella [id], oppure `null` per la radice.
  String? pathOf(String? id) {
    if (id == null) return null;
    final names = <String>[];
    String? current = id;
    while (current != null) {
      final row = foldersDao.rows[current]!;
      names.add(row.name);
      current = row.parentId;
    }
    return names.reversed.join('/');
  }

  List<String> folderPaths() => [
        for (final id in foldersDao.rows.keys) pathOf(id)!,
      ];

  List<String> importedSummary() => [
        for (final n in notesDao.rows.values)
          '${pathOf(n.folderId) ?? 'radice'}|${n.title}|${n.content}',
      ];

  Future<({int importedNotes, int importedFolders})> commit(
    List<ImportEntry> entries,
  ) async {
    final result = await ImportService.commitEntries(folders, notes, entries);
    await _settle();
    return result;
  }

  group('ZIP prodotto dall\'esportazione', () {
    test('il backup contiene davvero il contenitore Non_Catalogate (premessa del difetto)', () {
      final names = _zipNames(_exportBackup().bytes);

      expect(
        names.where((n) => n.startsWith('$uncatalogedFolderName/')),
        unorderedEquals([
          '$uncatalogedFolderName/1 - Nome Nota.md',
          '$uncatalogedFolderName/10 cose da fare.md',
        ]),
      );
    });

    test('esporta → importa: struttura della radice e titoli identici', () async {
      final result = await commit(
        ImportService.decodeZipEntries(_exportBackup().bytes),
      );

      expect(result.importedNotes, _notes.length);
      expect(result.importedFolders, _expectedFolderCount);
      expect(
        folderPaths(),
        unorderedEquals(['Lavoro', 'Lavoro/2 - Progetti', 'Personale']),
      );
      expect(importedSummary(), unorderedEquals(_expectedImported));
    });

    test('difetto 1: le note senza cartella stanno alla radice, senza cartella "Non_Catalogate"', () async {
      await commit(ImportService.decodeZipEntries(_exportBackup().bytes));

      expect(
        foldersDao.rows.values.where((f) => isUncatalogedFolderName(f.name)),
        isEmpty,
        reason: 'nessuna cartella visibile con il nome del contenitore',
      );
      final uncategorized = notesDao.rows.values
          .where((n) => n.title == '10 cose da fare' || (n.title == '1 - Nome Nota' && n.content == 'corpo A'))
          .toList();
      expect(uncategorized, hasLength(2));
      for (final note in uncategorized) {
        expect(note.folderId, isNull, reason: '"${note.title}" deve comparire solo in "Tutte le note"');
      }
    });

    test('difetto 2: "1 - Nome Nota" conserva il prefisso anche se il testo inizia con "# Nome Nota"', () async {
      await commit(ImportService.decodeZipEntries(_exportBackup().bytes));

      final imported = notesDao.rows.values
          .singleWhere((n) => n.content.startsWith('# Nome Nota'));
      expect(imported.title, '1 - Nome Nota');
      expect(imported.content, '# Nome Nota\n\ncorpo C');
    });

    test('importare due volte è additivo: note raddoppiate, cartelle riusate, ancora nessuna Non_Catalogate', () async {
      final bytes = _exportBackup().bytes;
      await commit(ImportService.decodeZipEntries(bytes));
      final second = await commit(ImportService.decodeZipEntries(bytes));

      expect(second.importedNotes, _notes.length);
      expect(second.importedFolders, 0, reason: 'le cartelle esistenti si riusano');
      expect(notesDao.rows, hasLength(_notes.length * 2));
      expect(foldersDao.rows, hasLength(_expectedFolderCount));
      expect(
        importedSummary(),
        unorderedEquals([..._expectedImported, ..._expectedImported]),
      );
    });

    test('una cartella "Non_Catalogate" creata da vecchie importazioni non riceve nuove note', () async {
      final legacy = folders.addFolder(uncatalogedFolderName);
      await _settle();

      final result = await commit(
        ImportService.decodeZipEntries(_exportBackup().bytes),
      );

      expect(result.importedFolders, _expectedFolderCount, reason: 'quella vecchia non conta né si riusa');
      expect(
        notesDao.rows.values.where((n) => n.folderId == legacy.id),
        isEmpty,
      );
      expect(
        foldersDao.rows.values.where((f) => isUncatalogedFolderName(f.name)),
        hasLength(1),
        reason: 'solo quella già presente: l\'import non ne crea altre',
      );
    });

    test('una cartella vera annidata "Lavoro/Non_Catalogate" resta una cartella', () async {
      final bytes = _zipOf({
        'Lavoro/Non_Catalogate/x.md': 'dentro',
        'Non_Catalogate/y.md': 'radice',
      });

      final result = await commit(ImportService.decodeZipEntries(bytes));

      expect(result.importedFolders, 2);
      expect(
        folderPaths(),
        unorderedEquals(['Lavoro', 'Lavoro/Non_Catalogate']),
      );
      expect(
        importedSummary(),
        unorderedEquals(['Lavoro/Non_Catalogate|x|dentro', 'radice|y|radice']),
      );
    });

    test('un archivio senza note non crea nulla', () async {
      final result = await commit(ImportService.decodeZipEntries(_zipOf({})));

      expect(result.importedNotes, 0);
      expect(result.importedFolders, 0);
      expect(notesDao.rows, isEmpty);
      expect(foldersDao.rows, isEmpty);
    });
  });

  group('ZIP creati da altri strumenti', () {
    test('separatori Windows, rumore di macOS e file non-nota', () async {
      final bytes = _zipOf({
        r'Lavoro\Sub\n.md': '# n\n\ncorpo',
        r'Non_Catalogate\A.md': 'a',
        'Reale/ok.md': 'ok',
        '__MACOSX/Lavoro/._n.md': 'spazzatura',
        'Lavoro/._n.md': 'spazzatura',
        'Lavoro/immagine.png': 'png',
        'Lavoro/.DS_Store': 'bin',
      });

      final result = await commit(ImportService.decodeZipEntries(bytes));

      expect(result.importedNotes, 3);
      expect(
        folderPaths(),
        unorderedEquals(['Lavoro', 'Lavoro/Sub', 'Reale']),
        reason: 'né "Non_Catalogate" né "__MACOSX" diventano cartelle',
      );
      expect(
        importedSummary(),
        unorderedEquals(['Lavoro/Sub|n|corpo', 'radice|A|a', 'Reale|ok|ok']),
      );
    });

    test('un file sopra il limite di una nota viene rifiutato', () {
      const size = ImportService.maxEntryBytes + 1;
      final archive = Archive()
        ..addFile(ArchiveFile('Grande.md', size, Uint8List(size)));
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

      expect(() => ImportService.decodeZipEntries(bytes), throwsFormatException);
    });

    test('troppi file da importare vengono rifiutati', () {
      final archive = Archive();
      for (var i = 0; i <= ImportService.maxImportedFiles; i++) {
        archive.addFile(ArchiveFile('n$i.md', 1, const [97]));
      }
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

      expect(() => ImportService.decodeZipEntries(bytes), throwsFormatException);
    });
  });

  group('cartella scelta sul filesystem', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('scripta_import_');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<void> write(List<String> segments, String text) async {
      final file = File(p.joinAll([root.path, ...segments]));
      await file.parent.create(recursive: true);
      await file.writeAsString(text);
    }

    test('stesse regole dello ZIP: radice, annidamento, rumore di macOS', () async {
      await write(['Non_Catalogate', '1 - Nome Nota.md'], 'radice');
      await write(['Lavoro', '2 - Progetti', '01. Introduzione.md'], '# Introduzione\n\ncorpo');
      await write(['Lavoro', 'Non_Catalogate', 'x.md'], 'vera cartella');
      await write(['superiore.md'], 'in cima');
      await write(['__MACOSX', 'Lavoro', '._x.md'], 'spazzatura');
      await write(['Lavoro', '._x.md'], 'spazzatura');
      await write(['Lavoro', '.DS_Store'], 'bin');
      await write(['Lavoro', 'immagine.png'], 'png');

      final entries = await ImportService.extractFromDirectory(root);
      final result = await commit(entries);

      expect(result.importedNotes, 4);
      expect(
        folderPaths(),
        unorderedEquals([
          'Lavoro',
          'Lavoro/2 - Progetti',
          'Lavoro/Non_Catalogate',
        ]),
      );
      expect(
        importedSummary(),
        unorderedEquals([
          'radice|1 - Nome Nota|radice',
          // "# Introduzione" non è l'eco di "01. Introduzione": il titolo con
          // il prefisso numerico vince e l'intestazione resta nel testo.
          'Lavoro/2 - Progetti|01. Introduzione|# Introduzione\n\ncorpo',
          'Lavoro/Non_Catalogate|x|vera cartella',
          'radice|superiore|in cima',
        ]),
      );
    });

    test('importare la cartella equivale a importare lo ZIP da cui proviene', () async {
      final zipBytes = _exportBackup().bytes;
      for (final file in ZipDecoder().decodeBytes(zipBytes).files) {
        if (!file.isFile) continue;
        final target = File(p.joinAll([root.path, ...file.name.split('/')]));
        await target.parent.create(recursive: true);
        await target.writeAsBytes(file.content as List<int>);
      }

      final fromDisk = await ImportService.extractFromDirectory(root);
      final fromZip = ImportService.decodeZipEntries(zipBytes);
      expect(_describe(fromDisk), _describe(fromZip));

      final result = await commit(fromDisk);
      expect(result.importedFolders, _expectedFolderCount);
      expect(importedSummary(), unorderedEquals(_expectedImported));
    });

    test(
      'un "\\" nel nome di un file è un carattere, non un separatore (Linux, macOS, Android, iOS)',
      () async {
        await write(['Lavoro', r'a\b.md'], 'x');

        final entries = await ImportService.extractFromDirectory(root);

        expect(entries, hasLength(1));
        expect(entries.single.folderPathSegments, ['Lavoro']);
        expect(entries.single.fileName, r'a\b.md');
      },
      skip: Platform.isWindows
          ? 'su Windows il backslash non è ammesso in un nome di file'
          : null,
    );

    test('una cartella vuota non produce nulla', () async {
      final entries = await ImportService.extractFromDirectory(root);
      final result = await commit(entries);

      expect(entries, isEmpty);
      expect(result.importedNotes, 0);
      expect(result.importedFolders, 0);
    });
  });
}
