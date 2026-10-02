import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
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

  /// Versione dello schema locale. OGNI modifica allo schema richiede di
  /// incrementarla e di aggiungere il relativo blocco in `_onUpgrade`
  /// (sqflite chiama `onUpgrade` solo se la versione salvata è minore).
  ///   1 -> schema iniziale
  ///   2 -> colonna `dirty` su folders/notes (selezione del push indipendente
  ///        dall'orologio del client, vedi NotesDao.upsert)
  ///   3 -> indici PARZIALI sui tombstone (`deleted_at IS NOT NULL`) di
  ///        folders/notes. La purge dei tombstone confermati gira dopo OGNI
  ///        sync e, essendo `dirty = 0` vero per quasi tutte le righe,
  ///        l'unico indice disponibile non la aiutava: scansionava l'intera
  ///        tabella note (contenuto incluso). L'indice parziale contiene solo
  ///        le righe cancellate (poche), quindi non costa spazio né scritture
  ///        sulle note attive.
  static const int _schemaVersion = 3;
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

  /// Apertura in corso, condivisa tra i chiamanti: `folderProvider`,
  /// `notesProvider` e `syncProvider` leggono `db` quasi simultaneamente al
  /// primo avvio. Memorizzare il FUTURE (e non solo il risultato) garantisce
  /// che [_open] venga eseguita UNA sola volta anche con chiamanti
  /// concorrenti, invece di lanciare più `openDatabase` in parallelo sullo
  /// stesso file (con PRAGMA/onCreate/onUpgrade ripetuti).
  Future<Database>? _opening;

  Future<Database> get db {
    final open = _db;
    if (open != null) return Future<Database>.value(open);
    return _opening ??= _openOnce();
  }

  Future<Database> _openOnce() async {
    try {
      final database = await _open();
      _db = database;
      return database;
    } finally {
      // Anche in caso di errore: il chiamante successivo riprova da capo.
      _opening = null;
    }
  }

  Future<Database> _open() async {
    final path = debugDatabasePathOverride ?? p.join((await getApplicationSupportDirectory()).path, 'scripta.db');

    return openDatabase(
      path,
      version: _schemaVersion,
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
        // Con WAL, `synchronous = NORMAL` è sicuro contro la corruzione (al
        // più si perde l'ultima transazione in caso di blackout, mai per un
        // semplice crash/kill dell'app) e riduce gli fsync a ogni commit:
        // l'autosave con debounce pesa meno sull'I/O. Come per journal_mode
        // si usa `rawQuery`, perché `execute()` su Android rifiuta gli
        // statement che possono produrre un result set.
        await db.rawQuery('PRAGMA synchronous = NORMAL');
        // Attende fino a 5 s invece di fallire subito con SQLITE_BUSY se
        // un'altra istanza dell'app (possibile su desktop) tiene per un
        // istante il lock di scrittura sullo stesso file.
        await db.rawQuery('PRAGMA busy_timeout = 5000');
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE folders (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            parent_id   TEXT,
            is_expanded INTEGER NOT NULL DEFAULT 1,
            updated_at  INTEGER NOT NULL,
            deleted_at  INTEGER,
            dirty       INTEGER NOT NULL DEFAULT 1
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
            deleted_at  INTEGER,
            dirty       INTEGER NOT NULL DEFAULT 1
          )
        ''');
        await db.execute('CREATE INDEX idx_notes_folder ON notes(folder_id)');
        await db.execute('CREATE INDEX idx_notes_updated ON notes(updated_at)');
        await db.execute('CREATE INDEX idx_notes_dirty ON notes(dirty)');
        await db.execute('CREATE INDEX idx_folders_dirty ON folders(dirty)');
        await _createTombstoneIndexes(db);

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
      onUpgrade: _onUpgrade,
    );
  }

  /// Migrazioni incrementali: ogni blocco `if (oldVersion < N)` porta lo
  /// schema dalla versione N-1 alla N, in ordine, dentro la transazione di
  /// upgrade di sqflite (se un blocco lancia, l'upgrade viene annullato).
  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE folders ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1');
      await db.execute('ALTER TABLE notes ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1');

      // Stessa semantica della versione precedente: era "da inviare" ciò che
      // aveva updated_at > cursore. Le righe più vecchie del cursore sono già
      // sul server: pulite. Nessun re-upload di massa.
      final cursorRows = await db.query('sync_meta', where: 'key = ?', whereArgs: ['last_synced_at'], limit: 1);
      final cursor = cursorRows.isEmpty ? 0 : (int.tryParse(cursorRows.first['value'] as String) ?? 0);
      await db.rawUpdate('UPDATE folders SET dirty = CASE WHEN updated_at > ? THEN 1 ELSE 0 END', [cursor]);
      await db.rawUpdate('UPDATE notes SET dirty = CASE WHEN updated_at > ? THEN 1 ELSE 0 END', [cursor]);

      await db.execute('CREATE INDEX IF NOT EXISTS idx_notes_dirty ON notes(dirty)');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_folders_dirty ON folders(dirty)');
    }

    if (oldVersion < 3) {
      await _createTombstoneIndexes(db);
    }
  }

  /// Indici parziali per `purgeCleanTombstones`
  /// (`WHERE deleted_at IS NOT NULL AND dirty = 0`): il planner di SQLite può
  /// usarli perché la condizione dell'indice compare tra i termini AND della
  /// query. `IF NOT EXISTS` rende la funzione idempotente (creazione e
  /// migrazione condividono lo stesso codice).
  static Future<void> _createTombstoneIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_notes_tombstones ON notes(id) WHERE deleted_at IS NOT NULL',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_folders_tombstones ON folders(id) WHERE deleted_at IS NOT NULL',
    );
  }

  /// Chiude la connessione (usato solo nei test, per garantire isolamento
  /// tra un test e l'altro).
  Future<void> close() async {
    // Un'apertura ancora in volo scriverebbe `_db` DOPO questa chiusura,
    // lasciando una connessione orfana: la si attende prima.
    final pending = _opening;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        // L'apertura è fallita: non c'è nulla da chiudere.
      }
    }
    final d = _db;
    _db = null;
    await d?.close();
  }
}
