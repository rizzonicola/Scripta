# Specifiche Tecniche di Sincronizzazione: Architettura Local-First, Protocollo REST & LWW

**Progetto**: Scripta  
**Versione Specifiche**: 2.0.0 (riscritta dal codice: P6, fase 1)  
**Backend di Riferimento**: `notes-server` (Go, SQLite WAL / libSQL, **una transazione per batch**, protocollo di sync «delta» basato su ID)

> [!IMPORTANT]
> **La fonte di verità è il codice, non questo documento.** Per il client: `lib/core/services/sync_api_service.dart`,
> `lib/features/sync/` e `lib/core/database/`. Per il server: `internal/handlers/api_sync.go` e `internal/models/models.go`.
> Se questo testo e il codice divergono, vale il codice: correggere il testo.
>
> Le versioni 1.x di questo documento descrivevano un protocollo **a percorsi** (`relative_path`, liste `accepted` e
> `server_wins`, file `.md` su disco). Quel protocollo **non esiste più**: oggi ogni cartella e ogni nota ha un `id` (UUID), il contenuto
> sta nel database e la sync è uno scambio unico `POST /api/v1/sync`.

---

## 1. Visione d'Insieme & Filosofia Local-First

L'applicazione **Scripta** adotta il paradigma **Local-First**, progettato per offrire un'esperienza utente istantanea, resiliente e priva di interruzioni, a prescindere dalla disponibilità della connessione di rete.

### Principi Cardine:
1. **La copia locale è la sorgente primaria di verità (Local Primary)**: Tutte le operazioni di creazione, lettura, modifica ed eliminazione (CRUD) avvengono istantaneamente sul database e storage locale. L'interfaccia grafica non attende mai una risposta di rete per completare un'azione dell'utente (zero latenza percepita).
2. **Disponibilità Offline Incondizionata**: L'utente può aprire l'applicazione, consultare l'intero archivio note, organizzare le cartelle e scrivere documenti anche in assenza totale di connettività o in modalità aereo.
3. **Sincronizzazione Asincrona Protetta da Debouncing**: La riconciliazione con il backend Go (`notes-server`) avviene in modo asincrono attraverso trigger configurabili e controllati da timer di debouncing (500ms salvataggio note, 600ms cambio nota, inattività configurabile), garantendo la convergenza dei dati (consistenza eventuale) senza saturare la rete né bloccare il thread principale della UI.
4. **Idempotenza & Tolleranza ai Guasti**: Ogni scambio di sincronizzazione è idempotente: una transazione interrotta a metà a causa di una disconnessione improvvisa può essere ripetuta senza causare duplicazioni o corruzione dei dati.

---

## 2. Gestione del Database Locale (SQLite / sqflite)

### 2.1 Struttura e Modello Relazionale
Il client conserva i dati in un database **SQLite** locale (pacchetto `sqflite`, `lib/core/database/app_database.dart`, schema versione 3). Non c'è un ORM: l'accesso passa dai DAO (`FoldersDao`, `NotesDao`, `SyncMetaDao`).

```
┌─────────────────┐       ┌──────────────────┐
│     FOLDERS     │◄──────┤      NOTES       │
├─────────────────┤1     *├──────────────────┤
│ id (UUID PK)    │       │ id (UUID PK)     │
│ name            │       │ title, content   │
│ parent_id       │       │ folder_id        │
│ is_expanded *   │       │ is_favorite      │
│ updated_at (ms) │       │ is_pinned        │
│ deleted_at (ms) │       │ order_index      │
│ dirty           │       │ created_at *     │
└─────────────────┘       │ updated_at (ms)  │
                          │ deleted_at (ms)  │
                          │ dirty            │
                          └──────────────────┘
┌─────────────────┐
│    SYNC_META    │      * campi SOLO locali: non vengono mai inviati
├─────────────────┤
│ key (TEXT PK)   │
│ value (TEXT)    │      oggi: `last_synced_at` (il cursore)
└─────────────────┘
```

`parent_id` e `folder_id` sono semplici colonne di testo, **senza chiave esterna** nel database locale: l'integrità dei riferimenti la verifica il server (vedi §4.2, rifiuti `422`).

### 2.2 Schema DDL di Riferimento

