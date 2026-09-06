import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Punto di accesso unico al database locale SQLite: la SINGOLA fonte di
/// verità che la UI legge tramite i provider Riverpod (mai direttamente).
///
/// SCHEMA — interamente ID-based, coerente 1:1 con lo schema del server
/// (vedi backend `internal/db/db.go`): nessuna colonna rappresenta un
/// percorso testuale, e il contenuto Markdown vive nella colonna `content`
/// della tabella `notes` (non più su file separati).
///
///   folders(id TEXT PK, name, parent_id NULLABLE, is_expanded (solo UI,
///           MAI inviato al server), updated_at, deleted_at NULLABLE)
///   notes(id TEXT PK, title, content, folder_id NULLABLE, is_favorite,
///         is_pinned, order_index, created_at (solo locale, per
///         l'ordinamento "data creazione", MAI inviato al server),
///         updated_at, deleted_at NULLABLE)
///
/// `deleted_at` NULL = riga attiva; valorizzato = tombstone (soft delete),
/// propagato dalla sync e infine rimosso fisicamente da [purgeSyncedTombstone]
/// una volta che la sync ha confermato che il server lo ha ricevuto.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  /// Solo per i test: se valorizzato, il database viene aperto a QUESTO
  /// percorso invece di interrogare `path_provider` (che richiede un
  /// platform channel non disponibile nell'ambiente `flutter test` puro,
  /// a differenza di `sqflite_common_ffi`, che invece funziona lì senza
  /// bisogno di alcun device/emulatore). Vedi test/widget_test.dart.
  @visibleForTesting
  static String? debugDatabasePathOverride;

  /// Inizializza (una sola volta) il [DatabaseFactory] corretto per la
  /// piattaforma corrente. Su Android/iOS il plugin `sqflite` usa il proprio
  /// engine nativo automaticamente; su desktop (Linux/Windows/macOS) serve
  /// invece esplicitamente `sqflite_common_ffi`, che usa sqlite3 nativo via
  /// FFI. Va chiamato prima di qualunque apertura di database (fatto da
  /// [main] all'avvio dell'app, vedi lib/main.dart).
  static void ensureFactoryInitialized() {
    if (kIsWeb) {
      // Il web non è un target supportato da questa app (nessuna cartella
      // web/ nel progetto): nessuna inizializzazione necessaria qui.
      return;
    }
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    // Android/iOS: il databaseFactory di default del plugin sqflite va già bene.
  }

  Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final path = debugDatabasePathOverride ?? p.join((await getApplicationSupportDirectory()).path, 'scripta.db');

    return openDatabase(
      path,
      version: 1,
      onConfigure: (db) async {
        // Integrità referenziale non necessaria lato client (nessuna FK
        // dichiarata nello schema locale), ma WAL migliora sensibilmente la
        // reattività della UI durante scritture frequenti (autosave a ogni
        // battitura, con debounce, mentre l'utente continua a leggere/
        // scorrere altre note).
        //
        // IMPORTANTE: "PRAGMA journal_mode = WAL" restituisce una riga con
        // il nome del journal mode effettivamente impostato. Su Android il
        // plugin sqflite instrada `execute()` verso
        // SQLiteDatabase.execSQL(), che accetta SOLO statement che non
        // producono un result set: per un PRAGMA che ne produce uno va
        // usato `rawQuery` (o `rawUpdate`), altrimenti si ottiene
        // "Queries can be performed using SQLiteDatabase query or
        // rawQuery methods only." e l'apertura del database fallisce ad
        // ogni avvio, portando con sé anche note/cartelle non salvate e
        // sync mai avviata.
        await db.rawQuery('PRAGMA journal_mode = WAL');
        // "PRAGMA foreign_keys = ON" non restituisce righe: execute() va bene.
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE folders (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            parent_id   TEXT,
            is_expanded INTEGER NOT NULL DEFAULT 1,
            updated_at  INTEGER NOT NULL,
            deleted_at  INTEGER
          )
        ''');
        await db.execute('CREATE INDEX idx_folders_parent ON folders(parent_id)');
        await db.execute('CREATE INDEX idx_folders_updated ON folders(updated_at)');

        await db.execute('''
          CREATE TABLE notes (
            id          TEXT PRIMARY KEY,
            title       TEXT NOT NULL DEFAULT '',
            content     TEXT NOT NULL DEFAULT '',
            folder_id   TEXT,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            is_pinned   INTEGER NOT NULL DEFAULT 0,
            order_index INTEGER NOT NULL DEFAULT 0,
            created_at  INTEGER NOT NULL,
            updated_at  INTEGER NOT NULL,
            deleted_at  INTEGER
          )
        ''');
        await db.execute('CREATE INDEX idx_notes_folder ON notes(folder_id)');
        await db.execute('CREATE INDEX idx_notes_updated ON notes(updated_at)');

        // Coppia chiave/valore per lo stato della sync (cursore
        // last_synced_at, ecc.). Le preferenze utente "generiche" restano su
        // SharedPreferences (settings_provider.dart, non toccato da questo
        // refactor): questa tabella è dedicata al solo stato di sync, che è
        // intrinsecamente parte del layer dati/sync.
        await db.execute('''
          CREATE TABLE sync_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
    );
  }

  /// Chiude la connessione (usato solo nei test, per garantire isolamento
  /// tra un test e l'altro).
  Future<void> close() async {
    final d = _db;
    _db = null;
    await d?.close();
  }
}
