// Y-01 (app): listDirty() restituisce i genitori prima dei figli.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/database/app_database.dart';
import 'package:scripta/core/database/folders_dao.dart';

FolderRow _f(String id, [String? parent]) => FolderRow(
      id: id,
      name: id,
      parentId: parent,
      isExpanded: false,
      updatedAt: 1000,
      deletedAt: null,
    );

List<String> _ids(List<FolderRow> rows) => rows.map((r) => r.id).toList();

void main() {
  group('sortFoldersParentsFirst', () {
    test('un elenco già ordinato resta identico', () {
      final input = [_f('a'), _f('b', 'a'), _f('c', 'b'), _f('x')];
      expect(_ids(sortFoldersParentsFirst(input)), ['a', 'b', 'c', 'x']);
    });

    test('il figlio prima del genitore viene messo dopo di lui', () {
      final input = [_f('figlio', 'padre'), _f('padre')];
      expect(_ids(sortFoldersParentsFirst(input)), ['padre', 'figlio']);
    });

    test('catena inversa: ogni genitore precede il figlio', () {
      final out =
          _ids(sortFoldersParentsFirst([_f('c', 'b'), _f('b', 'a'), _f('a')]));
      expect(out, ['a', 'b', 'c']);
    });

    test('righe indipendenti e genitori fuori dall\'elenco non si spostano',
        () {
      // "x" ha un genitore già sul server (non fra le sporche): resta dov'è.
      final input = [
        _f('x', 'gia-sul-server'),
        _f('y'),
        _f('z', 'gia-sul-server')
      ];
      expect(_ids(sortFoldersParentsFirst(input)), ['x', 'y', 'z']);
    });

    test('più figli dello stesso genitore mantengono l\'ordine originale', () {
      final input = [_f('f1', 'p'), _f('f2', 'p'), _f('f3', 'p'), _f('p')];
      expect(_ids(sortFoldersParentsFirst(input)), ['p', 'f1', 'f2', 'f3']);
    });

    test('un ciclo non si perde: viene accodato nell\'ordine originale', () {
      final input = [_f('a', 'b'), _f('b', 'a'), _f('ok')];
      final out = _ids(sortFoldersParentsFirst(input));
      expect(out.toSet(), {'a', 'b', 'ok'});
      expect(out.first, 'ok');
      expect(out.sublist(1), ['a', 'b']);
    });

    test('una cartella genitore di se stessa non blocca nulla', () {
      final out = _ids(sortFoldersParentsFirst([_f('s', 's'), _f('t')]));
      expect(out, ['s', 't']);
    });

    test('catena molto profonda in ordine inverso: nessuna ricorsione', () {
      const n = 20000;
      final input = <FolderRow>[
        for (var i = n; i >= 2; i--) _f('f$i', 'f${i - 1}'),
        _f('f1'),
      ];
      final out = sortFoldersParentsFirst(input);
      expect(out.length, n);
      expect(out.first.id, 'f1');
      expect(out.last.id, 'f$n');
    });
  });

  group('FoldersDao.listDirty', () {
    late String dbPath;

    setUp(() async {
      AppDatabase.ensureFactoryInitialized();
      await AppDatabase.instance.close();
      dbPath = p.join(Directory.systemTemp.path,
          'scripta_folder_order_${DateTime.now().microsecondsSinceEpoch}.db');
      AppDatabase.debugDatabasePathOverride = dbPath;
    });

    tearDown(() async {
      await AppDatabase.instance.close();
      AppDatabase.debugDatabasePathOverride = null;
    });

    test('il figlio scritto PRIMA del genitore esce dopo di lui', () async {
      final dao = FoldersDao();
      // Nessuna chiave esterna su parent_id: si può scrivere prima il figlio.
      await dao.upsert(_f('figlio', 'padre'));
      await dao.upsert(_f('padre'));

      expect(_ids(await dao.listDirty()), ['padre', 'figlio']);
    });

    test('un REPLACE del genitore (nuovo rowid) non porta il figlio davanti',
        () async {
      final dao = FoldersDao();
      await dao.upsert(_f('padre'));
      await dao.upsert(_f('figlio', 'padre'));
      // Il genitore viene riscritto (es. rinomina): REPLACE = nuovo rowid.
      await dao
          .upsert(_f('padre').copyWith(name: 'rinominato', updatedAt: 2000));

      expect(_ids(await dao.listDirty()), ['padre', 'figlio']);
    });

    test('repairCycles spezza il ciclo e rende la riparazione sincronizzabile',
        () async {
      final dao = FoldersDao();
      await dao.upsert(_f('a', 'b'));
      await dao.upsert(_f('b', 'a'));

      await dao.repairCycles(5000);

      final rows = await dao.getActive();
      expect(rows.length, 2);
      final roots = rows.where((r) => r.parentId == null).toList();
      expect(roots.length, 1);
      expect(roots.single.updatedAt, 5000);
      expect(
          (await dao.listDirty()).map((r) => r.id), contains(roots.single.id));
    });

    test('repairCycles non tocca un albero già valido', () async {
      final dao = FoldersDao();
      await dao.upsert(_f('padre'));
      await dao.upsert(_f('figlio', 'padre'));

      await dao.repairCycles(5000);

      final rows = await dao.getActive();
      expect(rows.firstWhere((r) => r.id == 'figlio').parentId, 'padre');
      expect(rows.firstWhere((r) => r.id == 'figlio').updatedAt, 1000);
    });
  });
}
