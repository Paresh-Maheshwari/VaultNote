/// Note model - represents a single note in the app.
/// 
/// Stored in SQLite locally and synced to GitHub as markdown files.
/// Content may be encrypted (starts with "ENC:" prefix).
/// Gist info is stored in the note itself for easy sync.
class Note {
  final String id;          // Unique ID (timestamp-based)
  final String title;
  final String content;     // May be encrypted
  final List<String> tags;
  final String folder;      // Folder name
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isSynced;      // True if synced to GitHub
  final bool isPinned;      // Pinned notes appear first
  final bool isFavorite;    // Starred/favorite notes
  // Gist sharing info (syncs with note)
  final String? gistId;     // GitHub gist ID
  final String? gistUrl;    // Shareable gist URL
  final bool? gistPublic;   // Public or private gist (nullable for migration)
  final bool? gistPasswordProtected;  // Password-protected gist (no auto-update)

  Note({
    required this.id,
    required this.title,
    required this.content,
    this.tags = const [],
    this.folder = '',
    required this.createdAt,
    required this.updatedAt,
    this.isSynced = false,
    this.isPinned = false,
    this.isFavorite = false,
    this.gistId,
    this.gistUrl,
    this.gistPublic,
    this.gistPasswordProtected,
  });

  /// Check if note is shared as gist.
  bool get isSharedAsGist => gistId != null && gistUrl != null;

  /// Convert to JSON for storage/export.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'tags': tags,
      'folder': folder,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'isSynced': isSynced,
      'isPinned': isPinned,
      'isFavorite': isFavorite,
      'gistId': gistId,
      'gistUrl': gistUrl,
      'gistPublic': gistPublic,
      'gistPasswordProtected': gistPasswordProtected,
    };
  }

  /// Create from JSON.
  factory Note.fromJson(Map<String, dynamic> json) {
    return Note(
      id: json['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      title: json['title'] ?? '',
      content: json['content'] ?? '',
      tags: List<String>.from(json['tags'] ?? []),
      folder: json['folder'] ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] ?? '') ?? DateTime.now(),
      isSynced: json['isSynced'] ?? false,
      isPinned: json['isPinned'] ?? false,
      isFavorite: json['isFavorite'] ?? false,
      gistId: json['gistId'],
      gistUrl: json['gistUrl'],
      gistPublic: json['gistPublic'] ?? false,
      gistPasswordProtected: json['gistPasswordProtected'],
    );
  }

  /// Create copy with updated fields.
  Note copyWith({
    String? title,
    String? content,
    List<String>? tags,
    String? folder,
    DateTime? updatedAt,
    bool? isSynced,
    bool? isPinned,
    bool? isFavorite,
    String? gistId,
    String? gistUrl,
    bool? gistPublic,
    bool? gistPasswordProtected,
    bool clearGist = false,  // Set true to remove gist info
  }) {
    return Note(
      id: id,
      title: title ?? this.title,
      content: content ?? this.content,
      tags: tags ?? this.tags,
      folder: folder ?? this.folder,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isSynced: isSynced ?? this.isSynced,
      isPinned: isPinned ?? this.isPinned,
      isFavorite: isFavorite ?? this.isFavorite,
      gistId: clearGist ? null : (gistId ?? this.gistId),
      gistUrl: clearGist ? null : (gistUrl ?? this.gistUrl),
      gistPublic: clearGist ? false : (gistPublic ?? this.gistPublic ?? false),
      gistPasswordProtected: clearGist ? null : (gistPasswordProtected ?? this.gistPasswordProtected),
    );
  }
}
