# Scripta Web / PWA

Scripta 1.0.9 include un target Web installabile come PWA. La build è unica
per tutti i browser:

- **Chromium** (Chrome, Edge, Chromium): usa **dart2wasm + skwasm** quando
  WebAssembly GC e il contesto cross-origin isolato sono disponibili.
- **Safari, Firefox e browser senza Wasm GC**: usano il fallback
  **dart2js + CanvasKit**, incluso nella stessa build.

Il database locale è SQLite compilato in WebAssembly
(`sqflite_common_ffi_web`), persistito in **IndexedDB**. Il service worker
personalizzato (`web/scripta_sw.js`) rende l'app disponibile offline dopo il
primo caricamento completo.

---

## 1. Build locale

Prerequisiti:

- Flutter **3.44.4** (Dart 3.12.2). La versione è la stessa usata dal target
  Android; non usare il Flutter di sistema se è più vecchio.
- `unzip` disponibile nel `PATH` (Flutter lo usa per il Web SDK).
- Connessione a Internet al primo build (download del Web SDK e degli asset
  SQLite già presenti nel repository).

Comandi:

```bash
flutter pub get --enforce-lockfile
dart run tool/web/build_web.dart \
  --flutter "$(command -v flutter)"
```

Output: `build/web`.

Lo script:

1. esegue `flutter build web --release --wasm --no-web-resources-cdn
   --pwa-strategy=none --base-href /`;
2. rimuove il `flutter_service_worker.js` vuoto generato da Flutter;
3. copia `web/_headers` nell'output (Cloudflare Pages non lo tratta come
   asset dell'app);
4. calcola l'elenco esatto degli asset e inietta id build + precache in
   `build/web/scripta_sw.js`, escludendo mappe, simboli e file di servizio.

Per provare la PWA in locale serve un server HTTP con HTTPS o `localhost`.
`flutter run -d chrome` è utile per lo sviluppo, ma **non** inietta il
precache: per verificare l'offline usare `build/web` servito da un server
statico (es. `dart pub global activate dhttpd` e `dhttpd --path build/web`).

---

## 2. Installazione

### Chrome / Edge (desktop e Android)

1. Aprire l'app su HTTPS.
2. Usare l'icona di installazione nella barra degli indirizzi (o menu →
   “Installa app”).
3. La PWA si apre in una finestra standalone e compare nel launcher.

### Safari (macOS)

1. Aprire l'app in Safari.
2. Menu **File → Aggiungi al Dock** (macOS Sonoma o successivo).
3. La PWA usa il motore WebKit e il fallback CanvasKit.

### iPhone / iPad (Home Screen)

1. Aprire l'app in **Safari** (non in un browser alternativo).
2. Toccare **Condividi → Aggiungi alla schermata Home**.
3. Avviare dall'icona: la modalità è standalone e il database è separato da
   quello della scheda Safari.

### Firefox

Firefox desktop non offre più l'installazione PWA completa; l'app resta
utilizzabile come sito web con offline tramite service worker. Su Firefox
Android, dove il supporto è disponibile, usare il menu → “Installa” / “Aggiungi
alla schermata Home”. Il comportamento dipende dalla versione e dalle flag del
browser: non è garantito come su Chromium.

---

## 3. Offline e aggiornamenti

### Primo caricamento

Il service worker si registra dopo il `load` della pagina. Al termine
dell'installazione ha in cache:

- `index.html`, bootstrap, JS/Wasm, CanvasKit/skwasm, font, icone;
- `sqlite3.wasm` e `sqflite_sw.js` (database Web);
- tutti gli altri asset della build, tranne mappe, simboli e il service worker
  stesso.

Da quel momento l'app si avvia anche senza rete.

### Richieste

- **Navigazione**: network-first. Se la rete risponde con una pagina valida,
  viene usata; se la rete manca o risponde con errore, viene servita la
  `index.html` in cache.
- **Asset same-origin**: cache-first.
- **Richieste cross-origin e non-GET**: mai intercettate. Le API di sync, i
  download e le richieste POST restano gestiti dal browser.
- Le cache create dal service worker hanno tutte il prefisso `scripta-`; le
  altre cache dell'origine non vengono toccate.

### Aggiornamento automatico e invisibile

Non esiste alcun pulsante, banner o widget di aggiornamento.

1. Al deploy di una nuova build cambia `scripta_sw.js` (id build e lista
   precache).
2. Il browser scarica il nuovo service worker in background e lo installa.
3. Il nuovo service worker **resta in attesa**: non viene mai chiamato
   `skipWaiting()`.
4. Si attiva solo quando tutte le finestre/tab della versione precedente sono
   state chiuse.
5. Alla riapertura l'app usa la nuova versione; all'attivazione le cache
   `scripta-*` vecchie vengono eliminate.

La pagina richiede un controllo aggiornamenti al `load` e, quando torna
visibile, al massimo ogni 15 minuti. Non viene mostrata alcuna UI.

