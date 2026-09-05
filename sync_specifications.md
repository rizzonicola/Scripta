# Specifiche Tecniche di Sincronizzazione: Architettura Local-First, Protocollo REST & LWW

**Progetto**: Scripta  
**Ruolo**: Lead Flutter Architect  
**Versione Specifiche**: 1.2.0 (Fase 3: Audit & Consolidamento E2E)  
**Backend di Riferimento**: `notes-server` (Go 1.22+, SQLite WAL & libSQL/Turso, Scritture Atomiche POSIX, Transazioni Batch Esplicite, Lock per-path)

> [!IMPORTANT]
> **Organizzazione Repository & Backend Incluso per Sviluppo**:  
> La cartella `notes-server/` è inclusa nella radice di questo repository per consentire l'avvio immediato dell'ambiente di test locale e del collaudo End-to-End durante lo sviluppo. Nella build di release finale dell'applicazione mobile/desktop, la cartella `notes-server/` viene completamente scollegata dal codice sorgente dell'app e distribuita come servizio autonomo (via Docker / cloud hosting).

---

## 1. Visione d'Insieme & Filosofia Local-First

L'applicazione **Scripta** adotta il paradigma **Local-First**, progettato per offrire un'esperienza utente istantanea, resiliente e priva di interruzioni, a prescindere dalla disponibilità della connessione di rete.

### Principi Cardine:
1. **La copia locale è la sorgente primaria di verità (Local Primary)**: Tutte le operazioni di creazione, lettura, modifica ed eliminazione (CRUD) avvengono istantaneamente sul database e storage locale. L'interfaccia grafica non attende mai una risposta di rete per completare un'azione dell'utente (zero latenza percepita).
2. **Disponibilità Offline Incondizionata**: L'utente può aprire l'applicazione, consultare l'intero archivio note, organizzare le cartelle e scrivere documenti anche in assenza totale di connettività o in modalità aereo.
3. **Sincronizzazione Asincrona Protetta da Debouncing**: La riconciliazione con il backend Go (`notes-server`) avviene in modo asincrono attraverso trigger configurabili e controllati da timer di debouncing (500ms salvataggio note, 600ms cambio nota, inattività configurabile), garantendo la convergenza dei dati (consistenza eventuale) senza saturare la rete né bloccare il thread principale della UI.
4. **Idempotenza & Tolleranza ai Guasti**: Ogni scambio di sincronizzazione è idempotente: una transazione interrotta a metà a causa di una disconnessione improvvisa può essere ripetuta senza causare duplicazioni o corruzione dei dati.

---

## 2. Gestione del Database Locale (Architettura Drift / SQLite)

### 2.1 Struttura e Modello Relazionale
Nel client Flutter, la persistenza strutturata ad alte prestazioni è affidata a **SQLite** in modalità **WAL (Write-Ahead Logging)** attraverso il toolkit tipizzato **Drift**. 

Il database locale comprende quattro entità fondamentali:

```
┌─────────────────┐       ┌─────────────────┐
│     FOLDERS     │◄──────┤      NOTES      │
├─────────────────┤1     *├─────────────────┤
│ id (UUID PK)    │       │ id (UUID PK)    │
│ name (TEXT)     │       │ folder_id (FK)  │
│ parent_id (FK)  │       │ title (TEXT)    │
│ is_expanded     │       │ content (TEXT)  │
└─────────────────┘       │ relative_path   │
                          │ created_at (ms) │
                          │ updated_at (ms) │
                          │ is_favorite     │
                          │ is_pinned       │
                          │ order_index     │
                          └─────────────────┘

┌─────────────────┐       ┌─────────────────┐
│ SYNC_TOMBSTONES │       │  SYNC_METADATA  │
├─────────────────┤       ├─────────────────┤
│ relative_path PK│       │ key (TEXT PK)   │
│ deleted_at (ms) │       │ value (TEXT)    │
└─────────────────┘       └─────────────────┘
```

### 2.2 Schema DDL di Riferimento (Drift)

