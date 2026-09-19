# Scripta ✒️

> **Minimal, Markdown-First & Highly Customizable Note-Taking Application**  
> Crafted with Dart & Flutter for Desktop (Linux, macOS, Windows), Tablet, and Mobile (Android, iOS).

---

## ✨ Key Features

1. **Universal Adaptive Layout**:
   - **Desktop (> 1024px)**: 3-column layout (Folders tree + Notes list + Editor).
   - **Tablet (600px - 1024px)**: 2-column layout with collapsible folder drawer.
   - **Mobile (< 600px)**: Single-pane responsive flow with drawer and seamless note-to-editor transitions.
   - Fluid support for both Portrait and Landscape orientations.

2. **Dual Mode (Edit & Read-Only)**:
   - **Read-Only Mode**: Clean typography, rich Markdown rendering, tables, checklist tasks, and syntax-highlighted code blocks with **native text selection, highlighting, and copying**.
   - **Edit Mode**: Instant text editing with auto-save and continuous undo/redo history.
   - **Contextual Formatting Toolbar**: One-click styling for Bold, Italic, Headings (H1, H2, H3), Bulleted & Numbered lists, Tables, Links, Code blocks, and Task lists (`- [ ]`).

3. **Distraction-Free Focus Mode**:
   - One tap hides sidebar, app bar, and toolbars.
   - **State Persistence**: Preserves your active mode (stays in Edit if editing; stays in Read-Only if reading).
   - Discrete floating exit button with hover/tap animations to return effortlessly.

4. **Hierarchical Folder Tree**:
   - Unlimited recursive folders and subfolders.
   - Real-time note counts, expand/collapse toggles, and contextual actions (add subfolder, rename, delete).

5. **Multilingual (i18n)**:
   - Native support for **Italian (Italiano)**, **English**, and **French (Français)**.
   - Automatic system language detection on startup.
   - In-app override in Settings.

6. **Interactive Onboarding**:
   - Beautiful 4-stage tutorial on first launch explaining Markdown philosophy, Dual Mode, Focus Mode, and Folders.
   - Accessible anytime from Settings.

7. **Customization & Typography**:
   - Theme options: **System Default**, **Light**, and **Dark** (crafted Obsidian palette).
   - Typography picker: **Inter**, **JetBrains Mono**, **Merriweather**, and **Roboto**.
   - Adjustable font size and line height sliders with live preview.
   - Open-source credits dialog with built-in `showLicensePage`.

---

## 📂 Project Architecture

```text
InkFlow/
├── pubspec.yaml                 # Dependencies & asset configuration
├── analysis_options.yaml        # Flutter linter rules
├── l10n.yaml                    # Flutter localization setup
├── README.md                    # Project documentation
│
├── android/                     # Android native platform runner & configs
│   ├── app/src/main/
│   │   ├── AndroidManifest.xml
│   │   └── res/values/styles.xml
│   └── build.gradle
│
├── linux/                       # Linux native platform runner & Flatpak configs
│   ├── CMakeLists.txt
│   ├── main.cc
│   ├── my_application.cc
│   └── packaging/
│       ├── io.github.inkflow.Inkflow.json          # Flatpak Manifest
│       ├── io.github.inkflow.Inkflow.metainfo.xml   # AppStream Metadata
│       ├── io.github.inkflow.Inkflow.desktop       # Desktop Entry
│       └── icons/io.github.inkflow.Inkflow.svg     # Scalable Vector Icon
│
├── assets/
│   ├── icons/app_icon.svg       # Vector application icon
│   └── samples/welcome_note.md  # Markdown starter note
│
├── lib/
│   ├── main.dart                # Application entrypoint
│   ├── app.dart                 # Root MaterialApp, i18n & Theme injection
│   │
│   ├── core/                    # Core design system, utilities & constants
│   │   ├── constants/app_constants.dart
│   │   ├── l10n/
│   │   │   ├── app_localizations.dart
│   │   │   ├── app_en.arb
│   │   │   ├── app_it.arb
│   │   │   └── app_fr.arb
│   │   ├── theme/
│   │   │   ├── app_theme.dart
│   │   │   └── color_schemes.dart
│   │   └── utils/
│   │       ├── markdown_toolbar_actions.dart
│   │       └── responsive_breakpoints.dart
│   │
│   ├── features/                # Domain features (Clean Architecture)
│   │   ├── folders/             # Hierarchical folder tree state & UI
│   │   ├── notes/               # Note model, search, filtering & card UI
│   │   ├── editor/              # Dual mode, Focus mode, Toolbar & Markdown
│   │   ├── onboarding/          # First-launch interactive carousel
│   │   └── settings/            # Theme, Language, Typography & About dialog
│   │
│   └── shell/                   # Adaptive shell & responsive top bar
│       ├── adaptive_app_shell.dart
│       └── top_app_bar.dart
│
└── test/
    └── widget_test.dart         # Unit and widget test suite
```

---

## 🚀 Getting Started

