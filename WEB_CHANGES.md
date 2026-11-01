# Scripta Web/PWA — modifiche

Questo documento elenca in modo verificabile tutte le modifiche introdotte
dal target Web/PWA di Scripta 1.0.8. Le modifiche ai file preesistenti sono
annotate con marcatori `WEB`, `WEB-BEGIN`, `WEB-END` e `WEB-ORIG`, così che
ogni intervento sia riconoscibile e reversibile senza leggere l'intero diff.

## 1. Convenzioni di annotazione

| Marcatore | Significato |
|---|---|
| `// WEB:` | aggiunta o adattamento puntuale per il target Web |
| `// WEB-BEGIN` … `// WEB-END` | blocco di modifiche Web delimitato |
| `// WEB-ORIG:` | riga originale sostituita, conservata come commento |

Nei file Dart i marcatori sono commenti `//`; in `pubspec.yaml` e
`pubspec.lock` sono commenti YAML `#`. Le righe `WEB-ORIG` non sono codice
attivo: servono a ricostruire la versione precedente e a motivare la modifica.
Il file `pubspec.lock` è generato da `flutter pub get`; l'annotazione è un
commento in testa, preservato da `flutter pub get --enforce-lockfile`, e il
suo diff contiene solo le dipendenze transitive nuove.

Nessun file in `android/`, `ios/`, `macos/`, `linux/`, `windows/`,
`.github/workflows/`, `flake.*`, `lib/core/l10n/`, nei test esistenti o nelle
viste UI (inclusa `settings_view.dart`) è stato modificato.

## 2. File preesistenti modificati

### `lib/core/database/app_database.dart`

- Import sostituiti: `path`, `path_provider`, `sqflite_common_ffi` e
  `platform_utils` non sono più importati direttamente. Al loro posto viene
  importata la factory condizionale `lib/web_support/db_factory/db_factory.dart`.
  Le righe rimosse sono conservate in un blocco `WEB-ORIG`.
- `ensureFactoryInitialized()` delega a `initializeDatabaseFactory()`: su
  Android/iOS resta la factory di default di `sqflite`, su desktop
  `sqflite_common_ffi`, sul Web `sqflite_common_ffi_web`.
- `_open()` usa `resolveDatabasePath()` invece di `path_provider`: sul Web
  restituisce il nome logico `scripta.db` (chiave dell'immagine SQLite in
  IndexedDB), sulle altre piattaforme il percorso in
  `getApplicationSupportDirectory()`.
- `PRAGMA journal_mode = WAL` viene eseguito solo se `!kIsWeb`: il virtual
  file system Web (IndexedDB) non supporta WAL. Su Android/iOS/desktop il
  comportamento è invariato.
- `kIsWeb` resta importato perché usato dalla guardia WAL; non viene più
  usato per un ritorno anticipato.

### `lib/core/services/window_decoration_service.dart`

- Aggiunto l'import di `kIsWeb`.
- `updateTitleBarTheme()` e `initializeFullScreenShortcut()` escono subito
  sul Web: `Platform` non è disponibile e i canali nativi GTK/DWM non
  esistono. Su Linux/Windows il codice continua a funzionare come prima.
- Le due guardie originali sono conservate in blocchi `WEB-ORIG`.

### `lib/core/services/export_service.dart`

- Aggiunto `kIsWeb` all'import di `flutter/foundation.dart`.
- `_saveExportFile()`: su Web `FilePicker.saveFile()` avvia il download del
  browser e restituisce `null`; il risultato viene quindi considerato
  riuscito (`saved: true`). Su Android/iOS/desktop resta la logica originale.
- Il fallback nella directory privata dell'app viene eseguito solo se
  `!kIsWeb && (Platform.isAndroid || Platform.isIOS)`. Sul Web non esiste una
  directory privata scrivibile equivalente e il download è già stato
  delegato al browser.
- La guardia originale è conservata in un blocco `WEB-ORIG`.

### `lib/core/services/import_service.dart`

- Aggiunto `kIsWeb` all'import di `flutter/foundation.dart`.
- La voce “Da cartella” del foglio di importazione è nascosta sul Web: la
  File System Access API non espone una selezione di cartella tramite
  `file_picker` e `getDirectoryPath()` lancia `UnsupportedError`.