Per forzare subito un aggiornamento in fase di test: chiudere tutte le tab
dell'app e riaprirla. Non usare “Cancella dati sito” se non si vuole perdere
il database locale.

---

## 4. Dati locali e rischi

### Dove vivono i dati

- **Note/cartelle**: immagine SQLite in **IndexedDB**, nome logico
  `scripta.db`, gestita da `sqflite_common_ffi_web`.
- **Preferenze**: `localStorage` / `shared_preferences`.
- **Sessione server**: `flutter_secure_storage_web` (WebCrypto; richiede
  HTTPS). La chiave è in `localStorage`, i dati cifrati nello storage del
  browser.
- **Service worker**: solo Cache Storage con prefisso `scripta-`. Non legge né
  scrive mai IndexedDB, `localStorage` o SharedPreferences.

I dati sono **per origine**. `https://xxx.pages.dev`, le preview
`https://<hash>.xxx.pages.dev` e il dominio finale sono archivi separati: non
aspettarsi di vedere le stesse note passando dall'uno all'altro.

### Rischio di rimozione dei dati (iOS/Safari)

Safari può eliminare i dati dei siti dopo circa **7 giorni** senza
interazione. Una PWA installata dalla Home Screen è generalmente esente, ma
non è una garanzia: Apple può applicare politiche diverse in base a spazio,
versione di iOS e modalità di installazione. Su iOS:

- installare dalla Home Screen e usare l'app con regolarità;
- esportare un backup ZIP periodico (Impostazioni → Esporta);
- non fare affidamento solo sullo storage del browser per dati non
  sincronizzati.

Su desktop il rischio è minore, ma “Cancella dati sito”, modalità in incognito,
pulizie automatiche e politiche aziendali possono comunque rimuovere IndexedDB.
Il backup ZIP e la sync col server restano le uniche copie indipendenti.

---

## 5. Cloudflare Pages

L'app è pensata per il deploy tramite **Git integration** di Cloudflare Pages:
Cloudflare costruisce a ogni push, senza workflow GitHub aggiuntivi e senza
segreti nel repository.

### Configurazione (una tantum, manuale)

1. Accedere a Cloudflare Dashboard → **Workers & Pages → Create → Pages →
   Connect to Git**.
2. Selezionare il repository Scripta e il branch di produzione (es. `main`).
3. Impostazioni di build:
   - **Framework preset**: `None`
   - **Build command**: `bash tool/web/cloudflare_build.sh`
   - **Build output directory**: `build/web`
   - **Root directory**: `/` (root del repository)
4. Variabili d'ambiente: nessuna obbligatoria. `FLUTTER_BIN` è opzionale e
   non è un segreto; `SCRIPTA_FLUTTER_SDK` può puntare a una cache SDK.
   `CF_PAGES_COMMIT_SHA` viene impostata da Cloudflare e usata nell'id build.
5. Deploy. Il primo build scarica Flutter 3.44.4 se non è già presente nel
   build image, esegue `flutter pub get --enforce-lockfile`, `flutter precache
   --web` e `dart run tool/web/build_web.dart`. Il build image deve avere
   `unzip` (usato da Flutter per il Web SDK), oltre a `curl`, `tar` e `xz`;
   lo script verifica `unzip` e termina con un errore esplicito se manca.
6. Aggiungere il dominio personalizzato da **Custom domains**. Ricordare che
   il dominio finale è una nuova origine: le note del `pages.dev` non vengono
   migrate automaticamente. Esportare/importare un backup ZIP oppure usare la
   sync.

Non vengono usati segreti, token o credenziali nel repository. Il deploy è
gestito interamente da Cloudflare Pages tramite Git.

### Header

`web/_headers` viene copiato in `build/web/_headers`. Contiene:

- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Permissions-Policy: camera=(), microphone=(), geolocation=()`
- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: credentialless`
- `Cache-Control: no-cache` per entry point, manifest e service worker
- cache HTTP di un giorno per asset statici

`COOP` + `COEP: credentialless` abilitano `crossOriginIsolated` su Chromium,
condizione necessaria per skwasm. `credentialless` è preferito a
`require-corp` perché non blocca immagini remote eventualmente incluse nelle
note. Safari/Firefox che non supportano l'isolamento usano CanvasKit.

Se si modifica la policy, verificare sempre:

```bash
curl -I https://<dominio>/
curl -I https://<dominio>/scripta_sw.js
```

### Cache e rollback

- `scripta_sw.js`, `index.html`, `flutter_bootstrap.js`, `main.dart.*`,
  `manifest.json` e `version.json` sono serviti con `no-cache`.
- Gli asset statici hanno cache HTTP breve; l'offline è garantito dal precache.
- Per un rollback: fare rollback del deploy da Cloudflare Pages o pushare il
  commit precedente. Il service worker vecchio resta valido finché non si
  chiudono tutte le tab; poi si attiva la versione del deploy corrente.

---

## 6. Compatibilità dipendenze

