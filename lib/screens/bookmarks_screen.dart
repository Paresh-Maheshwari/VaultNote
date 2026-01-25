// ============================================================================
// BOOKMARKS SCREEN
// ============================================================================
//
// Main bookmarks management screen with search, filter, and organization.
// Supports folder-based organization and manual GitHub sync.
//
// Features:
// - Folder filtering with color-coded organization
// - Search by title and URL
// - Manual GitHub sync with progress indication
// - Import/export (JSON, HTML formats)
// - Bookmark editing and deletion
// - Visual folder indicators with custom colors
// - Pull-to-refresh for sync
//
// Organization:
// - Folder-based categorization (Work, Personal, etc.)
// - Nested folder support (Work/Projects)
// - Color-coded folder indicators
// - Search across all bookmarks
//
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import '../providers/bookmarks_provider.dart';
import '../models/bookmark.dart';
import 'bookmark_detail_screen.dart';

// Folder colors
const _folderColors = <String, Color>{
  'All': Colors.grey,
  'Bookmarks': Colors.blue,
  'Work': Colors.orange,
  'Personal': Colors.green,
  'Reading': Colors.purple,
  'Shared': Colors.teal,
  'Dev': Colors.red,
  'Design': Colors.pink,
  'Research': Colors.indigo,
};

Color _getFolderColor(String folder) {
  // Check exact match first
  if (_folderColors.containsKey(folder)) return _folderColors[folder]!;
  // Check parent folder for nested (e.g., "Work/Projects" -> "Work")
  final parent = folder.split('/').first;
  if (_folderColors.containsKey(parent)) return _folderColors[parent]!;
  // Hash-based color for unknown folders
  final hash = folder.hashCode.abs() % Colors.primaries.length;
  return Colors.primaries[hash];
}

class BookmarksScreen extends StatefulWidget {
  const BookmarksScreen({super.key});

  @override
  State<BookmarksScreen> createState() => _BookmarksScreenState();
}