- `importFromFolder()` ha una guardia difensiva `if (kIsWeb)` con messaggio
  all'utente: il metodo resta raggiungibile anche se la voce è nascosta.
- L'import da ZIP resta invariato su tutte le piattaforme. Su Web
  `PlatformFile.path` è `null`, quindi il controllo preventivo della
  dimensione su disco viene saltato e si applica il controllo sui byte letti
  già presente in `_extractFromZipBytes`.

### `pubspec.yaml`

- Aggiunta la dipendenza `sqflite_common_ffi_web: ^1.2.0`, usata solo
  dall'implementazione Web della factory SQLite. Le dipendenze native
  (`sqflite`, `sqflite_common_ffi`) restano invariate.

### `pubspec.lock`

- Aggiornamento generato da `flutter pub get`: nuove voci transitive
  `sqflite_common_ffi_web`, `dev_build`, `pool`, `process_run`. Nessuna
  versione delle dipendenze esistenti è stata rimossa o degradata.

## 3. Nuovi file

### Database Web

- `lib/web_support/db_factory/db_factory.dart` — export condizionale
  `db_factory_io.dart` / `db_factory_web.dart` tramite
  `if (dart.library.js_interop)`.
- `lib/web_support/db_factory/db_factory_io.dart` — factory nativa
  (Android/iOS/desktop/test), percorso in `getApplicationSupportDirectory()`
  e re-export di `Database`/`openDatabase`.
- `lib/web_support/db_factory/db_factory_web.dart` — factory Web con
  `createDatabaseFactoryFfiWeb`, URI relativi `sqlite3.wasm` e
  `sqflite_sw.js`, percorso logico `scripta.db`.

### PWA e asset Web

- `web/index.html` — entry point, manifest, icone, registrazione del service
  worker personalizzato e controllo aggiornamenti invisibile.
- `web/manifest.json` — manifest PWA (nome, colori, standalone, icone any e
  maskable).
- `web/scripta_sw.js` — service worker personalizzato: precache completo,
  navigazione network-first con fallback `index.html`, asset cache-first,
  nessuna intercettazione cross-origin/non-GET, nessun `skipWaiting()`.
- `web/_headers` — header Cloudflare Pages, inclusi COOP/COEP per skwasm.
- `web/icons/Icon-180.png`, `Icon-192.png`, `Icon-512.png`,
  `Icon-maskable-192.png`, `Icon-maskable-512.png`, `web/favicon.png` —
  icone generate da `icons/icon.svg`.
- `web/sqlite3.wasm` — runtime SQLite Wasm 3.8.0.
- `web/sqflite_sw.js` — worker generato da
  `sqflite_common_ffi_web:setup`, allineato a `sqlite3` 3.8.0.

### Build e documentazione

- `tool/web/build_web.dart` — esegue `flutter build web --release --wasm
  --no-web-resources-cdn --pwa-strategy=none`, elimina il
  `flutter_service_worker.js` vuoto, copia `_headers` e inietta id build +
  lista precache in `scripta_sw.js`.
- `tool/web/cloudflare_build.sh` — entry point di build per Cloudflare Pages;
  usa Flutter 3.44.4, `--enforce-lockfile`, `precache --web`, nessun segreto.
- `tool/web/web_changes.patch` — patch dei soli file preesistenti.
- `WEB.md` — installazione, offline, aggiornamenti, rischi dati iOS,
  configurazione Cloudflare, header, compatibilità e limiti noti.
- `WEB_CHANGES.md` — questo documento.

## 4. Comportamento PWA

- **Build unica**: `dart2wasm` + `skwasm` su Chromium con Wasm GC e
  isolamento cross-origin; `dart2js` + CanvasKit su Safari, Firefox, iOS e
  browser senza queste capacità.
- **Offline**: dopo il primo caricamento completo il service worker ha in
  cache 67 file (44,4 MiB), inclusi JS/Wasm, renderer, font, icone,
  `sqlite3.wasm` e `sqflite_sw.js`.
- **Aggiornamenti**: nessun pulsante/banner/widget; nessun `skipWaiting()`.
  Il nuovo service worker resta in `waiting` finché tutte le finestre/tab
  della versione precedente non vengono chiuse; all'attivazione elimina le
  cache `scripta-*` vecchie.
