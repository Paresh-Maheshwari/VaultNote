// ============================================================================
// BOOKMARK MODEL
// ============================================================================
//
// Data model representing a saved bookmark with metadata and user annotations.
// Supports nested folder organization and timestamped notes.
//
// Features:
// - Basic metadata (title, URL, description)
// - Visual elements (favicon, Open Graph image)
// - User organization (folder, tags, notes)
// - Sync tracking (creation date, sync status)
// - Nested folder support using '/' separator
// - Multiple timestamped notes separated by "---" markers
//
// ============================================================================

/// Represents a saved bookmark with metadata and user annotations.
/// 
/// This model stores all information about a bookmarked webpage including:
/// - Basic metadata (title, URL, description)
/// - Visual elements (favicon, Open Graph image)
/// - User organization (folder, tags, notes)
/// - Sync tracking (creation date, sync status)
/// 
/// Supports nested folder organization using '/' separator (e.g., "Work/Projects").
/// Notes can contain multiple timestamped entries separated by "---" markers.
class Bookmark {
  /// Unique identifier for the bookmark (typically timestamp-based)
  final String id;
  
  /// Target URL of the bookmarked page
  final String url;
  
  /// Display title (from page title or user-defined)
  final String title;
  
  /// Meta description extracted from webpage (optional)
  final String? description;
  
  /// Open Graph image URL for visual preview (optional)
  final String? image;
  
  /// User-added notes, supports multiple timestamped entries (optional)
  final String? notes;
  
  /// Website favicon URL for visual identification (optional)
  final String? favicon;
  
  /// Organization folder, supports nesting with '/' (default: 'Bookmarks')
  final String folder;
  
  /// Searchable tags for categorization
  final List<String> tags;
  
  /// Timestamp when bookmark was created
  final DateTime createdAt;
  
  /// Whether bookmark has been synced to GitHub
  final bool isSynced;

  /// Creates a new Bookmark instance with all required and optional fields.
  Bookmark({
    required this.id,
    required this.url,
    required this.title,
    this.description,
    this.image,
    this.notes,
    this.favicon,
    this.folder = 'Bookmarks',
    this.tags = const [],
    required this.createdAt,
    this.isSynced = false,
  }) : assert(id.isNotEmpty, 'Bookmark ID cannot be empty'),
       assert(url.isNotEmpty, 'Bookmark URL cannot be empty'),
       assert(title.isNotEmpty, 'Bookmark title cannot be empty');

  /// Creates a copy of this bookmark with optionally updated fields.
  /// 
  /// Useful for updating specific properties while maintaining immutability.
  /// Any field not provided will retain its current value.
  Bookmark copyWith({
    String? id,
    String? url,
    String? title,
    String? description,
    String? image,
    String? notes,
    String? favicon,
    String? folder,
    List<String>? tags,
    DateTime? createdAt,
    bool? isSynced,
  }) {
    return Bookmark(
      id: id ?? this.id,
      url: url ?? this.url,
      title: title ?? this.title,
      description: description ?? this.description,
      image: image ?? this.image,
      notes: notes ?? this.notes,
      favicon: favicon ?? this.favicon,
      folder: folder ?? this.folder,
      tags: tags ?? this.tags,
      createdAt: createdAt ?? this.createdAt,
      isSynced: isSynced ?? this.isSynced,
    );
  }

  /// Converts bookmark to JSON map for database storage.
  /// 
  /// Tags are joined with commas, dates are ISO8601 strings.
  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'title': title,
    'description': description,
    'image': image,
    'notes': notes,
    'favicon': favicon,
    'folder': folder,
    'tags': tags.join(','),
    'createdAt': createdAt.toIso8601String(),
    'isSynced': isSynced ? 1 : 0,
  };

  /// Creates bookmark from JSON map (typically from database).
  /// 
  /// Handles type conversions: comma-separated tags to list,
  /// ISO8601 string to DateTime.
  /// Provides defaults for missing optional fields.
  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
    id: json['id'] as String,
    url: json['url'] as String,
    title: json['title'] as String,
    description: json['description'] as String?,
    image: json['image'] as String?,
    notes: json['notes'] as String?,
    favicon: json['favicon'] as String?,
    folder: json['folder'] as String? ?? 'Bookmarks',
    tags: (json['tags'] as String?)?.split(',').where((t) => t.isNotEmpty).toList() ?? [],
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    isSynced: (json['isSynced'] ?? 0) == 1,
  );
}