### Prerequisites
- [Flutter SDK](https://flutter.dev/docs/get-started/install) (v3.16 or later)
- Dart SDK (v3.2 or later)

### Installation
```bash
# 1. Clone repository
git clone https://github.com/inkflow/inkflow.git
cd inkflow

# 2. Get dependencies
flutter pub get

# 3. Run on your preferred platform
flutter run -d linux    # Linux Desktop
flutter run -d android  # Android Device / Emulator
flutter run -d chrome   # Web Browser
```

---

## 🖥️ Piattaforme supportate e download

I workflow in `.github/workflows/` compilano e pubblicano automaticamente gli artefatti nella *Release* GitHub a ogni tag `v*.*.*` (oppure manualmente da *Actions → Run workflow*).

| Piattaforma | Artefatto | Note |
|---|---|---|
| Android | `Scripta-*.apk` | APK per ABI + universale |
| Linux | `Scripta.flatpak` | Flatpak |
| macOS (Intel + Apple Silicon) | `Scripta-macos-universal.dmg` / `.zip` | Binario universale, firma ad-hoc, **non notarizzato** |
| Windows x64 | `Scripta-windows-x64-setup.exe` | Installer unico (Inno Setup), non firmato |
| Windows ARM64 | `Scripta-windows-arm64-setup.exe` | Installer unico (Inno Setup), build nativa ARM64, non firmato |
| iOS | `Scripta-ios-unsigned.ipa` | **Non firmato**: solo per sideloading |

### macOS — avviso Gatekeeper
L'app non è notarizzata da Apple, quindi al primo avvio macOS la blocca. Apri il `.dmg`, trascina *Scripta* in *Applicazioni*, poi:
- **clic destro su Scripta → Apri → Apri**, oppure
- *Impostazioni di Sistema → Privacy e sicurezza → "Apri comunque"*, oppure
- da Terminale: `xattr -dr com.apple.quarantine /Applications/Scripta.app`

### Windows
Scarica l'installer `Scripta-windows-x64-setup.exe` (oppure `-arm64-setup.exe` per i PC Windows su ARM) ed eseguilo: l'installazione è per-utente (non servono privilegi di amministratore; dalla prima finestra si può scegliere "per tutti gli utenti"), crea la voce nel menu Start e, a richiesta, l'icona sul desktop. Windows SmartScreen può mostrare un avviso perché l'installer non è firmato (*Ulteriori informazioni → Esegui comunque*). Il runtime C++ e `sqlite3.dll` sono già inclusi nell'installer. I dati delle note restano nel profilo utente anche dopo la disinstallazione. L'installer è generato da `tools/windows_installer.iss`.

### iOS — sideloading dell'IPA non firmato
L'IPA **non è firmato** e non è pensato per l'App Store: va installato con uno strumento di sideloading che lo ri-firma con il *tuo* Apple ID.
1. Scarica `Scripta-ios-unsigned.ipa`.
2. Installalo con [AltStore](https://altstore.io) o [Sideloadly](https://sideloadly.io) (o strumenti equivalenti), collegando l'iPhone e accedendo con il tuo Apple ID.
3. Sull'iPhone: *Impostazioni → Generali → VPN e gestione dispositivo* → considera attendibile il tuo profilo sviluppatore. Con Apple ID gratuito può servire attivare la *Modalità sviluppatore* (*Privacy e sicurezza*).
4. Con un Apple ID gratuito l'app scade dopo 7 giorni e va ri-firmata (AltStore lo fa in automatico se il computer è raggiungibile).

> **Sicurezza delle credenziali di sync (iOS/macOS).** Le build non firmate/ad-hoc possono non avere accesso al Keychain. In quel caso Scripta salva le credenziali di sync in `SharedPreferences` (**non cifrate**, ma confinate nella sandbox dell'app) invece di far fallire la sync. Su Android, Linux e Windows il comportamento resta quello cifrato.

### Generare/aggiornare le cartelle `ios/`, `macos/`, `windows/`
Le cartelle di piattaforma vengono create da `tools/setup_platforms.sh` (che lancia `flutter create` senza toccare `lib/`, `pubspec.yaml`, `android/`, `linux/`, applica entitlement/nomi/target minimi e genera le icone). I workflow lo eseguono automaticamente; per generarle in locale (e poi committarle):

```bash
pip install pillow          # per le icone
bash tools/setup_platforms.sh all      # oppure: ios | macos | windows
```

### Build in locale
```bash
flutter build macos --release                    # macOS universale (solo su Mac)
flutter build ios --release --no-codesign        # poi: mkdir Payload, copia build/ios/iphoneos/Runner.app, zip -> .ipa
flutter build windows --release                  # Windows (architettura dell'host; solo su Windows)
# Windows ARM64: su un PC ARM64 con Flutter >= 3.44 lo stesso comando produce un exe ARM64 nativo
# (la cross-compilazione `--target-platform windows-arm64` non è disponibile nel canale stable)
```
Su Windows `sqlite3.dll` deve stare accanto all'eseguibile (se non è già inclusa nel bundle: vedi `tools/windows_sqlite_dll.ps1`). Al primo avvio, i font (Google Fonts) vengono scaricati e messi in cache: serve la rete, altrimenti l'app usa il font di sistema.

---

## 📦 Linux Flatpak Packaging

Inkflow includes Flatpak distribution configuration in `linux/packaging/`:

### Building the Flatpak:
```bash
# Build the Flutter Linux bundle
flutter build linux --release

# Build and install Flatpak bundle
flatpak-builder --user --install --force-clean build-dir linux/packaging/io.github.inkflow.Inkflow.json

# Run via Flatpak
flatpak run io.github.inkflow.Inkflow
```

---

## 📄 License
This project is open-source under the [MIT License](LICENSE).