```sql
-- Tabella Cartelle (Gerarchica con supporto nesting ricorsivo)
CREATE TABLE folders (
    id TEXT NOT NULL PRIMARY KEY,
    name TEXT NOT NULL,
    parent_id TEXT REFERENCES folders(id) ON DELETE CASCADE,
    is_expanded INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL
);

-- Tabella Note
CREATE TABLE notes (
    id TEXT NOT NULL PRIMARY KEY,
    folder_id TEXT REFERENCES folders(id) ON DELETE SET NULL,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    relative_path TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    is_favorite INTEGER NOT NULL DEFAULT 0,
    is_pinned INTEGER NOT NULL DEFAULT 0,
    order_index INTEGER NOT NULL DEFAULT 0
);

-- Indici per prestazioni di ricerca e ordinamento
CREATE INDEX idx_notes_folder_id ON notes(folder_id);
CREATE INDEX idx_notes_updated_at ON notes(updated_at DESC);
CREATE INDEX idx_notes_relative_path ON notes(relative_path);

-- Tabella Tombstones (Registrazione delle note eliminate per la propagazione remota)
CREATE TABLE sync_tombstones (
    relative_path TEXT NOT NULL PRIMARY KEY,
    deleted_at INTEGER NOT NULL
);

-- Tabella Metadati di Sincronizzazione (Timestamp, stato auth, cursori)
CREATE TABLE sync_metadata (
    key TEXT NOT NULL PRIMARY KEY,
    value TEXT NOT NULL
);
```

### 2.3 Ciclo di Vita delle Eliminazioni (Tombstoning)
In un'architettura distribuita Local-First, eliminare fisicamente un record dal database locale impedirebbe al client di comunicare al server l'avvenuta cancellazione. Pertanto:
1. Quando l'utente elimina una nota, il record viene rimosso dalla tabella `notes` (o marcato come `deleted = 1`).
2. Viene inserito un record corrispondente nella tabella `sync_tombstones` con il `relative_path` e il timestamp di eliminazione.
3. Durante il ciclo successivo di sincronizzazione, i tombstones vengono inclusi nel payload con `deleted: true`.
4. Solo quando il server risponde includendo quel `relative_path` nella lista `accepted`, il tombstone viene definitivamente rimosso dalla tabella locale.

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
- **Range consentito**: da 10 a 120 secondi (minimo di sicurezza a 10s per evitare hammering del server).
- **Default di fabbrica**: 30 secondi.
- **Funzionamento**: finché l'utente continua a digitare, il timer scorre e si riavvia. Trascorsi N secondi dall'ultima pressione tasto, il sync parte in modalità silente in background.

---

## 4. Contratti API REST (v1) & Flussi di Comunicazione

Tutti gli endpoint REST sono esposti dal server Go sulla radice `/api/v1`. I dati sono scambiati in formato JSON con encoding UTF-8.

### 4.1 Autenticazione: `POST /api/v1/auth/login`
Autentica l'utente con credenziali e rilascia un JSON Web Token (JWT con firma HMAC-SHA256 e scadenza a 7 giorni).

- **Headers**: `Content-Type: application/json`
- **Request Body**:
```json
{
  "username": "mario.rossi",
  "password": "password-in-chiaro"
}
```
- **Response (200 OK)**:
```json
{
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "expires_at": 1767225600,
  "user_id": "b3f1c24e-89a1-4321-bcde-1234567890ab",
  "username": "mario.rossi"
}
```
- **Gestione Token**: Il token JWT viene memorizzato in modo cifrato via `SecureStorageService` (`flutter_secure_storage`) e aggiunto come header `Authorization: Bearer <token>` in tutte le richieste successive.

---

### 4.2 Sincronizzazione Note: `POST /api/v1/sync`
*(Richiede header `Authorization: Bearer <token>`)*

Invia un batch di note create, modificate o eliminate localmente e riceve l'esito della sincronizzazione unitamente a eventuali aggiornamenti presenti sul server.

