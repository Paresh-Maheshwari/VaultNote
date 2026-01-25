// ============================================================================
// BOOKMARK SERVICE
// ============================================================================
//
// Database service for bookmark persistence and operations. Handles:
// - SQLite CRUD operations for bookmarks
// - Webpage metadata fetching (title, description, Open Graph)
// - Search functionality across title/URL/description
// - Import/export features (JSON, HTML)
// - Duplicate detection and handling
//
// ## Database Schema
//
// bookmarks table:
//   id TEXT PRIMARY KEY           # Timestamp-based unique ID
//   url TEXT NOT NULL            # Target URL
//   title TEXT NOT NULL          # Page title or user-defined
//   description TEXT             # Meta description from page
//   image TEXT                   # Open Graph image URL
//   notes TEXT                   # User notes (timestamped entries)
//   favicon TEXT                 # Website favicon URL
//   folder TEXT DEFAULT 'Bookmarks'  # Organization folder
//   tags TEXT                    # Comma-separated tags
//   createdAt TEXT NOT NULL      # ISO8601 timestamp
//   isSynced INTEGER DEFAULT 0   # GitHub sync status
//
// ============================================================================

import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import '../models/bookmark.dart';
import '../services/debug_service.dart';
import '../services/database_service.dart';

/// Database service for bookmark persistence and operations
class BookmarkService {
  /// Gets the shared database instance
  static Future<Database> get database async {
    return await DatabaseService().database;
  }

