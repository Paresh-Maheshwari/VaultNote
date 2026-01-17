// ============================================================================
// GIST SERVICE
// ============================================================================
//
// GitHub Gist API for sharing notes publicly or privately.
// Gists are auto-updated when note content changes.
// Encrypted notes are decrypted before sharing (using session password).
// ============================================================================

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/note.dart';
import '../services/encryption_service.dart';
import '../services/debug_service.dart';

/// Result of creating a gist.
class GistResult {
  final String id;
  final String url;
  GistResult({required this.id, required this.url});
}

/// GitHub Gist API service.
class GistService {
  static const String _baseUrl = 'https://api.github.com';

  /// Create new gist from note.
  /// If gistPassword provided, encrypts content with PENC: prefix.
  /// Otherwise decrypts content if encrypted (using session password).
  static Future<GistResult?> createGist(Note note, String accessToken, {bool isPublic = false, String? gistPassword}) async {
    try {
      String content;
      if (gistPassword != null && gistPassword.isNotEmpty) {
        // Password-protected gist - encrypt with custom password
        final plainContent = _getPlainContent(note);
        content = EncryptionService.encryptForProtectedGist(plainContent, gistPassword);
      } else {
        // Normal gist - use plain content
        content = _getPlainContent(note);
      }
      
      final fileName = '${_sanitizeFileName(note.title)}.md';
      final isProtected = gistPassword != null && gistPassword.isNotEmpty;
      final gistContent = isProtected
          ? _formatProtectedGistContent(note, content)
          : _formatGistContent(note, content);
      
      final response = await http.post(
        Uri.parse('$_baseUrl/gists'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Accept': 'application/vnd.github+json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'description': isProtected 
              ? '🔒 Protected note from Vaultnote'
              : 'Shared from Vaultnote: ${note.title}',
          'public': isPublic,
          'files': {fileName: {'content': gistContent}}
        }),
      );

      if (response.statusCode == 201) {
        final data = jsonDecode(response.body);
        DebugService.log('Gist', 'Created gist: ${data['id']}${isProtected ? ' (protected)' : ''}');
        return GistResult(id: data['id'], url: data['html_url']);
      } else {
        DebugService.log('Gist', 'Create failed: ${response.statusCode}', isError: true);
        return null;
      }
    } catch (e) {
      DebugService.log('Gist', 'Create error: $e', isError: true);
      return null;
    }
  }

  /// Update existing gist with new note content.
  /// Skips password-protected gists (they should be re-shared instead).
  static Future<bool> updateGist(String gistId, Note note, String accessToken) async {
    // Never auto-update protected gists - content would be exposed
    if (note.gistPasswordProtected == true) return false;
    
    try {
      final content = _getPlainContent(note);
      final fileName = '${_sanitizeFileName(note.title)}.md';
      
      final response = await http.patch(
        Uri.parse('$_baseUrl/gists/$gistId'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Accept': 'application/vnd.github+json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'description': 'Shared from Vaultnote: ${note.title}',
          'files': {fileName: {'content': _formatGistContent(note, content)}}
        }),
      );

      if (response.statusCode == 200) {
        DebugService.log('Gist', 'Updated gist: $gistId');
        return true;
      } else {
        DebugService.log('Gist', 'Update failed: ${response.statusCode}', isError: true);
        return false;
      }
    } catch (e) {
      DebugService.log('Gist', 'Update error: $e', isError: true);
      return false;
    }
  }

  /// Delete gist from GitHub.
  static Future<bool> deleteGist(String gistId, String accessToken) async {
    try {
      final response = await http.delete(
        Uri.parse('$_baseUrl/gists/$gistId'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Accept': 'application/vnd.github+json',
        },
      );

      if (response.statusCode == 204) {
        DebugService.log('Gist', 'Deleted gist: $gistId');
        return true;
      } else {
        DebugService.log('Gist', 'Delete failed: ${response.statusCode}', isError: true);
        return false;
      }
    } catch (e) {
      DebugService.log('Gist', 'Delete error: $e', isError: true);
      return false;
    }
  }

  /// Get plain content (decrypt if encrypted).
  static String _getPlainContent(Note note) {
    if (EncryptionService.isEncrypted(note.content)) {
      final sessionPassword = EncryptionService.sessionPassword;
      if (sessionPassword != null) {
        return EncryptionService.decrypt(note.content, sessionPassword) ?? note.content;
      }
      return note.content;
    }
    return note.content;
  }

  /// Format note as markdown for gist display.
  static String _formatGistContent(Note note, String content) {
    final tags = note.tags.isNotEmpty ? '\n**Tags:** ${note.tags.join(', ')}' : '';
    final folder = note.folder.isNotEmpty ? '\n**Folder:** ${note.folder}' : '';
    
    return '''# ${note.title}
$tags$folder

$content

---
*Shared from Vaultnote*  
*Last updated: ${DateTime.now().toString().split('.')[0]}*
''';
  }

  /// Format protected gist content (encrypted).
  static String _formatProtectedGistContent(Note note, String encryptedContent) {
    return '''# 🔒 Protected Note

This note is password-protected and encrypted.

To view this note:
1. Open **Vaultnote** app
2. Go to **Gists** tab
3. Tap **Open Protected Gist**
4. Paste this gist URL and enter the password

---

$encryptedContent

---
*Encrypted with Vaultnote*
''';
  }

  /// Fetch gist content by URL or ID.
  static Future<String?> fetchGistContent(String gistUrlOrId) async {
    try {
      String gistId = gistUrlOrId;
      // Extract ID from URL if needed
      if (gistUrlOrId.contains('gist.github.com')) {
        gistId = gistUrlOrId.split('/').last;
      }
      
      final response = await http.get(
        Uri.parse('$_baseUrl/gists/$gistId'),
        headers: {'Accept': 'application/vnd.github+json'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final files = data['files'] as Map<String, dynamic>;
        if (files.isNotEmpty) {
          final firstFile = files.values.first as Map<String, dynamic>;
          return firstFile['content'] as String?;
        }
      }
      return null;
    } catch (e) {
      DebugService.log('Gist', 'Fetch error: $e', isError: true);
      return null;
    }
  }

  /// Sanitize title for use as filename.
  static String _sanitizeFileName(String title) {
    if (title.isEmpty) return 'untitled';
    return title
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '-')
        .toLowerCase();
  }
}
