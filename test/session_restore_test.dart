import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:scripta/core/constants/app_constants.dart';
import 'package:scripta/core/database/app_database.dart';
import 'package:scripta/core/database/folders_dao.dart';
import 'package:scripta/core/database/notes_dao.dart';
import 'package:scripta/core/services/session_state_service.dart';
import 'package:scripta/features/editor/models/editor_state_model.dart';
import 'package:scripta/features/editor/providers/editor_provider.dart';
import 'package:scripta/features/folders/providers/folder_provider.dart';
import 'package:scripta/features/notes/providers/notes_provider.dart';
import 'package:scripta/shell/session_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Ripresa dell'ultima posizione: dopo aver chiuso e riaperto l'app l'utente
// deve ritrovare la stessa modalità (Modifica / Visualizza), la stessa cartella
// e la stessa nota, non "Modifica" + "Tutte le note" + prima nota.
//
// Struttura:
//  * SessionStateService: lettura/scrittura su SharedPreferences, tollerante
//    a valori mancanti o corrotti;
//  * i tre notifier: partono dal valore ripristinato e lo VALIDANO (una nota o
//    una cartella possono essere sparite nel frattempo);
//  * "riavvio simulato": due ProviderContainer in sequenza sullo stesso SQLite
//    reale, come due avvii successivi dell'app.

// ---------------------------------------------------------------------------
// DAO finti e dati di esempio
// ---------------------------------------------------------------------------

class _FakeNotesDao implements NotesDao {
  final Map<String, NoteRow> rows = {};

  @override
  Future<List<NoteRow>> getActive() async =>
      rows.values.where((r) => !r.isDeleted).toList();

  @override
  Future<void> upsert(NoteRow row) async => rows[row.id] = row;

