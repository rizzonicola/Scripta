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
