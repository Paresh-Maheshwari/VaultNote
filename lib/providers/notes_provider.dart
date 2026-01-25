// ============================================================================
// NOTES PROVIDER
// ============================================================================
//
// Main state management for VaultNote. Handles:
// - Note CRUD operations (plain text local storage)
// - GitHub sync (encrypt on upload, decrypt on download)
// - Password management with HMAC validation
// - Gist sharing
//
// ## Architecture
//
// - Notes stored as plain text in local SQLite database
// - Single master password with HMAC validation (local)
// - Encryption only for GitHub sync (not local storage)
// - Version tracking for multi-device coordination
//
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/note.dart';
import '../models/bookmark.dart';
import '../services/database_service.dart';
import '../services/bookmark_service.dart';
import '../services/github_service.dart';
import '../services/github_auth_service.dart';
import '../services/gist_service.dart';
import '../services/encryption_service.dart';
import '../services/debug_service.dart';
import '../data/welcome_notes.dart';

/// Result of syncing encryption status with GitHub
enum EncryptionSyncResult { 
  ok,              // Encryption in sync
  needsPassword,   // Remote has encryption, local doesn't - need password
  versionMismatch, // Remote version newer - password changed on another device
  disabledRemotely, // Remote disabled encryption - auto-disabled locally
  notConfigured    // GitHub not configured
}

/// Result of changing master password
enum ChangePasswordResult { 
  success, 
  wrongPassword, 
  lockedByAnotherDevice, // Another device is changing password
  error 
}

class NotesProvider extends ChangeNotifier {
  final DatabaseService _databaseService = DatabaseService();
  final GitHubService _githubService = GitHubService();
  GitHubAuthService? _authService;
  GitHubAuthService? get authService => _authService;
  List<Note> _notes = [];
  bool _isLoading = false;
  bool _isSyncing = false;
  bool _isEncryptionOperationInProgress = false;
  bool _passwordChangeDetected = false;
  Timer? _syncTimer;
  int _conflictCount = 0;
  int _syncIntervalMinutes = 2;
  String? _lastError;
  bool _suppressSyncNotifications = true; // Suppress automatic sync notifications by default
  bool _passwordVerified = false; // Track if password was verified this session
  
  // Upload lock to prevent concurrent uploads of same file
  final Set<String> _uploadingNotes = {};
  final Set<String> _updatingGists = {};
  bool _welcomeNotesCreated = false;
  
  bool get passwordChangeDetected => _passwordChangeDetected;
  String? get lastError => _lastError;
  void clearError() { _lastError = null; notifyListeners(); }
  bool get suppressSyncNotifications => _suppressSyncNotifications;
  
  /// Force clear conflict count (for UI refresh)
  void clearConflicts() {
    _conflictCount = 0;
    _lastError = null;
    notifyListeners();
  }

  /// Clear all local data (notes, cache, etc.)
  Future<void> clearAllLocalData() async {
    try {
      // Clear in-memory data
      _notes.clear();
      _localShaCache.clear();
      _conflictCount = 0;
      _lastError = null;
      _welcomeNotesCreated = false;
      
      // Clear cached tags and folders
      _invalidateCache();
      
      // Clear database
      await _databaseService.clearAllNotes();
      
      // Clear bookmarks from database
      await BookmarkService.clearAllBookmarks();
      
      // Clear SHA cache file
      await _saveShaCache();
      
      // Notify listeners
      notifyListeners();
      
      DebugService.log('Database', 'All local data cleared successfully');
    } catch (e) {
      DebugService.log('Database', 'Error clearing local data: $e', isError: true);
      rethrow;
    }
  }
  
  // SHA cache for incremental sync (persisted to SharedPreferences)
  // Key: file path on GitHub, Value: SHA hash
  // Used to detect which files changed since last sync
  Map<String, String> _localShaCache = {};
  