- **Request Body**:
```json
{
  "notes": [
    {
      "relative_path": "lavoro/riunione-2026-09-01.md",
      "content": "# Verbale Riunione\n\nPunti discussi...",
      "updated_at": 1756900000000,
      "deleted": false
    },
    {
      "relative_path": "personale/vecchia-idea.md",
      "content": "",
      "updated_at": 1756910000000,
      "deleted": true
    }
  ]
}
```

- **Response (200 OK)**:
```json
{
  "accepted": [
    {
      "relative_path": "personale/vecchia-idea.md",
      "updated_at": 1756910000000,
      "deleted": true
    }
  ],
  "server_wins": [
    {
      "relative_path": "lavoro/riunione-2026-09-01.md",
      "content": "# Verbale Riunione\n\nModifica più recente effettuata sul server",
      "updated_at": 1756950000000,
      "deleted": false
    }
  ]
}
```

---

### 4.3 Download / Lettura Note Remote: `GET /api/v1/notes/download`
*(Richiede header `Authorization: Bearer <token>`)*

Scarica il contenuto grezzo di un singolo file Markdown memorizzato sul filesystem del server.

- **Parametri Query**: `path=lavoro/riunione-2026-09-01.md`
- **Response (200 OK)**:
  - Header: `Content-Type: text/markdown; charset=utf-8`
  - Body: contenuto UTF-8 raw del file.

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

### 4.6 Gestione degli Errori HTTP & Ciclo di Vita delle Sessioni

Il client implementa una gestione degli errori HTTP a prova di guasto:
- **`401 Unauthorized` (Token Scaduto o Non Valido)**:
  - Quando `/api/v1/sync` o `/api/v1/user/settings` restituisce `401`, il client marca immediatamente `isAuthenticated = false`, rimuove il token scaduto dal Secure Storage e notifica l'utente nella barra di stato (`Sessione scaduta: effettua nuovamente l'accesso`).
  - L'interfaccia non si blocca e l'app continua a operare normalmente in modalità offline locale.
- **`400 Bad Request`**:
  - Il payload JSON di errore restituito dal server (`{"error":"..."}`) viene estratto e mostrato nei log diagnostici di sincronizzazione senza provocare eccezioni non gestite.
- **`500 Internal Server Error` o Mancanza di Connettività**:
  - In caso di timeout (10s auth/settings, 20s sync), mancata risoluzione DNS o errore 500 del server, il client imposta `isOnline = false`, mantiene la sessione autenticata per i tentativi successivi e preserva tutte le modifiche locali e i tombstones nel database locale.

---

## 5. Algoritmo di Risoluzione dei Conflitti Last-Write-Wins (LWW)

La coerenza finale tra i nodi client e il server centrale è disciplinata da un algoritmo deterministico **Last-Write-Wins (LWW)** basato sui timestamp Unix in millisecondi (`updated_at`).

```
                    ┌─────────────────────────┐
                    │ Client invia NoteChange │
                    └────────────┬────────────┘
                                 │
                                 ▼
                     Nota esiste sul Server?
                      /                     \
                    NO                      YES
                    /                         \
                   /                 updated_at_client >=
                  /                  updated_at_server ?
                 /                          /      \
                /                         YES       NO
               ▼                           ▼         ▼
        ┌──────────────┐            ┌──────────┐  ┌─────────────────────┐
        │ CLIENT WINS  │            │  CLIENT  │  │     SERVER WINS     │
        │ Scrive file  │            │   WINS   │  │ Server restituisce  │
        │  atomico &   │            │  Aggiorna│  │ la sua versione più │
        │ entra in     │            │  file e  │  │ recente in          │
        │ "accepted"   │            │ metadati │  │ "server_wins"       │
        └──────────────┘            └──────────┘  └──────────┬──────────┘
                                                             │
                                                             ▼
                                                  ┌─────────────────────┐
                                                  │ Client aggiorna     │
                                                  │ copia locale o      │
                                                  │ crea cartella/nota  │
                                                  └─────────────────────┘