```sql
CREATE TABLE folders (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  parent_id   TEXT,
  is_expanded INTEGER NOT NULL DEFAULT 1,
  updated_at  INTEGER NOT NULL,
  deleted_at  INTEGER,
  dirty       INTEGER NOT NULL DEFAULT 1
);

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
);

CREATE TABLE sync_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
-- più gli indici su parent_id / folder_id / updated_at / dirty e gli indici
-- PARZIALI sui tombstone (`WHERE deleted_at IS NOT NULL`).
```

Tutti i timestamp sono **millisecondi** Unix UTC.

### 2.3 Selezione di ciò che si invia: `dirty`
- Ogni scrittura **locale** (`upsert`) imposta `dirty = 1`. È il flag a decidere cosa va inviato, **non** il confronto fra `updated_at` e l'orologio: un orologio del dispositivo sbagliato non può far perdere modifiche.
- Le righe applicate dalla pull sono scritte con `dirty = 0`.
- Dopo un invio riuscito, `markSynced` azzera `dirty` **solo se la riga non è cambiata** durante il round-trip (confronto sull'`updated_at` letto prima dell'invio): una modifica fatta mentre la sync era in corso resta sporca e parte al giro successivo.

### 2.4 Ciclo di Vita delle Eliminazioni (Tombstoning)
1. Eliminare una cartella o una nota **non cancella la riga**: imposta `deleted_at` (e `dirty = 1`). La riga resta nel database locale come *tombstone*.
2. Al giro successivo il tombstone viaggia come una normale entità con `deleted_at` valorizzato.
3. Il server lo registra (e, per una cartella, propaga la cancellazione a sottocartelle e note ancora attive) e lo conserva **30 giorni**, così anche i dispositivi che erano offline lo apprendono.
4. Dopo ogni sync riuscita il client elimina fisicamente i propri tombstone già confermati (`deleted_at IS NOT NULL AND dirty = 0`).

---

## 3. Sync Toggles (Trigger di Sincronizzazione)

L'applicazione espone all'utente una sezione dedicata nelle Impostazioni per configurare quando e come avviare la sincronizzazione:

| Trigger | Descrizione | Implementazione Tecnica in Flutter |
| :--- | :--- | :--- |
| **Sync Manuale** | Pulsante dedicato nella schermata Impostazioni e icona nella `TopAppBar`. | Invocazione esplicita del metodo `ref.read(syncProvider.notifier).triggerSync()`. |
| **App Launch** | Avvia la sincronizzazione automatica all'apertura dell'app. | Eseguito nel metodo `_init()` di `SyncNotifier` (con lieve deferral di 500ms per non impattare il primo frame della UI). |
| **App Lifecycle (Pause / Exit)** | Invia le modifiche non appena l'app passa in background, si minimizza o si chiude. | Intercettato tramite `WidgetsBindingObserver.didChangeAppLifecycleState` (`AppLifecycleState.paused` / `inactive`). |
| **Note Switch / Editor Close** | Invia le modifiche quando l'utente chiude l'editor, torna all'elenco o seleziona un'altra nota. | Hook agganciati a `dispose()` di `NoteEditorPane`, al callback `onBack` della navigazione mobile e a `ref.listen(notesProvider.select((s) => s.activeNoteId))`. |
| **Inactivity Debounce** | Sincronizza automaticamente dopo un intervallo prestabilito di inattività durante la scrittura. | Timer di debounce (`_inactivityTimer`) resettato ad ogni modifica in `onTitleChanged` e `onContentChanged`. |

### Configurazione del Debounce di Inattività:
- **Range consentito**: da 10 a 300 secondi (minimo di sicurezza a 10s per evitare hammering del server).
- **Default di fabbrica**: 30 secondi.
- **Funzionamento**: finché l'utente continua a digitare, il timer scorre e si riavvia. Trascorsi N secondi dall'ultima pressione tasto, il sync parte in modalità silente in background.

---

## 4. Contratti API REST (v1) & Flussi di Comunicazione

Tutti gli endpoint REST sono esposti dal server Go sulla radice `/api/v1`. I dati sono scambiati in formato JSON con encoding UTF-8.

### 4.1 Autenticazione: `POST /api/v1/auth/login`
Autentica l'utente e rilascia un JSON Web Token (HMAC-SHA256) con un refresh token opaco. L'access token dura **1 ora di default** (`JWT_TTL`); il refresh token dura **90 giorni di default** (`REFRESH_TOKEN_TTL`) ed è sliding: ogni refresh ne emette uno nuovo con scadenza rinnovata.