  Future<void> _loadShaCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString('sha_cache');
      if (json != null && json.isNotEmpty) {
        final decoded = jsonDecode(json);
        if (decoded is Map) {
          _localShaCache = Map<String, String>.from(decoded);
          DebugService.log('Cache', 'Loaded ${_localShaCache.length} SHA entries');
        } else {
          DebugService.log('Cache', 'Invalid SHA cache format, resetting', isError: true);
          _localShaCache = {};
        }
      }
    } catch (e) {
      DebugService.log('Cache', 'Failed to load SHA cache: $e', isError: true);
      _localShaCache = {};
    }
  }
  
  Future<void> _saveShaCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('sha_cache', jsonEncode(_localShaCache));
    } catch (e) {
      DebugService.log('Cache', 'Failed to save SHA cache: $e', isError: true);
    }
  }
  
  // Cached values for performance
  List<String>? _cachedTags;
  List<String>? _cachedFolders;

  List<Note> get notes => _notes;
  bool get isLoading => _isLoading;
  bool get isSyncing => _isSyncing;
  int get conflictCount => _conflictCount;
  bool get isGitHubConfigured => _authService?.isConfigured ?? false;
  String? get repoOwner => _authService?.owner;
  String? get repoName => _authService?.repo;
  String? get repoBranch => _authService?.branch;
  int get syncIntervalMinutes => _syncIntervalMinutes;
  
  List<String> get allTags {
    _cachedTags ??= _notes.expand((n) => n.tags).toSet().toList()..sort();
    return _cachedTags!;
  }
  
  List<String> get allFolders {
    _cachedFolders ??= _notes.map((n) => n.folder).where((f) => f.isNotEmpty).toSet().toList()..sort();
    return _cachedFolders!;
  }
  
  void _invalidateCache() {
    _cachedTags = null;
    _cachedFolders = null;
  }

  /// Load notes from database and check for incomplete operations
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _syncIntervalMinutes = prefs.getInt('sync_interval') ?? 2;
    _suppressSyncNotifications = prefs.getBool('suppress_sync_notifications') ?? true;
    await _loadShaCache();
    
    // Check for incomplete password change operations (crash recovery)
    await _checkForIncompleteOperations();
    
    _authService = GitHubAuthService();
    await _authService!.loadConfig();
    if (_authService!.isConfigured) {
      _githubService.setAuth(_authService!);
      // Check encryption status before starting sync
      final encStatus = await syncEncryptionStatus();
      if (encStatus == EncryptionSyncResult.ok) {
        _startAutoSync();
      }
    }
    await loadNotes();
    
    // Clear SHA cache if database is empty but cache has entries (fresh install with stale cache)
    if (_notes.isEmpty && _localShaCache.isNotEmpty) {
      DebugService.log('Sync', 'Clearing stale SHA cache (empty DB but ${_localShaCache.length} cached)');
      _localShaCache.clear();
      await _saveShaCache();
    }
  }

  /// Check for incomplete password change operations and recover
  Future<void> _checkForIncompleteOperations() async {
    if (!isGitHubConfigured) return;
    
    try {
      // Always check GitHub for lock status (locks are time-sensitive)
      final remoteConfig = await _githubService.getEncryptionVersion();
      if (remoteConfig == null) return;
      
      final isLocked = remoteConfig['locked'] == true;
      final lockDevice = remoteConfig['device'];
      final lockTimestamp = remoteConfig['timestamp'];
      
      if (isLocked) {
        DebugService.log('Encryption', 'Detected locked state on startup');
        
        // Check if this device created the lock
        final currentDeviceId = EncryptionService.createVersionLock()['device'];
        
        if (lockDevice == currentDeviceId) {
          // This device created the lock - likely crashed during password change
          DebugService.log('Encryption', 'Detected incomplete password change from this device');
          
          // Check if lock is stale
          if (lockTimestamp != null) {
            final lockTime = DateTime.tryParse(lockTimestamp);
            if (lockTime != null && DateTime.now().difference(lockTime).inHours > 1) {
              // Stale lock from this device - force unlock
              DebugService.log('Encryption', 'Removing stale lock from crashed operation');
              await _githubService.saveEncryptionVersion(
                version: remoteConfig['version'], 
                enabled: remoteConfig['enabled'],
                locked: false
              );
              
              // Update database with unlocked state
              final repoKey = '${_authService?.owner}/${_authService?.repo}';
              final localVersion = await EncryptionService.getEncryptionVersion();
              final localEnabled = await EncryptionService.isMasterEncryptionEnabled();
              
              await _databaseService.updateEncryptionVersions(
                repoKey: repoKey,
                localVersion: localVersion,
                remoteVersion: remoteConfig['version'] ?? 0,
                localEnabled: localEnabled,
                remoteEnabled: remoteConfig['enabled'] ?? false,
              );
            }
          }
        } else {
          // Another device has the lock
          final lockData = {
            'locked': true,
            'device': lockDevice,
            'timestamp': lockTimestamp,
          };
          
          if (EncryptionService.isLockExpired(lockData)) {
            DebugService.log('Encryption', 'Detected expired lock from another device');
            // Could show user option to force unlock
          }
        }
      }
      
      // Check for version mismatch (password changed on another device)
      final localVersion = await EncryptionService.getEncryptionVersion();
      final remoteVersion = remoteConfig['version'] ?? 0;
      
      if (remoteVersion > localVersion) {
        DebugService.log('Encryption', 'Detected password change on another device (remote: v$remoteVersion, local: v$localVersion)');
        _passwordChangeDetected = true;
      }
      
    } catch (e) {
      DebugService.log('Encryption', 'Crash recovery check failed: $e', isError: true);
    }
  }



  void _startAutoSync() {
    _syncTimer?.cancel();
    if (_syncIntervalMinutes <= 0) {
      DebugService.log('Sync', 'Auto-sync disabled');
      return;
    }
    DebugService.log('Sync', 'Auto-sync every $_syncIntervalMinutes min');
    _syncTimer = Timer.periodic(Duration(minutes: _syncIntervalMinutes), (_) {
      if (isGitHubConfigured && !_isSyncing) {
        syncAll().catchError((e) {
          DebugService.log('Sync', 'Auto-sync failed: $e', isError: true);
        });
      }
    });
  }

  Future<void> setSyncInterval(int minutes) async {
    _syncIntervalMinutes = minutes;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('sync_interval', minutes);
    _startAutoSync();
    notifyListeners();
  }

  void _stopAutoSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  Future<EncryptionSyncResult> initGitHub(GitHubAuthService authService) async {
    _authService = authService;
    _githubService.setAuth(authService);
    
    // Check GitHub encryption status FIRST
    final syncResult = await syncEncryptionStatus();
    
    // Only start auto-sync and sync if we have password (or no encryption)
    if (syncResult == EncryptionSyncResult.ok) {
      _startAutoSync();
      syncAll();
    }
    
    notifyListeners();
    return syncResult;
  }

  /// Sync encryption status between local device and GitHub.
  /// 
  /// Checks version numbers to detect password changes on other devices.
  /// 
  /// Returns:
  /// - ok: Versions match, safe to proceed
  /// - needsPassword: Remote has encryption, local doesn't (new device setup)
  /// - versionMismatch: Remote version newer (password changed on another device)
  /// - notConfigured: GitHub not set up
  Future<EncryptionSyncResult> syncEncryptionStatus() async {
    if (!isGitHubConfigured) return EncryptionSyncResult.notConfigured;
    
    final repoKey = '${_authService?.owner}/${_authService?.repo}';
    final localMasterEnabled = await EncryptionService.isMasterEncryptionEnabled();
    final localVersion = await EncryptionService.getEncryptionVersion();
    final hasSessionPassword = EncryptionService.sessionPassword != null;
    
    DebugService.log('Encryption', 'Local: v$localVersion enabled=$localMasterEnabled session=$hasSessionPassword');
    
    // Check database cache first (set after clearGitHubAndReupload)
    final cachedVersions = await _databaseService.getEncryptionVersions(repoKey);
    int remoteVersion;
    bool remoteHasEncryption;
    
    if (cachedVersions != null && cachedVersions['remote_version'] == localVersion) {
      // Cache matches local - use it (avoids stale GitHub API response after branch reset)
      remoteVersion = cachedVersions['remote_version'] as int;
      remoteHasEncryption = cachedVersions['remote_enabled'] as bool? ?? false;
    } else {
      // Fetch from GitHub
      final remoteConfig = await _githubService.getEncryptionVersion();
      remoteHasEncryption = remoteConfig != null && (remoteConfig['enabled'] as bool? ?? false);
      remoteVersion = remoteConfig?['version'] as int? ?? 0;
    }
    
    DebugService.log('Encryption', 'GitHub: v$remoteVersion enabled=$remoteHasEncryption');
    
    // Handle sync cases
    if (remoteHasEncryption && !localMasterEnabled) {
      DebugService.log('Encryption', 'Result: needsPassword (remote enabled, local not)');
      // Store current state
      await _databaseService.updateEncryptionVersions(
        repoKey: repoKey,
        localVersion: localVersion,
        remoteVersion: remoteVersion,
        localEnabled: localMasterEnabled,
        remoteEnabled: remoteHasEncryption,
      );
      return EncryptionSyncResult.needsPassword;
    }
    
    // Both have encryption but no session password (app restarted)
    if (remoteHasEncryption && localMasterEnabled && !hasSessionPassword) {
      await _databaseService.updateEncryptionVersions(
        repoKey: repoKey,
        localVersion: localVersion,
        remoteVersion: remoteVersion,
        localEnabled: localMasterEnabled,
        remoteEnabled: remoteHasEncryption,
      );
      return EncryptionSyncResult.needsPassword;
    }
    
    // Both have encryption with session password - verify it works
    if (remoteHasEncryption && localMasterEnabled && hasSessionPassword && !_passwordVerified) {
      DebugService.log('Sync', 'Verifying session password can decrypt remote notes...');
      final canDecrypt = await verifyPasswordWithRemoteNote(EncryptionService.sessionPassword!);
      DebugService.log('Sync', 'Password verification result: $canDecrypt');
      if (!canDecrypt) {
        DebugService.log('Sync', 'Session password cannot decrypt remote notes');
        await _databaseService.updateEncryptionVersions(
          repoKey: repoKey,
          localVersion: localVersion,
          remoteVersion: remoteVersion,
          localEnabled: localMasterEnabled,
          remoteEnabled: remoteHasEncryption,
        );
        return EncryptionSyncResult.needsPassword;
      }
      _passwordVerified = true;
    }
    
    if (remoteHasEncryption && localMasterEnabled && remoteVersion > localVersion) {
      DebugService.log('Encryption', 'Result: versionMismatch (remote v$remoteVersion > local v$localVersion)');
      // Store current state
      await _databaseService.updateEncryptionVersions(
        repoKey: repoKey,
        localVersion: localVersion,
        remoteVersion: remoteVersion,
        localEnabled: localMasterEnabled,
        remoteEnabled: remoteHasEncryption,
      );
      return EncryptionSyncResult.versionMismatch;
    }
    
    // Upload if needed
    int finalRemoteVersion = remoteVersion;
    bool finalRemoteEnabled = remoteHasEncryption;
    
    if (localMasterEnabled && !remoteHasEncryption) {
      DebugService.log('Sync', 'Uploading encryption version to GitHub');
      await _githubService.saveEncryptionVersion(version: localVersion, enabled: true);
      finalRemoteVersion = localVersion;
      finalRemoteEnabled = true;
      
      // Force re-upload all notes with encryption
      await _markAllNotesForReupload();
    }
    
    if (localVersion > remoteVersion) {
      DebugService.log('Sync', 'Local version higher, uploading v$localVersion to GitHub');
      await _githubService.saveEncryptionVersion(version: localVersion, enabled: localMasterEnabled);
      finalRemoteVersion = localVersion;
      finalRemoteEnabled = localMasterEnabled;
      
      // If encryption state changed, force re-upload all notes
      if (localMasterEnabled != remoteHasEncryption) {
        await _markAllNotesForReupload();
      }
    } else if (remoteVersion > localVersion && !localMasterEnabled && !remoteHasEncryption) {
      DebugService.log('Sync', 'Syncing to higher disabled version v$remoteVersion');
      await EncryptionService.setEncryptionVersion(remoteVersion);
    }
    
    // Store final state in database
    await _databaseService.updateEncryptionVersions(
      repoKey: repoKey,
      localVersion: localVersion,
      remoteVersion: finalRemoteVersion,
      localEnabled: localMasterEnabled,
      remoteEnabled: finalRemoteEnabled,
    );
    
    return EncryptionSyncResult.ok;
  }

  /// Verify password by trying to decrypt a note from GitHub.
  Future<bool> verifyPasswordWithRemoteNote(String password) async {
    try {
      final content = await _githubService.fetchFirstNoteContent();
      if (content == null) return true; // No notes
      
      // Extract note content (after frontmatter)
      final lines = content.split('\n');
      int contentStart = 0;
      bool inFrontmatter = false;
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].trim() == '---' && i == 0) { inFrontmatter = true; continue; }
        if (lines[i].trim() == '---' && inFrontmatter) { contentStart = i + 1; break; }
      }
      final noteContent = lines.sublist(contentStart).join('\n').trim();
      
      if (!EncryptionService.isEncrypted(noteContent)) return true; // Not encrypted
      
      final decrypted = EncryptionService.decrypt(noteContent, password);
      return decrypted != null && !EncryptionService.isEncrypted(decrypted);
    } catch (e) {
      DebugService.log('Sync', 'Password verify failed: $e', isError: true);
      return false;
    }
  }

  /// Setup local encryption from remote version (new device setup).
  /// Returns false if password is wrong.
  Future<bool> setupEncryptionFromRemote(String password) async {
    final remoteConfig = await _githubService.getEncryptionVersion();
    if (remoteConfig == null) return false;
    
    // Verify password can decrypt remote notes
    final canDecrypt = await verifyPasswordWithRemoteNote(password);
    if (!canDecrypt) {
      DebugService.log('Encryption', 'Password verification failed');
      return false;
    }
    
    // Setup local encryption with password
    await EncryptionService.enableMasterEncryption(password);
    
    // Copy remote version to local storage
    final remoteVersion = remoteConfig['version'] as int? ?? 1;
    await EncryptionService.setEncryptionVersion(remoteVersion);
    
    // Set session password for GitHub sync
    EncryptionService.setSessionPassword(password);
    
    // Store encryption state in database
    final repoKey = '${_authService?.owner}/${_authService?.repo}';
    final localVersion = await EncryptionService.getEncryptionVersion();
    final localEnabled = await EncryptionService.isMasterEncryptionEnabled();
    
    await _databaseService.updateEncryptionVersions(
      repoKey: repoKey,
      localVersion: localVersion,
      remoteVersion: remoteVersion,
      localEnabled: localEnabled,
      remoteEnabled: remoteConfig['enabled'] ?? false,
    );
    
    DebugService.log('Sync', 'Local encryption setup from remote v$remoteVersion');
    
    _passwordChangeDetected = false;
    _passwordVerified = true;
    _startAutoSync();
    syncAll();
    notifyListeners();
    return true;
  }
  
  /// Handle password changed on another device.
  Future<bool> handleRemotePasswordChange(String newPassword) async {
    // Verify password by attempting to enable encryption
    try {
      await EncryptionService.enableMasterEncryption(newPassword);
      await setupEncryptionFromRemote(newPassword);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Check if remote GitHub has encryption enabled.
  Future<bool> isRemoteEncryptionEnabled() async {
    final repoKey = '${_authService?.owner}/${_authService?.repo}';
    
    // Try database first
    final stored = await _databaseService.getEncryptionVersions(repoKey);
    if (stored != null) {
      return stored['remote_enabled'] as bool;
    }
    
    // Fallback to GitHub (first time)
    final remoteConfig = await _githubService.getEncryptionVersion();
    return remoteConfig != null && (remoteConfig['enabled'] as bool? ?? false);
  }

  /// Change master password.
  /// 
  /// Multi-device safe: Uses lock file on GitHub to prevent concurrent changes.
  /// 
  /// Flow:
  /// 1. Verify old password
  /// 2. Lock encryption config on GitHub (prevents other devices from changing)
  /// 3. Re-encrypt all notes: decrypt with old, encrypt with new
  /// 4. Update local verify token and increment version
  /// 5. Upload new config to GitHub (unlocks automatically)
  /// 6. Sync re-encrypted notes
  /// 
  /// Returns:
  /// - success: Password changed
  /// - wrongPassword: Old password incorrect
  /// - lockedByAnotherDevice: Another device is changing password
  /// Change master password following simplified architecture flow.
  /// Steps: Verify current → Update HMAC → Increment version → Lock → Sync to GitHub
  /// Includes comprehensive failback handling for all failure scenarios.
  Future<ChangePasswordResult> changePassword(String oldPassword, String newPassword) async {
    // Step 1: Verify current password using HMAC validation (local)
    final valid = await EncryptionService.verifyMasterPassword(oldPassword);
    if (!valid) return ChangePasswordResult.wrongPassword;
    
    // Step 2: Check if another device is changing password
    if (isGitHubConfigured) {
      final remoteConfig = await _githubService.getEncryptionVersion();
      if (remoteConfig != null && remoteConfig['locked'] == true) {
        // Check if lock is stale (older than 1 hour)
        if (EncryptionService.isLockExpired(remoteConfig)) {
          DebugService.log('Encryption', 'Detected stale lock, attempting force unlock');
          // Force unlock stale lock
          try {
            await _githubService.saveEncryptionVersion(
              version: remoteConfig['version'], 
              enabled: remoteConfig['enabled'],
              locked: false
            );
            
            // Update database with unlocked state
            final repoKey = '${_authService?.owner}/${_authService?.repo}';
            final localVersion = await EncryptionService.getEncryptionVersion();
            final localEnabled = await EncryptionService.isMasterEncryptionEnabled();
            
            await _databaseService.updateEncryptionVersions(
              repoKey: repoKey,
              localVersion: localVersion,
              remoteVersion: remoteConfig['version'] ?? 0,
              localEnabled: localEnabled,
              remoteEnabled: remoteConfig['enabled'] ?? false,
            );
          } catch (e) {
            DebugService.log('Encryption', 'Failed to force unlock stale lock: $e', isError: true);
            return ChangePasswordResult.lockedByAnotherDevice;
          }
        } else {
          return ChangePasswordResult.lockedByAnotherDevice;
        }
      }
    }
    
    _isEncryptionOperationInProgress = true;
    notifyListeners();
    
    DebugService.log('Encryption', 'Starting password change...');
    
    // Store original state for rollback
    final originalPassword = oldPassword;
    String? originalHash;
    int? originalVersion;
    
    try {
      // Store original state
      originalHash = await const FlutterSecureStorage().read(key: 'password_hash');
      originalVersion = await EncryptionService.getEncryptionVersion();
      
      // Step 3: Generate new HMAC hash and store locally
      try {
        await EncryptionService.changeMasterPassword(newPassword);
        DebugService.log('Encryption', 'HMAC hash updated locally');
      } catch (e) {
        DebugService.log('Encryption', 'HMAC update failed: $e', isError: true);
        throw Exception('Local HMAC update failed');
      }
      
      // Step 4: Create lock on GitHub with new version
      final newVersion = await EncryptionService.getEncryptionVersion();
      if (isGitHubConfigured) {
        try {
          final lockData = EncryptionService.createVersionLock();
          await _githubService.saveEncryptionVersion(
            version: newVersion, 
            enabled: true,
            locked: true, 
            deviceId: lockData['device']
          );
          DebugService.log('Encryption', 'GitHub lock created successfully');
        } catch (e) {
          DebugService.log('Encryption', 'Lock creation failed: $e', isError: true);
          // Rollback HMAC hash
          if (originalHash != null) {
            await const FlutterSecureStorage().write(key: 'password_hash', value: originalHash);
          }
          await EncryptionService.setEncryptionVersion(originalVersion);
          EncryptionService.setSessionPassword(originalPassword);
          throw Exception('GitHub lock creation failed');
        }
      }
      
      // Step 5: Notes stay plain text locally - no re-encryption needed!
      // Mark all notes for re-sync to GitHub (will encrypt with new password)
      try {
        for (int i = 0; i < _notes.length; i++) {
          final note = _notes[i];
          final updated = note.copyWith(isSynced: false);
          await _databaseService.updateNote(updated);
          _notes[i] = updated;
        }
        DebugService.log('Encryption', 'Notes marked for re-sync');
      } catch (e) {
        DebugService.log('Encryption', 'Note marking failed: $e', isError: true);
        // Continue - this is not critical, sync will handle it
      }
      
      // Step 6: Remove lock
      if (isGitHubConfigured) {
        try {
          await _githubService.saveEncryptionVersion(
            version: newVersion, 
            locked: false
          );
          DebugService.log('Encryption', 'GitHub lock removed');
        } catch (e) {
          DebugService.log('Encryption', 'Unlock failed: $e', isError: true);
          // Don't rollback - password changed successfully locally
          // Other devices will detect version change and prompt for new password
          // Keep retrying unlock in background
          _retryUnlock(newVersion);
        }
      }
      
      DebugService.log('Encryption', 'Password changed to v$newVersion');
      
      _isEncryptionOperationInProgress = false;
      notifyListeners();
      
      // Step 7: Sync notes to GitHub (will encrypt with new password)
      if (isGitHubConfigured) {
        try {
          await syncToGitHub();
          DebugService.log('Encryption', 'Notes synced with new password');
        } catch (e) {
          DebugService.log('Encryption', 'Sync failed after password change: $e', isError: true);
          // Don't fail - password change was successful
          // Notes will sync on next attempt
        }
      }
      
      return ChangePasswordResult.success;
      
    } catch (e) {
      DebugService.log('Encryption', 'Password change failed: $e', isError: true);
      
      // Comprehensive rollback based on failure point
      await _rollbackPasswordChange(originalPassword, originalHash, originalVersion);
      
      _isEncryptionOperationInProgress = false;
      notifyListeners();
      return ChangePasswordResult.error;
    }
  }

  /// Rollback password change on failure
  Future<void> _rollbackPasswordChange(String originalPassword, String? originalHash, int? originalVersion) async {
    DebugService.log('Encryption', 'Rolling back password change...');
    
    try {
      // Restore original HMAC hash
      if (originalHash != null) {
        await const FlutterSecureStorage().write(key: 'password_hash', value: originalHash);
        DebugService.log('Encryption', 'HMAC hash restored');
      }
      
      // Restore original version
      if (originalVersion != null) {
        await EncryptionService.setEncryptionVersion(originalVersion);
        DebugService.log('Encryption', 'Version restored to v$originalVersion');
      }
      
      // Restore session password
      EncryptionService.setSessionPassword(originalPassword);
      
      // Force unlock GitHub if possible
      if (isGitHubConfigured) {
        try {
          final version = originalVersion ?? await EncryptionService.getEncryptionVersion();
          await _githubService.saveEncryptionVersion(version: version, locked: false);
          DebugService.log('Encryption', 'GitHub unlocked during rollback');
        } catch (e) {
          DebugService.log('Encryption', 'Failed to unlock during rollback: $e', isError: true);
        }
      }
      
    } catch (e) {
      DebugService.log('Encryption', 'Rollback failed: $e', isError: true);
    }
  }

  /// Retry unlock in background for failed unlock scenarios
  Future<void> _retryUnlock(int version) async {
    int attempts = 0;
    const maxAttempts = 5;
    const retryDelay = Duration(seconds: 30);
    
    while (attempts < maxAttempts) {
      await Future.delayed(retryDelay);
      attempts++;
      
      try {
        await _githubService.saveEncryptionVersion(version: version, locked: false);
        DebugService.log('Encryption', 'Retry unlock successful after $attempts attempts');
        return;
      } catch (e) {
        DebugService.log('Encryption', 'Retry unlock attempt $attempts failed: $e', isError: true);
      }
    }
    
    DebugService.log('Encryption', 'All retry unlock attempts failed', isError: true);
  }

  /// Disable master encryption - notes become plain text locally.
  Future<ChangePasswordResult> disableEncryptionAndSync(String password) async {
    // Step 1: Verify password
    final valid = await EncryptionService.verifyMasterPassword(password);
    if (!valid) return ChangePasswordResult.wrongPassword;
    
    // Step 2: Check if another device is changing password (locked)
    if (isGitHubConfigured) {
      final remoteConfig = await _githubService.getEncryptionVersion();
      if (remoteConfig != null && remoteConfig['locked'] == true) {
        if (!EncryptionService.isLockExpired(remoteConfig)) {
          return ChangePasswordResult.lockedByAnotherDevice;
        }
      }
    }
    
    _isEncryptionOperationInProgress = true;
    notifyListeners();
    
    DebugService.log('Encryption', 'Disabling master encryption...');
    
    try {
      // Get current version and increment
      final currentVersion = await EncryptionService.getEncryptionVersion();
      final newVersion = currentVersion + 1;
      
      // Disable encryption locally
      await EncryptionService.disableMasterEncryption();
      
      // Update GitHub encryption.json with new version and enabled: false
      if (isGitHubConfigured) {
        await _githubService.saveEncryptionVersion(version: newVersion, enabled: false);
        DebugService.log('Encryption', 'GitHub encryption config updated to v$newVersion (disabled)');
        
        // Update database
        final repoKey = '${_authService?.owner}/${_authService?.repo}';
        await _databaseService.updateEncryptionVersions(
          repoKey: repoKey,
          localVersion: newVersion,
          remoteVersion: newVersion,
          localEnabled: false,
          remoteEnabled: false,
        );
      }
      
      // Mark all notes for re-sync to upload as unencrypted
      for (int i = 0; i < _notes.length; i++) {
        final note = _notes[i];
        final updated = note.copyWith(isSynced: false);
        await _databaseService.updateNote(updated);
        _notes[i] = updated;
      }
      DebugService.log('Encryption', 'Notes marked for unencrypted re-upload');
      
      _isEncryptionOperationInProgress = false;
      notifyListeners();
      
      // Sync notes to GitHub (will be unencrypted)
      if (isGitHubConfigured) {
        await syncToGitHub();
        DebugService.log('Encryption', 'Notes re-uploaded as unencrypted');
      }
      
      return ChangePasswordResult.success;
    } catch (e) {
      DebugService.log('Encryption', 'Disable encryption failed: $e', isError: true);
      _isEncryptionOperationInProgress = false;
      notifyListeners();
      return ChangePasswordResult.error;
    }
  }


  /// Update GitHub branch for sync.
  Future<void> updateBranch(String branch) async {
    await _authService?.updateBranch(branch);
    notifyListeners();
  }

  /// Fetch available branches from GitHub repository.
  Future<List<String>> fetchBranches() async {
    final auth = _authService;
    if (auth == null || !auth.isConfigured || auth.owner == null || auth.repo == null) return [];
    return await auth.fetchBranches(auth.owner!, auth.repo!);
  }

  /// Disconnect from GitHub.
  /// Clears auth config, SHA cache, and marks all notes for re-sync.
  Future<void> disconnectGitHub() async {
    _stopAutoSync();
    
    // Clear encryption versions for current repo
    if (_authService != null) {
      final repoKey = '${_authService?.owner}/${_authService?.repo}';
      await _databaseService.clearEncryptionVersions(repoKey);
    }
    
    await _authService?.clearConfig();
    _authService = null;
    // Clear SHA cache (stale for new repo)
    _localShaCache.clear();
    await _saveShaCache();
    // Reset all notes sync status so they sync with new account
    await _resetAllSyncStatus();
    notifyListeners();
  }

  /// Mark all notes as unsynced (for re-upload to new repo).
  Future<void> _resetAllSyncStatus() async {
    for (int i = 0; i < _notes.length; i++) {
      if (_notes[i].isSynced) {
        final updated = _notes[i].copyWith(isSynced: false);
        await _databaseService.updateNote(updated);
        _notes[i] = updated;
      }
    }
  }

  /// Mark all notes for re-upload (when encryption changes).
  Future<void> _markAllNotesForReupload() async {
    DebugService.log('Sync', 'Marking all notes for re-upload due to encryption change');
    for (int i = 0; i < _notes.length; i++) {
      final updated = _notes[i].copyWith(isSynced: false);
      await _databaseService.updateNote(updated);
      _notes[i] = updated;
    }
    // Clear SHA cache so all files are treated as changed
    _localShaCache.clear();
    await _saveShaCache();
    notifyListeners();
  }

  /// Force re-sync all notes to GitHub.
  Future<void> markAllForSync() async {
    await _resetAllSyncStatus();
    notifyListeners();
  }

  /// Force encryption sync and re-upload all notes.
  Future<void> forceEncryptionSync() async {
    if (!isGitHubConfigured) return;
    
    DebugService.log('Sync', 'Forcing encryption sync and note re-upload');
    
    // Clear database cache to force fresh GitHub check
    final repoKey = '${_authService?.owner}/${_authService?.repo}';
    await _databaseService.clearEncryptionVersions(repoKey);
    
    // Mark all notes for re-upload
    await _markAllNotesForReupload();
    
    // Force sync
    await syncAll();
  }

  /// Load all notes from local database.
  Future<void> loadNotes() async {
    _isLoading = true;
    notifyListeners();
    
    _notes = await _databaseService.getAllNotes();
    
    // Create welcome notes on first launch (empty database)
    if (_notes.isEmpty && !_welcomeNotesCreated) {
      _welcomeNotesCreated = true;
      await _createWelcomeNotes();
      _notes = await _databaseService.getAllNotes();
    }
    
    _invalidateCache();
    final sharedCount = _notes.where((n) => n.isSharedAsGist).length;
    DebugService.log('Notes', 'Loaded ${_notes.length} notes ($sharedCount shared as gists)');
    
    // Clear conflicts if all notes are synced
    final unsyncedCount = _notes.where((n) => !n.isSynced).length;
    if (unsyncedCount == 0 && _conflictCount > 0) {
      DebugService.log('Sync', 'All notes synced - clearing stale conflicts');
      _conflictCount = 0;
      _lastError = null;
    }
    
    _isLoading = false;
    notifyListeners();
  }

  /// Create welcome notes for first-time users
  Future<void> _createWelcomeNotes() async {
    try {
      final welcomeNotes = WelcomeNotes.createWelcomeNotes();
      for (final note in welcomeNotes) {
        await _databaseService.insertNote(note);
      }
      DebugService.log('Notes', 'Created ${welcomeNotes.length} welcome notes for first launch');
    } catch (e) {
      DebugService.log('Notes', 'Error creating welcome notes: $e', isError: true);
    }
  }

  /// Add a new note to database and sync to GitHub.
  Future<void> addNote(Note note) async {
    await _databaseService.insertNote(note);
    _notes.add(note);
    _invalidateCache();
    notifyListeners();
    // Sync to GitHub immediately
    if (isGitHubConfigured) {
      final success = await _githubService.uploadNote(note);
      if (success) {
        final synced = note.copyWith(isSynced: true);
        await _databaseService.updateNote(synced);
        final index = _notes.indexWhere((n) => n.id == note.id);
        if (index != -1) _notes[index] = synced;
        notifyListeners();
      }
    }
  }

  /// Update existing note in database and sync to GitHub.
  /// Also schedules gist update if note is shared.
  Future<void> updateNote(Note note) async {
    final oldNote = _notes.firstWhere((n) => n.id == note.id, orElse: () => note);
    
    // Preserve gist info from old note if new note doesn't have it
    Note updatedNote = note;
    if (oldNote.isSharedAsGist && !note.isSharedAsGist) {
      updatedNote = note.copyWith(
        gistId: oldNote.gistId,
        gistUrl: oldNote.gistUrl,
        gistPublic: oldNote.gistPublic,
      );
      DebugService.log('Gist', 'Preserved gist info during note update: ${oldNote.gistId}');
    }
    
    await _databaseService.updateNote(updatedNote);
    final index = _notes.indexWhere((n) => n.id == note.id);
    if (index != -1) {
      _notes[index] = updatedNote;
      _invalidateCache();
      notifyListeners();
    }
    
    // Schedule gist update if content changed
    if (isNoteShared(updatedNote.id) && oldNote.content != updatedNote.content) {
      _scheduleGistUpdate(updatedNote.id);
    }
    
    // Sync to GitHub (skip if already uploading)
    if (isGitHubConfigured && !_uploadingNotes.contains(updatedNote.id)) {
      if (oldNote.folder != updatedNote.folder) {
        // Folder changed - delete old path, create new
        _githubService.deleteNote(oldNote.id);
      }
      _uploadingNotes.add(updatedNote.id);
      _githubService.uploadNote(updatedNote).then((_) {
        _uploadingNotes.remove(updatedNote.id);
      });
    }
  }

  /// Delete note from database and GitHub.
  /// Also deletes associated gist if shared.
  Future<void> deleteNote(String id) async {
    // Get note before deleting (needed for GitHub path)
    final noteToDelete = _notes.firstWhere((n) => n.id == id, orElse: () => Note(
      id: id, 
      title: 'Unknown', 
      content: '', 
      createdAt: DateTime.now(), 
      updatedAt: DateTime.now(),
      isFavorite: false,
    ));
    
    // Delete associated gist first if note is shared
    if (isNoteShared(id)) {
      await unshareGist(id);
    }
    
    // Delete from local database
    await _databaseService.deleteNote(id);
    _notes.removeWhere((note) => note.id == id);
    _invalidateCache();
    
    // Delete from GitHub
    if (_githubService.isConfigured) {
      _githubService.setNoteForDeletion(noteToDelete);
      final success = await _githubService.deleteNote(id);
      _githubService.setNoteForDeletion(null);
      
      if (!success) {
        DebugService.log('Notes', 'Failed to delete note $id from GitHub', isError: true);
      }
    }
    
    notifyListeners();
  }

  /// Toggle pin status of a note.
  /// Toggle pin status of a note.
  Future<void> togglePin(String id) async {
    final index = _notes.indexWhere((n) => n.id == id);
    if (index != -1) {
      final updated = _notes[index].copyWith(
        isPinned: !_notes[index].isPinned,
        updatedAt: DateTime.now(),
        isSynced: false,
      );
      await _databaseService.updateNote(updated);
      _notes[index] = updated;
      notifyListeners();
      // Upload single note to GitHub
      if (isGitHubConfigured && !_uploadingNotes.contains(id)) {
        _uploadingNotes.add(id);
        _githubService.uploadNote(updated).then((_) {
          _uploadingNotes.remove(id);
        });
      }
    }
  }

  /// Toggle favorite status of a note.
  Future<void> toggleFavorite(String id) async {
    final index = _notes.indexWhere((n) => n.id == id);
    if (index != -1) {
      final updated = _notes[index].copyWith(
        isFavorite: !_notes[index].isFavorite,
        updatedAt: DateTime.now(),
        isSynced: false,
      );
      await _databaseService.updateNote(updated);
      _notes[index] = updated;
      notifyListeners();
      // Upload single note to GitHub
      if (isGitHubConfigured && !_uploadingNotes.contains(id)) {
        _uploadingNotes.add(id);
        _githubService.uploadNote(updated).then((_) {
          _uploadingNotes.remove(id);
        });
      }
    }
  }

  /// Search notes by title, content, tags, or folder.
  List<Note> searchNotes(String query) {
    if (query.isEmpty) return _notes;
    final q = query.toLowerCase();
    return _notes.where((note) =>
        note.title.toLowerCase().contains(q) ||
        note.content.toLowerCase().contains(q) ||
        note.tags.any((tag) => tag.toLowerCase().contains(q)) ||
        note.folder.toLowerCase().contains(q)
    ).toList();
  }

  /// Filter notes by tag.
  List<Note> filterByTag(String tag) {
    return _notes.where((note) => note.tags.contains(tag)).toList();
  }

  /// Sort notes by title, created date, or updated date.
  List<Note> sortNotes(List<Note> notes, String sortBy, bool ascending) {
    final sorted = List<Note>.from(notes);
    switch (sortBy) {
      case 'title':
        sorted.sort((a, b) => a.title.compareTo(b.title));
        break;
      case 'created':
        sorted.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        break;
      case 'updated':
      default:
        sorted.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    }
    return ascending ? sorted : sorted.reversed.toList();
  }

  /// Upload unsynced notes to GitHub.
  /// 
  /// Checks encryption status first to detect password changes.
  /// Uploads notes sequentially to avoid conflicts.
  Future<void> syncToGitHub() async {
    if (!_githubService.isConfigured || _isSyncing || _isEncryptionOperationInProgress) return;
    
    // Check for password changes before uploading
    final encStatus = await syncEncryptionStatus();
    if (encStatus == EncryptionSyncResult.versionMismatch || 
        encStatus == EncryptionSyncResult.needsPassword) {
      _passwordChangeDetected = true;
      notifyListeners();
      return;
    }
    
    _isSyncing = true;
    notifyListeners();

    final unsynced = _notes.where((n) => !n.isSynced).toList();
    DebugService.log('Sync', 'Starting upload: ${unsynced.length} notes to sync');
    
    if (unsynced.isEmpty) {
      _isSyncing = false;
      notifyListeners();
      return;
    }
    
    // Get SHAs for notes we're uploading
    final shas = await _githubService.getShasForNotes(unsynced);
    
    int success = 0;
    
    // Upload sequentially to avoid conflicts
    for (final note in unsynced) {
      if (_uploadingNotes.contains(note.id)) continue;
      
      _uploadingNotes.add(note.id);
      try {
        final uploaded = await _githubService.uploadNoteWithSha(note, shas);
        if (uploaded) {
          final synced = note.copyWith(isSynced: true);
          await _databaseService.updateNote(synced);
          final index = _notes.indexWhere((n) => n.id == note.id);
          if (index != -1) _notes[index] = synced;
          success++;
        }
      } finally {
        _uploadingNotes.remove(note.id);
      }
    }

    DebugService.log('Sync', 'Upload complete: $success/${unsynced.length} success');
    _conflictCount = unsynced.length - success;
    
    // Clear conflicts if all notes are now synced
    final totalUnsynced = _notes.where((n) => !n.isSynced).length;
    if (totalUnsynced == 0) {
      _conflictCount = 0;
      _lastError = null;
      DebugService.log('Sync', 'All notes synced - conflicts cleared');
    } else if (_conflictCount > 0) {
      // Only set error if not suppressing notifications
      if (!_suppressSyncNotifications) {
        _lastError = 'Failed to upload $_conflictCount note(s)';
      }
    } else {
      _lastError = null;
    }
    _isSyncing = false;
    notifyListeners();
  }

  /// Download changed notes from GitHub (incremental sync).
  /// 
  /// Uses SHA cache to detect which files changed since last sync.
  /// Only downloads files with different SHA than cached.
  /// 
  /// Flow:
  /// 1. Check encryption status (abort if password mismatch)
  /// 2. Get changed files from GitHub (compare SHAs)
  /// 3. Clean up stale cache entries (deleted files)
  /// 4. Download and merge changed notes
  /// 5. Update SHA cache
  Future<void> syncFromGitHub() async {
    if (!_githubService.isConfigured) return;
    
    // Check for password changes
    final encStatus = await syncEncryptionStatus();
    if (encStatus == EncryptionSyncResult.versionMismatch || 
        encStatus == EncryptionSyncResult.needsPassword) {
      _passwordChangeDetected = true;
      notifyListeners();
      return;
    }
    _passwordChangeDetected = false;
    
    _isSyncing = true;
    notifyListeners();

    DebugService.log('Sync', 'Starting incremental sync from GitHub');
    
    try {
      // Get changed notes and all remote paths
      final result = await _githubService.getChangedNotes(_localShaCache, _notes);
      
      final changed = result.changed;
      final remotePaths = result.remotePaths;
      
      // Clean up stale cache entries (files deleted on remote)
      final stalePaths = _localShaCache.keys.where((p) => !remotePaths.containsKey(p)).toList();
      if (stalePaths.isNotEmpty) {
        DebugService.log('Sync', 'Removing ${stalePaths.length} stale cache entries');
        for (final path in stalePaths) {
          _localShaCache.remove(path);
        }
      }
      
      // Delete local notes that were deleted on remote
      final remoteNoteIds = <String>{};
      for (final path in remotePaths.keys) {
        final parts = path.split('/');
        if (parts.length >= 3 && parts.last.endsWith('.md')) {
          remoteNoteIds.add(parts.last.replaceAll('.md', ''));
        }
      }
      final notesToDelete = _notes.where((n) => n.isSynced && !remoteNoteIds.contains(n.id)).toList();
      if (notesToDelete.isNotEmpty) {
        DebugService.log('Sync', 'Deleting ${notesToDelete.length} notes removed from remote');
        for (final note in notesToDelete) {
          await _databaseService.deleteNote(note.id);
          _notes.removeWhere((n) => n.id == note.id);
          DebugService.log('Sync', 'Deleted local note: ${note.id} (${note.title})');
        }
        _invalidateCache();
      }
      
      DebugService.log('Sync', 'Found ${changed.length} changed/new notes');
      
      int added = 0, updated = 0;
      
      // Process downloads in parallel for better performance
      final futures = changed.map((item) async {
        if (item.note != null) {
          final localIndex = _notes.indexWhere((n) => n.id == item.note!.id);
          
          if (localIndex == -1) {
            // New note - check for ID collision
            final duplicateExists = _notes.any((n) => n.id == item.note!.id);
            if (duplicateExists) {
              // Generate new ID for duplicate
              final newId = DateTime.now().millisecondsSinceEpoch.toString();
              final newNote = Note(
                id: newId,
                title: item.note!.title,
                content: item.note!.content,
                tags: item.note!.tags,
                folder: item.note!.folder,
                createdAt: item.note!.createdAt,
                updatedAt: item.note!.updatedAt,
                isSynced: true,
                isFavorite: item.note!.isFavorite, // Preserve favorite status from sync
              );
              await _databaseService.insertNote(newNote);
              _notes.add(newNote);
              DebugService.log('Sync', 'Duplicate ID ${item.note!.id} from ${item.path} - created new ID: $newId', isError: true);
              return 'added';
            } else {
              // Truly new note
              await _databaseService.insertNote(item.note!);
              _notes.add(item.note!);
              DebugService.log('Sync', 'Added new note: ${item.note!.id} from ${item.path}');
              return 'added';
            }
          } else {
            // SHA changed = remote is truth, use remote data completely
            final localNote = _notes[localIndex];
            final remoteNote = item.note!;
            
            // Log gist changes
            if (localNote.isSharedAsGist && !remoteNote.isSharedAsGist) {
              DebugService.log('Sync', 'Gist was deleted remotely for: ${localNote.id}');
            } else if (!localNote.isSharedAsGist && remoteNote.isSharedAsGist) {
              DebugService.log('Sync', 'Got gist info from remote: ${remoteNote.gistId}');
            }
            
            await _databaseService.updateNote(remoteNote);
            _notes[localIndex] = remoteNote;
            DebugService.log('Sync', 'Updated note: ${item.note!.id} from ${item.path}');
            return 'updated';
          }
        }
        return 'none';
      });
      
      // Wait for all downloads to complete in parallel
      final results = await Future.wait(futures);
      
      // Count results
      for (final result in results) {
        if (result == 'added') added++;
        if (result == 'updated') updated++;
      }
      
      // Update SHA cache for all processed items
      for (final item in changed) {
        _localShaCache[item.path] = item.sha;
      }
      
      // Remove cache entries for items that failed SHA comparison
      final failedPaths = <String>[];
      for (final entry in _localShaCache.entries.toList()) {
        final path = entry.key;
        final cachedSha = entry.value;
        
        // Check if this path exists in current remote paths
        if (remotePaths.containsKey(path)) {
          final remoteSha = remotePaths[path];
          // If SHA comparison fails (corrupted or invalid), remove from cache
          if (remoteSha != null && cachedSha != remoteSha && !changed.any((item) => item.path == path)) {
            failedPaths.add(path);
          }
        }
      }
      
      if (failedPaths.isNotEmpty) {
        DebugService.log('Sync', 'Removing ${failedPaths.length} cache entries with invalid SHA');
        for (final path in failedPaths) {
          _localShaCache.remove(path);
        }
      }
      
      await _saveShaCache();
      _lastError = null;
      DebugService.log('Sync', 'Download complete: $added added, $updated updated (parallel)');
      
      // Gist info now syncs with notes via frontmatter - no separate sync needed
    } catch (e) {
      _lastError = 'Sync failed: ${_friendlyError(e)}';
      DebugService.log('Sync', 'Sync error: $e', isError: true);
    }
    
    _isSyncing = false;
    notifyListeners();
  }
  
  /// Convert error to user-friendly message.
  String _friendlyError(dynamic e) {
    final msg = e.toString();
    if (msg.contains('SocketException') || msg.contains('Connection refused')) {
      return 'No internet connection';
    }
    if (msg.contains('HandshakeException')) {
      return 'SSL/TLS error - check your network';
    }
    if (msg.contains('TimeoutException')) {
      return 'Request timed out';
    }
    if (msg.contains('401') || msg.contains('Unauthorized')) {
      return 'Authentication failed - reconnect GitHub';
    }
    if (msg.contains('403') || msg.contains('Forbidden')) {
      return 'Access denied - check repo permissions';
    }
    if (msg.contains('404')) {
      return 'Repository not found';
    }
    return 'Network error';
  }

  /// Full sync: pull from GitHub, then push local changes.
  Future<void> syncAll() async {
    if (!_githubService.isConfigured || _isSyncing) return;
    if (_passwordChangeDetected) return;
    
    await syncFromGitHub();
    if (_passwordChangeDetected) return;
    await syncToGitHub();
  }

  @override
  void dispose() {
    _stopAutoSync();
    super.dispose();
  }

  /// Import note from JSON (used for backup restore).
  Future<void> importNote(Map<String, dynamic> json) async {
    final note = Note.fromJson(json).copyWith(isSynced: false);
    final existing = _notes.indexWhere((n) => n.id == note.id);
    if (existing != -1) {
      await updateNote(note);
    } else {
      await addNote(note);
    }
  }



  /// Clear GitHub history and re-upload all notes.
  /// Used when enabling encryption to remove unencrypted history.
  Future<void> clearGitHubAndReupload({List<Bookmark>? bookmarks}) async {
    if (!_githubService.isConfigured) return;
    
    // Block other syncs during history clear
    _isSyncing = true;
    _isEncryptionOperationInProgress = true;
    
    try {
      final localVersion = await EncryptionService.getEncryptionVersion();
      
      // Clear history and upload all notes + bookmarks in single orphan commit
      final success = await _githubService.clearHistoryWithNotes(_notes, encryptionVersion: localVersion, bookmarks: bookmarks);
      
      if (success) {
        // Update database with fresh state - set remote to match local
        final repoKey = '${_authService?.owner}/${_authService?.repo}';
        final localEnabled = await EncryptionService.isMasterEncryptionEnabled();
        await _databaseService.updateEncryptionVersions(
          repoKey: repoKey,
          localVersion: localVersion,
          remoteVersion: localVersion,  // Remote now matches local
          localEnabled: localEnabled,
          remoteEnabled: localEnabled,  // Remote now matches local
        );
        
        // Mark all as synced
        for (int i = 0; i < _notes.length; i++) {
          _notes[i] = _notes[i].copyWith(isSynced: true);
          await _databaseService.updateNote(_notes[i]);
        }
        
        // Clear SHA cache (will rebuild on next sync)
        _localShaCache.clear();
        await _saveShaCache();
      }
    } finally {
      _isSyncing = false;
      _isEncryptionOperationInProgress = false;
    }
    
    notifyListeners();
  }

  /// Delete all notes from GitHub and re-upload with encryption (keeps history).
  Future<void> deleteAndReuploadEncrypted() async {
    if (!_githubService.isConfigured) return;
    
    // 1. Upload encryption config FIRST
    final localVersion = await EncryptionService.getEncryptionVersion();
    final localEnabled = await EncryptionService.isMasterEncryptionEnabled();
    await _githubService.saveEncryptionVersion(version: localVersion, enabled: localEnabled);
    
    // 2. Update database
    final repoKey = '${_authService?.owner}/${_authService?.repo}';
    await _databaseService.updateEncryptionVersions(
      repoKey: repoKey,
      localVersion: localVersion,
      remoteVersion: localVersion,
      localEnabled: localEnabled,
      remoteEnabled: localEnabled,
    );
    
    // 3. Mark ALL notes unsynced so they get re-uploaded with encryption
    for (int i = 0; i < _notes.length; i++) {
      _notes[i] = _notes[i].copyWith(isSynced: false);
      await _databaseService.updateNote(_notes[i]);
    }
    _localShaCache.clear();
    await _saveShaCache();
    
    // 4. Re-upload all notes (now encrypted)
    await syncToGitHub();
    notifyListeners();
  }

  /// Get remote encryption config (from database or GitHub).
  Future<Map<String, dynamic>?> getRemoteEncryptionConfig({bool forceRefresh = false}) async {
    final repoKey = '${_authService?.owner}/${_authService?.repo}';
    
    // Try database first (unless force refresh)
    if (!forceRefresh) {
      final stored = await _databaseService.getEncryptionVersions(repoKey);
      if (stored != null) {
        return {
          'enabled': stored['remote_enabled'],
          'version': stored['remote_version'],
        };
      }
    }
    
    // Fetch from GitHub
    final remoteConfig = await _githubService.getEncryptionVersion();
    if (remoteConfig != null) {
      // Store in database
      final localVersion = await EncryptionService.getEncryptionVersion();
      final localEnabled = await EncryptionService.isMasterEncryptionEnabled();
      
      await _databaseService.updateEncryptionVersions(
        repoKey: repoKey,
        localVersion: localVersion,
        remoteVersion: remoteConfig['version'] ?? 0,
        localEnabled: localEnabled,
        remoteEnabled: remoteConfig['enabled'] ?? false,
      );
      
      return {
        'enabled': remoteConfig['enabled'],
        'version': remoteConfig['version'],
      };
    }
    
    return null;
  }

  /// Get encryption status directly from GitHub (no cache).
  Future<Map<String, dynamic>?> getEncryptionStatusFromGitHub() async {
    return await _githubService.getEncryptionVersion();
  }

  // === Gist Management ===
  // Gist info is now stored in the Note itself (gistId, gistUrl, gistPublic)
  // and syncs automatically with notes via GitHub markdown frontmatter.

  /// Get note by ID.
  Note? getNoteById(String noteId) {
    try {
      return _notes.firstWhere((n) => n.id == noteId);
    } catch (e) {
      return null;
    }
  }

  /// Check if note is shared as a gist.
  bool isNoteShared(String noteId) {
    final note = getNoteById(noteId);
    return note?.isSharedAsGist ?? false;
  }

  /// Get gist URL for a note.
  String? getGistUrl(String noteId) {
    final note = getNoteById(noteId);
    return note?.gistUrl;
  }

  /// Share note as GitHub Gist.
  /// Creates gist and stores info in the note itself.
  Future<bool> shareNoteAsGist(String noteId, {bool isPublic = false, String? gistPassword}) async {
    if (!isGitHubConfigured || _authService?.accessToken == null) {
      DebugService.log('Gist', 'Cannot share: GitHub not configured', isError: true);
      return false;
    }

    final note = getNoteById(noteId);
    if (note == null) {
      DebugService.log('Gist', 'Cannot share: Note not found', isError: true);
      return false;
    }

    if (isNoteShared(noteId)) {
      DebugService.log('Gist', 'Note already shared', isError: true);
      return false;
    }

    try {
      final result = await GistService.createGist(
        note, 
        _authService!.accessToken!, 
        isPublic: isPublic,
        gistPassword: gistPassword,
      );
      if (result != null) {
        // Update note with gist info - mark synced to prevent duplicate uploads
        final isProtected = gistPassword != null && gistPassword.isNotEmpty;
        final updatedNote = note.copyWith(
          gistId: result.id,
          gistUrl: result.url,
          gistPublic: isPublic,
          gistPasswordProtected: isProtected,
          isSynced: true,
        );
        
        // Save to database FIRST
        await _databaseService.updateNote(updatedNote);
        DebugService.log('Gist', 'Saved to DB: gistId=${updatedNote.gistId}');
        
        // Update in-memory
        final index = _notes.indexWhere((n) => n.id == noteId);
        if (index != -1) _notes[index] = updatedNote;
        notifyListeners();
        
        // Upload note to GitHub (gist info in frontmatter)
        await _githubService.uploadNote(updatedNote);

        DebugService.log('Gist', 'Shared note as gist: ${result.url}');
        return true;
      }
    } catch (e) {
      DebugService.log('Gist', 'Share failed: $e', isError: true);
    }
    return false;
  }

  /// Update gist when note content changes.
  Future<bool> updateGist(String noteId) async {
    if (!isGitHubConfigured || _authService?.accessToken == null) return false;

    // Skip if already updating
    if (_updatingGists.contains(noteId)) return false;

    final note = getNoteById(noteId);
    if (note == null || !note.isSharedAsGist) return false;

    _updatingGists.add(noteId);
    try {
      final success = await GistService.updateGist(note.gistId!, note, _authService!.accessToken!);
      if (success) {
        DebugService.log('Gist', 'Updated gist: ${note.gistId}');
        return true;
      }
    } catch (e) {
      DebugService.log('Gist', 'Update gist failed: $e', isError: true);
    } finally {
      _updatingGists.remove(noteId);
    }
    return false;
  }

  /// Delete gist and remove sharing.
  Future<bool> unshareGist(String noteId) async {
    final note = getNoteById(noteId);
    if (note == null || !note.isSharedAsGist) return false;

    final gistId = note.gistId!;
    
    try {
      // Remove gist info from note locally first
      final updatedNote = note.copyWith(clearGist: true, isSynced: false);
      await _databaseService.updateNote(updatedNote);
      final index = _notes.indexWhere((n) => n.id == noteId);
      if (index != -1) _notes[index] = updatedNote;
      notifyListeners();
      
      // Delete gist from GitHub
      if (isGitHubConfigured && _authService?.accessToken != null) {
        await GistService.deleteGist(gistId, _authService!.accessToken!);
        // Upload note to remove gist info from frontmatter
        await _githubService.uploadNote(updatedNote);
        // Mark as synced
        final syncedNote = updatedNote.copyWith(isSynced: true);
        await _databaseService.updateNote(syncedNote);
        if (index != -1) _notes[index] = syncedNote;
        notifyListeners();
      }

      DebugService.log('Gist', 'Unshared gist: $gistId');
      return true;
    } catch (e) {
      DebugService.log('Gist', 'Unshare failed: $e', isError: true);
      return false;
    }
  }
  


  // Debounced gist update (3 second delay)
  Timer? _gistUpdateTimer;
  String? _lastUpdatedNoteId;
  
  /// Schedule gist update with debounce.
  /// Waits 3 seconds after last edit before updating.
  /// Skips password-protected gists (no auto-update).
  Future<void> _scheduleGistUpdate(String noteId) async {
    if (!isNoteShared(noteId)) return;
    
    // Skip auto-update for password-protected gists
    final note = getNoteById(noteId);
    if (note?.gistPasswordProtected == true) return;
    
    _gistUpdateTimer?.cancel();
    
    if (_lastUpdatedNoteId != noteId) {
      _lastUpdatedNoteId = noteId;
      _gistUpdateTimer = Timer(const Duration(seconds: 3), () {
        updateGist(noteId);
        _lastUpdatedNoteId = null;
      });
    }
  }
}