class _BookmarksScreenState extends State<BookmarksScreen> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  String? _expandedParent; // For nested folder expansion
  Timer? _searchDebounceTimer;
  
  // Pagination
  static const int _pageSize = 30;
  int _displayedCount = _pageSize;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _searchController.addListener(_onSearchChanged);
  }
  
  void _onSearchChanged() {
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        context.read<BookmarksProvider>().setSearch(_searchController.text);
      }
    });
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 500) {
      setState(() => _displayedCount += _pageSize);
    }
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<BookmarksProvider>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    // Build folder tree
    final folderTree = _buildFolderTree(provider.folders);

    return Scaffold(
      body: Column(
        children: [
          // Search bar + menu
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                    hintText: 'Search bookmarks...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 20),
                            onPressed: () {
                              _searchController.clear();
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: isDark ? Colors.grey[900] : Colors.grey[100],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  onChanged: provider.setSearch,
                ),
              ),
              const SizedBox(width: 8),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (v) => _handleMenu(context, provider, v),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'export_json', child: Text('Export JSON')),
                  const PopupMenuItem(value: 'export_html', child: Text('Export HTML')),
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'import_json', child: Text('Import JSON')),
                  const PopupMenuItem(value: 'import_html', child: Text('Import HTML')),
                ],
              ),
            ],
          ),
        ),

        // Folder chips
        if (provider.folders.length > 1)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: _buildFolderChips(folderTree, provider),
            ),
          ),

        // Bookmarks list with time groups
        Expanded(
          child: provider.bookmarks.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bookmark_border, size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text('No bookmarks yet', style: TextStyle(color: Colors.grey[600])),
                      const SizedBox(height: 8),
                      Text('Use browser extension to save', style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                    ],
                  ),
                )
              : _buildGroupedList(context, provider),
        ),
      ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddDialog(context, provider),
        child: const Icon(Icons.add),
      ),
    );
  }

  // Build folder tree: {"Work": ["Work", "Work/Projects"], "Personal": ["Personal"]}
  Map<String, List<String>> _buildFolderTree(List<String> folders) {
    final tree = <String, List<String>>{};
    for (final folder in folders) {
      if (folder == 'All') continue;
      final parent = folder.split('/').first;
      tree.putIfAbsent(parent, () => []);
      if (!tree[parent]!.contains(folder)) tree[parent]!.add(folder);
    }
    return tree;
  }

  List<Widget> _buildFolderChips(Map<String, List<String>> tree, BookmarksProvider provider) {
    final chips = <Widget>[];
    final selected = provider.selectedFolder;
    
    // "All" chip
    chips.add(Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: const Text('All'),
        selected: selected == 'All',
        selectedColor: Colors.grey.withValues(alpha: 0.3),
        onSelected: (_) => provider.setFolder('All'),
      ),
    ));

    // Folder chips with colors
    for (final parent in tree.keys) {
      final children = tree[parent]!;
      final color = _getFolderColor(parent);
      final hasChildren = children.length > 1 || (children.isNotEmpty && children.first != parent);
      final isExpanded = _expandedParent == parent;
      final isSelected = selected == parent || children.contains(selected);

      chips.add(Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilterChip(
          avatar: hasChildren 
            ? Icon(isExpanded ? Icons.expand_less : Icons.expand_more, size: 18, color: isSelected ? Colors.white : color)
            : null,
          label: Text(parent),
          selected: isSelected,
          selectedColor: color.withValues(alpha: 0.8),
          backgroundColor: color.withValues(alpha: 0.15),
          labelStyle: TextStyle(color: isSelected ? Colors.white : color),
          onSelected: (_) {
            if (hasChildren) {
              setState(() => _expandedParent = isExpanded ? null : parent);
            }
            provider.setFolder(parent);
          },
        ),
      ));

      // Show subfolders if expanded
      if (isExpanded && hasChildren) {
        for (final child in children) {
          if (child == parent) continue;
          final subName = child.split('/').skip(1).join('/');
          chips.add(Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text('  $subName'),
              selected: selected == child,
              selectedColor: color.withValues(alpha: 0.6),
              backgroundColor: color.withValues(alpha: 0.1),
              labelStyle: TextStyle(color: selected == child ? Colors.white : color, fontSize: 12),
              onSelected: (_) => provider.setFolder(child),
            ),
          ));
        }
      }
    }
    return chips;
  }

  Widget _buildGroupedList(BuildContext context, BookmarksProvider provider) {
    final allBookmarks = provider.bookmarks;
    final bookmarks = allBookmarks.take(_displayedCount).toList();
    final hasMore = allBookmarks.length > _displayedCount;
    
    final groups = <String, List<Bookmark>>{};
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    
    for (final b in bookmarks) {
      final date = DateTime(b.createdAt.year, b.createdAt.month, b.createdAt.day);
      final diff = today.difference(date).inDays;
      String group;
      if (diff == 0) {
        group = 'Today';
      } else if (diff == 1) {
        group = 'Yesterday';
      } else if (diff < 7) {
        group = 'This Week';
      } else if (diff < 30) {
        group = 'This Month';
      } else {
        group = 'Older';
      }
      groups.putIfAbsent(group, () => []).add(b);
    }

    final order = ['Today', 'Yesterday', 'This Week', 'This Month', 'Older'];
    final items = <Widget>[];
    
    for (final group in order) {
      if (!groups.containsKey(group)) continue;
      items.add(Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: Text(group, style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey[600], fontSize: 13)),
      ));
      for (final bookmark in groups[group]!) {
        items.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _BookmarkCard(
            bookmark: bookmark,
            folderColor: _getFolderColor(bookmark.folder),
            onTap: () => _openDetail(context, bookmark),
            onLongPress: () => _copyUrl(context, bookmark.url),
            onDelete: () => _confirmDelete(context, provider, bookmark),
          ),
        ));
      }
    }
    
    if (hasMore) {
      items.add(const SizedBox(height: 50));
    }
    
    return ListView(controller: _scrollController, children: items);
  }

  void _openDetail(BuildContext context, Bookmark bookmark) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => BookmarkDetailScreen(bookmark: bookmark),
    ));
  }

  void _handleMenu(BuildContext context, BookmarksProvider provider, String action) async {
    try {
      switch (action) {
        case 'export_json':
          {
            final json = await provider.exportJson();
            if (context.mounted) {
              await _saveFile(context, 'bookmarks.json', json);
            }
            break;
          }
        case 'export_html':
          {
            final html = await provider.exportHtml();
            if (context.mounted) {
              await _saveFile(context, 'bookmarks.html', html);
            }
            break;
          }
        case 'import_json':
          {
            final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
            if (result != null) {
              final file = File(result.files.single.path!);
              final json = await file.readAsString();
              final count = await provider.importJson(json);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported $count bookmarks')));
              }
            }
            break;
          }
        case 'import_html':
          {
            final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['html', 'htm']);
            if (result != null) {
              final file = File(result.files.single.path!);
              final html = await file.readAsString();
              final count = await provider.importHtml(html);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported $count bookmarks')));
              }
            }
            break;
          }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _saveFile(BuildContext context, String filename, String content) async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = utf8.encode(content);
    String? path;

    if (Platform.isLinux) {
      try {
        path = await FilePicker.platform.saveFile(
          dialogTitle: 'Export Bookmarks',
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: [filename.split('.').last],
        );
      } catch (e) {
        // Fallback to manual path input on Linux
        if (!context.mounted) return;
        final controller = TextEditingController(text: '${Directory.current.path}/$filename');
        path = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Export Bookmarks'),
            content: TextField(
              controller: controller, 
              decoration: const InputDecoration(
                labelText: 'Save path', 
                border: OutlineInputBorder()
              ), 
              autofocus: true
            ),
            actions: [
              TextButton(
                onPressed: () {
                  controller.dispose();
                  Navigator.pop(ctx);
                }, 
                child: const Text('Cancel')
              ),
              FilledButton(
                onPressed: () {
                  final path = controller.text.trim();
                  controller.dispose();
                  Navigator.pop(ctx, path.isNotEmpty ? path : null);
                }, 
                child: const Text('Export')
              ),
            ],
          ),
        );
      }
    } else if (Platform.isAndroid || Platform.isIOS) {
      path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Bookmarks',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: [filename.split('.').last],
        bytes: Uint8List.fromList(bytes),
      );
      if (path != null) {
        messenger.showSnackBar(SnackBar(content: Text('Exported to $path')));
      }
      return;
    } else {
      path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Bookmarks',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: [filename.split('.').last],
      );
    }

    if (path == null || path.isEmpty) return;
    try {
      await File(path).writeAsString(content);
      messenger.showSnackBar(SnackBar(content: Text('Exported to $path')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  void _showAddDialog(BuildContext context, BookmarksProvider provider) {
    final urlController = TextEditingController();
    final titleController = TextEditingController();
    final tagsController = TextEditingController();
    final folders = {...provider.folders.where((f) => f != 'All'), 'Bookmarks'}.toList()..sort();
    String selectedFolder = provider.selectedFolder != 'All' && folders.contains(provider.selectedFolder) 
        ? provider.selectedFolder : 'Bookmarks';
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.bookmark_add, color: Colors.blue, size: 20),
              ),
              const SizedBox(width: 12),
              const Expanded(child: Text('Add Bookmark')),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: urlController,
                  decoration: InputDecoration(
                    labelText: 'URL',
                    hintText: 'https://...',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.grey.withValues(alpha: 0.05),
                    prefixIcon: const Icon(Icons.link, size: 20),
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: titleController,
                  decoration: InputDecoration(
                    labelText: 'Title (optional)',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.grey.withValues(alpha: 0.05),
                    prefixIcon: const Icon(Icons.title, size: 20),
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: ValueKey(selectedFolder),
                  initialValue: selectedFolder,
                  decoration: InputDecoration(
                    labelText: 'Folder',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.grey.withValues(alpha: 0.05),
                    prefixIcon: const Icon(Icons.folder, size: 20),
                  ),
                  items: [
                    ...folders.map((f) => DropdownMenuItem(value: f, child: Text(f))),
                    DropdownMenuItem(
                      value: '__new__',
                      child: Row(
                        children: [
                          Icon(Icons.create_new_folder, size: 18, color: Colors.blue[600]),
                          const SizedBox(width: 8),
                          Text('Create new folder', style: TextStyle(color: Colors.blue[600])),
                        ],
                      ),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == '__new__') {
                      final newFolderController = TextEditingController();
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          title: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.blue.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.create_new_folder, color: Colors.blue, size: 20),
                              ),
                              const SizedBox(width: 12),
                              const Text('New Folder'),
                            ],
                          ),
                          content: TextField(
                            controller: newFolderController,
                            autofocus: true,
                            textCapitalization: TextCapitalization.words,
                            decoration: InputDecoration(
                              labelText: 'Folder name',
                              hintText: 'e.g. Work, Research',
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              filled: true,
                              fillColor: Colors.grey.withValues(alpha: 0.05),
                              prefixIcon: const Icon(Icons.folder_outlined, size: 20),
                            ),
                            onSubmitted: (_) {
                              final name = newFolderController.text.trim();
                              if (name.isNotEmpty) {
                                folders.add(name);
                                folders.sort();
                                setState(() => selectedFolder = name);
                              }
                              Navigator.pop(ctx);
                            },
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                            FilledButton(
                              onPressed: () {
                                final name = newFolderController.text.trim();
                                if (name.isNotEmpty) {
                                  folders.add(name);
                                  folders.sort();
                                  setState(() => selectedFolder = name);
                                }
                                Navigator.pop(ctx);
                              },
                              child: const Text('Create'),
                            ),
                          ],
                        ),
                      );
                    } else {
                      setState(() => selectedFolder = v ?? 'Bookmarks');
                    }
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: tagsController,
                  decoration: InputDecoration(
                    labelText: 'Tags (comma separated)',
                    hintText: 'work, reference',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.grey.withValues(alpha: 0.05),
                    prefixIcon: const Icon(Icons.label, size: 20),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context), 
              child: const Text('Cancel')
            ),
            FilledButton.icon(
              onPressed: () async {
                final url = urlController.text.trim();
                if (url.isEmpty) return;
                final fullUrl = url.startsWith('http') ? url : 'https://$url';
                
                // Validate URL format
                final uri = Uri.tryParse(fullUrl);
                if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invalid URL'), backgroundColor: Colors.red),
                    );
                  }
                  return;
                }
                
                // Check duplicate
                final existing = await provider.checkDuplicate(fullUrl);
                if (existing != null) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Already saved: ${existing.title}'),
                        backgroundColor: Colors.orange,
                      ),
                    );
                  }
                  return;
                }
                
                final tags = tagsController.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
                provider.add(Bookmark(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  url: fullUrl,
                  title: titleController.text.trim().isEmpty ? url : titleController.text.trim(),
                  folder: selectedFolder,
                  tags: tags.isEmpty ? ['bookmark'] : tags,
                  createdAt: DateTime.now(),
                ));
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Bookmark added'), duration: Duration(seconds: 2))
                  );
                }
              },
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }



  void _copyUrl(BuildContext context, String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('URL copied'), duration: Duration(seconds: 1)),
    );
  }

  void _confirmDelete(BuildContext context, BookmarksProvider provider, Bookmark bookmark) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete bookmark?'),
        content: Text(bookmark.title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              provider.delete(bookmark.id);
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

class _BookmarkCard extends StatelessWidget {
  final Bookmark bookmark;
  final Color folderColor;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;

  const _BookmarkCard({
    required this.bookmark,
    required this.folderColor,
    required this.onTap, 
    required this.onLongPress,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final domain = Uri.tryParse(bookmark.url)?.host.replaceFirst('www.', '') ?? '';
    final faviconUrl = domain.isNotEmpty ? 'https://icons.duckduckgo.com/ip3/$domain.ico' : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Color indicator
              Container(
                width: 4,
                height: 40,
                decoration: BoxDecoration(
                  color: folderColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              // Favicon
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: faviconUrl != null 
                  ? Image.network(
                      faviconUrl,
                      width: 36,
                      height: 36,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildFallbackIcon(domain, isDark, theme),
                    )
                  : _buildFallbackIcon(domain, isDark, theme),
              ),
              const SizedBox(width: 12),
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bookmark.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(domain, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                    // Show tags
                    if (bookmark.tags.isNotEmpty && bookmark.tags.first != 'bookmark')
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Wrap(
                          spacing: 4,
                          children: bookmark.tags.take(3).map((t) => Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.grey.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(t, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
                          )).toList(),
                        ),
                      ),
                  ],
                ),
              ),
              // Actions - show buttons directly on desktop, menu on mobile
              Builder(
                builder: (context) {
                  final isDesktop = MediaQuery.of(context).size.width > 600;
                  if (isDesktop) {
                    // Desktop: show buttons directly
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.copy, size: 18),
                          onPressed: onLongPress,
                          tooltip: 'Copy URL',
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, size: 18, color: Colors.red),
                          onPressed: onDelete,
                          tooltip: 'Delete',
                        ),
                      ],
                    );
                  }
                  // Mobile: 3-dot menu
                  return PopupMenuButton<String>(
                    icon: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(Icons.more_vert, size: 18, color: Colors.grey[600]),
                    ),
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 8,
                    onSelected: (v) {
                      switch (v) {
                        case 'copy': onLongPress();
                        case 'delete': onDelete();
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'copy', 
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.blue.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Icon(Icons.copy, size: 16, color: Colors.blue),
                            ),
                            const SizedBox(width: 12),
                            const Text('Copy URL'),
                          ]
                        )
                      ),
                      PopupMenuItem(
                        value: 'delete', 
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.red.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                            ),
                            const SizedBox(width: 12),
                            const Text('Delete', style: TextStyle(color: Colors.red)),
                          ]
                        )
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFallbackIcon(String domain, bool isDark, ThemeData theme) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[800] : Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          domain.isNotEmpty ? domain[0].toUpperCase() : 'B',
          style: TextStyle(fontWeight: FontWeight.bold, color: theme.primaryColor),
        ),
      ),
    );
  }
}
