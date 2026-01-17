# VaultNote Architecture

[![Flutter](https://img.shields.io/badge/Flutter-3.10+-blue.svg)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.0+-blue.svg)](https://dart.dev)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](../LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20Windows%20%7C%20macOS%20%7C%20Android%20%7C%20iOS-lightgrey.svg)]()

> **Encrypted markdown notes with GitHub sync**

A cross-platform Flutter app for secure note-taking with end-to-end encryption and GitHub backup.

---

## Table of Contents

- [Project Structure](#project-structure)
- [System Architecture](#system-architecture)
- [Core Components](#core-components)
- [Encryption Architecture](#encryption-architecture)
- [GitHub Sync](#github-sync)
- [Multi-Device Coordination](#multi-device-coordination)
- [Gist Sharing](#gist-sharing)
- [App Startup Flow](#app-startup-flow)
- [Navigation Structure](#navigation-structure)
- [Keyboard Shortcuts](#keyboard-shortcuts)
- [Development](#development)
- [Dependencies](#dependencies)
- [Performance](#performance)
- [Security Considerations](#security-considerations)
- [Contributing](#contributing)

---

## Project Structure

```
lib/
├── main.dart                    # App entry, theme setup, lock screen routing
├── models/
│   └── note.dart                # Note data model with gist fields
├── providers/
│   ├── notes_provider.dart      # Main state management (~1700 lines)
│   └── theme_provider.dart      # Theme & editor preferences
├── services/
│   ├── database_service.dart    # SQLite local storage
│   ├── encryption_service.dart  # AES-256 encryption, HMAC validation
│   ├── github_auth_service.dart # OAuth device flow authentication
│   ├── github_service.dart      # GitHub API for note sync
│   ├── gist_service.dart        # GitHub Gist sharing
│   ├── biometric_service.dart   # Fingerprint/Face unlock
│   └── debug_service.dart       # In-memory logging (500 max)
├── screens/
│   ├── lock_screen.dart         # Master password entry with biometric
│   ├── notes_list_screen.dart   # Main UI with grid/list view
│   ├── note_editor_screen.dart  # Markdown editor (mobile)
│   ├── rich_editor_screen.dart  # WYSIWYG editor with slash commands
│   ├── settings_screen.dart     # App configuration
│   ├── github_setup_screen.dart # GitHub OAuth wizard
│   ├── gists_screen.dart        # Shared gists management
│   └── debug_logs_screen.dart   # Debug log viewer
├── widgets/
│   └── code_block_component.dart # Syntax-highlighted code blocks
├── utils/
│   └── snackbar_helper.dart     # Consistent notifications
└── data/
    └── welcome_notes.dart       # 6 first-launch tutorial notes
```

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                           USER DEVICE                               │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────────┐  │
│  │   Flutter   │    │   SQLite    │    │    Secure Storage       │  │
│  │     UI      │◄──►│  Database   │    │  (HMAC hash, tokens,    │  │
│  │             │    │ (Plain Text)│    │   biometric password)   │  │
│  └──────┬──────┘    └─────────────┘    └─────────────────────────┘  │
│         │                                                           │
│  ┌──────▼──────┐                                                    │
│  │ Encryption  │ ◄── Session password (memory only, never saved)    │
│  │  Service    │                                                    │
│  └──────┬──────┘                                                    │
└─────────┼───────────────────────────────────────────────────────────┘
          │
          │ Encrypt on upload / Decrypt on download
          ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         GITHUB REPOSITORY                           │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ notes/                                                      │    │ 
│  │   FolderName/                                               │    │
│  │     1234567890.md  ◄── Encrypted markdown with frontmatter  │    │
│  │                                                             │    │
│  │ .notes-sync/                                                │    │
│  │   encryption.json  ◄── Version, enabled, lock status        │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Core Components

### Note Model

```dart
class Note {
  final String id;           // Timestamp-based unique ID
  final String title;
  final String content;      // Plain text locally, encrypted on GitHub
  final List<String> tags;
  final String folder;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isSynced;       // GitHub sync status
  final bool isPinned;       // Pinned notes appear first
  final bool isFavorite;     // Starred/favorite notes
  
  // Gist sharing info (syncs via frontmatter)
  final String? gistId;
  final String? gistUrl;
  final bool? gistPublic;
  final bool? gistPasswordProtected;
  
  bool get isSharedAsGist => gistId != null && gistUrl != null;
}
```

### NotesProvider

Central state management (~1700 lines):

| Category | Methods |
|----------|---------|
| **CRUD** | `addNote()`, `updateNote()`, `deleteNote()`, `loadNotes()`, `getNoteById()` |
| **Sync** | `syncAll()`, `syncFromGitHub()`, `syncToGitHub()`, `markAllForSync()` |
| **GitHub** | `initGitHub()`, `disconnectGitHub()`, `updateBranch()`, `fetchBranches()`, `clearGitHubAndReupload()` |
| **Encryption** | `syncEncryptionStatus()`, `changePassword()`, `disableEncryptionAndSync()`, `setupEncryptionFromRemote()`, `handleRemotePasswordChange()`, `verifyPasswordWithRemoteNote()`, `isRemoteEncryptionEnabled()`, `getRemoteEncryptionConfig()`, `forceEncryptionSync()` |
| **Organization** | `togglePin()`, `toggleFavorite()`, `searchNotes()`, `filterByTag()`, `sortNotes()` |
| **Data** | `clearAllLocalData()`, `importNote()`, `deleteAndReuploadEncrypted()` |
| **Internal** | `_loadShaCache()`, `_saveShaCache()`, `_createWelcomeNotes()`, `_startAutoSync()`, `_stopAutoSync()`, `setSyncInterval()` |

Key state:
- `_notes` - All notes in memory
- `_isSyncing` - Sync in progress
- `_localShaCache` - SHA cache for incremental sync
- `_uploadingNotes` - Lock to prevent concurrent uploads
- `_welcomeNotesCreated` - First launch flag
- `_passwordChangeDetected` - Multi-device password change

### Services Overview

| Service | Purpose |
|---------|---------|
| `DatabaseService` | SQLite storage, migrations, encryption version tracking |
| `EncryptionService` | AES-256 encryption, HMAC validation, session password |
| `GitHubAuthService` | OAuth device flow, token management |
| `GitHubService` | Note sync, incremental updates, encryption config |
| `GistService` | Create/update/delete gists, password protection |
| `BiometricService` | Fingerprint/Face unlock |
| `DebugService` | In-memory logging (max 500 entries) |

### EncryptionService Methods

| Category | Methods |
|----------|---------|
| **Session** | `setSessionPassword()`, `clearSession()`, `sessionPassword` (getter) |
| **Core** | `encrypt()`, `decrypt()`, `isEncrypted()` |
| **Master** | `isMasterEncryptionEnabled()`, `enableMasterEncryption()`, `disableMasterEncryption()`, `verifyMasterPassword()`, `changeMasterPassword()` |
| **Version** | `getEncryptionVersion()`, `setEncryptionVersion()`, `createVersionLock()`, `isLockExpired()` |
| **Sync** | `encryptForSync()`, `decryptFromSync()` |
| **Gist** | `encryptForProtectedGist()`, `decryptProtectedGist()`, `isProtectedGist()` |

### GitHubService Methods

| Category | Methods |
|----------|---------|
| **Notes** | `uploadNote()`, `uploadNoteWithSha()`, `deleteNote()`, `getChangedNotes()`, `fetchFirstNoteContent()` |
| **Tree** | `getShasForNotes()`, `_getRemoteNotesWithSha()`, `_listAllNotePaths()` |
| **Encryption** | `saveEncryptionVersion()`, `getEncryptionVersion()` |
| **History** | `clearHistoryWithNotes()`, `deleteAllNotes()` |
| **Internal** | `_noteToMarkdown()`, `_markdownToNote()`, `_parseNoteFromContent()` |

### GistService Methods

| Method | Purpose |
|--------|---------|
| `createGist()` | Create new gist (public/secret/protected) |
| `updateGist()` | Update existing gist content |
| `deleteGist()` | Delete gist |
| `fetchGistContent()` | Fetch gist by URL or ID |

### DatabaseService Methods

| Method | Purpose |
|--------|---------|
| `getAllNotes()` | Load all notes from SQLite |
| `insertNote()` | Insert new note |
| `updateNote()` | Update existing note |
| `deleteNote()` | Delete note by ID |
| `clearAllNotes()` | Delete all notes |
| `updateEncryptionVersions()` | Store encryption version per repo |
| `getEncryptionVersions()` | Get stored encryption version |

### BiometricService Methods

| Method | Purpose |
|--------|---------|
| `isAvailable()` | Check if device supports biometric |
| `isEnabled()` | Check if biometric unlock enabled |
| `enable()` | Enable biometric with password |
| `disable()` | Disable biometric unlock |
| `authenticate()` | Prompt biometric auth |
| `authenticateAndGetPassword()` | Auth and return stored password |

### GitHubAuthService Methods

| Method | Purpose |
|--------|---------|
| `loadConfig()` | Load saved repo config |
| `saveRepo()` | Save owner/repo/branch |
| `updateBranch()` | Change branch |
| `clearConfig()` | Disconnect GitHub |
| `requestDeviceCode()` | Start OAuth device flow |
| `pollForToken()` | Poll for OAuth token |
| `fetchUserRepos()` | List user's repositories |
| `fetchBranches()` | List repo branches |

---

## Encryption Architecture

### Storage Model

| Location | Format | Purpose |
|----------|--------|---------|
| Local SQLite | Plain text | Fast access, no decryption overhead |
| GitHub | `ENC:` prefix | Secure cloud backup |
| Gists | Plain or `PENC:` | Sharing with optional protection |

### Encryption Format

```
ENC:base64(salt):base64(iv):base64(ciphertext)
```

- **Algorithm**: AES-256-CBC
- **Key Derivation**: PBKDF2 (SHA-256, 10,000 iterations)
- **Salt**: 16 bytes random per encryption
- **IV**: 16 bytes random per encryption

### Password Flows

```
┌─────────────────────────────────────────────────────────────────┐
│                     PASSWORD ENTRY POINTS                       │
├─────────────────────────────────────────────────────────────────┤
│  1. Lock Screen (app startup)                                   │
│     └─► Enter password → HMAC verify → Set session → Unlock     │
│                                                                 │
│  2. Settings - Enable Encryption                                │
│     └─► Create password → Generate HMAC → Set session           │
│                                                                 │
│  3. Settings - Change Password                                  │
│     └─► Verify old → Create new HMAC → Increment version        │
│                                                                 │
│  4. GitHub Setup - Remote Encrypted                             │
│     └─► Enter password → Decrypt test note → Setup local        │
│                                                                 │
│  5. Gist Share - Password Protection                            │
│     └─► Enter gist password → Encrypt with PENC: → Share        │
└─────────────────────────────────────────────────────────────────┘
```

### Security Model

| Data | Storage | Protection |
|------|---------|------------|
| Notes (local) | SQLite | Plain text (device encryption) |
| Notes (GitHub) | Markdown files | AES-256-CBC |
| Password hash | Secure Storage | HMAC-SHA256 |
| GitHub token | Secure Storage | Platform keychain |
| Session password | Memory only | Cleared on app exit |
| Biometric password | Secure Storage | Platform keychain |

---

## GitHub Sync

### File Structure on GitHub

```
repository/
├── notes/
│   ├── Work/
│   │   ├── 1704067200000.md
│   │   └── 1704153600000.md
│   └── Personal/
│       └── 1704240000000.md
└── .notes-sync/
    └── encryption.json
```

### Note Frontmatter Format

```yaml
---
id: 1704067200000
title: Meeting Notes
tags: [work, meeting]
folder: Work
createdAt: 2024-01-01T00:00:00.000Z
updatedAt: 2024-01-01T12:00:00.000Z
isFavorite: true
gistId: abc123def456
gistUrl: https://gist.github.com/user/abc123def456
gistPublic: false
gistPasswordProtected: false
---
ENC:base64salt:base64iv:base64ciphertext
```

### Incremental Sync Flow

```
1. Fetch branch SHA
         │
         ▼
2. Get full tree (single API call)
         │
         ▼
3. Compare SHAs with local cache (_localShaCache)
         │
         ├─► Changed files → Download & decrypt
         └─► Unchanged → Skip
         │
         ▼
4. Upload unsynced local notes (encrypt with session password)
         │
         ▼
5. Update SHA cache
```

### Encryption Config

```json
// .notes-sync/encryption.json
{
  "version": 5,
  "enabled": true,
  "locked": false,
  "device": "device_1704067200000_123456",
  "timestamp": "2024-01-01T00:00:00.000Z"
}
```

---

## Multi-Device Coordination

### Encryption Sync Results

```dart
enum EncryptionSyncResult { 
  ok,               // Encryption in sync
  needsPassword,    // Remote has encryption, local doesn't
  versionMismatch,  // Remote version newer - password changed
  disabledRemotely, // Remote disabled encryption
  notConfigured     // GitHub not configured
}
```

### Version Sync States

| Local | Remote | Action |
|-------|--------|--------|
| v1 enabled | v1 enabled | Sync normally |
| v2 enabled | v1 enabled | Upload new config |
| v1 enabled | v2 enabled | Prompt for new password |
| Any | locked | Wait or force unlock (>5 min) |
| disabled | enabled | Prompt for password |

### Password Change Flow

```
1. Verify current password (HMAC)
         │
         ▼
2. Check for lock on GitHub
         │
         ├─► Locked by other device → Abort
         └─► Not locked → Continue
         │
         ▼
3. Create lock on GitHub
         │
         ▼
4. Update local HMAC hash
         │
         ▼
5. Increment version
         │
         ▼
6. Mark all notes for re-upload (isSynced = false)
         │
         ▼
7. Remove lock
         │
         ▼
8. Sync notes (encrypted with new password)
```

---

## Gist Sharing

### Gist Types

| Type | Visibility | Encryption | Auto-Update |
|------|------------|------------|-------------|
| Public | Anyone can find | None | Yes (3s debounce) |
| Secret | Link only | None | Yes (3s debounce) |
| Protected | Link only | `PENC:` | No |

### Gist Flow

```
Share Note                          Recipient
    │                                   │
    ├─► Enable password protection      ├─► Open VaultNote app
    ├─► Enter custom password           ├─► Go to Gists → Open Protected
    ├─► Encrypt with PENC: prefix       ├─► Paste gist URL
    └─► Create gist                     ├─► Enter password
                                        └─► View decrypted content
```

### Gist Content Processing

```dart
// Normal gist - decrypt if encrypted, share plain
content = _getPlainContent(note);

// Protected gist - encrypt with custom password
content = EncryptionService.encryptForProtectedGist(plainContent, gistPassword);
```

---

## App Startup Flow

```
main()
  │
  ├─► runZonedGuarded (error handling)
  │
  ├─► Initialize SQLite FFI (Linux/Windows)
  │
  ├─► Load SharedPreferences
  │
  ├─► Check EncryptionService.isMasterEncryptionEnabled()
  │
  ├─► [Encrypted]
  │       └─► LockScreen
  │               ├─► Check biometric available
  │               ├─► Auto-prompt biometric if enabled
  │               ├─► Enter password / Use biometric
  │               ├─► Verify HMAC (verifyMasterPassword)
  │               ├─► Set session password (memory only)
  │               └─► Call onUnlocked → NotesListScreen
  │
  └─► [Not Encrypted]
          └─► NotesListScreen
                  ├─► NotesProvider.init()
                  ├─► Load notes from SQLite
                  ├─► Create welcome notes (first launch, 6 notes)
                  ├─► Load GitHub config
                  ├─► Check encryption sync status
                  └─► Start auto-sync timer (2 min interval)
```

---

## Navigation Structure

```
NotesListScreen
    │
    ├─► Navigation (Rail on desktop, Bottom on mobile)
    │       ├─► All Notes (index 0)
    │       ├─► Starred (index 1) - _showOnlyStarred filter
    │       ├─► Gists (index 2) - GistsScreen
    │       └─► Settings (index 3) - SettingsScreen
    │
    ├─► Note Actions
    │       ├─► Tap → Open editor (Rich on desktop, Markdown on mobile)
    │       ├─► Swipe right → Pin/Unpin (isPinned toggle)
    │       ├─► Swipe left → Delete note
    │       └─► Tap star → Toggle favorite (isFavorite)
    │
    ├─► Search & Filter
    │       ├─► Search by title, content, tags, folder
    │       ├─► Filter by tag (multi-select)
    │       ├─► Filter by folder
    │       └─► Sort by title/created/updated (pinned always first)
    │
    └─► Editors
            ├─► RichEditorScreen (desktop, AppFlowy WYSIWYG)
            │       ├─► Slash commands (/)
            │       ├─► Markdown shortcuts (**, __, etc.)
            │       └─► Syntax highlighting (code blocks)
            │
            └─► NoteEditorScreen (mobile, markdown)
                    ├─► Preview mode (Ctrl+P)
                    ├─► Focus mode (Esc)
                    └─► Gist sharing from toolbar
```

---

## Keyboard Shortcuts

| Shortcut | Action | Screen |
|----------|--------|--------|
| `Ctrl+N` | New note | Notes list |
| `Ctrl+F` | Focus search | Notes list |
| `Ctrl+R` | Refresh/sync | Notes list |
| `Ctrl+S` | Save note | Editor |
| `Ctrl+P` | Toggle preview | Editor |
| `Esc` | Exit focus/preview | Editor |
| `Ctrl+B` | Bold | Rich editor |
| `Ctrl+I` | Italic | Rich editor |

---

## Development

### Prerequisites

- Flutter 3.10+
- Dart 3.0+
- SQLite (desktop platforms)

### Quick Start

```bash
# Clone repository
git clone https://github.com/Paresh-Maheshwari/VaultNote.git
cd VaultNote

# Install dependencies
flutter pub get

# Run
flutter run -d linux    # or windows, macos, android, ios
```

### Build Release

```bash
# Desktop
flutter build linux --release
flutter build windows --release
flutter build macos --release

# Mobile
flutter build apk --release
flutter build ios --release
```

---

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `provider` | ^6.1.5 | State management |
| `sqflite` | ^2.4.2 | SQLite database |
| `sqflite_common_ffi` | ^2.4.0 | SQLite for desktop |
| `flutter_secure_storage` | ^10.0.0 | Secure token/password storage |
| `encrypt` | ^5.0.3 | AES-256 encryption |
| `pointycastle` | ^3.9.1 | PBKDF2 key derivation |
| `crypto` | ^3.0.3 | HMAC-SHA256 |
| `http` | ^1.3.0 | GitHub API calls |
| `appflowy_editor` | ^6.2.0 | Rich text WYSIWYG editor |
| `flutter_markdown_plus` | ^1.0.7 | Markdown rendering |
| `flutter_highlight` | ^0.7.0 | Syntax highlighting |
| `local_auth` | ^3.0.0 | Biometric authentication |
| `share_plus` | ^12.0.1 | Share functionality |
| `file_picker` | ^10.3.8 | File import/export |
| `intl` | ^0.20.2 | Date formatting |

---

## Performance

### Local Operations

| Operation | Time |
|-----------|------|
| Read note | 1-5ms |
| Write note | 1-5ms |
| Search | 15-25ms |
| Load all | 50-100ms |

### Sync Optimizations

- Single Tree API call for change detection
- SHA caching (`_localShaCache`) to skip unchanged files
- Parallel downloads (10 concurrent)
- Sequential uploads (avoid conflicts)
- Upload lock (`_uploadingNotes`) prevents duplicate uploads
- Pagination (`_pageSize = 20`) for large collections

---

## Security Considerations

### ✅ Protected

- Notes encrypted on GitHub (AES-256-CBC)
- Password never stored (HMAC only)
- Session password in memory only (cleared on exit)
- Tokens in platform secure storage
- Biometric password in secure storage

### ⚠️ Not Protected

- Local notes are plain text (relies on device encryption)
- Note titles visible in GitHub (only content encrypted)
- Gist metadata visible (title, description)

### Recommendations

1. Enable device encryption
2. Use strong master password
3. Use private GitHub repository
4. Enable biometric for convenience

---

## Debug Logging

Access in Settings → Debug Logs:

| Tag | Purpose |
|-----|---------|
| `App` | App lifecycle, startup |
| `DB` | Database operations |
| `Sync` | GitHub sync operations |
| `GitHub` | API calls |
| `Encryption` | Encryption operations |
| `Gist` | Gist sharing |
| `Notes` | Note CRUD operations |
| `Flutter` | Framework errors |
| `Platform` | Platform errors |

---

## Contributing

1. Fork the repository
2. Create feature branch: `git checkout -b feature/amazing`
3. Commit changes: `git commit -m 'Add amazing feature'`
4. Push to branch: `git push origin feature/amazing`
5. Open Pull Request

---

## License

AGPL-3.0 with Commons Clause - See [LICENSE](../LICENSE) for details.

**You can:** Use, modify, distribute, fork  
**You cannot:** Sell as SaaS or hosted service
