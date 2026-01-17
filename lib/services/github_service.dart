// ============================================================================
// GITHUB SERVICE
// ============================================================================
//
// Handles all GitHub API interactions for note sync:
// - Upload/download notes as markdown files
// - Incremental sync using SHA comparison
// - Encryption config management (.notes-sync/encryption.json)
// - Multi-device locking for password changes
//
// ## File Structure on GitHub
//
// notes/
//   FolderName/
//     1234567890.md    # Note file (ID as filename)
// .notes-sync/
//   encryption.json    # Encryption version, enabled, lock status
//
// ## Note Format
//
// Each note is stored as markdown with YAML frontmatter:
// ---
// id: 1234567890
// title: Note Title
// tags: [tag1, tag2]
// folder: FolderName
// createdAt: 2024-01-01T00:00:00.000Z
// updatedAt: 2024-01-01T00:00:00.000Z
// isFavorite: false
// gistId: abc123
// gistUrl: https://gist.github.com/...
// ---
// Note content here...
//
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/note.dart';
import 'github_auth_service.dart';
import 'debug_service.dart';
import 'encryption_service.dart';

/// Service for syncing notes with GitHub repository.
class GitHubService {
  GitHubAuthService? _authService;
  
  static const String _baseUrl = 'https://api.github.com';

  /// Set authentication service.
  void setAuth(GitHubAuthService authService) {
    _authService = authService;
  }

  bool get isConfigured => _authService?.isConfigured ?? false;
  String? get owner => _authService?.owner;
  String? get repo => _authService?.repo;
  String? get branch => _authService?.branch;

  Map<String, String> get _headers => _authService?.headers ?? {};

  /// Convert Note to markdown with YAML frontmatter.
  /// Encrypts content for GitHub sync if master encryption is enabled.
  String _noteToMarkdown(Note note) {
    final gistInfo = note.isSharedAsGist 
        ? '''gistId: ${note.gistId}
gistUrl: ${note.gistUrl}
gistPublic: ${note.gistPublic}
gistPasswordProtected: ${note.gistPasswordProtected ?? false}
''' 
        : '';
    
    // Encrypt content for GitHub sync if encryption is enabled
    String content = note.content;
    final encryptedContent = EncryptionService.encryptForSync(content);
    if (encryptedContent != null) {
      content = encryptedContent;
    }
    
    final frontmatter = '''---
id: ${note.id}
title: ${note.title}
tags: [${note.tags.join(', ')}]
folder: ${note.folder}
createdAt: ${note.createdAt.toIso8601String()}
updatedAt: ${note.updatedAt.toIso8601String()}
isFavorite: ${note.isFavorite}
$gistInfo---

''';
    return frontmatter + content;
  }

  /// Parse Note from markdown file content.
  /// Extracts ID from filename first, falls back to frontmatter.
  Note? _parseNoteFromContent(String content, String filePath) {
    // Get ID from filename (e.g., "1234567890.md" → "1234567890")
    final fileName = filePath.split('/').last;
    String id = fileName.replaceAll('.md', '');
    
    // Validate filename ID (should be numeric timestamp)
    if (!RegExp(r'^\d+$').hasMatch(id)) {
      // Fallback: extract from frontmatter for old files
      final frontmatterMatch = RegExp(r'^---\s*\n(.*?)\n---', dotAll: true).firstMatch(content);
      if (frontmatterMatch != null) {
        final frontmatter = frontmatterMatch.group(1) ?? '';
        final idMatch = RegExp(r'^id:\s*(.+)$', multiLine: true).firstMatch(frontmatter);
        if (idMatch != null) {
          final frontmatterId = idMatch.group(1)?.trim();
          if (frontmatterId != null && RegExp(r'^\d+$').hasMatch(frontmatterId)) {
            id = frontmatterId;
          } else {
            // Generate new ID for invalid cases
            id = DateTime.now().millisecondsSinceEpoch.toString();
          }
        } else {
          return null; // No valid ID found
        }
      } else {
        return null; // No frontmatter
      }
    }
    
    return _markdownToNote(content, id);
  }

