import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/database/app_database.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:sqflite/sqflite.dart';

NoteRow _note(String id, {int updatedAt = 1000, int? deletedAt, String title = 't'}) => NoteRow(
      id: id,
      title: title,
      content: '',
      folderId: null,
      isFavorite: false,
      isPinned: false,
      orderIndex: 0,
      createdAt: 1,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
    );

void main() {
  late String dbPath;

  setUp(() async {
    AppDatabase.ensureFactoryInitialized();
    await AppDatabase.instance.close();
    dbPath = p.join(Directory.systemTemp.path, 'scripta_dirty_${DateTime.now().microsecondsSinceEpoch}.db');
    AppDatabase.debugDatabasePathOverride = dbPath;
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = null;
  });

  test('le scritture locali sono dirty, quelle remote no', () async {
    final dao = NotesDao();
    await dao.upsert(_note('local'));
    await dao.applyRemoteLWWBatch([_note('remote')]);

    final dirty = (await dao.listDirty()).map((r) => r.id).toSet();
    expect(dirty, {'local'});
  });

  test('markSynced non azzera una riga modificata durante il round-trip', () async {
    final dao = NotesDao();
    await dao.upsert(_note('a', updatedAt: 1000));
    await dao.upsert(_note('b', updatedAt: 1000));
    // "a" viene ri-modificata mentre la sync era in corso.
    await dao.upsert(_note('a', updatedAt: 2000));

    await dao.markSynced({'a': 1000, 'b': 1000});

    final dirty = (await dao.listDirty()).map((r) => r.id).toSet();
    expect(dirty, {'a'});
  });

  test('una pull non sovrascrive una modifica locale sporca più recente', () async {
    final dao = NotesDao();
    await dao.upsert(_note('a', updatedAt: 5000, title: 'locale'));
    await dao.applyRemoteLWWBatch([_note('a', updatedAt: 4000, title: 'remoto vecchio')]);
    expect((await dao.getById('a'))!.title, 'locale');
  });

  test('una riga pulita accetta la versione del server anche con updated_at minore', () async {
    final dao = NotesDao();
    await dao.upsert(_note('a', updatedAt: 9000, title: 'locale (orologio avanti)'));
    await dao.markSynced({'a': 9000});
    await dao.applyRemoteLWWBatch([_note('a', updatedAt: 3000, title: 'server')]);
    expect((await dao.getById('a'))!.title, 'server');
  });

  test('purgeCleanTombstones elimina solo i tombstone confermati', () async {
    final dao = NotesDao();
    await dao.applyRemoteLWWBatch([_note('gone', deletedAt: 10)]); // tombstone remoto (pulito)
    await dao.upsert(_note('pending', deletedAt: 20)); // cancellazione locale non ancora inviata

    await dao.purgeCleanTombstones();

    expect(await dao.getById('gone'), isNull);
    expect(await dao.getById('pending'), isNotNull);
  });

  test('deleteCleanNotIn (full resync) tiene le righe sporche e quelle del server', () async {
    final dao = NotesDao();
    await dao.applyRemoteLWWBatch([_note('keep'), _note('stale')]);
    await dao.upsert(_note('dirty'));

    await dao.deleteCleanNotIn({'keep'});

    expect(await dao.getById('keep'), isNotNull);
    expect(await dao.getById('stale'), isNull);
    expect(await dao.getById('dirty'), isNotNull);
  });

  test('migrazione v1 -> v2: aggiunge dirty in base al vecchio cursore', () async {
    // Crea un DB con lo schema v1 (senza colonna dirty).
    final v1 = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('CREATE TABLE folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT, '
              'is_expanded INTEGER NOT NULL DEFAULT 1, updated_at INTEGER NOT NULL, deleted_at INTEGER)');
          await db.execute('CREATE TABLE notes (id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT \'\', '
              'content TEXT NOT NULL DEFAULT \'\', folder_id TEXT, is_favorite INTEGER NOT NULL DEFAULT 0, '
              'is_pinned INTEGER NOT NULL DEFAULT 0, order_index INTEGER NOT NULL DEFAULT 0, '
              'created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER)');
          await db.execute('CREATE TABLE sync_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        },
      ),
    );
    await v1.insert('sync_meta', {'key': 'last_synced_at', 'value': '5000'});
    await v1.insert('notes', {'id': 'old', 'title': '', 'content': '', 'created_at': 1, 'updated_at': 4000});
    await v1.insert('notes', {'id': 'new', 'title': '', 'content': '', 'created_at': 1, 'updated_at': 6000});
    await v1.close();

    // L'apertura tramite AppDatabase (versione 2) deve eseguire onUpgrade.
    final dirty = (await NotesDao().listDirty()).map((r) => r.id).toSet();
    expect(dirty, {'new'});
  });
}
