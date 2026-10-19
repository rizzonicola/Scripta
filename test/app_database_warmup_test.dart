import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/database/app_database.dart';

// Apertura anticipata del database (AppDatabase.warmUp, chiamata da main()):
// deve partire da sola, restare UNA sola apertura condivisa con chi chiede `db`
// e, se fallisce, non lasciare un'eccezione asincrona né impedire il tentativo
// successivo.

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String reason = 'condizione non raggiunta in tempo',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String dbPath;

  setUp(() async {
    AppDatabase.ensureFactoryInitialized();
    await AppDatabase.instance.close();
    dbPath = p.join(
      Directory.systemTemp.path,
      'scripta_warmup_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    AppDatabase.debugDatabasePathOverride = dbPath;
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    AppDatabase.debugDatabasePathOverride = null;
  });

  test('warmUp apre il database senza che nessuno chieda `db`', () async {
    expect(File(dbPath).existsSync(), isFalse);

    AppDatabase.warmUp();

    // Nessun chiamante ha letto `db`: il file compare solo se l'apertura è
    // partita davvero da warmUp.
    await _waitUntil(
      () => File(dbPath).existsSync(),
      reason: 'warmUp non ha avviato l\'apertura del database',
    );

    final db = await AppDatabase.instance.db;
    expect(db.isOpen, isTrue);
  });

  test('warmUp e chiamanti concorrenti condividono UNA sola apertura', () async {
    final prima = AppDatabase.instance.db;
    AppDatabase.warmUp();
    final dopo = AppDatabase.instance.db;

    final risultati = await Future.wait([prima, dopo]);
    expect(identical(risultati[0], risultati[1]), isTrue);

    // Anche una lettura successiva, a database già aperto, è la stessa istanza.
    expect(identical(await AppDatabase.instance.db, risultati[0]), isTrue);
  });

  test('un errore di apertura anticipata non sfugge e la lettura vera riprova', () async {
    // Il "genitore" del percorso è un FILE: il database non può essere aperto.
    final blocco = File(p.join(
      Directory.systemTemp.path,
      'scripta_warmup_blocco_${DateTime.now().microsecondsSinceEpoch}',
    ))
      ..writeAsStringSync('non è una cartella');
    addTearDown(() {
      if (blocco.existsSync()) blocco.deleteSync();
    });
    AppDatabase.debugDatabasePathOverride = p.join(blocco.path, 'scripta.db');

    // Non lancia e non produce eccezioni asincrone non gestite (altrimenti il
    // test fallirebbe da solo).
    AppDatabase.warmUp();
    // `close` attende l'apertura in volo: dopo questa riga il tentativo anticipato è finito.
    await AppDatabase.instance.close();

    // La prima lettura vera ritenta davvero, e vede l'errore come prima.
    await expectLater(AppDatabase.instance.db, throwsA(anything));

    // Rimosso l'ostacolo, il tentativo successivo riesce.
    AppDatabase.debugDatabasePathOverride = dbPath;
    final db = await AppDatabase.instance.db;
    expect(db.isOpen, isTrue);
  });
}
