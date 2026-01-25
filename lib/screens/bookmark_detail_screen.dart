// ============================================================================
// BOOKMARK DETAIL SCREEN
// ============================================================================
//
// Detail view for individual bookmark viewing and editing.
// Provides comprehensive bookmark information and management.
//
// Features:
// - Hero image display (Open Graph image)
// - URL display in styled container with copy functionality
// - Editable notes section with auto-save
// - Metadata display (folder, creation date, tags)
// - Action buttons (open URL, edit, delete)
// - Responsive layout for different screen sizes
//
// Notes Editing:
// - Auto-save with debounce timer (500ms)
// - Supports timestamped entries
// - Preserves formatting and line breaks
//
// ============================================================================

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/bookmark.dart';
import '../providers/bookmarks_provider.dart';

/// Detail screen for viewing and editing a single bookmark.
/// 
/// Displays bookmark information including:
/// - Hero image (if available)
/// - Title
/// - URL in a styled container
/// - Description and tags
/// - Metadata (folder and creation date)
/// - Editable notes section
/// 
/// Provides actions for opening URL, copying, editing, and deletion.
class BookmarkDetailScreen extends StatefulWidget {
  /// The bookmark to display and edit
  final Bookmark bookmark;
  
  const BookmarkDetailScreen({super.key, required this.bookmark});

  @override
  State<BookmarkDetailScreen> createState() => _BookmarkDetailScreenState();
}

class _BookmarkDetailScreenState extends State<BookmarkDetailScreen> {
  /// Current bookmark state (may be updated during editing)
  late Bookmark _bookmark;
  
  /// Provider for bookmark operations (update, delete, toggle read)
  late BookmarksProvider _provider;
  
  /// Controller for the notes text field
  late TextEditingController _notesController;
  
  /// Debounce timer for notes auto-save
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _bookmark = widget.bookmark;
    // Initialize notes controller with existing notes content
    _notesController = TextEditingController(text: _bookmark.notes ?? '');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _provider = context.read<BookmarksProvider>();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Extract domain from URL for app bar title
    final domain = Uri.tryParse(_bookmark.url)?.host.replaceFirst('www.', '') ?? '';

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      // App bar with domain title and action buttons
      appBar: AppBar(
        backgroundColor: theme.appBarTheme.backgroundColor,
        elevation: 0,
        title: Text(domain.isNotEmpty ? domain : 'Bookmark'),
        actions: [
          // Copy URL button
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _bookmark.url));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('URL copied')),
              );
            },
          ),
          // Edit bookmark button
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: _showEditDialog,
          ),
          // Delete button
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            onPressed: _showDeleteDialog,
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Hero image section (if available)
            if (_bookmark.image != null)
              LayoutBuilder(
                builder: (context, constraints) {
                  final isDesktop = constraints.maxWidth > 600;
                  if (!isDesktop) {
                    // Mobile: full width
                    return Image.network(
                      _bookmark.image!,
                      width: double.infinity,
                      height: 200,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        height: 200,
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Center(child: Icon(Icons.image_not_supported, size: 48)),
                      ),
                    );
                  }
                  // Desktop: constrained width, centered
                  return Center(
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 500),
                      margin: const EdgeInsets.symmetric(horizontal: 24),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Image.network(
                            _bookmark.image!,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: const Center(child: Icon(Icons.image_not_supported, size: 48)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            
            // Main content section
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title
                  Text(
                    _bookmark.title,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  // URL display container
                  GestureDetector(
                    onTap: () => launchUrl(Uri.parse(_bookmark.url), mode: LaunchMode.externalApplication),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _bookmark.url,
                        style: TextStyle(color: Colors.blue[600], fontSize: 13),
                      ),
                    ),
                  ),
                  
                  // Description section (if available)
                  if (_bookmark.description != null && _bookmark.description!.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      _bookmark.description!,
                      style: TextStyle(color: Colors.grey[600], height: 1.4),
                    ),
                  ],
                  
                  // Tags section (if available)
                  if (_bookmark.tags.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _bookmark.tags.map((tag) => Chip(
                        label: Text(tag, style: const TextStyle(fontSize: 12)),
                        visualDensity: VisualDensity.compact,
                      )).toList(),
                    ),
                  ],
                  
                  // Metadata section (folder and creation date)
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(Icons.folder_outlined, size: 16, color: Colors.grey[600]),
                      const SizedBox(width: 4),
                      Text(_bookmark.folder, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                      const SizedBox(width: 16),
                      Icon(Icons.schedule, size: 16, color: Colors.grey[600]),
                      const SizedBox(width: 4),
                      Text(_formatDate(_bookmark.createdAt), style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                    ],
                  ),
                  
                  // Notes section - editable plain text area
                  const SizedBox(height: 24),
                  const Text('Notes', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(minHeight: 120),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.cardTheme.color,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: theme.dividerColor),
                    ),
                    child: TextField(
                      controller: _notesController,
                      maxLines: null, // Allow unlimited lines
                      decoration: const InputDecoration(
                        hintText: 'Write your notes here...',
                        border: InputBorder.none, // Clean look without borders
                      ),
                      onChanged: _updateNotes, // Auto-save on every change
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Updates bookmark notes with debouncing (500ms delay).
  /// 
  /// Called on every text change in the notes field.
  /// Debounces to avoid excessive database writes.
  void _updateNotes(String text) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return; // Check if widget is still mounted
      final updatedBookmark = _bookmark.copyWith(notes: text);
      _provider.update(updatedBookmark);
      setState(() => _bookmark = updatedBookmark);
    });
  }

  /// Shows edit dialog for bookmark title, tags, and folder.
  void _showEditDialog() {
    final titleController = TextEditingController(text: _bookmark.title);
    final tagsController = TextEditingController(text: _bookmark.tags.join(', '));
    final folderController = TextEditingController(text: _bookmark.folder);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Bookmark'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(labelText: 'Title'),
              maxLength: 200,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: tagsController,
              decoration: const InputDecoration(labelText: 'Tags (comma separated)'),
              maxLength: 500,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: folderController,
              decoration: const InputDecoration(labelText: 'Folder'),
              maxLength: 100,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              titleController.dispose();
              tagsController.dispose();
              folderController.dispose();
              Navigator.pop(context);
            }, 
            child: const Text('Cancel')
          ),
          TextButton(
            onPressed: () {
              final title = titleController.text.trim();
              final folder = folderController.text.trim();
              
              // Validate inputs
              if (title.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Title cannot be empty')),
                );
                return;
              }
              
              final updatedBookmark = _bookmark.copyWith(
                title: title,
                tags: tagsController.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList(),
                folder: folder.isEmpty ? 'Bookmarks' : folder,
              );
              
              titleController.dispose();
              tagsController.dispose();
              folderController.dispose();
              
              _provider.update(updatedBookmark);
              setState(() => _bookmark = updatedBookmark);
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
  /// 
  /// Displays bookmark title in confirmation message and provides
  /// cancel/delete options. On delete, removes bookmark and navigates back.
  void _showDeleteDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Bookmark'),
        content: Text('Delete "${_bookmark.title}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              _provider.delete(_bookmark.id);
              Navigator.pop(context); // Close dialog
              Navigator.pop(context); // Close detail screen
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  /// Formats creation date into human-readable relative time.
  /// 
  /// Returns user-friendly strings like "today", "yesterday", "3 days ago"
  /// for recent dates, or full date for older bookmarks.
  /// 
  /// [date] - DateTime to format
  /// Returns formatted string representation
  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inDays == 0) return 'today';
    if (diff.inDays == 1) return 'yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${date.day}/${date.month}/${date.year}';
  }
}