- **Headers**: `Content-Type: application/json`, `X-Scripta-Client: scripta/<versione>` (solo per i log del server)
- **Request Body**:
```json
{ "username": "mario.rossi", "password": "password-in-chiaro" }
```
- **Response (200 OK)**:
```json
{
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "expires_at": 1767225600,
  "refresh_token": "u7V...opaco...",
  "refresh_expires_at": 1775001600,
  "user_id": "b3f1c24e-89a1-4321-bcde-1234567890ab",
  "username": "mario.rossi"
}
```
- **`expires_at` e `refresh_expires_at` sono in SECONDI Unix** (come il campo `exp` di un JWT), a differenza di tutti i timestamp di sync, che sono in millisecondi. Il client converte `expires_at` in millisecondi (`SyncNotifier.tokenExpiryMillis`) e lo salva nelle preferenze; serve solo a evitare un upload grosso con un token scaduto (§4.6).
- **Gestione Token**: access token e refresh token sono memorizzati in modo cifrato via `SecureStorageService` (`flutter_secure_storage`). L'access token è inviato come `Authorization: Bearer <token>`; su `401` il client chiama `POST /api/v1/auth/refresh` una sola volta per sessione, salva prima il nuovo refresh token e poi il nuovo access token, e riprova la richiesta. Un refresh rifiutato chiude la sessione; un errore di rete/5xx non cancella le credenziali.

### 4.1.1 Refresh: `POST /api/v1/auth/refresh`
Pubblico. Body `{ "refresh_token": "..." }`; risposta 200 con lo stesso formato del login (nuovo access token + nuovo refresh token). Ogni token è monouso: il riuso di uno già ruotato revoca l'intera famiglia. Errori: `401` `invalid_grant` (mancante, sconosciuto, scaduto o già usato) e `403` `account_blocked`.

### 4.1.2 Logout: `POST /api/v1/auth/logout` e `POST /api/v1/auth/logout-all`
`logout` è pubblico e accetta un Bearer opzionale e un body opzionale `{ "refresh_token": "..." }`: revoca la famiglia del refresh token e, se presente, il `jti` dell'access token. Funziona anche con l'access token scaduto. `logout-all` richiede un access token valido (o un refresh riuscito) e revoca tutte le famiglie refresh dell'utente più tutti i JWT emessi fino a quel momento.

---

### 4.2 Sincronizzazione: `POST /api/v1/sync`
*(Richiede `Authorization: Bearer <token>`)*

L'unico endpoint di sincronizzazione: **delta sync** basato su ID. Il client invia le cartelle e le note **sporche** (`dirty = 1`) e riceve tutto ciò che è cambiato sul server dal cursore indicato.

**Request** (`Content-Type: application/json; charset=utf-8`; header opzionale `X-Scripta-Client: scripta/<versione>`):
```json
{
  "last_synced_at": 1756900000000,
  "folders": [
    { "id": "f-1", "name": "Lavoro", "parent_id": null, "updated_at": 1756900000000, "deleted_at": null }
  ],
  "notes": [
    {
      "id": "n-1", "title": "Riunione", "content": "# Riunione\n\n...",
      "folder_id": "f-1", "is_favorite": false, "is_pinned": false, "order_index": 0,
      "created_at": 1756800000000, "updated_at": 1756900000000, "deleted_at": null
    }
  ]
}
```
- `last_synced_at`: il cursore locale (`sync_meta.last_synced_at`); `0` alla prima sync.
- `created_at` è **obbligatorio** per le note: un valore assente o `<= 0` fa fallire l'intero batch con `422` e `reason=invalid_created_at`. L'app `v1.0.8` lo invia sempre.
- Le cartelle sono inviate **con i genitori prima dei figli** (`sortFoldersParentsFirst`). Il server accetta comunque anche l'ordine inverso, se il genitore è nello stesso batch.