```

### Regole Formali di Convergenza:
1. **Client Wins (`updated_at_client >= updated_at_server`)**:
   - Il server accetta il file inviato dal client.
   - La scrittura su disco sul server avviene in modalità **atomica POSIX**: viene scritto prima un file temporaneo (`.tmp-*`), viene forzato il flush sul disco fisico con `fsync`, e infine viene eseguita la `os.Rename` sul percorso definitivo.
   - Se `deleted == true`, il file viene cancellato fisicamente dal server e il metadato marcato come eliminato.
   - La nota viene inclusa nella lista `accepted` della risposta.

2. **Server Wins (`updated_at_client < updated_at_server`)**:
   - La versione presente sul server è più recente di quella inviata dal client.
   - Il server respinge la modifica del client e inserisce la versione del server nella lista `server_wins` con il suo contenuto Markdown aggiornato.
   - Il client Flutter riceve l'array `server_wins` e aggiorna la copia nel database locale, allineando sia il contenuto sia il timestamp `updated_at`.
   - Se la nota appartiene a una cartella non ancora presente in locale, il client genera automaticamente la struttura delle cartelle corrispondente.

3. **Integrità dei Percorsi & Sicurezza anti-Path-Traversal**:
   - Ogni `relative_path` viene normalizzato dal server con `filepath.Clean`.
   - Viene verificato che il percorso non contenga sequenze ingannevoli come `../` o tentativi di jailbreak al di fuori della cartella protetta dell'utente (`/data/users/{user_id}/notes`).
   - Eventuali percorsi non conformi vengono scartati senza interrompere la sincronizzazione delle restanti note.

### 5.1 Strategia di Debouncing & Concorrenza Client/Server

Per evitare carichi inutili di I/O e prevenire race conditions durante l'uso intensivo dell'editor o della navigazione tra note:
1. **Debouncing Scrittura Note (500 ms)**: Durante la digitazione nei campi titolo e contenuto, l'aggiornamento della persistenza locale e il ricalcolo dei metadati è ritardato di 500ms; ogni modifica prima di questo intervallo resetta il timer.
2. **Debouncing Cambio Nota (600 ms)**: Se l'utente scorre rapidamente la lista delle note o naviga rapidamente nell'albero delle cartelle, le richieste di sync vengono ritardate di 600ms per consolidare lo stato finale ed eseguire un'unica chiamata batch.
3. **Timer di Inattività Configurabile (10s - 300s)**: Durante la scrittura continua, il sync in background si attiva solo dopo un periodo di inattività dell'utente.
4. **Flush Preventivo (`flushPendingSaves`)**: Prima di ciascuna chiamata a `triggerSync()`, il client forza il flush immediato delle modifiche in sospeso, garantendo che il payload contenga sempre l'esatto snapshot corrente.
5. **Lock per-path & Batch Tx nel Backend Go**: Sul server, `SyncHandler` avvia un'unica transazione SQLite esplicita (`BeginTx`) per l'intero lotto di note, e acquisisce un lock univoco per ciascun percorso (`Store.LockPath`) evitando conflitti in caso di chiamate concorrenti da dispositivi multipli.

---

## 6. Sicurezza e Storage Cifrato

1. **Storage Cifrato Locale**:
   - Il client memorizza il token JWT, il nome utente e l'URL del server tramite `SecureStorageService`.
   - Piattaforme supportate:
     - **Android**: Android Keystore + `EncryptedSharedPreferences` (AES-256 GCM).
     - **iOS / macOS**: Apple Keychain con accessibilità `first_unlock`.
     - **Linux**: Secret Service API (Freedesktop Secret Service / GNOME Keyring / KWallet).
2. **Nessun salvataggio in chiaro delle password**:
   - L'applicazione non memorizza mai la password dell'utente sul disco locale dopo il login completato.
   - Solo il token JWT cifrato e a tempo determinato risiede nello storage sicuro.
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
