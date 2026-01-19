# VaultNote

<p align="center">
  <img src="assets/vaultnote_icon_v4.svg" width="120" alt="VaultNote Logo">
</p>

<p align="center">
  <strong>Encrypted markdown notes with GitHub sync</strong>
</p>

<p align="center">
  <a href="https://flutter.dev"><img src="https://img.shields.io/badge/Flutter-3.10+-blue.svg" alt="Flutter"></a>
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/Dart-3.0+-blue.svg" alt="Dart"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-AGPL--3.0-green.svg" alt="License"></a>
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#download">Download</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#documentation">Docs</a> •
  <a href="#contributing">Contributing</a>
</p>

<p align="center">
  <a href="https://vaultnote.web.app">🌐 Website</a>
</p>

---

## Features

### Note Taking

- **Rich WYSIWYG Editor** - AppFlowy-powered editor with slash commands
- **Markdown Editor** - Full markdown support with live preview
- **Syntax Highlighting** - Code blocks with language detection
- **Focus Mode** - Distraction-free writing
- **Keyboard Shortcuts** - Ctrl+S save, Ctrl+P preview, Ctrl+N new note

### Security

- **AES-256 Encryption** - Notes encrypted before GitHub upload
- **Master Password** - HMAC-based validation (password never stored)
- **Biometric Unlock** - Fingerprint/Face unlock support
- **Session-based** - Password in memory only, cleared on exit
- **Your Data, Your Repo** - Notes stored in YOUR private GitHub repository

### GitHub Sync

- **OAuth Device Flow** - Secure authentication (no PAT needed)
- **Incremental Sync** - SHA-based change detection
- **Multi-device** - Sync across all devices with password coordination
- **Auto Sync** - Configurable interval (2, 5, or 10 minutes)
- **Branch Selection** - Choose which branch to sync

### Organization

- **Folders** - Organize notes into folders
- **Tags** - Multiple tags per note
- **Star/Favorite** - Quick access to important notes
- **Pin Notes** - Keep notes at top (swipe right)
- **Search** - Full-text search across title, content, tags
- **Sort & Filter** - By date, title, tag, or folder

### Gist Sharing

- **Public Gists** - Share notes publicly
- **Secret Gists** - Share via link only
- **Password Protected** - Encrypt shared gists with custom password
- **Auto-update** - Gists sync when note changes

### Platform Support

| Platform | Status          |
| -------- | --------------- |
| Linux    | ✅ Full support |
| Windows  | ✅ Full support |
| Android  | ✅ Full support |

---

## Download

### Releases

Download from [GitHub Releases](../../releases):

- **Android** - Signed APK
- **Linux** - Binary
- **Windows** - Executable

### Build from Source

```bash
git clone https://github.com/Paresh-Maheshwari/VaultNote.git
cd VaultNote
flutter pub get
flutter run
```

---

## Quick Start

### 1. First Launch

- App creates 6 welcome notes explaining features
- Delete them when ready

### 2. Enable Encryption (Recommended)

- Settings → Security → Enable Encryption
- Set master password
- Notes encrypted on GitHub sync

### 3. Connect GitHub

- Settings → GitHub Sync → Connect
- Authorize via device code
- Select repository and branch

### 4. Start Taking Notes

- Tap + to create note
- Swipe right to pin
- Tap ⭐ to favorite
- Swipe left to delete

---

## Keyboard Shortcuts

| Shortcut   | Action          |
| ---------- | --------------- |
| `Ctrl+N` | New note        |
| `Ctrl+S` | Save note       |
| `Ctrl+P` | Toggle preview  |
| `Ctrl+F` | Focus search    |
| `Ctrl+R` | Refresh/sync    |
| `Esc`    | Exit focus mode |

---

## Architecture

```
lib/
├── main.dart                 # App entry, theme, lock screen
├── models/
│   └── note.dart             # Note model with gist fields
├── providers/
│   ├── notes_provider.dart   # State management, sync, encryption
│   └── theme_provider.dart   # Theme preferences
├── services/
│   ├── database_service.dart     # SQLite storage
│   ├── encryption_service.dart   # AES-256, HMAC validation
│   ├── github_service.dart       # GitHub API sync
│   ├── github_auth_service.dart  # OAuth device flow
│   ├── gist_service.dart         # Gist sharing
│   ├── biometric_service.dart    # Fingerprint/Face unlock
│   └── debug_service.dart        # In-memory logging
├── screens/
│   ├── lock_screen.dart          # Password/biometric entry
│   ├── notes_list_screen.dart    # Main UI
│   ├── note_editor_screen.dart   # Markdown editor
│   ├── rich_editor_screen.dart   # WYSIWYG editor
│   ├── settings_screen.dart      # Configuration
│   ├── github_setup_screen.dart  # GitHub OAuth wizard
│   ├── gists_screen.dart         # Gist management
│   └── debug_logs_screen.dart    # Log viewer
├── widgets/
│   └── code_block_component.dart # Syntax highlighting
├── utils/
│   └── snackbar_helper.dart      # Notifications
└── data/
    └── welcome_notes.dart        # First-launch guides
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed documentation.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

```bash
# Setup
git clone https://github.com/Paresh-Maheshwari/VaultNote.git
cd VaultNote
flutter pub get

# Run
flutter run -d linux

# Analyze
dart analyze lib/
```

## Code Signing Policy

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org)

**Team roles:**
- Committers and reviewers: [Paresh-Maheshwari](https://github.com/Paresh-Maheshwari)
- Approvers: [Paresh-Maheshwari](https://github.com/Paresh-Maheshwari)

**Privacy policy:** This program will not transfer any information to other networked systems unless specifically requested by the user or the person installing or operating it.

## Support

If you find VaultNote helpful:
- ⭐ Star the repository
- 🐛 Report issues at [GitHub Issues](../../issues)
- ☕ [Buy me a coffee](https://buymeacoffee.com/paresh_maheshwari)

---

<p align="center">
  <em>Built with ❤️ using Flutter</em>
</p>