**Response 200**:
```json
{
  "server_time": 1756900001234,
  "full_resync": false,
  "folders": [ { "id": "f-1", "name": "Lavoro", "parent_id": null, "updated_at": 1756900000000, "deleted_at": null } ],
  "notes": [ { "id": "n-1", "title": "Riunione", "content": "...", "folder_id": "f-1",
               "is_favorite": false, "is_pinned": false, "order_index": 0,
               "updated_at": 1756900000000, "deleted_at": null } ],
  "caps": { "proto": 2 }
}
```
- `server_time`: il **nuovo cursore**. Il client lo salva **solo dopo** aver applicato la risposta; su qualunque errore il cursore resta invariato.
- La risposta comprende l'**eco** di ciò che il client ha appena inviato e, se il push ha perso il confronto LWW, la versione vincente del server. Per questo si applica con la regola LWW locale (§5).
- `full_resync`: il cursore era più vecchio della retention dei tombstone (30 giorni), negativo o nel futuro. La risposta è lo stato **completo** (solo righe attive): il client elimina le righe locali **pulite** che non compaiono.
- `caps` (opzionale, additivo): capability del server. Chiave assente = «non supportato»; chiave sconosciuta = ignorata; risposta senza `caps` (server 2.1.0 e precedenti) = nessuna funzione opzionale, comportamento invariato. Il client ricorda le capability **per URL** dall'ultima risposta 200 (`SyncNotifier.serverCaps`) e non le usa prima della prima risposta. Oggi `caps` è **informativo**: nessuna funzione del client è ancora attivata o disattivata in base ad esso; serve a negoziare estensioni future senza rompere i server precedenti.
- **Non esistono** `accepted`, `server_wins`, `relative_path` né `deleted` (contratto precedente).

**Errori**

| Codice | Significato | Cosa fa il client |
|---|---|---|
| `401` | access token scaduto, mancante o revocato | un tentativo di refresh; se anche il refresh è rifiutato, `isAuthenticated = false`, credenziali cancellate, messaggio «Sessione scaduta»; i dati locali restano |
| `413` | corpo troppo grande | errore mostrato; nessuna modifica persa (restano sporche) |
| `422` | uno o più elementi rifiutati (`rejected: [{kind, id, reason}]`); **il server ha annullato l'intero batch** e non restituisce un cursore | ripara le righe rifiutate (§5) e riprova una volta |
| `503` | database occupato; header `Retry-After` | riprova con attesa (§4.6) |
| altri | errore generico `{"error": "..."}` | mostrato, cursore invariato |

Motivi di rifiuto (`reason`): `invalid_id`, `invalid_parent_id`, `invalid_folder_id`.

La sync è **idempotente**: rinviare lo stesso batch (per esempio dopo una rete caduta) dà lo stesso stato finale.

---

### 4.3 Download di una nota: `GET /api/v1/notes/download`
*(Richiede `Authorization: Bearer <token>`)*

Scarica il Markdown di **una nota**, per **ID**: `GET /api/v1/notes/download?id=<id della nota>`. Risposta 200: corpo = contenuto UTF-8, `Content-Type: text/markdown; charset=utf-8`, `Content-Disposition: attachment; filename="<titolo>.md"`. Errori: `400` (id mancante), `401`, `404` (inesistente, di un altro utente o cancellata). Non fa parte del protocollo di sync: l'app non lo usa per sincronizzare.

---

### 4.4 Sincronizzazione Impostazioni Utente: `GET` e `PUT /api/v1/user/settings`
*(Richiede header `Authorization: Bearer <token>`)*

Sincronizza l'esperienza visiva e tipografica dell'utente tra dispositivi multipli.

#### GET `/api/v1/user/settings`
Restituisce le preferenze memorizzate nel database del server (o valori di default se mai impostate):
```json
{
  "theme": "dark",
  "color_scheme": "dark_teal",
  "language": "it",
  "font_family": "Inter",
  "font_size": 16,
  "line_spacing": 1.6,
  "layout": "split",
  "updated_at": 1756950000000
}
```

#### PUT `/api/v1/user/settings`
Invia l'aggiornamento completo delle preferenze non appena l'utente modifica tema, font o lingua nell'app:
```json
{
  "theme": "dark",
  "color_scheme": "oled",
  "language": "it",
  "font_family": "JetBrains Mono",
  "font_size": 16,
  "line_spacing": 1.6,
  "layout": "split"
}
```