| Componente | Versione / note |
|---|---|
| Flutter | 3.44.4 (Dart 3.12.2) |
| `sqflite` / `sqflite_common_ffi` | restano per Android/iOS/desktop; non usati sul Web |
| `sqflite_common_ffi_web` | 1.2.0, sperimentale; un solo `openDatabase` per database |
| `sqlite3` (Dart) | 3.5.2 nel lock dell'app; il worker Web è compilato separatamente con `sqlite3` 3.8.0 |
| `sqlite3.wasm` | release 3.8.0, allineata al worker (`web/sqlite3.wasm`) |
| `sqflite_sw.js` | generato da `sqflite_common_ffi_web:setup` con `sqlite3` 3.8.0 |
| `file_picker` | 13.3.0; su Web `saveFile` avvia il download e restituisce `null`; `getDirectoryPath` non è supportato |
| `flutter_secure_storage_web` | richiede HTTPS e WebCrypto; nessun fallback in chiaro sul Web |
| `shared_preferences` | `localStorage`; dati per origine |
| Renderer | skwasm (Wasm) su Chromium isolato; CanvasKit (dart2js) altrove |

Nota sul database Web: il worker è un artefatto JS autonomo e include le
proprie binding `sqlite3` (3.8.0). Il pacchetto `sqlite3` 3.5.2 presente nel
lock dell'app viene compilato nel bundle principale ma non esegue SQLite sul
thread principale quando è attivo il worker. Se in futuro si aggiorna
`sqflite_common_ffi_web`, rigenerare **insieme** `web/sqflite_sw.js` e
`web/sqlite3.wasm` e verificare il runtime in un browser reale.

---

## 7. Limiti noti

- **Import da cartella**: non disponibile sul Web (`getDirectoryPath` non
  esiste); la voce è nascosta. L'import da ZIP resta disponibile.
- **Export**: il download è gestito dal browser; non esiste il fallback nella
  directory privata dell'app come su mobile.
- **Fullscreen F11 / title bar nativa**: non applicabili sul Web; i servizi
  escono senza chiamare i canali nativi.
- **Wasm**: richiede WebAssembly GC e isolamento cross-origin. Senza queste
  condizioni si usa automaticamente CanvasKit.
- **iOS**: possibile rimozione dati dopo inattività (vedi §4); nessuna
  garanzia di persistenza infinita.
- **Storage**: IndexedDB può essere limitato o cancellato dall'utente, da
  politiche aziendali o dalla modalità incognito.
- **Sync**: il server configurato deve usare HTTPS e consentire CORS per
  l'origine della PWA; non è gestito dal service worker. Un server HTTP viene
  bloccato dal browser per mixed content.
- **Service worker**: non intercetta richieste cross-origin o non-GET; le API
  di sync non sono disponibili offline.
- **Prime installazioni**: il primo caricamento deve andare a buon fine e
  completare il precache; se una risorsa manca, l'installazione del service
  worker fallisce e verrà ritentata.
- **Aggiornamenti**: una tab rimasta aperta può trattenere la versione
  precedente a tempo indeterminato; è il comportamento richiesto (nessun
  `skipWaiting`).

---

## 8. Verifica rapida

```bash
# Analisi e test esistenti
flutter analyze
flutter test

# Build web completa (Wasm + fallback JS)
dart run tool/web/build_web.dart

# Controlli sul service worker generato
rg -n "skipWaiting" build/web/scripta_sw.js   # deve essere vuoto
rg -n "scripta-" build/web/scripta_sw.js      # prefisso cache
```

Checklist manuale:

1. Aprire `build/web` su `localhost`/HTTPS e verificare il primo avvio.
2. DevTools → Application → Service Workers: `scripta_sw.js` attivo.
3. Application → Cache Storage: cache `scripta-*` con gli asset.
4. Impostare offline e ricaricare: l'app si apre e le note restano.
5. Creare una nota, ricaricare, verificare la persistenza (IndexedDB).
6. Installare la PWA da Chrome/Edge e da iPhone Home Screen.
7. Deployare una modifica, chiudere tutte le tab, riaprire: nuova versione
   attiva senza alcuna UI.

---

## 9. File

- `web/index.html` — entry point, manifest, registrazione SW.
- `web/manifest.json` — manifest PWA (icone, colori, standalone).
- `web/scripta_sw.js` — service worker personalizzato (template con marker).
- `web/_headers` — header Cloudflare Pages.
- `web/icons/` — icone 180/192/512 e maskable.
- `web/sqlite3.wasm`, `web/sqflite_sw.js` — runtime SQLite Web.
- `lib/web_support/db_factory/` — factory SQLite condizionale IO/Web.
- `tool/web/build_web.dart` — build + iniezione precache.
- `tool/web/cloudflare_build.sh` — build Cloudflare Pages.
- `WEB_CHANGES.md` — elenco annotato delle modifiche.
- `tool/web/web_changes.patch` — patch reversibile dei file preesistenti.
