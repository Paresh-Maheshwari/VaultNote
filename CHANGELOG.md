# Changelog

All notable changes to VaultNote will be documented in this file.

## [1.1.0] - 2026-01-26

### Added
- **Bookmark Management System**
  - Complete bookmark model with metadata (title, URL, description, favicon, Open Graph images)
  - Nested folder organization using '/' separator (e.g., "Work/Projects")
  - Timestamped notes with multiple entries separated by "---" markers
  - Tag-based categorization and full-text search capabilities
  - GitHub sync integration with SHA-based change tracking

- **Browser Extension Integration**
  - Cross-browser extension for Chrome, Firefox, and Edge (Manifest V3)
  - Local HTTP server (port 52525) with REST API endpoints
  - Optional API key authentication with constant-time comparison security
  - CORS-enabled communication between extension and app
  - Context menu and popup interface for one-click bookmark saving

- **Dynamic Scratchpad System**
  - Multi-tab interface with unlimited tabs and editable names (15 char limit)
  - 8-color coding system for visual organization (Blue, Green, Orange, Purple, Red, Teal, Pink, Amber)
  - Persistent storage via SharedPreferences with auto-save functionality
  - Export scratchpad content to permanent notes
  - Keyboard shortcuts: Ctrl+Q (open), Ctrl+N (new tab), Ctrl+W (close tab)
  - Live character count per tab

### Enhanced
- **Navigation System**: Added bookmarks tab to main navigation (5-destination layout)
- **Database Service**: New bookmarks table with migration support and encryption tracking
- **GitHub Service**: Bookmark sync methods with organized repository structure (notes/, bookmarks/)
- **Settings Screen**: Extension server configuration and API key management interface
- **Notes System**: Pin notes functionality with GitHub sync support (pinned notes stay at top)

### Security
- Input validation and sanitization for all bookmark data
- Secure API key authentication for browser extension communication
- Request size limits and timeout configurations to prevent abuse
- Constant-time string comparison to prevent timing attacks

### Dependencies
- `receive_sharing_intent: ^1.8.1` - Android sharing intent support
- `transparent_image: ^2.0.1` - Transparent image placeholders for favicons

### Technical Implementation
- **New Models**: Bookmark data model with JSON serialization and validation
- **New Providers**: BookmarksProvider for state management and browser extension integration
- **New Services**: BookmarkService (database operations), BookmarkServer (HTTP API)
- **New Screens**: BookmarksScreen (list/search), BookmarkDetailScreen (edit), ScratchpadScreen (multi-tab)
- **Browser Extension**: Complete extension package with background service worker and settings page

---
## [1.0.0] - 2026-01-18

### Added
- Initial release of VaultNote
- AES-256 encryption for all notes before synchronization
- GitHub repository integration for backup and multi-device sync
- Rich WYSIWYG editor with AppFlowy integration
- Markdown editor with live preview and syntax highlighting
- Biometric authentication (fingerprint/face unlock)
- Master password with HMAC validation (password never stored)
- Cross-platform support (Android, Linux, Windows)
- GitHub Gists integration for note sharing
- Folder and tag organization system
- Search functionality across all notes
- Dark and light theme support
- Session-based security with automatic password clearing
- Complete offline functionality
- Open source under AGPL-3.0 license

### Security
- Local-first approach with encrypted storage
- No telemetry or analytics
- Private GitHub repository synchronization
- User maintains complete data ownership
