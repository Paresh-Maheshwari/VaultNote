// ============================================================================
// BOOKMARKS PROVIDER
// ============================================================================
//
// State management for bookmark operations and GitHub sync. Handles:
// - Bookmark CRUD operations with local SQLite storage
// - GitHub sync with SHA-based incremental updates
// - Browser extension communication via HTTP server
// - Shared content from other apps (mobile)
// - Search and folder filtering
//
// ## Architecture
//
// - Bookmarks stored as plain JSON in local SQLite database
// - GitHub sync with folder-based organization (bookmarks/FolderName/id.json)
// - Auto-sync timer with user-configurable intervals
// - HTTP server for browser extension integration
//
// ============================================================================

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bookmark.dart';
import '../services/bookmark_service.dart';
import '../services/bookmark_server.dart';
import '../services/debug_service.dart';
import '../services/github_service.dart';
import '../services/github_auth_service.dart';
// Only import on mobile to avoid desktop plugin errors
import 'package:receive_sharing_intent/receive_sharing_intent.dart'
    if (dart.library.js) 'package:receive_sharing_intent/receive_sharing_intent_stub.dart'
    if (dart.library.io) 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// State management for bookmarks with sync and filtering
class BookmarksProvider extends ChangeNotifier {
  List<Bookmark> _bookmarks = [];
  String _selectedFolder = 'All';
  String _searchQuery = '';
  BookmarkServer? _server;
  StreamSubscription? _shareSubscription;
  
  final GitHubService _githubService = GitHubService();
  bool _isSyncing = false;
  final Map<String, String> _localShaCache = {};
  Timer? _syncTimer;
  int _syncIntervalMinutes = 2;
  final Set<String> _uploadingBookmarks = {};
  bool _githubInitialized = false;
  
  // Pending deletions to retry on next sync (folder\nid format - newline separator)
  final Set<String> _pendingDeletions = {};
  
  // Browser extension server settings
  bool _extensionServerEnabled = false;
  int _extensionServerPort = 52525;
  String _extensionServerHost = '127.0.0.1';
  String? _extensionApiKey;

  bool get isSyncing => _isSyncing;
  bool get extensionServerEnabled => _extensionServerEnabled;
  int get extensionServerPort => _extensionServerPort;
  String get extensionServerHost => _extensionServerHost;
  String? get extensionApiKey => _extensionApiKey;
  bool get isServerRunning => _server != null;
  int get syncIntervalMinutes => _syncIntervalMinutes;

  List<Bookmark> get bookmarks {
    // Return cached filtered results - actual filtering happens in loadBookmarks()
    return _bookmarks;
  }

  List<String> get folders {
    // Get all folders from database, not just filtered bookmarks
    return _allFolders;
  }

  // Cache all folders separately from filtered bookmarks
  List<String> _allFolders = ['All'];

  String get selectedFolder => _selectedFolder;
  String get searchQuery => _searchQuery;
  int get count => _bookmarks.length;
  bool get isGitHubConfigured => _githubService.isConfigured;

  Future<void> init() async {
    DebugService.log('Bookmarks', 'Initializing BookmarksProvider...');
    await loadBookmarks();
    _startServer();
    _listenForSharedContent();
  }

  /// Sets up listener for shared content from other apps (mobile only).
  void _listenForSharedContent() {
    // Only on mobile - skip entirely on desktop to avoid plugin errors
    if (!Platform.isAndroid && !Platform.isIOS) {
      DebugService.log('Bookmarks', 'Skipping sharing intent on desktop platform');
      return;
    }

    try {
      // Handle shared content when app is opened from share
      ReceiveSharingIntent.instance.getInitialMedia().then((files) {
        for (final file in files) {
          if (file.path.startsWith('http') || file.type == SharedMediaType.url) {
            _handleSharedUrl(file.path);
          } else if (file.message != null) {
            _handleSharedUrl(file.message!);
          }
        }
      }).catchError((e) {
        DebugService.log('Bookmarks', 'Sharing intent error: $e', isError: true);
      });

      // Handle shared content while app is running
      _shareSubscription = ReceiveSharingIntent.instance.getMediaStream().listen(
        (files) {
          for (final file in files) {
            if (file.path.startsWith('http') || file.type == SharedMediaType.url) {
              _handleSharedUrl(file.path);
            } else if (file.message != null) {
              _handleSharedUrl(file.message!);
            }
          }
        },
        onError: (e) => DebugService.log('Bookmarks', 'Sharing stream error: $e', isError: true),
      );
    } catch (e) {
      DebugService.log('Bookmarks', 'Failed to initialize sharing intent: $e', isError: true);
    }
  }