- **Dati**: SQLite in IndexedDB (`sqflite_databases`), preferenze in
  `localStorage`, sessione server in `flutter_secure_storage_web` (HTTPS).
  Il service worker non tocca IndexedDB, `localStorage` o SharedPreferences.

## 5. Verifiche eseguite

### Analisi e test

```text
flutter analyze  → No issues found!
flutter test     → 443 test superati (baseline: 443)
```

### Build Web

```text
dart run tool/web/build_web.dart --flutter /home/nicola/flutter/bin/flutter
→ Precache: 67 file, 44.4 MiB
→ build/web/scripta_sw.js con BUILD_ID locale e 67 percorsi
→ build/web/_headers presente
→ build/web/flutter_service_worker.js assente
```

### Runtime (Chromium 155 / Brave headless, server locale con COOP+COEP)

- `window.crossOriginIsolated === true`.
- `_flutter.buildConfig` contiene sia `dart2wasm`/`skwasm` sia
  `dart2js`/`canvaskit`; il browser ha caricato `main.dart.wasm`,
  `main.dart.mjs`, `canvaskit/skwasm.js` e `canvaskit/skwasm.wasm`.
- Fallback verificato forzando a `false` solo il probe WasmGC: la stessa
  build ha caricato `main.dart.js` e `canvaskit/chromium/canvaskit.*`, con
  ricarica offline funzionante e nessun errore. È il percorso usato da
  Safari/Firefox o dai browser senza Wasm GC.
- Service worker `scripta_sw.js` attivo; Cache Storage
  `scripta-local-…` con 67 entry.
- IndexedDB `sqflite_databases` creata con gli store `blocks` e `files`.
- Ricarica con rete disattivata: app caricata, nessun errore di pagina, nessuna
  richiesta fallita.
- Aggiornamento simulato con una tab controllata: il nuovo service worker
  resta in `waiting` (`installed`) e la cache vecchia resta; dopo la chiusura
  di tutte le tab, alla riapertura il nuovo service worker è attivo e la
  cache vecchia è stata eliminata.

### Android

Confronto con l'APK baseline (stesso commit `41d9f16`, prima delle modifiche
Web):

```text
baseline: 71.131.411 byte
finale:   71.131.999 byte  (+588 byte, +0,0008%)
permessi: identici (INTERNET + DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION)
entry ZIP: 435 in entrambi gli APK
differenza di dimensione: solo assets/flutter_assets/NOTICES.Z
                          (licenze della nuova dipendenza, +299 byte compressi)
libapp.so: stesse dimensioni per arm64-v8a, armeabi-v7a e x86_64
           (CRC diverso per metadati/non determinismo della build AOT)
```

L'hash SHA-256 dell'APK cambia perché la firma e i metadati di build non
sono deterministici; non è una differenza funzionale. Il codice Android non
è stato modificato: le guardie Web (`kIsWeb`) sono costanti `false` in
compilazione Android e vengono eliminate dal compilatore. L'unica differenza
di dimensione nell'APK è il file delle licenze, dovuto alla nuova dipendenza
`sqflite_common_ffi_web` presente nel lock (non usata sul target Android).

## 6. Applicazione e rollback della patch

La patch contiene solo i sei file preesistenti modificati (non i nuovi file):

```bash
# applicare le modifiche a un albero al commit 41d9f16
git apply tool/web/web_changes.patch

# verificare che la patch sia reversibile
git apply --check -R tool/web/web_changes.patch

# rimuovere le modifiche Web dai file preesistenti
git apply -R tool/web/web_changes.patch
```

I nuovi file (`web/`, `lib/web_support/`, `tool/web/`, `WEB.md`,
`WEB_CHANGES.md`) sono indipendenti e possono essere rimossi senza toccare
il codice nativo. Dopo il rollback dei file preesistenti, l'app torna al
comportamento del commit `41d9f16` su Android/iOS/desktop.

## 7. Configurazione Cloudflare

La configurazione dell'account Cloudflare, del repository Git, del dominio e
dei DNS è manuale e **non** è stata eseguita da questo lavoro. I passi sono
documentati in `WEB.md` §5. Non sono stati aggiunti segreti, token o workflow
GitHub.
