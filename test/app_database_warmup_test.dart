import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/database/app_database.dart';

// A-05 — apertura anticipata del database (`AppDatabase.warmUp`, chiamata da
// `main()` prima di `runApp` senza attenderla).
//
// Garanzie che servono perché l'anticipo sia innocuo:
//  * un'apertura anticipata e una "vera" concorrenti condividono la STESSA
//    apertura (non due `openDatabase` in parallelo sullo stesso file);
//  * lo schema creato è quello di sempre;
//  * un errore dell'apertura anticipata non esce come eccezione non gestita e
//    non impedisce il tentativo successivo, che vede il proprio esito.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  String newDbPath(String name) => p.join(tempDir.path, name);

  setUp(() async {
    AppDatabase.ensureFactoryInitialized();
    await AppDatabase.instance.close();
    tempDir = Directory.systemTemp.createTempSync('scripta_warmup_');
    AppDatabase.debugDatabasePathOverride = newDbPath('ok.db');
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = null;
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // Su Windows il file può restare bloccato un istante: è solo un temporaneo.
    }
  });

  test('warmUp e db concorrenti condividono la stessa apertura', () async {
    final warm = AppDatabase.instance.warmUp();
    // `db` richiesto mentre l'apertura anticipata è ancora in corso.
    final first = AppDatabase.instance.db;
    final second = AppDatabase.instance.db;

    expect(identical(first, second), isTrue,
        reason: 'due richieste concorrenti devono ricevere lo stesso Future');

    await warm;
    final opened = await first;
    expect(identical(opened, await AppDatabase.instance.db), isTrue);
  });

  test('warmUp avvia davvero l\'apertura: il file compare senza altre richieste di `db`', () async {
    final path = AppDatabase.debugDatabasePathOverride!;
    expect(File(path).existsSync(), isFalse, reason: 'premessa: nessuno ha ancora aperto il database');

    await AppDatabase.instance.warmUp();

    expect(File(path).existsSync(), isTrue);
  });

  test('dopo warmUp lo schema è quello di sempre', () async {
    await AppDatabase.instance.warmUp();

    final db = await AppDatabase.instance.db;
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('notes', 'folders')",
    );
    expect(tables.map((r) => r['name']).toSet(), {'notes', 'folders'});
  });

  test('un errore di apertura anticipata non lancia e non blocca il tentativo successivo', () async {
    // Un file che NON è un database: l'apertura fallisce al primo PRAGMA
    // ("file is not a database"), su ogni piattaforma.
    final broken = File(newDbPath('rotto.db'))..writeAsStringSync('questo non è un database sqlite' * 20);
    AppDatabase.debugDatabasePathOverride = broken.path;

    // L'apertura anticipata NON deve lanciare.
    await AppDatabase.instance.warmUp();

    // Il primo chiamante vero riprova da capo e vede il proprio errore
    // (se `_opening` non fosse stato azzerato otterrebbe quello vecchio e,
    // soprattutto, nessun nuovo tentativo sarebbe possibile).
    await expectLater(AppDatabase.instance.db, throwsA(anything));

    // Risolto il problema, un nuovo tentativo riesce.
    AppDatabase.debugDatabasePathOverride = newDbPath('sano.db');
    final db = await AppDatabase.instance.db;
    expect(db.isOpen, isTrue);
  });
}
