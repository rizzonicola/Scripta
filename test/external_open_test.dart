import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/database/folders_dao.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:scripta/features/external_open/services/external_open_processor.dart';
import 'package:scripta/core/services/external_open_service.dart';
import 'package:scripta/features/folders/models/external_open_destination.dart';
import 'package:scripta/features/folders/providers/folder_provider.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Apertura di file/cartelle dall'esterno ("Apri con Scripta" e drag & drop).
// Si usano i veri notifier con DAO in memoria, come per l'import: il test
// verifica ciò che finisce nel database (titolo, corpo, cartelle, nota attiva),
// non solo il valore di ritorno del parser.

class _MemoryNotesDao implements NotesDao {
  final Map<String, NoteRow> rows = {};

  @override
  Future<List<NoteRow>> getActive() async =>
      rows.values.where((r) => !r.isDeleted).toList();

  @override
  Future<List<NoteRow>> getByIds(Iterable<String> ids) async => [
    for (final id in ids)
      if (rows[id] != null) rows[id]!,
  ];

  @override
  Future<void> upsert(NoteRow row) async => rows[row.id] = row;

  @override
  Future<void> upsertBatch(List<NoteRow> list) async {
    for (final row in list) {
      rows[row.id] = row;
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

final Provider<Ref> _refProvider = Provider<Ref>((ref) => ref);

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('normalizeOpenTarget', () {
    test('lascia intatto un percorso nativo', () {
      expect(
        ExternalOpenService.normalizeOpenTarget('/tmp/Note con spazi.md'),
        '/tmp/Note con spazi.md',
      );
    });

    test(
      'decodifica gli URI file:// nel percorso nativo della piattaforma',
      () {
        // `Uri.toFilePath` usa il separatore della piattaforma: su Windows un
        // URI POSIX diventa un percorso con backslash. Il test verifica la
        // conversione, non un separatore specifico.
        final expected = Platform.isWindows
            ? r'\tmp\Note con spazi.md'
            : '/tmp/Note con spazi.md';
        expect(
          ExternalOpenService.normalizeOpenTarget(
            'file:///tmp/Note%20con%20spazi.md',
          ),
          expected,
        );
      },
    );

    test('riconosce i percorsi Windows senza scambiarli per URI', () {
      expect(
        ExternalOpenService.normalizeOpenTarget(r'C:\Users\Nicola\Nota.md'),
        r'C:\Users\Nicola\Nota.md',
      );
      expect(
        ExternalOpenService.normalizeOpenTarget(r'\\server\share\Nota.md'),
        r'\\server\share\Nota.md',
      );
    });

    test('toglie le virgolette e ignora i valori vuoti', () {
      expect(
        ExternalOpenService.normalizeOpenTarget('"/tmp/Nota.md"'),
        '/tmp/Nota.md',
      );
      expect(ExternalOpenService.normalizeOpenTarget('   '), isNull);
    });

    test('gli argomenti con trattino sono opzioni, non file', () {
      expect(
        ExternalOpenService.commandLineTargets([
          '--observatory-port=1',
          '/tmp/Nota.md',
          '-v',
        ]),
        ['/tmp/Nota.md'],
      );
    });
  });

  group('ExternalOpenService', () {
    test('conserva la provenienza drag & drop', () {
      final requests = <ExternalOpenRequest>[];
      void listener(ExternalOpenRequest request) => requests.add(request);

      ExternalOpenService.instance.attach(listener);
      addTearDown(() => ExternalOpenService.instance.detach(listener));

      ExternalOpenService.instance.addPaths([
        '/tmp/Nota.md',
      ], source: ExternalOpenSource.dragDrop);

      expect(requests, hasLength(1));
      expect(requests.single.paths, ['/tmp/Nota.md']);
      expect(requests.single.source, ExternalOpenSource.dragDrop);
    });
  });

  group('ExternalOpenProcessor', () {
    late Directory tempDir;
    late ProviderContainer container;
    late _MemoryNotesDao notesDao;
    late _MemoryFoldersDao foldersDao;
    late FolderNotifier folders;
    late NotesNotifier notes;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('scripta_open_');
      notesDao = _MemoryNotesDao();
      foldersDao = _MemoryFoldersDao();
      container = ProviderContainer();
      folders = FolderNotifier(
        container.read(_refProvider),
        foldersDao: foldersDao,
        notesDao: notesDao,
      );
      notes = NotesNotifier(dao: notesDao);
      await _settle();
    });

    tearDown(() async {
      await _settle();
      notes.dispose();
      folders.dispose();
      container.dispose();
      await tempDir.delete(recursive: true);
    });

    Future<ExternalOpenOutcome> open(
      Iterable<String> paths, {
      ExternalOpenDestinationPicker? chooseFolderDestination,
      ExternalOpenDestinationPicker? chooseFileDestination,
      String? defaultFileFolderId,
    }) async {
      final outcome = await ExternalOpenProcessor.openPaths(
        paths,
        notes: notes,
        folders: folders,
        chooseFolderDestination: chooseFolderDestination,
        chooseFileDestination: chooseFileDestination,
        defaultFileFolderId: defaultFileFolderId,
      );
      await _settle();
      return outcome;
    }

    test('folderPathSegments restituisce i nomi dalla radice', () {
      final lavoro = folders.addFolder('Lavoro');
      final progetti = folders.addFolder('Progetti', parentId: lavoro.id);
      final sotto = folders.addFolder('Sotto', parentId: progetti.id);

      expect(folders.folderPathSegments(sotto.id), [
        'Lavoro',
        'Progetti',
        'Sotto',
      ]);
      expect(folders.folderPathSegments(lavoro.id), ['Lavoro']);
      expect(folders.folderPathSegments(null), isEmpty);
      expect(folders.folderPathSegments('inesistente'), isEmpty);
    });

    test('un file Markdown diventa una nuova nota attiva', () async {
      final file = File(p.join(tempDir.path, 'Riunione.md'));
      await file.writeAsString('# Riunione\n\ncorpo della nota');

      final outcome = await open([file.path]);

      expect(outcome.openedFiles, 1);
      expect(outcome.failedPaths, isEmpty);
      expect(notesDao.rows, hasLength(1));
      final row = notesDao.rows.values.single;
      expect(row.title, 'Riunione');
      expect(row.content, 'corpo della nota');
      expect(notes.state.activeNoteId, row.id);
    });

    test('un file .txt mantiene nome e contenuto', () async {
      final file = File(p.join(tempDir.path, 'Appunti.txt'));
      await file.writeAsString('riga uno\nriga due');

      await open([file.path]);

      final row = notesDao.rows.values.single;
      expect(row.title, 'Appunti');
      expect(row.content, 'riga uno\nriga due');
    });

    test('più file creano più note e l\'ultima diventa attiva', () async {
      final first = File(p.join(tempDir.path, 'Prima.md'));
      final second = File(p.join(tempDir.path, 'Seconda.txt'));
      await first.writeAsString('uno');
      await second.writeAsString('due');

      final outcome = await open([first.path, second.path]);

      expect(outcome.openedFiles, 2);
      expect(notesDao.rows, hasLength(2));
      final activeId = notes.state.activeNoteId;
      expect(activeId, isNotNull);
      final active = notes.state.notes.firstWhere((n) => n.id == activeId);
      expect(active.title, 'Seconda');
    });

    test('un file aperto dall\'esterno va nella cartella scelta', () async {
      final file = File(p.join(tempDir.path, 'Riunione.md'));
      await file.writeAsString('# Riunione\n\ncorpo della nota');
      final lavoro = folders.addFolder('Lavoro');
      await _settle();

      String? requestedName;
      final outcome = await open(
        [file.path],
        chooseFileDestination: (fileName) async {
          requestedName = fileName;
          return ExternalOpenDestination(folderId: lavoro.id);
        },
      );

      expect(requestedName, 'Riunione.md');
      expect(outcome.openedFiles, 1);
      expect(outcome.failedPaths, isEmpty);
      final row = notesDao.rows.values.single;
      expect(row.title, 'Riunione');
      expect(row.folderId, lavoro.id);
      expect(notes.state.activeNoteId, row.id);
    });

    test(
      'un file trascinato usa la cartella corrente senza chiedere',
      () async {
        final file = File(p.join(tempDir.path, 'Riunione.md'));
        await file.writeAsString('# Riunione\n\ncorpo della nota');
        final lavoro = folders.addFolder('Lavoro');
        await _settle();

        final outcome = await open([file.path], defaultFileFolderId: lavoro.id);

        expect(outcome.openedFiles, 1);
        final row = notesDao.rows.values.single;
        expect(row.folderId, lavoro.id);
      },
    );

    test('annullare la destinazione di un file non crea note', () async {
      final file = File(p.join(tempDir.path, 'Riunione.md'));
      await file.writeAsString('corpo della nota');

      final outcome = await open([
        file.path,
      ], chooseFileDestination: (_) async => null);

      expect(outcome.openedFiles, 0);
      expect(outcome.failedPaths, isEmpty);
      expect(notesDao.rows, isEmpty);
    });

    test(
      'una cartella ricrea se stessa e le sottocartelle senza attivare note',
      () async {
        final nested = Directory(p.join(tempDir.path, 'Progetti', 'Sotto'));
        await nested.create(recursive: true);
        await File(
          p.join(tempDir.path, 'Progetti', 'Appunti.txt'),
        ).writeAsString('ciao');
        await File(p.join(nested.path, 'Nota.md')).writeAsString('testo');

        final outcome = await open([p.join(tempDir.path, 'Progetti')]);

        expect(outcome.openedFolders, 1);
        expect(outcome.importedNotes, 2);
        expect(outcome.importedFolders, 2);
        expect(outcome.failedPaths, isEmpty);
        expect(notesDao.rows, hasLength(2));
        expect(notes.state.activeNoteId, isNull);

        final progetti = foldersDao.rows.values.firstWhere(
          (f) => f.name == 'Progetti',
        );
        expect(progetti.parentId, isNull);
        final sotto = foldersDao.rows.values.firstWhere(
          (f) => f.name == 'Sotto',
        );
        expect(sotto.parentId, progetti.id);

        final appunti = notesDao.rows.values.firstWhere(
          (n) => n.title == 'Appunti',
        );
        final nota = notesDao.rows.values.firstWhere((n) => n.title == 'Nota');
        expect(appunti.folderId, progetti.id);
        expect(nota.folderId, sotto.id);
      },
    );

    test(
      'la cartella importata viene creata nella destinazione scelta',
      () async {
        final nested = Directory(p.join(tempDir.path, 'Progetti', 'Sotto'));
        await nested.create(recursive: true);
        await File(p.join(nested.path, 'Nota.md')).writeAsString('testo');

        final lavoro = folders.addFolder('Lavoro');
        await _settle();

        String? requestedName;
        final outcome = await open(
          [p.join(tempDir.path, 'Progetti')],
          chooseFolderDestination: (folderName) async {
            requestedName = folderName;
            return const ExternalOpenDestination(pathSegments: ['Lavoro']);
          },
        );

        expect(requestedName, 'Progetti');
        expect(outcome.importedNotes, 1);
        expect(outcome.importedFolders, 2);

        final lavoroRow = foldersDao.rows[lavoro.id]!;
        final progetti = foldersDao.rows.values.firstWhere(
          (f) => f.name == 'Progetti',
        );
        expect(progetti.parentId, lavoroRow.id);
        final sotto = foldersDao.rows.values.firstWhere(
          (f) => f.name == 'Sotto',
        );
        expect(sotto.parentId, progetti.id);
        final nota = notesDao.rows.values.single;
        expect(nota.folderId, sotto.id);
      },
    );

    test('annullare la destinazione non importa nulla', () async {
      final dir = Directory(p.join(tempDir.path, 'Progetti'));
      await dir.create();
      await File(p.join(dir.path, 'Nota.md')).writeAsString('testo');

      final outcome = await open([
        dir.path,
      ], chooseFolderDestination: (_) async => null);

      expect(outcome.openedFolders, 0);
      expect(outcome.importedNotes, 0);
      expect(outcome.importedFolders, 0);
      expect(outcome.failedPaths, isEmpty);
      expect(notesDao.rows, isEmpty);
      expect(foldersDao.rows, isEmpty);
    });

    test('una cartella vuota non crea note', () async {
      final empty = Directory(p.join(tempDir.path, 'Vuota'));
      await empty.create();

      final outcome = await open([empty.path]);

      expect(outcome.openedFolders, 1);
      expect(outcome.importedNotes, 0);
      expect(notesDao.rows, isEmpty);
    });

    test('un formato non supportato viene ignorato', () async {
      final pdf = File(p.join(tempDir.path, 'Documento.pdf'));
      await pdf.writeAsBytes([0x25, 0x50, 0x44, 0x46]);

      final outcome = await open([pdf.path]);

      expect(outcome.ignoredPaths, [pdf.path]);
      expect(outcome.openedFiles, 0);
      expect(notesDao.rows, isEmpty);
    });

    test('un percorso inesistente viene segnalato come errore', () async {
      final missing = p.join(tempDir.path, 'NonEsiste.md');

      final outcome = await open([missing]);

      expect(outcome.failedPaths, [missing]);
      expect(notesDao.rows, isEmpty);
    });
  });
}
