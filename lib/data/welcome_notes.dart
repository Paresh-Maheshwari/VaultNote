// ============================================================================
// WELCOME NOTES
// ============================================================================
//
// Demo notes created on first app launch to showcase VaultNote features.
// Created only once when database is empty (tracked by _welcomeNotesCreated flag).
//
// Notes created:
// 1. Welcome - Quick start guide
// 2. Editor & Formatting - Markdown and slash commands
// 3. GitHub Sync Setup - OAuth device flow
// 4. Share as Gist - Public/secret/protected gists
// 5. Security & Encryption - Master password, biometric
// 6. Themes & Editor - Appearance settings
//
// ============================================================================

import '../models/note.dart';

class WelcomeNotes {
  static List<Note> createWelcomeNotes() {
    final now = DateTime.now();
    
    return [
      // Main welcome note
      Note(
        id: '${now.millisecondsSinceEpoch}001',
        title: '🎉 Welcome to VaultNote!',
        content: '''Your notes are **encrypted** and can sync securely to **GitHub**.

## 🚀 Get Started
1. **Create** - Tap the + button
2. **Organize** - Add folders & tags
3. **Star ⭐** - Tap star icon on note card
4. **Sync** - Settings → GitHub Sync

## 🔐 What's Special
- **Encrypted** - Notes secured locally
- **GitHub Sync** - Access anywhere, never lose data
- **Cross-platform** - Desktop & mobile

## ⌨️ Quick Actions
- **Swipe right** → Pin note (stays at top)
- **Swipe left** → Delete note
- **Tap ⭐** → Add to favorites
- **Ctrl+S** save, **Ctrl+P** preview, **Ctrl+N** new note

---
*Check out the other guide notes! Delete these when ready.*''',
        tags: ['guide'],
        folder: 'Guide',
        createdAt: now,
        updatedAt: now,
        isFavorite: true,
        isPinned: true,
      ),

      // Markdown guide
      Note(
        id: '${now.millisecondsSinceEpoch}002',
        title: '📝 Editor & Formatting',
        content: '''Learn how to format your notes with Markdown!

## Text Formatting
- **Bold** → `**text**` or Ctrl+B
- *Italic* → `*text*` or Ctrl+I
- ~~Strikethrough~~ → `~~text~~`
- `Code` → `` `code` ``

## Lists & Blocks
- Bullet: `- item` or `* item`
- Numbered: `1. item`
- Checkbox: `- [ ] task` or `- [x] done`
- Quote: `> text`
- Divider: `---`

## Headers
Type at start of line:
- `# ` → Heading 1
- `## ` → Heading 2
- `### ` → Heading 3

## Slash Commands (Rich Editor)
Type `/` then search:
- `/heading1` `/h1` → Heading
- `/bullet` → Bullet list
- `/todo` → Checkbox
- `/code` → Code block
- `/quote` → Quote block

## Shortcuts
- **Ctrl+S** → Save
- **Ctrl+P** → Preview mode
- **Esc** → Exit focus/preview

---
*Try the slash commands in rich editor!*''',
        tags: ['guide'],
        folder: 'Guide',
        createdAt: now.subtract(const Duration(minutes: 1)),
        updatedAt: now.subtract(const Duration(minutes: 1)),
      ),

      // GitHub sync guide
      Note(
        id: '${now.millisecondsSinceEpoch}003',
        title: '☁️ GitHub Sync Setup',
        content: '''## Why Sync?
- **Backup** - Never lose your notes
- **Access anywhere** - Any device with VaultNote
- **Encrypted** - GitHub can't read your notes

## Setup Steps
1. Go to **Settings** ⚙️
2. Tap **Setup GitHub Sync**
3. Opens GitHub login page
4. Enter the **code** shown in app
5. Authorize VaultNote
6. Select **repository** & **branch**
7. Done! Auto-sync enabled

## Tips
- Use a **private repository**
- Notes encrypted before upload
- Sync happens automatically

---
*Your notes stay encrypted end-to-end!*''',
        tags: ['guide'],
        folder: 'Guide',
        createdAt: now.subtract(const Duration(minutes: 2)),
        updatedAt: now.subtract(const Duration(minutes: 2)),
      ),

      // Gists guide
      Note(
        id: '${now.millisecondsSinceEpoch}004',
        title: '🔗 Share as Gist',
        content: '''Share any note as a GitHub Gist!

## How to Share
1. Open a note in editor
2. Tap **share icon** (○ with arrow) in toolbar
3. Choose **Public** or **Secret**
4. Optionally add **password protection**
5. Get shareable link!

## Gist Types
- **Public** - Anyone can find & view
- **Secret** - Only people with link
- **Protected** - Encrypted, needs password

## Gists Tab Features
- View all your shared notes
- **Copy Link** - Share with anyone
- **Unshare** - Delete gist permanently
- **Open Protected** - View encrypted gists
- Filter: All / Public / Secret / Protected

---
*Requires GitHub connection in Settings.*''',
        tags: ['guide'],
        folder: 'Guide',
        createdAt: now.subtract(const Duration(minutes: 3)),
        updatedAt: now.subtract(const Duration(minutes: 3)),
      ),

      // Security guide
      Note(
        id: '${now.millisecondsSinceEpoch}005',
        title: '🔒 Security & Encryption',
        content: '''Keep your notes protected!

## Master Encryption
- **AES-256** encryption for all notes
- Set a **master password**
- Notes encrypted locally & before sync

## Setup
1. Go to **Settings** ⚙️
2. Find **Security** section
3. Enable **Master Encryption**
4. Create a strong password

## Biometric Unlock
- Use **fingerprint** to unlock (if available)
- Enable in Security settings
- Faster than typing password

## Tips
- Use a strong, unique password
- Enable biometric for convenience
- Password syncs across devices

---
*Only you can read your notes!*''',
        tags: ['guide'],
        folder: 'Guide',
        createdAt: now.subtract(const Duration(minutes: 4)),
        updatedAt: now.subtract(const Duration(minutes: 4)),
      ),

      // Theme & customization guide
      Note(
        id: '${now.millisecondsSinceEpoch}006',
        title: '🎨 Themes & Editor',
        content: '''Customize your experience!

## Theme (Settings → Appearance)
- **System** - Follows device setting
- **Light** - Clean white background
- **Dark** - Easy on the eyes

## Editor Options
- **Rich Editor** - Visual formatting (desktop)
- **Markdown** - Raw text with syntax
- **Default View** - Edit or Preview mode

## Views
- **Grid** - Card layout with previews
- **List** - Compact list format
- Toggle with icon in toolbar

## Data Management
- **Export Notes** - Save as JSON backup
- **Import Notes** - Restore from backup
- **Clear Database** - Reset local data

---
*Find what works best for you!*''',
        tags: ['guide'],
        folder: 'Guide',
        createdAt: now.subtract(const Duration(minutes: 5)),
        updatedAt: now.subtract(const Duration(minutes: 5)),
      ),
    ];
  }
}
