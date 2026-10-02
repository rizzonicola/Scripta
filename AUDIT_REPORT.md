# Scripta 0.9.4 — audit e refactoring

## ⚠️ Stato della verifica (da leggere per primo)

L'ambiente in cui è stato fatto questo lavoro non ha né l'SDK Flutter/Dart né
accesso alla rete. Quindi:

- **`flutter analyze` e `flutter test` NON sono stati eseguiti**: né sulla suite
  esistente né sui test nuovi.
- `dart format` non è stato eseguito: il codice rigenerato potrebbe non
  coincidere con l'output del formatter.
- Nessuna prestazione è stata **misurata**: i benefici indicati sotto sono
  stime analitiche (complessità, numero di round-trip), non benchmark.

Al posto del compilatore ho usato controlli statici: parentesi bilanciate sui
30 file toccati, esistenza e uso di ogni import relativo, ricerca di
identificatori non risolti, confronto meccanico delle firme pubbliche dei DAO
(i fake nei test fanno `implements NotesDao/FoldersDao`: le firme sono
invariate) e rilettura integrale dei diff. Questo ha intercettato un errore di
compilazione reale (chiamate a metodi `static` non qualificate in
`note_card.dart`), già corretto. **Non sostituisce il compilatore.**

Da lanciare sulla tua macchina prima di fare merge:

```bash
flutter pub get
dart format lib test
flutter analyze
flutter test
```

Se qualcosa non compila, è quasi certamente in uno dei file elencati in
fondo; `scripta-audit.patch` mostra ogni riga cambiata.

---

## Cosa è cambiato

### Database e DAO
- **Apertura condivisa** (`AppDatabase.db`): il `Future` di apertura viene
  memorizzato, così `_open()` gira una sola volta anche con più provider che
  leggono `db` insieme all'avvio. È un irrobustimento, non un bug riprodotto
  (sqflite già unifica le aperture dello stesso percorso). `close()` ora
  attende un'apertura in volo.
- **PRAGMA**: `synchronous = NORMAL` (meno fsync a ogni autosave) e
  `busy_timeout = 5000` (niente `SQLITE_BUSY` immediato se un'altra istanza
  desktop tiene il lock).
- **Migrazione v3**: indici *parziali* sui tombstone (`deleted_at IS NOT NULL`)
  e purge riscritta con sotto-query, perché `dirty = 0` vale per quasi tutte le
  righe e con la query piatta SQLite tende a preferire `idx_notes_dirty`.
  L'effetto sul piano di esecuzione è atteso ma **non verificato**: controlla
  con `EXPLAIN QUERY PLAN` su un database reale.
- **`applyRemoteLWWBatch`** (note e cartelle): prima una SELECT + una scrittura
  per ogni riga ricevuta; ora una SELECT per blocco di 500 id (solo metadati,
  mai `content`) e un solo batch. Semantica identica, anche con lo stesso id
  ripetuto nel batch.
- **`deleteCleanNotIn`**: la DELETE ripete `dirty = 0`. Prima leggeva gli id
  puliti e li cancellava senza ricontrollare: una nota modificata *durante* la
  sync poteva essere eliminata. `hardDeleteIds` esegue tutti i blocchi in
  un'unica transazione (prima un commit per blocco).
- **`cascadeSoftDelete`**: una sola lettura del sottoalbero (prima una query
  per livello); si cancellano prima le note e poi tutte le cartelle in una
  transazione. Prima la radice veniva marcata per prima: un kill dell'app a
  metà lasciava una radice cancellata con figli e note ancora attivi.
- Nuovo `sql_helpers.dart` (`chunked`, `sqlPlaceholders`, `deleteByIds`).

### Sync
- **Nessun trigger perso**: se un trigger arriva mentre una sync è in corso
  viene ricordato; dopo un giro riuscito parte un giro di recupero (al massimo
  2 di seguito). Prima veniva scartato e la modifica restava non inviata fino
  al trigger successivo.
- `triggerSync` non lascia più sfuggire eccezioni (viene spesso lanciata da un
  `Timer` senza `await`).
- Dopo la sync, `refreshFromDb` (rilettura di tutte le note) solo se il DB
  locale è davvero cambiato.
- Un errore di SQLite locale non viene più mostrato come "server non
  raggiungibile".
- JSON di richiesta/risposta oltre 128 KB codificato/decodificato in un
  isolate (sotto soglia resta sincrono).

### Impostazioni e root dell'app
- `ScriptaApp` osserva solo i campi che influenzano `MaterialApp` (prima ogni
  tick dello slider del font ricostruiva tutto) e i temi sono memoizzati in un
  provider. `WindowDecorationService` non richiama il canale nativo a tema
  invariato e ignora toggle F11 sovrapposti.
- Push remoto delle impostazioni con debounce di 400 ms (prima una PUT per ogni
  variazione dello slider), con flush quando l'app va in background.

### Modelli e provider delle note
- `wordCount` / `readingTimeMinutes` calcolati una volta per istanza (scansione
  lineare, niente `split(RegExp)`); `previewSnippet` pulisce solo il prefisso di
  4000 caratteri e usa RegExp statiche.
- Ricerca: esito per nota memorizzato per istanza (`Expando`), così digitare
  non rifà `toLowerCase()` sul testo di tutte le note. Ordinamento per titolo
  con chiavi minuscole precalcolate.

### UI e architettura
- `folder_tree_view.dart` 826 → 269 righe, con `folder_dialogs`,
  `folder_menus`, `folder_item_tile`, `folder_name_dialog`,
  `folder_picker_dialog` estratti. I due dialog "sposta" quasi identici
  (nota/cartella) sono un solo `FolderPickerDialog`.