  /// Fetches webpage metadata including title, description, and Open Graph image.
  /// 
  /// Makes HTTP request to the URL and parses HTML for meta tags:
  /// - og:title, og:description, og:image (Open Graph)
  /// - Standard meta description
  /// - HTML title tag as fallback
  /// 
  /// Returns map with nullable string values for title, description, image.
  /// Returns empty map on network errors or parsing failures.
  /// 
  /// [url] - Target URL to fetch metadata from
  static Future<Map<String, String?>> fetchMetadata(String url) async {
    try {
      // Validate URL format first
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme || (!uri.scheme.startsWith('http'))) {
        return {};
      }
      
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..idleTimeout = const Duration(seconds: 10);
      final request = await client.getUrl(uri);
      final response = await request.close();
      
      // Check response size to prevent memory issues
      if (response.contentLength > 1024 * 1024) {
        client.close();
        return {};
      }
      
      // Add timeout for reading response to prevent hanging on large/slow responses
      final html = await response.transform(utf8.decoder).join()
          .timeout(const Duration(seconds: 10));
      client.close();
      
      // Limit HTML size to prevent ReDoS attacks
      final limitedHtml = html.length > 50000 ? html.substring(0, 50000) : html;
      
      // Extract meta tags with safer, simpler regex
      String? extract(String property) {
        try {
          final pattern = RegExp('(?:property|name)=["\']$property["\'][^>]*content=["\']([^"\']{0,500})["\']', caseSensitive: false);
          final match = pattern.firstMatch(limitedHtml);
          return match?.group(1)?.trim();
        } catch (_) {
          return null;
        }
      }
      
      // Get title from <title> tag as fallback
      String? getTitle() {
        try {
          final titleMatch = RegExp(r'<title[^>]*>([^<]{0,200})</title>', caseSensitive: false).firstMatch(limitedHtml);
          return titleMatch?.group(1)?.trim();
        } catch (_) {
          return null;
        }
      }
      
      return {
        'title': extract('og:title') ?? getTitle(),
        'description': extract('og:description') ?? extract('description'),
        'image': extract('og:image'),
      };
    } catch (_) {
      return {};
    }
  }

  /// Retrieves all bookmarks from database ordered by creation date (newest first).
  /// 
  /// Returns list of Bookmark objects converted from database rows.
  /// Empty list if no bookmarks exist.
  static Future<List<Bookmark>> getAll() async {
    final db = await database;
    final maps = await db.query('bookmarks', orderBy: 'createdAt DESC');
    return maps.map((m) => Bookmark.fromJson(m)).toList();
  }

  /// Gets all unique folders from database
  static Future<List<String>> getAllFolders() async {
    final db = await database;
    final result = await db.rawQuery('SELECT DISTINCT folder FROM bookmarks ORDER BY folder');
    final folders = result.map((row) => row['folder'] as String).toList();
    return ['All', ...folders];
  }
  /// 
  /// [folder] - Folder to filter by ('All' for no filter)
  /// [searchQuery] - Search term to match against title, URL, description, notes
  /// Returns filtered list of bookmarks
  static Future<List<Bookmark>> getFiltered({String folder = 'All', String searchQuery = ''}) async {
    final db = await database;
    
    String whereClause = '';
    List<String> whereArgs = [];
    
    // Add folder filter
    if (folder != 'All') {
      whereClause = 'folder = ? OR folder LIKE ?';
      whereArgs.addAll([folder, '$folder/%']);
    }
    
    // Add search filter
    if (searchQuery.isNotEmpty) {
      final searchWhere = 'title LIKE ? OR url LIKE ? OR description LIKE ? OR notes LIKE ?';
      final searchPattern = '%$searchQuery%';
      
      if (whereClause.isNotEmpty) {
        whereClause = '($whereClause) AND ($searchWhere)';
      } else {
        whereClause = searchWhere;
      }
      whereArgs.addAll([searchPattern, searchPattern, searchPattern, searchPattern]);
    }
    
    final maps = await db.query(
      'bookmarks',
      where: whereClause.isNotEmpty ? whereClause : null,
      whereArgs: whereArgs.isNotEmpty ? whereArgs : null,
      orderBy: 'createdAt DESC',
    );
    
    return maps.map((m) => Bookmark.fromJson(m)).toList();
  }

  /// Inserts a new bookmark into the database.
  /// 
  /// Uses REPLACE conflict resolution to handle duplicate IDs.
  /// Bookmark is converted to JSON map before insertion.
  /// 
  /// [bookmark] - Bookmark object to insert
  static Future<void> insert(Bookmark bookmark) async {
    final db = await database;
    await db.insert('bookmarks', bookmark.toJson(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Updates an existing bookmark in the database.
  /// 
  /// Updates all fields for the bookmark with matching ID.
  /// Bookmark is converted to JSON map before update.
  /// 
  /// [bookmark] - Updated bookmark object
  static Future<void> update(Bookmark bookmark) async {
    final db = await database;
    await db.update('bookmarks', bookmark.toJson(), where: 'id = ?', whereArgs: [bookmark.id]);
  }

  /// Batch insert/update bookmarks in a single transaction.
  /// 
  /// More efficient for sync operations with multiple bookmarks.
  /// Prevents partial updates if operation fails mid-way.
  static Future<void> upsertBatch(List<Bookmark> bookmarks) async {
    if (bookmarks.isEmpty) return;
    
    final db = await database;
    await db.transaction((txn) async {
      for (final bookmark in bookmarks) {
        await txn.insert('bookmarks', bookmark.toJson(), conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// Deletes a bookmark from the database by ID.
  /// 
  /// [id] - Unique identifier of bookmark to delete
  static Future<void> delete(String id) async {
    final db = await database;
    await db.delete('bookmarks', where: 'id = ?', whereArgs: [id]);
  }

  /// Clear all bookmarks from the database
  static Future<void> clearAllBookmarks() async {
    final db = await database;
    await db.delete('bookmarks');
  }

  /// Checks if a bookmark with the given URL already exists.
  /// 
  /// [url] - URL to check for existence
  /// Returns true if bookmark with URL exists, false otherwise
  static Future<bool> exists(String url) async {
    final db = await database;
    final result = await db.query('bookmarks', where: 'url = ?', whereArgs: [url]);
    return result.isNotEmpty;
  }

  /// Finds a bookmark by its URL.
  /// 
  /// [url] - URL to search for
  /// Returns Bookmark object if found, null otherwise
  static Future<Bookmark?> findByUrl(String url) async {
    final db = await database;
    final result = await db.query('bookmarks', where: 'url = ?', whereArgs: [url]);
    return result.isNotEmpty ? Bookmark.fromJson(result.first) : null;
  }

  /// Searches bookmarks by query string in title, URL, and description.
  /// 
  /// Uses SQL LIKE operator for case-insensitive partial matching.
  /// Results are ordered by creation date (newest first) and limited to 20.
  /// 
  /// [query] - Search term to match against title, URL, description
  /// Returns list of matching bookmarks
  static Future<List<Bookmark>> search(String query) async {
    final db = await database;
    final maps = await db.query('bookmarks', 
      where: 'title LIKE ? OR url LIKE ? OR description LIKE ?',
      whereArgs: ['%$query%', '%$query%', '%$query%'],
      orderBy: 'createdAt DESC',
      limit: 20,
    );
    return maps.map((m) => Bookmark.fromJson(m)).toList();
  }

  /// Exports all bookmarks to JSON format.
  /// 
  /// Creates JSON array containing all bookmark objects.
  /// Useful for backup or transferring bookmarks between devices.
  /// 
  /// Returns JSON string representation of all bookmarks
  static Future<String> exportToJson() async {
    final bookmarks = await getAll();
    return jsonEncode(bookmarks.map((b) => b.toJson()).toList());
  }

  /// Imports bookmarks from JSON format.
  /// 
  /// Parses JSON array and creates Bookmark objects.
  /// Skips bookmarks that already exist (based on URL).
  /// 
  /// [json] - JSON string containing bookmark array
  /// Returns number of bookmarks successfully imported
  static Future<int> importFromJson(String json) async {
    final List<dynamic> data = jsonDecode(json);
    int count = 0;
    for (final item in data) {
      final bookmark = Bookmark.fromJson(item).copyWith(isSynced: false);
      if (!await exists(bookmark.url)) {
        await insert(bookmark);
        count++;
      }
    }
    return count;
  }

  /// Exports bookmarks to HTML format compatible with browsers.
  /// 
  /// Creates Netscape bookmark file format that can be imported
  /// into most web browsers. Bookmarks are grouped by folder.
  /// 
  /// Returns HTML string in browser bookmark format
  static Future<String> exportToHtml() async {
    final bookmarks = await getAll();
    final buffer = StringBuffer();
    buffer.writeln('<!DOCTYPE NETSCAPE-Bookmark-file-1>');
    buffer.writeln('<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">');
    buffer.writeln('<TITLE>Bookmarks</TITLE>');
    buffer.writeln('<H1>Bookmarks</H1>');
    buffer.writeln('<DL><p>');
    
    // Group bookmarks by folder for organized HTML output
    final folders = <String, List<Bookmark>>{};
    for (final b in bookmarks) {
      folders.putIfAbsent(b.folder, () => []).add(b);
    }
    
    // Generate HTML structure with folders and bookmarks
    for (final entry in folders.entries) {
      buffer.writeln('<DT><H3>${entry.key}</H3>');
      buffer.writeln('<DL><p>');
      for (final b in entry.value) {
        final ts = b.createdAt.millisecondsSinceEpoch ~/ 1000;
        buffer.writeln('<DT><A HREF="${b.url}" ADD_DATE="$ts">${b.title}</A>');
      }
      buffer.writeln('</DL><p>');
    }
    buffer.writeln('</DL><p>');
    return buffer.toString();
  }

  /// Imports bookmarks from HTML file (universal browser format).
  /// 
  /// Parses standard Netscape bookmark HTML format used by all browsers.
  /// Extracts folders, titles, URLs, and timestamps.
  /// 
  /// [htmlContent] - HTML content to parse
  /// Returns number of bookmarks imported
  static Future<int> importFromHtml(String htmlContent) async {
    try {
      int importCount = 0;
      String currentFolder = 'Bookmarks';
      
      // Split into lines for parsing
      final lines = htmlContent.split('\n');
      
      for (final line in lines) {
        final trimmed = line.trim();
        
        // Parse folder names from <H3> tags
        if (trimmed.startsWith('<DT><H3>') || trimmed.startsWith('<H3>')) {
          final folderMatch = RegExp(r'<H3[^>]*>([^<]+)</H3>').firstMatch(trimmed);
          if (folderMatch != null) {
            currentFolder = folderMatch.group(1)!.trim();
          }
        }
        
        // Parse bookmarks from <A> tags
        else if (trimmed.startsWith('<DT><A ') || trimmed.startsWith('<A ')) {
          final urlMatch = RegExp(r'HREF="([^"]+)"').firstMatch(trimmed);
          final titleMatch = RegExp(r'>([^<]+)</A>').firstMatch(trimmed);
          final dateMatch = RegExp(r'ADD_DATE="(\d+)"').firstMatch(trimmed);
          
          if (urlMatch != null && titleMatch != null) {
            final url = urlMatch.group(1);
            final title = titleMatch.group(1);
            
            // Validate extracted data
            if (url == null || title == null || url.isEmpty || title.isEmpty) {
              continue;
            }
            final timestamp = dateMatch != null 
                ? DateTime.fromMillisecondsSinceEpoch((int.tryParse(dateMatch.group(1)!) ?? 0) * 1000)
                : DateTime.now();
            
            // Check if bookmark already exists
            final existing = await findByUrl(url);
            if (existing == null) {
              // Generate unique ID with microseconds to prevent collisions
              final uniqueId = '${DateTime.now().microsecondsSinceEpoch}_$importCount';
              final bookmark = Bookmark(
                id: uniqueId,
                url: url,
                title: title,
                folder: currentFolder,
                tags: ['imported'],
                createdAt: timestamp,
              );
              
              await insert(bookmark);
              importCount++;
            }
          }
        }
      }
      
      DebugService.log('BookmarkService', 'Imported $importCount bookmarks from HTML');
      return importCount;
    } catch (e) {
      DebugService.log('BookmarkService', 'HTML import error: $e');
      return 0;
    }
  }

}
