// ============================================================================
// DATABASE SERVICE
// ============================================================================
//
// SQLite database for local note and bookmark storage.
// 
// Tables:
// - notes: All note data (id, title, content, tags, folder, gist info, etc.)
// - bookmarks: All bookmark data (id, url, title, description, folder, etc.)
// - encryption_versions: Tracks encryption state for sync
//
// Database location: {app_support_dir}/databases/notes.db
// ============================================================================

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../models/note.dart';
import 'debug_service.dart';

/// SQLite database service for local storage.
class DatabaseService {
  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  /// Initialize database.
  Future<Database> _initDatabase() async {
    final dir = await getApplicationSupportDirectory();
    final dbDir = Directory(join(dir.path, 'databases'));
    if (!await dbDir.exists()) {
      await dbDir.create(recursive: true);
    }
    String path = join(dbDir.path, 'notes.db');
    DebugService.log('DB', 'Opening database: $path');
    return await openDatabase(
      path,
      version: 2,
      onCreate: _createDatabase,
      onUpgrade: _upgradeDatabase,
    );
  }

  /// Create tables for fresh install.
  Future<void> _createDatabase(Database db, int version) async {
    await db.execute('''
      CREATE TABLE notes(
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        tags TEXT,
        folder TEXT,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL,
        isSynced INTEGER NOT NULL DEFAULT 0,
        isPinned INTEGER NOT NULL DEFAULT 0,
        isFavorite INTEGER NOT NULL DEFAULT 0,
        gistId TEXT,
        gistUrl TEXT,
        gistPublic INTEGER NOT NULL DEFAULT 0,
        gistPasswordProtected INTEGER NOT NULL DEFAULT 0
      )
    ''');
    
    await db.execute('''
      CREATE TABLE bookmarks (
        id TEXT PRIMARY KEY,
        url TEXT NOT NULL,
        title TEXT NOT NULL,
        description TEXT,
        image TEXT,
        notes TEXT,
        favicon TEXT,
        folder TEXT DEFAULT 'Bookmarks',
        tags TEXT,
        createdAt TEXT NOT NULL,
        isSynced INTEGER DEFAULT 0
      )
    ''');
    
    // Encryption version tracking table
    await db.execute('''
      CREATE TABLE encryption_versions (
        id INTEGER PRIMARY KEY,
        local_version INTEGER NOT NULL DEFAULT 0,
        remote_version INTEGER NOT NULL DEFAULT 0,
        local_enabled INTEGER NOT NULL DEFAULT 0,
        remote_enabled INTEGER NOT NULL DEFAULT 0,
        last_synced TEXT NOT NULL,
        repo_key TEXT NOT NULL UNIQUE
      )
    ''');
  }

  /// Handle database upgrades
  Future<void> _upgradeDatabase(Database db, int oldVersion, int newVersion) async {
    DebugService.log('DB', 'Upgrading database from v$oldVersion to v$newVersion');
    
    try {
      if (oldVersion < 2) {
        // Add bookmarks table in version 2
        await db.execute('''
          CREATE TABLE bookmarks (
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            title TEXT NOT NULL,
            description TEXT,
            image TEXT,
            notes TEXT,
            favicon TEXT,
            folder TEXT DEFAULT 'Bookmarks',
            tags TEXT,
            createdAt TEXT NOT NULL,
            isSynced INTEGER DEFAULT 0
          )
        ''');
        DebugService.log('DB', 'Added bookmarks table in database upgrade');
      }
      
      // Handle future versions
      if (oldVersion < 3) {
        // Future migration logic goes here
        DebugService.log('DB', 'Database already at latest version');
      }
      
    } catch (e) {
      DebugService.log('DB', 'Database upgrade failed: $e', isError: true);
      throw Exception('Database upgrade failed: $e');
    }
  }

  // === Note Operations ===

  Future<List<Note>> getAllNotes() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('notes');
    int withGist = 0;
    final notes = List.generate(maps.length, (i) {
      final m = maps[i];
      final tagsStr = m['tags'] as String?;
      final tags = tagsStr != null && tagsStr.isNotEmpty 
          ? tagsStr.split(',').where((t) => t.isNotEmpty).toList() 
          : <String>[];
      if (m['gistId'] != null) withGist++;
      return Note.fromJson({
        ...m,
        'tags': tags,
        'isSynced': m['isSynced'] == 1,
        'isPinned': m['isPinned'] == 1,
        'isFavorite': (m['isFavorite'] ?? 0) == 1,
        'gistPublic': m['gistPublic'] == 1,
        'gistPasswordProtected': m['gistPasswordProtected'] == 1,
      });
    });
    if (withGist > 0) {
      DebugService.log('DB', 'Found $withGist notes with gistId in database');
    }
    return notes;
  }

  Future<void> insertNote(Note note) async {
    final db = await database;
    await db.insert(
      'notes',
      {
        ...note.toJson(),
        'tags': note.tags.join(','),
        'isSynced': note.isSynced ? 1 : 0,
        'isPinned': note.isPinned ? 1 : 0,
        'isFavorite': note.isFavorite ? 1 : 0,
        'gistPublic': (note.gistPublic ?? false) ? 1 : 0,
        'gistPasswordProtected': (note.gistPasswordProtected ?? false) ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateNote(Note note) async {
    final db = await database;
    await db.update(
      'notes',
      {
        ...note.toJson(),
        'tags': note.tags.join(','),
        'isSynced': note.isSynced ? 1 : 0,
        'isPinned': note.isPinned ? 1 : 0,
        'isFavorite': note.isFavorite ? 1 : 0,
        'gistPublic': (note.gistPublic ?? false) ? 1 : 0,
        'gistPasswordProtected': (note.gistPasswordProtected ?? false) ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [note.id],
    );
  }

  Future<void> deleteNote(String id) async {
    final db = await database;
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }

  /// Clear all notes from the database
  Future<void> clearAllNotes() async {
    final db = await database;
    await db.delete('notes');
    DebugService.log('Database', 'All notes cleared from database');
  }

  // === Encryption Version Tracking ===

  /// Update encryption version state in database
  Future<void> updateEncryptionVersions({
    required String repoKey,
    required int localVersion,
    required int remoteVersion,
    required bool localEnabled,
    required bool remoteEnabled,
  }) async {
    final db = await database;
    await db.insert(
      'encryption_versions',
      {
        'local_version': localVersion,
        'remote_version': remoteVersion,
        'local_enabled': localEnabled ? 1 : 0,
        'remote_enabled': remoteEnabled ? 1 : 0,
        'last_synced': DateTime.now().toIso8601String(),
        'repo_key': repoKey,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get encryption version state from database
  Future<Map<String, dynamic>?> getEncryptionVersions(String repoKey) async {
    final db = await database;
    final maps = await db.query(
      'encryption_versions',
      where: 'repo_key = ?',
      whereArgs: [repoKey],
      limit: 1,
    );
    
    if (maps.isNotEmpty) {
      final data = maps.first;
      return {
        'local_version': data['local_version'],
        'remote_version': data['remote_version'],
        'local_enabled': data['local_enabled'] == 1,
        'remote_enabled': data['remote_enabled'] == 1,
        'last_synced': data['last_synced'],
      };
    }
    return null;
  }

  /// Clear encryption versions for repo (when disconnecting)
  Future<void> clearEncryptionVersions(String repoKey) async {
    final db = await database;
    await db.delete('encryption_versions', where: 'repo_key = ?', whereArgs: [repoKey]);
  }
}