- `layout`: campo **riservato**. Il client supporta solo la modalità a due pannelli e invia sempre `"split"`; il server deve conservarlo senza interpretarlo. Un valore diverso ricevuto dal server non cambia la UI.
- `font_family`: il client accetta solo `"Inter"` e `"JetBrains Mono"`; altri valori vengono normalizzati a `"Inter"`.
- `font_size`, `line_spacing`: valori numerici validati e clampati dal client prima dell'applicazione.
- L'ambito del font (interfaccia intera o solo editor) è una preferenza locale del dispositivo e non fa parte di questo payload.

---

### 4.5 Esportazione Dati e Backup: Architettura Client-Side (`ExportService`)

A tutela della privacy (zero-knowledge) e per garantire la massima efficienza senza gravare con elaborazioni compresse sul backend Go, l'esportazione dell'archivio documentale è gestita interamente lato client tramite `ExportService` (`lib/core/services/export_service.dart`):

1. **Esportazione Archivio Completo (ZIP)**:
   - Viene generato un file ZIP compresso (`archive`) preservando l'intera gerarchia delle cartelle, i file Markdown `.md` e il file `settings.json` con le preferenze correnti.
   - Supporto nativo al selettore di sistema (Android SAF, iOS Files, Linux/macOS/Windows file picker).
2. **Esportazione Singola Nota**:
   - Formato grezzo Markdown (`.md`)
   - Formato documento PDF con impaginazione tipografica curata (`pdf` package)
   - Formato HTML renderizzato con foglio di stile coerente con il tema attivo.

---

### 4.6 Gestione degli Errori HTTP, Tempi e Ritentativi

- **Decodifica UTF-8**: il corpo delle risposte si legge **sempre come UTF-8** (`SyncApiService.bodyText`), anche se il `Content-Type` non dichiara un charset: il pacchetto `http`, senza charset, userebbe Latin-1 e trasformerebbe accenti ed emoji in caratteri sbagliati. Il server dichiara comunque `charset=utf-8`.
- **Timeout della sync «a progressi»**: non c'è più un tetto fisso sull'intera richiesta (un upload lento ma vivo veniva interrotto e ripartiva da zero). Il corpo parte a blocchi e la risposta si legge a flusso; la sync si ferma solo se per troppo tempo non si muove nessun byte: 30 s per la connessione, 20 s di silenzio durante invio o ricezione, 30 s di attesa della risposta dopo l'invio completo, e un tetto assoluto di 5 minuti. Login e impostazioni: 10 s; controllo di salute: 4 s.
- **Ritentativi con backoff**: per gli errori transitori (rete, timeout, `503`) fino a 3 tentativi, con attesa esponenziale (1,5 s, poi 3 s) e jitter ±25%. Se il server indica `Retry-After` non si riprova prima. La somma delle attese non supera 20 s: se la prossima non ci sta, si rinuncia subito (ripartiranno i trigger o il controllo periodico di connettività).
- **`401`**: vedi §4.2. Anche sulle impostazioni (`/user/settings`) l'utente vede il messaggio «Sessione scaduta: effettua nuovamente l'accesso». **Prima di un upload grosso** (oltre 256 KiB di testo) con un token che l'orologio locale dà per scaduto, il client verifica il token con una richiesta leggera: se è davvero scaduto non spedisce megabyte per ricevere un 401; se il server risponde bene, l'orologio del dispositivo è sfasato e l'upload prosegue.
- **Mancanza di connettività o errore del server**: `isOnline = false`, sessione mantenuta, modifiche e tombstone locali preservati.

---

## 5. Algoritmo di Risoluzione dei Conflitti Last-Write-Wins (LWW)

La convergenza è disciplinata da un **Last-Write-Wins riga per riga** sui timestamp `updated_at` (millisecondi Unix). Ogni cartella e ogni nota è un'unità indipendente, identificata dal suo `id`.

```
Client invia una riga (id, updated_at, ...)
              │
              ▼
   Il server ha già questo id?
        │NO                │SI
        ▼                  ▼
   scrive la riga   updated_at_client >= updated_at_server ?
                        │SI                │NO
                        ▼                  ▼
                  il client vince    il server vince: non cambia nulla,
                  (aggiorna riga)    la sua versione torna nella risposta
```