- **Leak risolti**: i `TextEditingController` dei dialog nuova/rinomina cartella
  non venivano mai rilasciati; ora li possiede uno `State`.
- `NoteCard` 500 → 426 righe (`_NoteCardActions`, `_NoteDragHandle`).
- `AdaptiveAppShell.build` scomposto in layout dedicati (focus, desktop,
  tablet, mobile); drawer condiviso.
- `activatorsFor` in cache: il dispatcher delle scorciatoie gira a ogni tasto
  premuto e ricostruiva tutti gli attivatori ogni volta.

### Export
- Nuovo `export_archive.dart` (logica pura, testabile). Correzioni sul
  **backup**: due note con lo stesso titolo nella stessa cartella avevano lo
  stesso percorso nello ZIP (una veniva persa o sostituita, a seconda del
  comportamento di `archive`); un id di meno di 6 caratteri faceva fallire
  l'intero export; i nomi di cartella non erano sanitizzati (`..` produceva
  una voce con path traversal). Inoltre all'isolate arrivano solo le note
  necessarie e solo i campi usati.

---

## Cambiamenti che alterano il comportamento (rivedili)

1. **Schema DB v3**: migrazione additiva e idempotente, ma a senso unico:
   tornare a una build precedente su un database già migrato può non aprirsi.
2. **`synchronous = NORMAL`**: un crash dell'app non perde né corrompe nulla;
   un'interruzione di corrente o crash dell'OS può far perdere gli ultimi
   commit. È il compromesso standard con WAL.
3. **Giri di sync di recupero** dopo trigger concorrenti (max 2): più richieste
   al server in scenari di uso intenso (es. alt-tab ripetuto con sync al
   cambio di stato attiva).
4. **Backup**: in caso di collisione i file diventano `Titolo (2).md`,
   `Titolo (3).md`; le cartelle con caratteri non ammessi usano `_`.
5. **Rinomina cartella** ora avvia la sync come le altre modifiche
   strutturali (prima restava `dirty` fino a un trigger non correlato).
6. **Dialog "sposta"**: scegliere la destinazione attuale chiude senza azione
   né snackbar (prima mostrava "Nota spostata…" anche senza spostamento).
7. **Salvataggio**: al passaggio in background viene svuotato subito il debounce
   di 500 ms anche per utenti solo-locali (prima solo con account connesso e
   sync al lifecycle attiva).
8. **Anteprima delle note**: i link mostrano il testo del link; prima compariva
   il letterale `$1`, perché `replaceAll` non interpreta i riferimenti.
9. Invio impostazioni al server con 400 ms di ritardo (con flush in background).

## Volutamente non fatto

- **`markdown_rendered_view.dart`**: vista di sola lettura già virtualizzata,
  parsing una tantum per nota. Spostarlo in un isolate richiede inviare l'AST di
  `flutter_md` tra isolate, cosa che non posso verificare senza il pacchetto.
- **`account_sync_section`, `note_editor_pane`, `markdown_editor_field`,
  `notes_list_view`**: riletti, rilascio delle risorse corretto; nessuna
  modifica oltre a un import.
- **i18n**: i dialog, l'export e l'import hanno stringhe italiane fisse.
  Migrarle richiede di rigenerare `app_localizations` (`flutter gen-l10n`).
- **`analysis_options.yaml`** invariato: non ho aggiunto lint di cui non potevo
  vedere gli effetti.
- **Multi-window**: l'app non lo supporta oggi e non l'ho introdotto (è una
  funzionalità, non un refactoring).
- `notes_provider.dart` (923 righe) e `sync_provider.dart` (790) sono
  **cresciuti** (logica di robustezza e commenti). Estrarre l'ordinamento in un
  file puro e un motore di sync separato è il passo successivo sensato, ma da
  fare con il compilatore a disposizione.

## Test aggiunti (non eseguiti)

| File | Copre |
|---|---|
| `dao_batch_test.dart` | helper SQL, apertura concorrente, PRAGMA, indici, LWW a batch (>1000 righe), `deleteCleanNotIn`, purge, cascade (anche con cicli) |
| `export_archive_test.dart` | nomi univoci, id corti, sanitizzazione, gerarchie cicliche, flatten |
| `note_model_test.dart` | parole (equivalenza con la vecchia definizione), tempo di lettura, snippet |
| `sync_robustness_test.dart` | coalescing dei trigger, nessun giro dopo errore, debounce e flush delle impostazioni |
| `sync_api_large_payload_test.dart` | percorso con isolate di richiesta e risposta |
| `app_commands_cache_test.dart` | cache degli attivatori |

`sync_robustness_test.dart` attende circa 800 ms per verificare l'assenza di
invii duplicati: su CI molto lente conviene alzare quel margine.

## File

Nuovi (lib): `core/database/sql_helpers.dart`, `core/services/export_archive.dart`,
`features/folders/presentation/{folder_dialogs,folder_menus,folder_item_tile,folder_name_dialog,folder_picker_dialog}.dart`.

Modificati: `app.dart`, `core/database/{app_database,notes_dao,folders_dao}.dart`,
`core/services/{export_service,sync_api_service,window_decoration_service}.dart`,
`core/utils/app_commands.dart`, `features/folders/presentation/folder_tree_view.dart`,
`features/notes/{models/note_model,presentation/note_card,presentation/notes_list_view,providers/notes_provider}.dart`,
`features/settings/providers/settings_provider.dart`,
`features/sync/providers/sync_provider.dart`, `shell/{adaptive_app_shell,app_shortcuts_scope}.dart`.
