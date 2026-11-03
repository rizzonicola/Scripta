import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/database/app_database.dart';
import 'package:scripta/core/database/folders_dao.dart';
import 'package:sqflite/sqflite.dart';

FolderRow _folder(
  String id, {
  String name = 'f',
  String? parentId,
  bool isExpanded = true,
  int orderIndex = 0,
  int updatedAt = 1000,
}) => FolderRow(
  id: id,
  name: name,
  parentId: parentId,
  isExpanded: isExpanded,
  orderIndex: orderIndex,
  updatedAt: updatedAt,
  deletedAt: null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String dbPath;

  setUp(() async {
    AppDatabase.ensureFactoryInitialized();
    await AppDatabase.instance.close();
    dbPath = p.join(
      Directory.systemTemp.path,
      'scripta_folder_order_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    AppDatabase.debugDatabasePathOverride = dbPath;
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = null;
    try {
      File(dbPath).deleteSync();
    } catch (_) {
      // File temporaneo già rimosso o ancora bloccato: irrilevante.
    }
  });

  test('applyRemoteLWWBatch preserva ordine ed espansione locali', () async {
    final dao = FoldersDao();
    await dao.upsert(
      _folder('f', name: 'Locale', isExpanded: false, orderIndex: 7),
    );
    await dao.markSynced({'f': 1000});

    await dao.applyRemoteLWW(_folder('f', name: 'Remoto', updatedAt: 2000));

    final row = (await dao.getById('f'))!;
    expect(row.name, 'Remoto');
    expect(row.orderIndex, 7);
    expect(row.isExpanded, isFalse);
    expect(await dao.listDirty(), isEmpty);
  });

  test(
    'setOrderIndexes non tocca updated_at e non rende la riga dirty',
    () async {
      final dao = FoldersDao();
      await dao.upsert(_folder('a'));
      await dao.upsert(_folder('b'));
      await dao.markSynced({'a': 1000, 'b': 1000});

      await dao.setOrderIndexes({'a': 2, 'b': 1});

      final a = (await dao.getById('a'))!;
      final b = (await dao.getById('b'))!;
      expect(a.updatedAt, 1000);
      expect(b.updatedAt, 1000);
      expect(a.orderIndex, 2);
      expect(b.orderIndex, 1);
      expect(await dao.listDirty(), isEmpty);
    },
  );

  test('getActive ordina per order_index e poi per nome', () async {
    final dao = FoldersDao();
    await dao.upsert(_folder('c', name: 'Gamma'));
    await dao.upsert(_folder('a', name: 'Alpha', orderIndex: 2));
    await dao.upsert(_folder('b', name: 'Beta', orderIndex: 1));

    expect((await dao.getActive()).map((r) => r.id), ['b', 'a', 'c']);
  });

  test('migrazione v3 -> v4 aggiunge order_index con default 0', () async {
    final v3 = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, '
            'parent_id TEXT, is_expanded INTEGER NOT NULL DEFAULT 1, '
            'updated_at INTEGER NOT NULL, deleted_at INTEGER, '
            'dirty INTEGER NOT NULL DEFAULT 1)',
          );
        },
      ),
    );
    await v3.insert('folders', {
      'id': 'old',
      'name': 'Old',
      'updated_at': 1234,
      'dirty': 0,
    });
    await v3.close();

    final row = (await FoldersDao().getById('old'))!;
    expect(row.name, 'Old');
    expect(row.updatedAt, 1234);
    expect(row.orderIndex, 0);
  });
}
