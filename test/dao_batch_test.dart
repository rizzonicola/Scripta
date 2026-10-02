import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/database/app_database.dart';
import 'package:scripta/core/database/folders_dao.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:scripta/core/database/sql_helpers.dart';

NoteRow _note(
  String id, {
  int createdAt = 1,
  int updatedAt = 1000,
  int? deletedAt,
  String title = 't',
  String? folderId,
}) =>
    NoteRow(
      id: id,
      title: title,
      content: '',
      folderId: folderId,
      isFavorite: false,
      isPinned: false,
      orderIndex: 0,
      createdAt: createdAt,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
    );

FolderRow _folder(
  String id, {
  String? parentId,
  String name = 'f',
  bool isExpanded = true,
  int updatedAt = 1000,
  int? deletedAt,
}) =>
    FolderRow(
      id: id,
      name: name,
      parentId: parentId,
      isExpanded: isExpanded,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
    );

Future<Set<String>> _activeNoteIds(NotesDao dao) async =>
    (await dao.getActive()).map((r) => r.id).toSet();

void main() {
  group('sql_helpers', () {
    test('chunked divide in blocchi consecutivi senza perdere elementi', () {
      expect(chunked([1, 2, 3, 4, 5], 2).toList(), [
        [1, 2],
        [3, 4],
        [5],
      ]);
      expect(chunked(<int>[], 2).toList(), isEmpty);
      expect(chunked([1, 2, 3], 10).toList(), [
        [1, 2, 3],
      ]);
    });

    test('sqlPlaceholders produce un segnaposto per elemento', () {
      expect(sqlPlaceholders(3), '?,?,?');
      expect(sqlPlaceholders(1), '?');
      expect(sqlPlaceholders(0), '');
    });
  });

  group('database', () {
    late String dbPath;

    setUp(() async {
      AppDatabase.ensureFactoryInitialized();
      await AppDatabase.instance.close();
      dbPath = p.join(
        Directory.systemTemp.path,
        'scripta_batch_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      AppDatabase.debugDatabasePathOverride = dbPath;
    });

    tearDown(() async {
      await AppDatabase.instance.close();
      AppDatabase.debugDatabasePathOverride = null;
    });

    test('aperture concorrenti condividono la stessa connessione', () async {
      final dbs = await Future.wait([
        for (var i = 0; i < 8; i++) AppDatabase.instance.db,
      ]);
      expect(dbs.every((d) => identical(d, dbs.first)), isTrue);
      expect(dbs.first.isOpen, isTrue);
    });

    test('dopo close() una nuova richiesta riapre il database', () async {
      final first = await AppDatabase.instance.db;
      await AppDatabase.instance.close();
      expect(first.isOpen, isFalse);

      final second = await AppDatabase.instance.db;
      expect(second.isOpen, isTrue);
      expect(identical(first, second), isFalse);
    });

    test('i PRAGMA di durabilità e attesa sul lock sono applicati', () async {
      final db = await AppDatabase.instance.db;
      final synchronous = await db.rawQuery('PRAGMA synchronous');
      expect(synchronous.first.values.first, 1); // NORMAL
      final busy = await db.rawQuery('PRAGMA busy_timeout');
      expect(busy.first.values.first, 5000);
    });

    test('gli indici parziali sui tombstone esistono', () async {
      final db = await AppDatabase.instance.db;
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE '%tombstones'",
      );
      expect(
        rows.map((r) => r['name']).toSet(),
        {'idx_notes_tombstones', 'idx_folders_tombstones'},
      );
    });
  });

  group('NotesDao (batch)', () {
    late String dbPath;

    setUp(() async {
      AppDatabase.ensureFactoryInitialized();
      await AppDatabase.instance.close();
      dbPath = p.join(
        Directory.systemTemp.path,
        'scripta_notes_batch_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      AppDatabase.debugDatabasePathOverride = dbPath;
    });

    tearDown(() async {
      await AppDatabase.instance.close();
      AppDatabase.debugDatabasePathOverride = null;
    });

    test('applyRemoteLWWBatch gestisce più righe del limite di variabili SQLite', () async {
      final dao = NotesDao();
      await dao.applyRemoteLWWBatch([
        for (var i = 0; i < 1200; i++) _note('n$i', updatedAt: 1000 + i),
      ]);

      expect((await dao.getActive()).length, 1200);
      expect(await dao.listDirty(), isEmpty);
    });

    test('in un batch la modifica locale sporca più recente resta, le altre righe si applicano', () async {
      final dao = NotesDao();
      await dao.upsert(_note('keep', updatedAt: 5000, title: 'locale'));

      await dao.applyRemoteLWWBatch([
        _note('keep', updatedAt: 4000, title: 'remoto vecchio'),
        _note('other', updatedAt: 100, title: 'nuova'),
      ]);

      expect((await dao.getById('keep'))!.title, 'locale');
      expect((await dao.listDirty()).map((r) => r.id).toSet(), {'keep'});
      expect((await dao.getById('other'))!.title, 'nuova');
    });

    test('una pull preserva la data di creazione locale', () async {
      final dao = NotesDao();
      await dao.upsert(_note('a', createdAt: 50, updatedAt: 1000));
      await dao.markSynced({'a': 1000});

      await dao.applyRemoteLWWBatch([
        _note('a', createdAt: 999, updatedAt: 2000, title: 'dal server'),
      ]);

      final row = await dao.getById('a');
      expect(row!.title, 'dal server');
      expect(row.createdAt, 50);
    });

    test('la data di creazione non supera l\'ultima modifica conosciuta', () async {
      final dao = NotesDao();
      await dao.upsert(_note('a', createdAt: 9000, updatedAt: 9500));
      await dao.markSynced({'a': 9500});

      await dao.applyRemoteLWWBatch([_note('a', createdAt: 1, updatedAt: 3000)]);

      expect((await dao.getById('a'))!.createdAt, 3000);
    });

    test('lo stesso id ripetuto nel batch equivale ad applicare le righe in sequenza', () async {
      final dao = NotesDao();
      await dao.applyRemoteLWWBatch([
        _note('x', updatedAt: 2000, title: 'v2'),
        _note('x', updatedAt: 1000, title: 'v1'),
      ]);

      // La riga locale è pulita dopo la prima: il server resta autoritativo.
      expect((await dao.getById('x'))!.title, 'v1');
    });

    test('deleteCleanNotIn elimina a blocchi e risparmia le righe sporche', () async {
      final dao = NotesDao();
      await dao.applyRemoteLWWBatch([for (var i = 0; i < 700; i++) _note('c$i')]);
      await dao.upsert(_note('mine')); // sporca: modifica locale non inviata

      await dao.deleteCleanNotIn({'c0'});

      expect(await _activeNoteIds(dao), {'c0', 'mine'});
    });

    test('purgeCleanTombstones elimina solo i tombstone già confermati', () async {
      final dao = NotesDao();
      await dao.applyRemoteLWWBatch([
        _note('gone', deletedAt: 10), // tombstone ricevuto dal server: pulito
        _note('alive'),
      ]);
      await dao.upsert(_note('pending', deletedAt: 20)); // eliminazione locale non ancora inviata

      await dao.purgeCleanTombstones();

      expect(await dao.getById('gone'), isNull);
      expect(await dao.getById('pending'), isNotNull);
      expect(await dao.getById('alive'), isNotNull);
    });

    test('upsertBatch scrive tutte le righe come sporche (e non fa nulla se vuoto)', () async {
      final dao = NotesDao();
      await dao.upsertBatch(const []);
      expect(await dao.getActive(), isEmpty);

      await dao.upsertBatch([_note('a'), _note('b')]);
      expect((await dao.listDirty()).map((r) => r.id).toSet(), {'a', 'b'});
    });

    test('hardDeleteIds elimina più righe del limite di variabili', () async {
      final dao = NotesDao();
      final ids = [for (var i = 0; i < 1200; i++) 'n$i'];
      await dao.upsertBatch([for (final id in ids) _note(id)]);

      await dao.hardDeleteIds(ids.where((id) => id != 'n0').toList());

      expect(await _activeNoteIds(dao), {'n0'});
    });
  });

  group('FoldersDao (batch e cascade)', () {
    late String dbPath;

    setUp(() async {
      AppDatabase.ensureFactoryInitialized();
      await AppDatabase.instance.close();
      dbPath = p.join(
        Directory.systemTemp.path,
        'scripta_folders_batch_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      AppDatabase.debugDatabasePathOverride = dbPath;
    });

    tearDown(() async {
      await AppDatabase.instance.close();
      AppDatabase.debugDatabasePathOverride = null;
    });

    test('cascadeSoftDelete cancella sottoalbero e note, risparmia le altre cartelle', () async {
      final folders = FoldersDao();
      final notes = NotesDao();
      await folders.upsert(_folder('root'));
      await folders.upsert(_folder('child', parentId: 'root'));
      await folders.upsert(_folder('grand', parentId: 'child'));
      await folders.upsert(_folder('sibling'));
      await notes.upsertBatch([
        _note('n1', folderId: 'root'),
        _note('n2', folderId: 'grand'),
        _note('n3', folderId: 'sibling'),
      ]);

      await folders.cascadeSoftDelete(
        'root',
        5000,
        deleteNotesInFolder: notes.softDeleteByFolder,
      );

      expect((await folders.getActive()).map((f) => f.id).toSet(), {'sibling'});
      expect(await _activeNoteIds(notes), {'n3'});
      for (final id in ['root', 'child', 'grand']) {
        expect((await folders.getById(id))!.deletedAt, 5000, reason: id);
      }
      expect((await folders.getById('sibling'))!.deletedAt, isNull);
      expect((await notes.getById('n1'))!.deletedAt, 5000);
      expect((await notes.getById('n2'))!.deletedAt, 5000);
    });

    test('cascadeSoftDelete termina anche con riferimenti genitore ciclici', () async {
      final folders = FoldersDao();
      await folders.upsert(_folder('a', parentId: 'b'));
      await folders.upsert(_folder('b', parentId: 'a'));

      await folders.cascadeSoftDelete(
        'a',
        7000,
        deleteNotesInFolder: (folderId, now) async {},
      );

      expect((await folders.getById('a'))!.deletedAt, 7000);
      expect((await folders.getById('b'))!.deletedAt, 7000);
    });

    test('cascadeSoftDelete marca come sporche le righe cancellate', () async {
      final folders = FoldersDao();
      await folders.upsert(_folder('root'));
      await folders.markSynced({'root': 1000}); // parte da pulita

      await folders.cascadeSoftDelete(
        'root',
        5000,
        deleteNotesInFolder: (folderId, now) async {},
      );

      expect((await folders.listDirty()).map((f) => f.id).toSet(), {'root'});
    });

    test('applyRemoteLWWBatch preserva isExpanded locale e applica il resto', () async {
      final folders = FoldersDao();
      await folders.upsert(_folder('f', name: 'F', isExpanded: false));
      await folders.markSynced({'f': 1000});

      await folders.applyRemoteLWWBatch([
        _folder('f', name: 'Rinominata', isExpanded: true, updatedAt: 2000),
      ]);

      final row = await folders.getById('f');
      expect(row!.name, 'Rinominata');
      expect(row.isExpanded, isFalse);
    });

    test('applyRemoteLWWBatch non sovrascrive una cartella sporca più recente', () async {
      final folders = FoldersDao();
      await folders.upsert(_folder('f', name: 'locale', updatedAt: 5000));

      await folders.applyRemoteLWWBatch([
        _folder('f', name: 'remota vecchia', updatedAt: 4000),
      ]);

      expect((await folders.getById('f'))!.name, 'locale');
      expect((await folders.listDirty()).map((f) => f.id).toSet(), {'f'});
    });

    test('purgeCleanTombstones elimina solo le cartelle cancellate e confermate', () async {
      final folders = FoldersDao();
      await folders.applyRemoteLWWBatch([
        _folder('gone', deletedAt: 10),
        _folder('alive'),
      ]);
      await folders.upsert(_folder('pending', deletedAt: 20));

      await folders.purgeCleanTombstones();

      expect(await folders.getById('gone'), isNull);
      expect(await folders.getById('pending'), isNotNull);
      expect(await folders.getById('alive'), isNotNull);
    });
  });
}