  @override
  Future<void> upsertBatch(List<NoteRow> list) async {
    for (final r in list) {
      rows[r.id] = r;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _FakeFoldersDao implements FoldersDao {
  final Map<String, FolderRow> rows = {};

  @override
  Future<List<FolderRow>> getActive() async =>
      rows.values.where((r) => !r.isDeleted).toList();

  @override
  Future<void> upsert(FolderRow row) async => rows[row.id] = row;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

NoteRow _noteRow(String id, {int updated = 1, String? folderId, int? deletedAt}) =>
    NoteRow(
      id: id,
      title: id,
      content: 'contenuto di $id',
      folderId: folderId,
      isFavorite: false,
      isPinned: false,
      orderIndex: 0,
      createdAt: 1,
      updatedAt: updated,
      deletedAt: deletedAt,
    );

FolderRow _folderRow(String id) => FolderRow(
      id: id,
      name: id,
      parentId: null,
      isExpanded: true,
      updatedAt: 1,
      deletedAt: null,
    );

/// `FolderNotifier` vuole un `Ref`: lo si ottiene da un provider banale.
final Provider<Ref> _refProvider = Provider<Ref>((ref) => ref);

/// Tempo concesso al caricamento iniziale dei notifier (DAO finti in memoria).
const Duration _loadWait = Duration(milliseconds: 50);

/// Attende (con polling e timeout) che [condition] diventi vera: niente
/// ritardi fissi con SQLite reale. Allo scadere non fallisce da sola: lo fa
/// l'`expect` successivo, con un messaggio che dice cosa non combacia.
Future<void> waitUntil(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  Duration interval = const Duration(milliseconds: 25),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(interval);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // -------------------------------------------------------------------------
  group('SessionStateService', () {
    test('senza nulla di salvato restituisce i valori di default', () async {
      final s = await SessionStateService.load();
      expect(s.editorMode, EditorMode.edit);
      expect(s.folderId, isNull);
      expect(s.noteId, isNull);
      expect(s.mobileEditorOpen, isFalse);
    });

    test('salva e rilegge modalità, cartella, nota e pannello mobile', () async {
      await SessionStateService.saveEditorMode(EditorMode.readOnly);
      await SessionStateService.saveFolderId('cartella-1');
      await SessionStateService.saveNoteId('nota-1');
      await SessionStateService.saveMobileEditorOpen(true);

      final s = await SessionStateService.load();
      expect(s.editorMode, EditorMode.readOnly);
      expect(s.folderId, 'cartella-1');
      expect(s.noteId, 'nota-1');
      expect(s.mobileEditorOpen, isTrue);
    });

    test('salvare null rimuove cartella e nota ("Tutte le note", nessuna nota)', () async {
      await SessionStateService.saveFolderId('cartella-1');
      await SessionStateService.saveNoteId('nota-1');
      await SessionStateService.saveFolderId(null);
      await SessionStateService.saveNoteId(null);

      final s = await SessionStateService.load();
      expect(s.folderId, isNull);
      expect(s.noteId, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(AppConstants.prefSessionFolderId), isFalse);
      expect(prefs.containsKey(AppConstants.prefSessionNoteId), isFalse);
    });

    test('modalità sconosciuta o id vuoto ricadono sul default', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.prefSessionEditorMode: 'modalita-inventata',
        AppConstants.prefSessionNoteId: '',
      });
      final s = await SessionStateService.load();
      expect(s.editorMode, EditorMode.edit);
      expect(s.noteId, isNull);
    });

    test('valori di tipo sbagliato non fanno fallire il caricamento', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.prefSessionEditorMode: 42,
        AppConstants.prefSessionMobileEditorOpen: 'sì',
      });
      final s = await SessionStateService.load();
      expect(s.editorMode, EditorMode.edit);
      expect(s.mobileEditorOpen, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('EditorNotifier', () {
    test('parte dalla modalità dell\'ultima sessione (Visualizza)', () {
      final container = ProviderContainer(
        overrides: [
          sessionSnapshotProvider.overrideWithValue(
            const SessionSnapshot(editorMode: EditorMode.readOnly),
          ),
        ],
      );
      addTearDown(container.dispose);

      // Sincrono: già al primo frame, senza passare da "Modifica".
      expect(container.read(editorProvider).mode, EditorMode.readOnly);
    });

    test('senza sessione parte in Modifica, come sempre', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(editorProvider).mode, EditorMode.edit);
    });

    test('focus mode non viene mai ripristinato', () {
      final container = ProviderContainer(
        overrides: [
          sessionSnapshotProvider.overrideWithValue(
            const SessionSnapshot(editorMode: EditorMode.readOnly),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(editorProvider).isFocusMode, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('NotesNotifier: ripresa della nota attiva', () {
    _FakeNotesDao threeNotes() => _FakeNotesDao()
      ..rows['a'] = _noteRow('a', updated: 300) // prima con l'ordine di default
      ..rows['b'] = _noteRow('b', updated: 200)
      ..rows['c'] = _noteRow('c', updated: 100);

    test('riapre la nota dell\'ultima sessione invece della prima', () async {
      final n = NotesNotifier(dao: threeNotes(), initialActiveNoteId: 'c');
      addTearDown(n.dispose);
      await Future<void>.delayed(_loadWait);

      expect(n.state.notes.first.id, 'a'); // controllo: la prima sarebbe 'a'
      expect(n.state.activeNoteId, 'c');
    });

    test('se la nota salvata non esiste più ripiega sulla prima', () async {
      final n = NotesNotifier(dao: threeNotes(), initialActiveNoteId: 'cancellata');
      addTearDown(n.dispose);
      await Future<void>.delayed(_loadWait);

      expect(n.state.activeNoteId, 'a');
    });

    test('una nota cancellata (tombstone) non viene riaperta', () async {
      final dao = threeNotes()..rows['c'] = _noteRow('c', updated: 100, deletedAt: 5);
      final n = NotesNotifier(dao: dao, initialActiveNoteId: 'c');
      addTearDown(n.dispose);
      await Future<void>.delayed(_loadWait);

      expect(n.state.activeNoteId, 'a');
    });

    test('senza sessione salvata il comportamento resta quello di sempre', () async {
      final n = NotesNotifier(dao: threeNotes());
      addTearDown(n.dispose);
      await Future<void>.delayed(_loadWait);

      expect(n.state.activeNoteId, 'a');
    });

    test('con il DB vuoto nessuna nota attiva, anche con una nota salvata', () async {
      final n = NotesNotifier(dao: _FakeNotesDao(), initialActiveNoteId: 'a');
      addTearDown(n.dispose);
      await Future<void>.delayed(_loadWait);

      expect(n.state.activeNoteId, isNull);
    });

    test('prima del caricamento non c\'è alcuna nota attiva fantasma', () {
      // Un id attivo con la lista ancora vuota farebbe comparire un editor
      // modificabile per una nota inesistente: l'id si applica solo al caricamento.
      final n = NotesNotifier(dao: threeNotes(), initialActiveNoteId: 'c');
      addTearDown(n.dispose);

      expect(n.state.activeNoteId, isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('FolderNotifier: ripresa della cartella selezionata', () {
    test('mantiene la cartella dell\'ultima sessione se esiste ancora', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final folders = FolderNotifier(
        container.read(_refProvider),
        foldersDao: _FakeFoldersDao()..rows['f1'] = _folderRow('f1'),
        notesDao: _FakeNotesDao(),
        initialSelectedFolderId: 'f1',
      );
      addTearDown(folders.dispose);

      // Selezionata subito, prima del caricamento: niente salto da "Tutte le note".
      expect(folders.state.selectedFolderId, 'f1');

      await Future<void>.delayed(_loadWait);
      expect(folders.state.selectedFolderId, 'f1');
      expect(folders.state.rootFolders.map((f) => f.id), ['f1']);
    });

    test('se la cartella non esiste più torna a "Tutte le note"', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final folders = FolderNotifier(
        container.read(_refProvider),
        foldersDao: _FakeFoldersDao()..rows['f1'] = _folderRow('f1'),
        notesDao: _FakeNotesDao(),
        initialSelectedFolderId: 'cancellata',
      );
      addTearDown(folders.dispose);

      await Future<void>.delayed(_loadWait);
      expect(folders.state.selectedFolderId, isNull);
      // L'albero viene caricato comunque.
      expect(folders.state.rootFolders.map((f) => f.id), ['f1']);
    });

    test('senza sessione salvata parte da "Tutte le note", come sempre', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final folders = FolderNotifier(
        container.read(_refProvider),
        foldersDao: _FakeFoldersDao()..rows['f1'] = _folderRow('f1'),
        notesDao: _FakeNotesDao(),
      );
      addTearDown(folders.dispose);

      await Future<void>.delayed(_loadWait);
      expect(folders.state.selectedFolderId, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Riavvio simulato con SQLite reale (stesso schema di test/widget_test.dart:
  // database su file temporaneo, factory ffi).
  group('riavvio simulato (SQLite reale)', () {
    setUp(() async {
      AppDatabase.ensureFactoryInitialized();
      await AppDatabase.instance.close();
      AppDatabase.debugDatabasePathOverride = p.join(
        Directory.systemTemp.path,
        'scripta_session_test_${DateTime.now().microsecondsSinceEpoch}.db',
      );
    });

    tearDown(() async {
      // Lascia smaltire l'I/O "fire and forget" dei notifier prima di chiudere
      // il DB (vedi la stessa nota in test/widget_test.dart).
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await AppDatabase.instance.close();
      AppDatabase.debugDatabasePathOverride = null;
    });

    test('nota, cartella e modalità tornano come li avevo lasciati', () async {
      // Dati già presenti sul disco, come all'avvio reale (così il caricamento
      // iniziale e le azioni dell'utente non si sovrappongono).
      await FoldersDao().upsert(_folderRow('f1'));
      await NotesDao().upsert(_noteRow('n1', updated: 300));
      await NotesDao().upsert(_noteRow('n2', updated: 200, folderId: 'f1'));

      // --- Sessione 1: l'utente apre la cartella, una nota NON prima in lista,
      //     e passa a "Visualizza". ---
      final first = ProviderContainer();
      first.read(sessionPersistenceProvider);
      await waitUntil(() async => first.read(notesProvider).notes.length == 2);
      expect(first.read(notesProvider).activeNoteId, 'n1'); // default di sempre

      first.read(folderProvider.notifier).selectFolder('f1');
      first.read(notesProvider.notifier).selectNote('n2');
      first.read(editorProvider.notifier).setMode(EditorMode.readOnly);

      await waitUntil(() async {
        final s = await SessionStateService.load();
        return s.noteId == 'n2' &&
            s.folderId == 'f1' &&
            s.editorMode == EditorMode.readOnly;
      });
      first.dispose(); // "chiudo l'app"

      // --- Sessione 2: "riapro l'app" (nuovo container, stesso disco). ---
      final snapshot = await SessionStateService.load();
      final second = ProviderContainer(
        overrides: [sessionSnapshotProvider.overrideWithValue(snapshot)],
      );
      addTearDown(second.dispose);
      second.read(sessionPersistenceProvider);

      // Modalità e cartella sono già giuste al primo frame, prima di qualsiasi I/O.
      expect(second.read(editorProvider).mode, EditorMode.readOnly);
      expect(second.read(folderProvider).selectedFolderId, 'f1');

      await waitUntil(() async => second.read(notesProvider).activeNoteId != null);
      await waitUntil(() async => second.read(folderProvider).rootFolders.isNotEmpty);

      expect(second.read(notesProvider).activeNoteId, 'n2');
      expect(second.read(folderProvider).selectedFolderId, 'f1');
      expect(second.read(editorProvider).mode, EditorMode.readOnly);

      // L'avvio non deve aver sovrascritto la sessione salvata con i valori
      // transitori di prima del caricamento dal database.
      final after = await SessionStateService.load();
      expect(after.noteId, 'n2');
      expect(after.folderId, 'f1');
      expect(after.editorMode, EditorMode.readOnly);
    });

    test('riferimenti non più validi: prima nota e "Tutte le note", e il disco si ripulisce',
        () async {
      await FoldersDao().upsert(_folderRow('f1'));
      await NotesDao().upsert(_noteRow('n1', updated: 300));
      await NotesDao().upsert(_noteRow('n2', updated: 200));

      // Sessione precedente chiusa su una nota e una cartella poi cancellate
      // da un altro dispositivo (arrivate con la sync).
      await SessionStateService.saveNoteId('nota-cancellata');
      await SessionStateService.saveFolderId('cartella-cancellata');
      await SessionStateService.saveEditorMode(EditorMode.readOnly);

      final snapshot = await SessionStateService.load();
      final container = ProviderContainer(
        overrides: [sessionSnapshotProvider.overrideWithValue(snapshot)],
      );
      addTearDown(container.dispose);
      container.read(sessionPersistenceProvider);

      await waitUntil(() async => container.read(notesProvider).activeNoteId != null);
      await waitUntil(() async => container.read(folderProvider).rootFolders.isNotEmpty);

      expect(container.read(notesProvider).activeNoteId, 'n1');
      expect(container.read(folderProvider).selectedFolderId, isNull);
      // La modalità non dipende dal database: resta quella salvata.
      expect(container.read(editorProvider).mode, EditorMode.readOnly);

      // I riferimenti rotti vengono sostituiti su disco da quelli reali.
      await waitUntil(() async {
        final s = await SessionStateService.load();
        return s.noteId == 'n1' && s.folderId == null;
      });
      final healed = await SessionStateService.load();
      expect(healed.noteId, 'n1');
      expect(healed.folderId, isNull);
    });
  });
}
