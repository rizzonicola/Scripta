// WEB: implementazione IO (Android, iOS, desktop, flutter test).
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/utils/platform_utils.dart';

// WEB: l'app_database usa Database/openDatabase senza importare direttamente
// sqflite_common_ffi (che non compila sul Web).
export 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show Database, openDatabase;

/// Inizializza la factory SQLite per le piattaforme native.
///
/// Android/iOS usano la factory di default del plugin sqflite; desktop e
/// test usano sqflite_common_ffi. Sul web questa funzione non viene mai
/// compilata (vedi db_factory.dart).
void initializeDatabaseFactory() {
  if (isDesktopPlatform) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
}

/// Percorso del database nella directory dati privata dell'app.
Future<String> resolveDatabasePath() async {
  return p.join((await getApplicationSupportDirectory()).path, 'scripta.db');
}
