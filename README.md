<div align="center">

  <img src="assets/icons/app_icon.png" alt="Scripta Logo" width="112" height="112" />

  # Scripta

  **Minimal. Fast. Markdown-First.**  
  *The modern, distraction-free note-taking experience for all your devices.*

  [![Flutter](https://img.shields.io/badge/Flutter-3.41-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
  [![Platforms](https://img.shields.io/badge/Platforms-Android%20%7C%20Linux%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-2E7D32)](#-supported-platforms)
  [![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
  [![Local-First](https://img.shields.io/badge/Architecture-Local--First-orange)](#)

</div>

---

## ⚡ What is Scripta?

**Scripta** is an open-source, local-first note-taking application designed for thinkers, writers, and developers. Built from the ground up to be lightweight, instant, and privacy-focused, Scripta gives you complete control over your notes with raw Markdown flexibility and a modern, fluid interface.

Whether you're drafting quick thoughts on your phone or organizing complex projects on your desktop, Scripta stays out of your way and lets your ideas flow.

---

## 📸 Screenshots

<div align="center">

  ### Desktop Experience
  <p align="center">
    <img src="assets/readme/screenshot-desktop.png" alt="Scripta Desktop Screenshot" width="88%" />
  </p>

  <br />

  ### Mobile Experience
  <p align="center">
    <img src="assets/readme/screenshot-mobile.png" alt="Scripta Mobile Screenshot" width="38%" />
  </p>

</div>

---

## ✨ Key Features

- **📝 Markdown-First Editor**: Write in clean, standard Markdown with intelligent toolbar helpers, syntax highlighting, and an instant, fluid rendered reading view.
- **⚡ Local-First & Zero Latency**: Instantaneous startup and sub-millisecond search powered by SQLite WAL. Your notes reside on your device, fully accessible offline.
- **🔄 Effortless Synchronization**: Privacy-respecting, asynchronous sync with self-hosted backends using Last-Write-Wins (LWW) conflict resolution and background debouncing.
- **🎨 Modern, Adaptive Design**: Gorgeous light and dark color schemes, custom typography, subtle haptics, and a responsive layout that feels native on desktop, tablet, and mobile.
- **📂 Hierarchical Organization**: Organize notes into nested folders, tag favorites, pin priority documents, and rearrange with drag-and-drop ease.
- **🔍 Instant Search**: Real-time filtering and content search find what you need across your entire vault in milliseconds.
- **📦 True Data Ownership**: Never get locked in. Import and export complete backups anytime with standard ZIP archives or plain Markdown files.

---

## 💻 Supported Platforms

Scripta is engineered as a native multi-platform application with full support across desktop and mobile:

| Platform | Format | Status |
|:---|:---|:---:|
| **Android** | Split APKs & Universal APK | ✅ Supported |
| **Linux** | Native Bundle & Flatpak | ✅ Supported |
| **Windows** | Native x64 & ARM64 Installer | ✅ Supported |
| **macOS** | Universal DMG & ZIP (Intel & Apple Silicon) | ✅ Supported |
| **iOS** | Unsigned IPA (Sideloading ready) | ✅ Supported |

---

## 🚀 Getting Started

Download the latest version for your platform directly from the [Releases](https://github.com/rizzonicola/Scripta/releases) page.

For development instructions or building from source:

```bash
# Clone the repository
git clone https://github.com/rizzonicola/Scripta.git
cd Scripta

# Install dependencies
flutter pub get

# Run tests
flutter test

# Launch the app
flutter run
```

---

## 📄 License

Scripta is free and open-source software licensed under the [GNU General Public License v3.0 (GPLv3)](LICENSE).