### Regole formali
1. **Server, push**: l'upsert ha effetto solo se `updated_at` del client è **maggiore o uguale** a quello memorizzato. Un `updated_at` oltre «adesso + 5 minuti» (orologio del client avanti) viene riportato all'ora del server, così non può vincere per sempre.
2. **Server, pull**: restituisce le righe con `synced_at` in `(last_synced_at, server_time]`, calcolate **dopo** il push. `synced_at` è uno stamp **del server**, monotono (e persistente: non scende dopo un riavvio del server con l'orologio indietro), distinto da `updated_at`. Il cursore `server_time` è quindi sicuro anche con orologi dei client sbagliati.
3. **Cancellazioni**: un tombstone è una riga con `deleted_at`. Cancellare una cartella cancella a cascata sottocartelle e note attive. I tombstone si conservano 30 giorni.
4. **Client, applicazione della risposta** (`applyRemoteLWWBatch`): la copia remota vince se la riga locale non esiste, è **pulita** (`dirty = 0`) o è meno recente; una modifica locale sporca e più recente **non** viene mai sovrascritta (partirà al giro successivo). `is_expanded` è solo locale e si preserva sempre.
5. **Rifiuti (`422`)**: il server annulla l'intero batch. Il client ripara ciò che è stato rifiutato: una nota con `folder_id` sconosciuto va fuori da ogni cartella, una cartella con `parent_id` sconosciuto diventa radice; le righe riparate risultano modificate (`dirty`, `updated_at` nuovo) e vengono rinviate. Nessun contenuto va perso. Un rifiuto `invalid_created_at` non è riparabile dal client: indica un payload non conforme al contratto corrente.
6. **Ordine**: il server richiede che il genitore di una cartella esista quando la scrive. Il client invia i genitori prima dei figli; il server accetta anche l'ordine inverso se il genitore è nel batch; un genitore inesistente o un ciclo fra cartelle nuove è rifiutato.

### 5.1 Strategia di Debouncing & Concorrenza Client/Server

1. **Debouncing scrittura note (500 ms)**: durante la digitazione la persistenza locale è ritardata di 500 ms.
2. **Debouncing cambio nota (600 ms)**: cambi rapidi di nota o di cartella consolidano le richieste di sync in una sola chiamata.
3. **Timer di inattività configurabile (10 s – 300 s)**: la sync in background parte dopo un periodo di inattività.
4. **Flush preventivo (`flushPendingSaves`)**: prima di ogni `triggerSync()` il client scrive le modifiche ancora in debounce, così il batch contiene l'ultima battitura.
5. **Un solo round alla volta**: il controllo di `isSyncing` è atomico; un trigger arrivato durante una sync non va perso (giro di recupero dopo un giro riuscito, in numero limitato).
6. **Server**: l'intero batch è elaborato in **una transazione SQLite**, serializzata da un lock sullo stamp: due dispositivi che sincronizzano insieme non si intrecciano.

---

## 6. Sicurezza e Storage Cifrato

1. **Storage Cifrato Locale**:
   - Il client memorizza l'access token JWT, il refresh token opaco, il nome utente e l'URL del server tramite `SecureStorageService`.
   - Piattaforme supportate:
     - **Android**: Android Keystore + `EncryptedSharedPreferences` (AES-256 GCM).
     - **iOS / macOS**: Apple Keychain con accessibilità `first_unlock`.
     - **Linux**: Secret Service API (Freedesktop Secret Service / GNOME Keyring / KWallet).
2. **Nessun salvataggio in chiaro delle password**:
   - L'applicazione non memorizza mai la password dell'utente sul disco locale dopo il login completato.
   - Solo l'access token JWT e il refresh token opaco risiedono nello storage sicuro; entrambi sono revocabili lato server.
   - Sul server, le password vengono cifrate immediatamente con **bcrypt** e non vengono mai scritte nei log né mostrate nella dashboard amministrativa.

---

## 7. Procedura di Collaudo Locale & Disaccoppiamento di Produzione

1. **Collaudo Locale con `notes-server/`**:
   ```bash
   cd notes-server
   go test -v ./...
   go run main.go
   ```
   Il server si avvierà su `http://localhost:8080`, con dashboard amministrativa disponibile su `http://localhost:8080/admin` (credenziali default: `admin`/`admin`).
2. **Build di Produzione**:
   La cartella `notes-server/` è rigorosamente esclusa dalla compilazione e dal packaging degli asset dell'applicazione Flutter (inclusa nei file `.dockerignore` e `.gitignore` dei target client). Per la produzione, il backend viene distribuito indipendentemente mediante il container Dockerfile multi-stage (`notes-server/Dockerfile`).