  /// Parse markdown content into Note object.
  Note _markdownToNote(String markdown, String existingId) {
    final lines = markdown.split('\n');
    String id = existingId;
    String title = '';
    List<String> tags = [];
    String folder = '';
    DateTime createdAt = DateTime.now();
    DateTime updatedAt = DateTime.now();
    bool isFavorite = false;
    String content = '';
    String? gistId;
    String? gistUrl;
    bool gistPublic = false;
    bool gistPasswordProtected = false;
    
    bool inFrontmatter = false;
    int contentStart = 0;
    
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line == '---' && i == 0) {
        inFrontmatter = true;
        continue;
      }
      if (line == '---' && inFrontmatter) {
        contentStart = i + 1;
        break;
      }
      if (inFrontmatter) {
        if (line.startsWith('id:')) {
          final frontmatterId = line.substring(3).trim();
          if (frontmatterId.isNotEmpty && RegExp(r'^\d{10,}$').hasMatch(frontmatterId)) {
            id = frontmatterId;
          } else if (frontmatterId.isNotEmpty) {
            id = DateTime.now().millisecondsSinceEpoch.toString();
            DebugService.log('Sync', 'Invalid frontmatter ID "$frontmatterId" - generated new: $id');
          }
        }
        if (line.startsWith('title:')) title = line.substring(6).trim();
        if (line.startsWith('folder:')) folder = line.substring(7).trim();
        if (line.startsWith('tags:')) {
          final tagStr = line.substring(5).trim();
          tags = tagStr.replaceAll('[', '').replaceAll(']', '')
              .split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
        }
        if (line.startsWith('createdAt:')) {
          createdAt = DateTime.tryParse(line.substring(10).trim()) ?? DateTime.now();
        }
        if (line.startsWith('updatedAt:')) {
          updatedAt = DateTime.tryParse(line.substring(10).trim()) ?? DateTime.now();
        }
        if (line.startsWith('isFavorite:')) {
          isFavorite = line.substring(11).trim() == 'true';
        }
        // Parse gist fields
        if (line.startsWith('gistId:')) gistId = line.substring(7).trim();
        if (line.startsWith('gistUrl:')) gistUrl = line.substring(8).trim();
        if (line.startsWith('gistPublic:')) gistPublic = line.substring(11).trim() == 'true';
        if (line.startsWith('gistPasswordProtected:')) gistPasswordProtected = line.substring(22).trim() == 'true';
      }
    }
    
    content = lines.sublist(contentStart).join('\n').trim();
    
    // Decrypt content if it was encrypted for GitHub sync
    final decryptedContent = EncryptionService.decryptFromSync(content);
    if (decryptedContent != null) {
      content = decryptedContent;
    }
    
    return Note(
      id: id,
      title: title,
      content: content,
      tags: tags,
      folder: folder,
      createdAt: createdAt,
      updatedAt: updatedAt,
      isSynced: true,
      isFavorite: isFavorite,
      gistId: gistId,
      gistUrl: gistUrl,
      gistPublic: gistPublic,
      gistPasswordProtected: gistPasswordProtected,
    );
  }

  /// Get SHA hash of a file on GitHub.
  /// SHA is required for updating existing files.
  Future<String?> _getFileSha(String path) async {
    try {
      final url = '$_baseUrl/repos/$owner/$repo/contents/$path?ref=$branch';
      final response = await http.get(Uri.parse(url), headers: _headers);
      if (response.statusCode == 200) {
        return jsonDecode(response.body)['sha'];
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Generate GitHub path for a note.
  /// Format: notes/{folder}/{id}.md
  String _getNotePath(Note note) {
    final folder = note.folder.isNotEmpty ? note.folder : 'Uncategorized';
    return 'notes/$folder/${note.id}.md';
  }

  /// Get SHAs for multiple notes in parallel.
  /// Fetches 10 at a time to avoid rate limits.
  Future<Map<String, String>> getShasForNotes(List<Note> notes) async {
    if (!isConfigured || notes.isEmpty) return {};
    
    final paths = notes.map((n) => _getNotePath(n)).toList();
    final Map<String, String> shas = {};
    
    // Fetch SHAs in parallel (10 at a time)
    for (var i = 0; i < paths.length; i += 10) {
      final batch = paths.skip(i).take(10).toList();
      final results = await Future.wait(
        batch.map((path) => _getFileSha(path)),
      );
      for (var j = 0; j < batch.length; j++) {
        if (results[j] != null) shas[batch[j]] = results[j]!;
      }
    }
    return shas;
  }

  /// Upload note with pre-fetched SHA.
  /// Retries up to 3 times on 409 conflict (SHA changed).
  Future<bool> uploadNoteWithSha(Note note, Map<String, String> shas) async {
    if (!isConfigured) return false;
    
    final path = _getNotePath(note);
    final content = base64Encode(utf8.encode(_noteToMarkdown(note)));
    
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        // First attempt uses pre-fetched SHA, retries get fresh SHA
        final sha = attempt == 0 ? shas[path] : await _getFileSha(path);
        final finalSha = sha ?? await _getFileSha(path);
        
        final body = {
          'message': 'Update note: ${note.title}',
          'content': content,
          'branch': branch,
          if (finalSha != null) 'sha': finalSha,
        };
        
        DebugService.log('GitHub', 'Upload attempt ${attempt + 1}: $path (SHA: ${finalSha ?? 'none'})');
        
        final response = await http.put(
          Uri.parse('$_baseUrl/repos/$owner/$repo/contents/$path'),
          headers: _headers,
          body: jsonEncode(body),
        );
        
        if (response.statusCode == 200 || response.statusCode == 201) {
          DebugService.log('GitHub', 'Upload success: ${response.statusCode}');
          return true;
        }
        
        if (response.statusCode == 409 && attempt < 2) {
          DebugService.log('GitHub', 'Conflict (409), retrying with fresh SHA');
          await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
          continue;
        }
        
        // Log detailed error for 422 and other failures
        final errorBody = response.body;
        DebugService.log('GitHub', 'Upload failed: ${response.statusCode} - $errorBody', isError: true);
        return false;
      } catch (e) {
        DebugService.log('GitHub', 'Upload attempt ${attempt + 1} error: $e', isError: true);
        if (attempt < 2) continue;
        return false;
      }
    }
    return false;
  }

  /// Upload single note to GitHub.
  /// Handles SHA fetching and retry on conflict.
  Future<bool> uploadNote(Note note) async {
    if (!isConfigured) {
      DebugService.log('GitHub', 'Upload failed: not configured', isError: true);
      return false;
    }
    
    try {
      final path = _getNotePath(note);
      final content = base64Encode(utf8.encode(_noteToMarkdown(note)));
      
      // Retry up to 3 times on 409 conflict
      for (int attempt = 0; attempt < 3; attempt++) {
        final sha = await _getFileSha(path);
        
        final body = {
          'message': 'Update note: ${note.title}',
          'content': content,
          'branch': branch,
          if (sha != null) 'sha': sha,
        };
        
        final url = '$_baseUrl/repos/$owner/$repo/contents/$path';
        if (attempt == 0) DebugService.log('GitHub', 'Uploading: $path');
        
        final response = await http.put(
          Uri.parse(url),
          headers: _headers,
          body: jsonEncode(body),
        );
        
        if (response.statusCode == 200 || response.statusCode == 201) {
          DebugService.log('GitHub', 'Upload success: ${response.statusCode}');
          return true;
        }
        
        if (response.statusCode == 409 && attempt < 2) {
          // Conflict - SHA changed, retry with fresh SHA
          await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
          continue;
        }
        
        DebugService.log('GitHub', 'Upload failed: ${response.statusCode}', isError: true);
        return false;
      }
      return false;
    } catch (e) {
      DebugService.log('GitHub', 'Upload error: $e', isError: true);
      return false;
    }
  }

  /// Delete note from GitHub.
  /// Finds the correct path if not provided.
  Future<bool> deleteNote(String noteId, {String? notePath}) async {
    if (!isConfigured) {
      DebugService.log('GitHub', 'Delete failed: not configured', isError: true);
      return false;
    }
    
    try {
      String? path = notePath;
      
      // Find note path if not provided
      if (path == null) {
        final note = await _findNoteById(noteId);
        if (note != null) {
          path = _getNotePath(note);
          DebugService.log('GitHub', 'Generated path for note $noteId: $path');
        } else {
          // Fallback: search all paths for noteId
          final paths = await _findNotePaths(noteId);
          if (paths.isEmpty) {
            DebugService.log('GitHub', 'Delete: Note $noteId not found on GitHub');
            return true; // Already deleted or never existed
          }
          path = paths.first;
          DebugService.log('GitHub', 'Found path by search: $path');
        }
      }
      
      DebugService.log('GitHub', 'Deleting: $path');
      
      final sha = await _getFileSha(path);
      if (sha == null) {
        DebugService.log('GitHub', 'Delete: File $path not found (already deleted?)');
        return true;
      }
      
      final url = '$_baseUrl/repos/$owner/$repo/contents/$path';
      final response = await http.delete(
        Uri.parse(url),
        headers: _headers,
        body: jsonEncode({
          'message': 'Delete note: $noteId',
          'sha': sha,
          'branch': branch,
        }),
      );
      
      if (response.statusCode == 200) {
        DebugService.log('GitHub', 'Delete success: $path');
        return true;
      } else {
        DebugService.log('GitHub', 'Delete failed: ${response.statusCode} - ${response.body}', isError: true);
        return false;
      }
    } catch (e) {
      DebugService.log('GitHub', 'deleteNote error: $e', isError: true);
      return false;
    }
  }

  // Note to delete (set by caller for path generation)
  Note? _noteToDelete;
  
  /// Set note data for deletion (needed for path generation).
  void setNoteForDeletion(Note? note) {
    _noteToDelete = note;
  }
  
  Future<Note?> _findNoteById(String noteId) async {
    return _noteToDelete;
  }

  /// Find all paths containing a note ID.
  Future<List<String>> _findNotePaths(String noteId) async {
    final allPaths = await _listAllNotePaths();
    return allPaths.where((p) => p.contains(noteId)).toList();
  }

  /// List all note file paths on GitHub.
  Future<List<String>> _listAllNotePaths() async {
    if (!isConfigured) return [];
    
    try {
      List<String> paths = [];
      
      // Get folders in notes/
      final url = '$_baseUrl/repos/$owner/$repo/contents/notes?ref=$branch';
      final response = await http.get(Uri.parse(url), headers: _headers);
      
      if (response.statusCode == 200) {
        final List<dynamic> items = jsonDecode(response.body);
        for (final item in items) {
          if (item['type'] == 'dir') {
            // Get files in subfolder
            final folderUrl = '$_baseUrl/repos/$owner/$repo/contents/notes/${item['name']}?ref=$branch';
            final folderResponse = await http.get(Uri.parse(folderUrl), headers: _headers);
            if (folderResponse.statusCode == 200) {
              final List<dynamic> files = jsonDecode(folderResponse.body);
              paths.addAll(files.where((f) => f['name'].endsWith('.md')).map<String>((f) => 'notes/${item['name']}/${f['name']}'));
            }
          } else if (item['name'].endsWith('.md')) {
            // Legacy: files directly in notes/
            paths.add('notes/${item['name']}');
          }
        }
      }
      return paths;
    } catch (e) {
      DebugService.log('GitHub', 'listAllNotePaths error: $e', isError: true);
      return [];
    }
  }

  /// Get all note paths with SHAs using Tree API (single request).
  /// More efficient than fetching each file individually.
  /// Retries up to 3 times with exponential backoff.
  Future<Map<String, String>> _getRemoteNotesWithSha() async {
    if (!isConfigured) {
      DebugService.log('GitHub', 'getRemoteNotes: not configured');
      return {};
    }
    
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        // Get branch SHA first
        final branchUrl = '$_baseUrl/repos/$owner/$repo/branches/$branch';
        final branchRes = await _getWithRetry(Uri.parse(branchUrl));
        if (branchRes == null) return {};
        if (branchRes.statusCode == 401) {
          DebugService.log('GitHub', 'Token expired or invalid (401)', isError: true);
          return {};
        }
        if (branchRes.statusCode != 200) {
          DebugService.log('GitHub', 'Branch fetch failed: ${branchRes.statusCode}', isError: true);
          return {};
        }
        
        final treeSha = jsonDecode(branchRes.body)['commit']['sha'];
        
        // Get full tree recursively (all files in one request)
        final treeRes = await _getWithRetry(Uri.parse('$_baseUrl/repos/$owner/$repo/git/trees/$treeSha?recursive=1'));
        if (treeRes == null || treeRes.statusCode != 200) {
          DebugService.log('GitHub', 'Tree fetch failed: ${treeRes?.statusCode}', isError: true);
          return {};
        }
        
        final tree = jsonDecode(treeRes.body)['tree'] as List? ?? [];
        final Map<String, String> pathsWithSha = {};
        
        // Filter for note files only
        for (final item in tree) {
          final path = item['path']?.toString();
          final sha = item['sha']?.toString();
          if (path != null && sha != null && path.startsWith('notes/') && path.endsWith('.md') && item['type'] == 'blob') {
            pathsWithSha[path] = sha;
          }
        }
        
        return pathsWithSha;
      } catch (e) {
        DebugService.log('GitHub', 'Tree API error (attempt ${attempt + 1}): $e', isError: true);
        if (attempt < 2) await Future.delayed(Duration(seconds: 1 << attempt));
      }
    }
    return {};
  }

  /// Fetch a single note's raw content for password verification.
  Future<String?> fetchFirstNoteContent() async {
    if (!isConfigured) return null;
    try {
      final paths = await _getRemoteNotesWithSha();
      if (paths.isEmpty) return null;
      
      final firstPath = paths.keys.first;
      final url = '$_baseUrl/repos/$owner/$repo/contents/$firstPath?ref=$branch';
      final response = await _getWithRetry(Uri.parse(url));
      if (response != null && response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return utf8.decode(base64Decode(data['content'].replaceAll('\n', '')));
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Get changed/new notes only (incremental sync).
  /// Compares remote SHAs with local cache to find changes.
  /// Returns changed notes and all remote paths for cache cleanup.
  Future<({List<({String path, String sha, Note? note})> changed, Map<String, String> remotePaths})> getChangedNotes(Map<String, String> localShaMap, List<Note> localNotes) async {
    if (!isConfigured) return (changed: <({String path, String sha, Note? note})>[], remotePaths: <String, String>{});
    
    final remoteNotes = await _getRemoteNotesWithSha();
    DebugService.log('Sync', 'Remote has ${remoteNotes.length} notes, local cache has ${localShaMap.length}');
    
    List<({String path, String sha, Note? note})> changed = [];
    
    for (final entry in remoteNotes.entries) {
      final path = entry.key;
      final remoteSha = entry.value;
      final localSha = localShaMap[path];
      
      // Download file, get ID from frontmatter only (don't guess from filename)
      if (localSha == null || localSha != remoteSha) {
        final url = '$_baseUrl/repos/$owner/$repo/contents/$path?ref=$branch';
        final response = await _getWithRetry(Uri.parse(url));
        if (response != null && response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final content = utf8.decode(base64Decode(data['content'].replaceAll('\n', '')));
          
          // Parse note to get real ID
          final note = _parseNoteFromContent(content, path);
          if (note == null) continue;
          
          // Check if this note exists locally using the real ID
          final realNoteExists = localNotes.any((n) => n.id == note.id);
          
          DebugService.log('Sync', 'Downloading $path (Real ID: ${note.id}) - exists locally: $realNoteExists');
          changed.add((path: path, sha: remoteSha, note: note));
        }
      }
    }
    
    return (changed: changed, remotePaths: remoteNotes);
  }

  /// HTTP GET with retry and exponential backoff.
  Future<http.Response?> _getWithRetry(Uri url, {int maxRetries = 3}) async {
    for (int i = 0; i < maxRetries; i++) {
      try {
        final response = await http.get(url, headers: _headers).timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TimeoutException('Request timeout'),
        );
        return response;
      } catch (e) {
        if (i == maxRetries - 1) {
          DebugService.log('GitHub', 'Request failed after $maxRetries retries: $e', isError: true);
          return null;
        }
        // Exponential backoff: 1s, 2s, 4s
        await Future.delayed(Duration(seconds: 1 << i));
      }
    }
    return null;
  }

  /// Delete all notes from GitHub.
  /// Used before re-uploading encrypted notes to clear history.
  Future<bool> deleteAllNotes() async {
    if (!isConfigured) return false;
    
    try {
      final paths = await _listAllNotePaths();
      for (final path in paths) {
        final sha = await _getFileSha(path);
        if (sha != null) {
          await http.delete(
            Uri.parse('$_baseUrl/repos/$owner/$repo/contents/$path'),
            headers: _headers,
            body: jsonEncode({'message': 'Clear for encryption', 'sha': sha, 'branch': branch}),
          );
        }
      }
      return true;
    } catch (e) {
      DebugService.log('GitHub', 'deleteAllNotes error: $e', isError: true);
      return false;
    }
  }

  // ============================================================================
  // ENCRYPTION VERSION TRACKING (SIMPLIFIED)
  // ============================================================================
  
  /// Save encryption version and lock status to GitHub.
  Future<bool> saveEncryptionVersion({int? version, bool? enabled, bool locked = false, String? deviceId}) async {
    if (!isConfigured) return false;
    
    try {
      final path = '.notes-sync/encryption.json';
      if (version == null) {
        return await _deleteFile(path);
      }
      
      final content = base64Encode(utf8.encode(jsonEncode({
        'version': version,
        'enabled': enabled ?? false, // Default: disabled (must be explicitly set)
        'locked': locked,
        'device': deviceId,
        'timestamp': DateTime.now().toIso8601String(),
      })));
      
      final sha = await _getFileSha(path);
      final response = await http.put(
        Uri.parse('$_baseUrl/repos/$owner/$repo/contents/$path'),
        headers: _headers,
        body: jsonEncode({
          'message': 'Update encryption v$version',
          'content': content,
          'branch': branch,
          if (sha != null) 'sha': sha,
        }),
      );
      
      final success = response.statusCode == 200 || response.statusCode == 201;
      
      // Clear cache after successful upload to prevent stale reads
      if (success) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      
      return success;
    } catch (e) {
      DebugService.log('GitHub', 'saveEncryptionVersion error: $e', isError: true);
      return false;
    }
  }

  /// Get encryption version and lock status from GitHub.
  Future<Map<String, dynamic>?> getEncryptionVersion() async {
    if (!isConfigured) return null;
    
    try {
      final path = '.notes-sync/encryption.json';
      final response = await http.get(
        Uri.parse('$_baseUrl/repos/$owner/$repo/contents/$path?ref=$branch'),
        headers: _headers,
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final content = utf8.decode(base64Decode(data['content'].replaceAll('\n', '')));
        return jsonDecode(content);
      }
      return null;
    } catch (e) {
      DebugService.log('GitHub', 'getEncryptionVersion error: $e', isError: true);
      return null;
    }
  }

  /// Delete a file from GitHub.
  Future<bool> _deleteFile(String path) async {
    final sha = await _getFileSha(path);
    if (sha == null) return true; // Already deleted
    
    final response = await http.delete(
      Uri.parse('$_baseUrl/repos/$owner/$repo/contents/$path'),
      headers: _headers,
      body: jsonEncode({'message': 'Remove $path', 'sha': sha, 'branch': branch}),
    );
    return response.statusCode == 200;
  }

  /// Clear commit history by creating orphan branch.
  /// 
  /// Used when enabling encryption to remove unencrypted history.
  /// Creates a new branch with no parent commits, then replaces
  /// the original branch.
  /// 
  /// Flow:
  /// 1. Create empty tree
  /// 2. Create orphan commit (no parents)
  /// 3. Create temp branch pointing to orphan
  /// Clear git history by creating orphan branch with all notes in single commit.
  /// 1. Create tree with all encrypted notes
  /// 2. Create orphan commit with that tree
  /// 3. Delete old branch
  /// 4. Create new branch with same name from orphan
  Future<bool> clearHistoryWithNotes(List<Note> notes, {int encryptionVersion = 1}) async {
    if (!isConfigured) return false;
    
    try {
      DebugService.log('GitHub', 'Starting history clear with ${notes.length} notes');
      final tempBranch = 'temp-clean-${DateTime.now().millisecondsSinceEpoch}';
      
      // 1. Create blobs for all notes + encryption config
      final List<Map<String, String>> treeItems = [];
      
      // Add encryption config
      final configContent = base64Encode(utf8.encode(jsonEncode({
        'version': encryptionVersion,
        'enabled': true,
        'locked': false,
        'timestamp': DateTime.now().toIso8601String(),
      })));
      final configBlobRes = await http.post(
        Uri.parse('$_baseUrl/repos/$owner/$repo/git/blobs'),
        headers: _headers,
        body: jsonEncode({'content': configContent, 'encoding': 'base64'}),
      );
      if (configBlobRes.statusCode != 201) {
        DebugService.log('GitHub', 'Failed to create config blob', isError: true);
        return false;
      }
      treeItems.add({
        'path': '.notes-sync/encryption.json',
        'mode': '100644',
        'type': 'blob',
        'sha': jsonDecode(configBlobRes.body)['sha'],
      });
      
      // Add all notes as blobs
      for (final note in notes) {
        final path = _getNotePath(note);
        final content = base64Encode(utf8.encode(_noteToMarkdown(note)));
        
        final blobRes = await http.post(
          Uri.parse('$_baseUrl/repos/$owner/$repo/git/blobs'),
          headers: _headers,
          body: jsonEncode({'content': content, 'encoding': 'base64'}),
        );
        if (blobRes.statusCode != 201) {
          DebugService.log('GitHub', 'Failed to create blob for ${note.id}', isError: true);
          continue;
        }
        treeItems.add({
          'path': path,
          'mode': '100644',
          'type': 'blob',
          'sha': jsonDecode(blobRes.body)['sha'],
        });
      }
      
      // 2. Create tree with all items
      final treeRes = await http.post(
        Uri.parse('$_baseUrl/repos/$owner/$repo/git/trees'),
        headers: _headers,
        body: jsonEncode({'tree': treeItems}),
      );
      if (treeRes.statusCode != 201) {
        DebugService.log('GitHub', 'Failed to create tree', isError: true);
        return false;
      }
      final treeSha = jsonDecode(treeRes.body)['sha'];
      
      // 3. Create orphan commit (no parent) with all notes
      final commitRes = await http.post(
        Uri.parse('$_baseUrl/repos/$owner/$repo/git/commits'),
        headers: _headers,
        body: jsonEncode({
          'message': 'Encrypted notes (fresh history)',
          'tree': treeSha,
          'parents': [], // Orphan - no parent!
        }),
      );
      if (commitRes.statusCode != 201) {
        DebugService.log('GitHub', 'Failed to create orphan commit', isError: true);
        return false;
      }
      final commitSha = jsonDecode(commitRes.body)['sha'];
      
      // 4. Create temp branch pointing to orphan
      final refRes = await http.post(
        Uri.parse('$_baseUrl/repos/$owner/$repo/git/refs'),
        headers: _headers,
        body: jsonEncode({'ref': 'refs/heads/$tempBranch', 'sha': commitSha}),
      );
      if (refRes.statusCode != 201) {
        DebugService.log('GitHub', 'Failed to create temp branch', isError: true);
        return false;
      }
      
      // 5. Set temp as default (required before deleting original)
      await http.patch(
        Uri.parse('$_baseUrl/repos/$owner/$repo'),
        headers: _headers,
        body: jsonEncode({'default_branch': tempBranch}),
      );
      await Future.delayed(const Duration(milliseconds: 500));
      
      // 6. Delete old branch
      final deleteRes = await http.delete(
        Uri.parse('$_baseUrl/repos/$owner/$repo/git/refs/heads/$branch'),
        headers: _headers,
      );
      DebugService.log('GitHub', 'Delete old branch: ${deleteRes.statusCode}');
      
      // 7. Recreate original branch from orphan commit
      await http.post(
        Uri.parse('$_baseUrl/repos/$owner/$repo/git/refs'),
        headers: _headers,
        body: jsonEncode({'ref': 'refs/heads/$branch', 'sha': commitSha}),
      );
      
      // 8. Restore default branch and delete temp
      await http.patch(
        Uri.parse('$_baseUrl/repos/$owner/$repo'),
        headers: _headers,
        body: jsonEncode({'default_branch': branch}),
      );
      await http.delete(
        Uri.parse('$_baseUrl/repos/$owner/$repo/git/refs/heads/$tempBranch'),
        headers: _headers,
      );
      
      DebugService.log('GitHub', 'History cleared successfully');
      return true;
    } catch (e) {
      DebugService.log('GitHub', 'clearHistoryWithNotes error: $e', isError: true);
      return false;
    }
  }
}
