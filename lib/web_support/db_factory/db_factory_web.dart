// WEB: implementazione Web (dart2js e dart2wasm).
// sqflite_common è una dipendenza transitiva di sqflite_common_ffi_web: viene
// importata direttamente solo per il tipo Database e il setter databaseFactory.
// ignore: depend_on_referenced_packages
import 'package:sqflite_common/sqflite.dart' show databaseFactory;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

// WEB: l'app_database usa Database/openDatabase senza importare direttamente
// sqflite_common_ffi (che non compila sul Web).
// ignore: depend_on_referenced_packages
export 'package:sqflite_common/sqflite.dart' show Database, openDatabase;

/// Inizializza la factory SQLite su Web.
///
/// Il database vive in un'immagine SQLite in memoria persistita in IndexedDB
/// dal worker di sqflite. I due URI sono RELATIVI alla base href dell'app:
/// gli asset vengono pubblicati accanto a index.html e serviti dal service
/// worker, quindi non dipendono dal dominio (pages.dev, preview, dominio
/// finale).
///
/// Una sola connessione per database: il virtual file system Web non ha
/// locking tra connessioni e aprirne due potrebbe corrompere i dati. Il
/// codice applicativo usa già un'unica istanza (AppDatabase._opening).
void initializeDatabaseFactory() {
  databaseFactory = createDatabaseFactoryFfiWeb(
    options: SqfliteFfiWebOptions(
      sqlite3WasmUri: Uri.parse('sqlite3.wasm'),
      sharedWorkerUri: Uri.parse('sqflite_sw.js'),
    ),
  );
}

/// Nome logico del database nel virtual file system Web.
///
/// Non è un percorso su disco: sqflite_common_ffi_web lo usa come chiave
/// dell'immagine SQLite dentro IndexedDB.
Future<String> resolveDatabasePath() async => 'scripta.db';