  /// Process shared URL and create bookmark
  void _handleSharedUrl(String text) {
    final urlMatch = RegExp(r'https?://[^\s]+').firstMatch(text);
    final url = urlMatch?.group(0) ?? text;
    if (url.isEmpty) return;

    String title = text.replaceAll(url, '').trim();
    if (title.isEmpty) {
      title = Uri.tryParse(url)?.host ?? 'Shared Bookmark';
    }
    _handleIncoming({'url': url, 'title': title, 'folder': 'Shared'});
  }

  /// Loads all bookmarks from database and updates UI.
  /// 
  /// Fetches bookmarks via BookmarkService, updates internal list,
  /// logs count for debugging, and notifies UI listeners.
  Future<void> loadBookmarks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _syncIntervalMinutes = prefs.getInt('sync_interval') ?? 2;
      _extensionServerEnabled = prefs.getBool('extension_server_enabled') ?? false;
      _extensionServerPort = prefs.getInt('extension_server_port') ?? 52525;
      _extensionServerHost = prefs.getString('extension_server_host') ?? '127.0.0.1';
      _extensionApiKey = prefs.getString('extension_api_key');
      
      // Load all folders for the folder list
      _allFolders = await BookmarkService.getAllFolders();
      
      // Use efficient database filtering instead of in-memory filtering
      _bookmarks = await BookmarkService.getFiltered(
        folder: _selectedFolder,
        searchQuery: _searchQuery,
      );
      DebugService.log('Bookmarks', 'Loaded ${_bookmarks.length} filtered bookmarks');
      notifyListeners();
    } catch (e) {
      DebugService.log('Bookmarks', 'Error loading bookmarks: $e', isError: true);
    }
  }

  /// Clear all bookmarks from memory and stop sync
  void clearAllBookmarks() {
    _bookmarks.clear();
    _localShaCache.clear();
    _uploadingBookmarks.clear();
    _selectedFolder = 'All';
    _searchQuery = '';
    _stopAutoSync();
    notifyListeners();
    DebugService.log('Bookmarks', 'All bookmarks cleared from memory');
  }

  void _startServer() {
    if (!_extensionServerEnabled) {
      DebugService.log('Bookmarks', 'Extension server disabled');
      return;
    }
    _server = BookmarkServer(
      onBookmark: _handleIncoming,
      onGetAll: _getAllForExtension,
      onGetFolders: _getFoldersForExtension,
      port: _extensionServerPort,
      host: _extensionServerHost,
      apiKey: _extensionApiKey,
    );
    _server!.start();
    DebugService.log('Bookmarks', 'BookmarkServer started on $_extensionServerHost:$_extensionServerPort');
  }

  void _handleIncoming(Map<String, dynamic> data) async {
    final url = data['url'] as String? ?? '';
    if (url.isEmpty) {
      DebugService.log('Bookmarks', 'Ignoring bookmark with empty URL', isError: true);
      return;
    }
    
    final newNotes = data['description'] as String? ?? data['notes'] as String?;
    
    // Check if URL already exists in database first
    final existingBookmark = await BookmarkService.findByUrl(url);
    if (existingBookmark != null) {
      // Always append new notes if provided
      if (newNotes != null && newNotes.isNotEmpty) {
        final timestamp = DateTime.now().toString().substring(0, 16);
        final updatedNotes = existingBookmark.notes != null && existingBookmark.notes!.isNotEmpty
            ? '${existingBookmark.notes}\n\n--- $timestamp ---\n$newNotes'
            : newNotes;
        final updated = existingBookmark.copyWith(notes: updatedNotes, isSynced: false);
        await BookmarkService.update(updated);
        
        // Update in-memory list
        final existingIndex = _bookmarks.indexWhere((b) => b.url == url);
        if (existingIndex != -1) {
          _bookmarks[existingIndex] = updated;
        } else {
          // Bookmark exists in DB but not in memory - add it
          _bookmarks.insert(0, updated);
        }
        notifyListeners();
        DebugService.log('Bookmarks', 'Added notes to existing: ${existingBookmark.title}');
      } else {
        DebugService.log('Bookmarks', 'Already exists (no new notes): ${existingBookmark.title}');
        // Still notify UI that bookmark was processed
        notifyListeners();
      }
      return;
    }

    // Parse tags
    List<String> tags = ['bookmark'];
    if (data['tags'] != null) {
      tags = (data['tags'] as List).map((t) => t.toString()).toList();
    }

    // Fetch metadata (image, description) from URL
    String? image = data['image'] as String?;
    String? description;
    String title = data['title'] as String? ?? 'Bookmark';
    
    final meta = await BookmarkService.fetchMetadata(url);
    image ??= meta['image'];
    // Don't override description from extension with metadata
    if (newNotes == null || newNotes.isEmpty) {
      description = meta['description'];
    }
    if (title == 'Bookmark' && meta['title'] != null) title = meta['title']!;

    final bookmark = Bookmark(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      url: url,
      title: title,
      description: description,
      image: image,
      notes: newNotes, // Selected text goes to notes
      folder: data['folder'] as String? ?? 'Bookmarks',
      tags: tags,
      createdAt: DateTime.now(),
      isSynced: false, // New bookmarks are unsynced
    );

    await add(bookmark);
    DebugService.log('Bookmarks', 'Saved: ${bookmark.title}');
  }

  List<Map<String, dynamic>> _getAllForExtension() {
    return _bookmarks.map((b) => {
      'id': b.id,
      'title': b.title,
      'url': b.url,
      'folder': b.folder,
      'tags': b.tags,
      'createdAt': b.createdAt.toIso8601String(),
    }).toList();
  }

  List<String> _getFoldersForExtension() {
    final folderSet = <String>{};
    for (final b in _bookmarks) {
      folderSet.add(b.folder);
    }
    return folderSet.toList()..sort();
  }

  Future<void> add(Bookmark bookmark) async {
    try {
      final unsyncedBookmark = bookmark.copyWith(isSynced: false);
      await BookmarkService.insert(unsyncedBookmark);
      // Reload to get updated filtered list and folders
      await loadBookmarks();
    } catch (e) {
      DebugService.log('Bookmarks', 'Error adding bookmark: $e', isError: true);
      rethrow;
    }
  }

  // Returns existing bookmark if duplicate, null otherwise
  Future<Bookmark?> checkDuplicate(String url) async {
    return BookmarkService.findByUrl(url);
  }

  Future<String> exportJson() => BookmarkService.exportToJson();
  Future<String> exportHtml() => BookmarkService.exportToHtml();
  
  Future<int> importJson(String json) async {
    final count = await BookmarkService.importFromJson(json);
    await loadBookmarks();
    return count;
  }

  /// Imports bookmarks from HTML file (universal browser format).
  /// 
  /// [htmlContent] - HTML content from browser export
  /// Returns number of bookmarks imported
  Future<int> importHtml(String htmlContent) async {
    final count = await BookmarkService.importFromHtml(htmlContent);
    await loadBookmarks();
    return count;
  }

  /// Upload unsynced bookmarks to GitHub sequentially
  Future<void> syncToGitHub() async {
    if (!_githubService.isConfigured) return;

    // Process pending deletions first
    if (_pendingDeletions.isNotEmpty) {
      DebugService.log('Sync', 'Processing ${_pendingDeletions.length} pending deletions');
      final completed = <String>[];
      for (final entry in _pendingDeletions) {
        final parts = entry.split('\n');
        if (parts.length == 2) {
          try {
            await _githubService.deleteBookmark(parts[0], parts[1]);
            completed.add(entry);
            DebugService.log('Sync', 'Deleted from GitHub: ${parts[1]}');
          } catch (e) {
            DebugService.log('Sync', 'Failed to delete ${parts[1]}: $e', isError: true);
          }
        }
      }
      _pendingDeletions.removeAll(completed);
    }

    final unsynced = _bookmarks.where((b) => !b.isSynced).toList();
    DebugService.log('Sync', 'Starting upload: ${unsynced.length} bookmarks to sync');
    
    if (unsynced.isEmpty) return;
    
    int success = 0;
    
    for (final bookmark in unsynced) {
      if (_uploadingBookmarks.contains(bookmark.id)) continue;
      
      _uploadingBookmarks.add(bookmark.id);
      try {
        await _githubService.uploadBookmark(bookmark);
        final synced = bookmark.copyWith(isSynced: true);
        await BookmarkService.update(synced);
        final index = _bookmarks.indexWhere((b) => b.id == bookmark.id);
        if (index != -1) _bookmarks[index] = synced;
        success++;
      } catch (e) {
        DebugService.log('Sync', 'Failed to upload bookmark ${bookmark.id}: $e', isError: true);
      } finally {
        _uploadingBookmarks.remove(bookmark.id);
      }
    }
    
    DebugService.log('Sync', 'Upload complete: $success/${unsynced.length} success');
  }

  /// Download changed bookmarks from GitHub using SHA comparison
  Future<void> syncFromGitHub() async {
    if (!_githubService.isConfigured) return;

    DebugService.log('Sync', 'Starting incremental sync from GitHub');
    
    try {
      // Get all bookmark files with SHAs using tree API (single request)
      final remotePaths = await _githubService.getBookmarkFilesWithSha();
      
      // Handle local bookmarks not on remote
      final toDelete = <String>[];
      final toReupload = <Bookmark>[];
      
      // If remote is empty but we have many synced bookmarks, don't delete - re-upload instead
      final syncedCount = _bookmarks.where((b) => b.isSynced).length;
      final remoteEmpty = remotePaths.isEmpty;
      
      for (final bookmark in _bookmarks) {
        final expectedPath = 'bookmarks/${bookmark.folder.replaceAll(RegExp(r'[^\w\-_/]'), '_')}/${bookmark.id}.json';
        if (!remotePaths.containsKey(expectedPath)) {
          if (bookmark.isSynced) {
            if (remoteEmpty && syncedCount > 5) {
              // Remote was likely cleared - mark for re-upload instead of delete
              toReupload.add(bookmark);
            } else {
              // Was synced before but now gone from remote = deleted on another device
              toDelete.add(bookmark.id);
              DebugService.log('Sync', 'Deleting ${bookmark.id} (removed from remote)');
            }
          }
          // If not synced, it's a new local bookmark - will be uploaded later
        }
      }
      
      // Mark bookmarks for re-upload (remote was cleared)
      if (toReupload.isNotEmpty) {
        DebugService.log('Sync', 'Remote empty - marking ${toReupload.length} bookmarks for re-upload');
        for (final bookmark in toReupload) {
          final updated = bookmark.copyWith(isSynced: false);
          await BookmarkService.update(updated);
          final idx = _bookmarks.indexWhere((b) => b.id == bookmark.id);
          if (idx != -1) _bookmarks[idx] = updated;
        }
      }
      
      // Delete bookmarks that were removed from remote
      for (final id in toDelete) {
        await BookmarkService.delete(id);
        _bookmarks.removeWhere((b) => b.id == id);
      }
      
      // Find changed files
      final changed = <String>[];
      for (final path in remotePaths.keys) {
        final remoteSha = remotePaths[path]!;
        final localSha = _localShaCache[path];
        if (localSha != remoteSha) {
          changed.add(path);
        }
      }
      
      // Clean up stale cache entries
      final stalePaths = _localShaCache.keys.where((p) => !remotePaths.containsKey(p)).toList();
      for (final path in stalePaths) {
        _localShaCache.remove(path);
      }
      
      DebugService.log('Sync', 'Found ${changed.length} changed/new bookmarks');
      
      // Process changed files in batches to avoid rate limiting
      const batchSize = 10; // Process 10 bookmarks at a time
      final List<Bookmark> validBookmarks = [];
      
      for (int i = 0; i < changed.length; i += batchSize) {
        final batch = changed.skip(i).take(batchSize);
        final futures = batch.map((path) async {
          try {
            // Path format: bookmarks/Folder/SubFolder/.../id.json
            // Extract folder (everything between "bookmarks/" and "/id.json")
            if (!path.startsWith('bookmarks/') || !path.endsWith('.json')) {
              DebugService.log('Sync', 'Invalid bookmark path: $path', isError: true);
              return null;
            }
            final pathWithoutPrefix = path.substring('bookmarks/'.length);
            final lastSlash = pathWithoutPrefix.lastIndexOf('/');
            if (lastSlash == -1) {
              DebugService.log('Sync', 'Invalid bookmark path: $path', isError: true);
              return null;
            }
            final folder = pathWithoutPrefix.substring(0, lastSlash);
            final bookmarkId = pathWithoutPrefix.substring(lastSlash + 1).replaceAll('.json', '');
            final githubBookmark = await _githubService.downloadBookmark(folder, bookmarkId);
            
            if (githubBookmark != null) {
              final syncedBookmark = githubBookmark.copyWith(isSynced: true);
              return syncedBookmark;
            }
          } catch (e) {
            DebugService.log('Sync', 'Failed to download bookmark from $path: $e', isError: true);
          }
          return null;
        });
        
        final results = await Future.wait(futures, eagerError: false);
        validBookmarks.addAll(results.where((b) => b != null).cast<Bookmark>());
        
        // Small delay between batches to respect rate limits
        if (i + batchSize < changed.length) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
      
      if (validBookmarks.isNotEmpty) {
        // Batch update database in single transaction
        await BookmarkService.upsertBatch(validBookmarks);
        
        // Update memory state
        int added = 0, updated = 0;
        for (final bookmark in validBookmarks) {
          final localIndex = _bookmarks.indexWhere((b) => b.id == bookmark.id);
          if (localIndex == -1) {
            _bookmarks.add(bookmark);
            added++;
          } else {
            _bookmarks[localIndex] = bookmark;
            updated++;
          }
        }
        
        DebugService.log('Sync', 'Download complete: $added added, $updated updated (batch)');
      } else {
        DebugService.log('Sync', 'Download complete: 0 added, 0 updated (batch)');
      }
      
      // Update SHA cache for all changed files
      for (final path in changed) {
        _localShaCache[path] = remotePaths[path]!;
      }
    } catch (e) {
      DebugService.log('Sync', 'Sync from GitHub failed: $e', isError: true);
    }
  }

  /// Syncs bookmarks with GitHub repository.
  /// 
  /// Downloads new bookmarks from GitHub, uploads local changes,
  /// and merges any conflicts.
  /// 
  /// Returns number of bookmarks synced
  Future<int> syncWithGitHub() async {
    if (_isSyncing) {
      DebugService.log('Bookmarks', 'Sync already in progress, skipping');
      return 0; // Prevent concurrent syncs
    }
    
    try {
      if (!_githubService.isConfigured) {
        DebugService.log('Bookmarks', 'GitHub service not configured', isError: true);
        throw Exception('GitHub not configured. Please set up GitHub sync in Settings.');
      }
      
      _isSyncing = true;
      notifyListeners();
      
      // First download changes from GitHub
      await syncFromGitHub();
      
      // Then upload local changes
      await syncToGitHub();
      
      await loadBookmarks(); // Refresh UI
      return _bookmarks.length;
    } catch (e) {
      DebugService.log('Bookmarks', 'Sync error: $e', isError: true);
      rethrow;
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  /// Uploads a single bookmark to GitHub immediately.
  /// 
  /// [bookmark] - Bookmark to upload
  Future<void> uploadToGitHub(Bookmark bookmark) async {
    try {
      if (!_githubService.isConfigured) {
        DebugService.log('Bookmarks', 'GitHub service not configured', isError: true);
        throw Exception('GitHub not configured. Please set up GitHub sync in Settings.');
      }
      
      await _githubService.uploadBookmark(bookmark);
      
      // Mark as synced
      final synced = bookmark.copyWith(isSynced: true);
      await BookmarkService.update(synced);
      final index = _bookmarks.indexWhere((b) => b.id == bookmark.id);
      if (index != -1) _bookmarks[index] = synced;
      notifyListeners();
    } catch (e) {
      DebugService.log('Bookmarks', 'Upload error: $e', isError: true);
      rethrow;
    }
  }

  /// Initialize GitHub service with auth
  void initGitHub(GitHubAuthService authService) {
    // Only initialize if auth is actually configured
    if (!authService.isConfigured) return;
    
    // Prevent multiple initializations with proper synchronization
    if (_githubInitialized) return;
    _githubInitialized = true; // Set immediately to prevent race condition
    
    _githubService.setAuth(authService);
    
    DebugService.log('Bookmarks', 'GitHub service configured: ${_githubService.isConfigured}');
    
    // Notify UI that GitHub is now configured
    notifyListeners();
    
    // Start auto-sync timer
    _startAutoSync();
    
    // Automatically start sync when GitHub becomes available
    if (_githubService.isConfigured) {
      DebugService.log('Bookmarks', 'Starting initial sync...');
      // Start sync in background without blocking UI
      Future.microtask(() async {
        try {
          // Ensure bookmarks are loaded (don't call notifyListeners twice)
          if (_bookmarks.isEmpty) {
            _bookmarks = await BookmarkService.getAll();
          }
          await syncWithGitHub();
        } catch (e) {
          DebugService.log('Bookmarks', 'Initial sync failed: $e', isError: true);
        }
      });
    } else {
      DebugService.log('Bookmarks', 'GitHub service not configured, skipping initial sync');
    }
  }

  /// Start auto-sync timer
  void _startAutoSync() {
    _syncTimer?.cancel();
    if (_syncIntervalMinutes <= 0) {
      DebugService.log('Bookmarks', 'Auto-sync disabled');
      return;
    }
    
    DebugService.log('Bookmarks', 'Auto-sync every $_syncIntervalMinutes min');
    _syncTimer = Timer.periodic(Duration(minutes: _syncIntervalMinutes), (_) {
      if (_githubService.isConfigured && !_isSyncing) {
        syncWithGitHub().catchError((e) {
          DebugService.log('Bookmarks', 'Auto-sync failed: $e', isError: true);
          return 0; // Return default value for catchError
        });
      }
    });
  }

  /// Stop auto-sync timer
  void _stopAutoSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }



  Future<void> update(Bookmark bookmark) async {
    try {
      // Get old bookmark to check folder change
      final oldBookmark = await BookmarkService.findByUrl(bookmark.url);
      
      final unsyncedBookmark = bookmark.copyWith(isSynced: false);
      await BookmarkService.update(unsyncedBookmark);
      
      // Reload to get updated filtered list and folders
      await loadBookmarks();
      
      // If folder changed, queue old file deletion
      if (_githubService.isConfigured && oldBookmark != null && oldBookmark.folder != bookmark.folder) {
        DebugService.log('Bookmarks', 'Folder changed: ${oldBookmark.folder} -> ${bookmark.folder}');
        _pendingDeletions.add('${oldBookmark.folder}\n${bookmark.id}');
      }
    } catch (e) {
      DebugService.log('Bookmarks', 'Error updating bookmark: $e', isError: true);
      rethrow;
    }
  }

  Future<void> delete(String id) async {
    try {
      // Get bookmark before deleting (needed for GitHub path)
      final bookmark = await BookmarkService.findByUrl(_bookmarks.firstWhere((b) => b.id == id).url);
      
      await BookmarkService.delete(id);
      
      // Reload to get updated filtered list and folders
      await loadBookmarks();
      
      // Queue deletion for GitHub (will be processed on sync)
      if (_githubService.isConfigured && bookmark != null) {
        _pendingDeletions.add('${bookmark.folder}\n$id');
        DebugService.log('Bookmarks', 'Queued deletion: $id');
      }
    } catch (e) {
      DebugService.log('Bookmarks', 'Error deleting bookmark: $e', isError: true);
      rethrow;
    }
  }

  /// Mark all bookmarks as synced (used after branch reset)
  Future<void> markAllSynced() async {
    for (int i = 0; i < _bookmarks.length; i++) {
      if (!_bookmarks[i].isSynced) {
        _bookmarks[i] = _bookmarks[i].copyWith(isSynced: true);
        await BookmarkService.update(_bookmarks[i]);
      }
    }
    notifyListeners();
  }

  void setFolder(String folder) {
    _selectedFolder = folder;
    // Reload bookmarks with new filter
    loadBookmarks();
  }

  void setSearch(String query) {
    _searchQuery = query;
    // Reload bookmarks with new filter
    loadBookmarks();
  }

  /// Enable or disable the browser extension server
  Future<void> setExtensionServerEnabled(bool enabled) async {
    if (_extensionServerEnabled == enabled) return;
    
    _extensionServerEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('extension_server_enabled', enabled);
    
    if (enabled) {
      _startServer();
    } else {
      _server?.stop();
      _server = null;
      DebugService.log('Bookmarks', 'Extension server stopped');
    }
    notifyListeners();
  }

  /// Set the browser extension server host (requires restart)
  Future<void> setExtensionServerHost(String host) async {
    if (_extensionServerHost == host) return;
    
    _extensionServerHost = host;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('extension_server_host', host);
    
    // Restart server if enabled
    if (_extensionServerEnabled) {
      _server?.stop();
      _server = null;
      _startServer();
    }
    notifyListeners();
  }

  /// Set the browser extension server port (requires restart)
  Future<void> setExtensionServerPort(int port) async {
    if (_extensionServerPort == port) return;
    
    _extensionServerPort = port;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('extension_server_port', port);
    
    // Restart server if enabled
    if (_extensionServerEnabled) {
      _server?.stop();
      _server = null;
      _startServer();
    }
    notifyListeners();
  }

  /// Set the browser extension API key (null to disable auth)
  Future<void> setExtensionApiKey(String? key) async {
    _extensionApiKey = key;
    final prefs = await SharedPreferences.getInstance();
    if (key == null || key.isEmpty) {
      await prefs.remove('extension_api_key');
      _extensionApiKey = null;
    } else {
      await prefs.setString('extension_api_key', key);
    }
    // Restart server to apply new key
    if (_extensionServerEnabled) {
      _server?.stop();
      _server = null;
      _startServer();
    }
    notifyListeners();
  }

  /// Generate a random API key
  String generateApiKey() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = DateTime.now().millisecondsSinceEpoch;
    return List.generate(32, (i) => chars[(random + i * 7) % chars.length]).join();
  }

  @override
  void dispose() {
    _stopAutoSync();
    _server?.stop();
    _shareSubscription?.cancel();
    super.dispose();
  }
}
