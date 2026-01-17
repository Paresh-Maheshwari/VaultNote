// ============================================================================
// NOTES LIST SCREEN
// ============================================================================
//
// Main screen showing all notes with search, filter, and sort.
// Supports both mobile (bottom nav) and desktop (sidebar) layouts.
//
// Features:
// - Grid/list view toggle
// - Search by title, content, tags, folder
// - Filter by tag, folder, or starred
// - Sort by title, created, updated (pinned always first)
// - Star/favorite notes (tap star icon)
// - Pin notes (swipe right)
// - Delete notes (swipe left)
// - Pull-to-refresh sync
// - Keyboard shortcuts (Ctrl+N, Ctrl+F, Ctrl+R)
//
// Navigation:
// - All Notes (index 0)
// - Starred (index 1)
// - Gists (index 2)
// - Settings (index 3)
//
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../providers/notes_provider.dart';
import '../providers/theme_provider.dart';
import '../models/note.dart';
import '../services/encryption_service.dart';
import '../services/debug_service.dart';
import '../utils/snackbar_helper.dart';
import 'note_editor_screen.dart';
import 'rich_editor_screen.dart';
import 'settings_screen.dart';
import 'gists_screen.dart';

/// Main notes list screen with search, filter, and navigation.
class NotesListScreen extends StatefulWidget {
  const NotesListScreen({super.key});

  @override
  State<NotesListScreen> createState() => _NotesListScreenState();
}

class _NotesListScreenState extends State<NotesListScreen> with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  String _searchQuery = '';
  final Set<String> _filterTags = {};  // Multi-select tags
  String? _filterFolder;
  String _sortBy = 'updated';
  bool _sortAscending = false;
  bool _isGridView = true;
  int _selectedIndex = 0;
  bool _showOnlyStarred = false;
  
  // Cache decrypted content to avoid repeated decryption
  final Map<String, String> _decryptCache = {};
  
  // Pagination for performance with large note collections
  static const int _pageSize = 20;
  int _displayedCount = _pageSize;
  bool _isLoadingMore = false;

  /// Decrypt content for preview display.
  /// Uses master session password if content is encrypted.
  String _decryptContent(String noteId, String content, [String folder = '']) {
    if (!EncryptionService.isEncrypted(content)) return content;
    if (_decryptCache.containsKey(noteId)) return _decryptCache[noteId]!;
    
    // Try master session password
    final pwd = EncryptionService.sessionPassword;
    if (pwd != null) {
      try {
        final decrypted = EncryptionService.decrypt(content, pwd);
        if (decrypted != null) {
          _decryptCache[noteId] = decrypted;
          return decrypted;
        }
      } catch (e) {
        DebugService.log('Decrypt', 'Decrypt failed: $e');
      }
    }
    
    return content;
  }
  
  void clearDecryptCache() => _decryptCache.clear();

  // Pre-decrypt removed - notes are always plain text locally

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final provider = context.read<NotesProvider>();
      await provider.loadNotes();
      // Notes are always plain text - no pre-decryption needed
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Sync when app comes back to foreground
      final provider = context.read<NotesProvider>();
      if (provider.isGitHubConfigured) {
        provider.syncAll();
      }
    }
  }

  void _onScroll() {
    if (_isLoadingMore) return;
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 500) {
      setState(() {
        _isLoadingMore = true;
        _displayedCount += _pageSize;
        _isLoadingMore = false;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // Orphaned notes check removed - notes are always plain text locally

  bool get _isDesktop => MediaQuery.of(context).size.width >= 600;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _createNote,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => _searchFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): _refresh,
      },
      child: Focus(
        autofocus: true,
        child: _isDesktop ? _buildDesktopLayout() : _buildMobileLayout(),
      ),
    );
  }

  void _refresh() {
    final provider = context.read<NotesProvider>();
    provider.loadNotes();
    showAppSnackBar(context, 'Refreshed');
  }

  Widget _buildNotesTab() {
    return Consumer<NotesProvider>(
      builder: (context, provider, _) {
        return RefreshIndicator(
          onRefresh: () async => provider.loadNotes(),
          child: Column(
            children: [
              if (provider.lastError != null)
                MaterialBanner(
                  backgroundColor: Colors.red.shade50,
                  content: Text(provider.lastError!, style: const TextStyle(color: Colors.red)),
                  leading: const Icon(Icons.error_outline, color: Colors.red),
                  actions: [
                    TextButton(
                      onPressed: () => provider.clearError(),
                      child: const Text('Dismiss'),
                    ),
                    TextButton(
                      onPressed: () { provider.clearError(); provider.syncAll(); },
                      child: const Text('Retry'),
                    ),
                  ],
                ),

              if (provider.passwordChangeDetected)
                MaterialBanner(
                  content: const Text('Password changed on another device'),
                  actions: [
                    TextButton(
                      onPressed: () => _showPasswordUpdateDialog(context, provider),
                      child: const Text('Enter New Password'),
                    ),
                  ],
                ),
              _buildSearchBar(),
              _buildFilterChips(),
              Expanded(child: _buildNotesBody()),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDesktopLayout() {
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height,
            child: NavigationRail(
              selectedIndex: _selectedIndex > 1 ? null : _selectedIndex,
              onDestinationSelected: (i) {
                setState(() {
                  _selectedIndex = i;
                  _showOnlyStarred = (i == 1); // Index 1 is Starred
                });
              },
              labelType: NavigationRailLabelType.all,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    FloatingActionButton(
                      heroTag: 'fab_desktop',
                      onPressed: _createNote,
                      child: const Icon(Icons.add),
                    ),
                  ],
                ),
              ),
              destinations: const [
                NavigationRailDestination(icon: Icon(Icons.notes), label: Text('All Notes')),
                NavigationRailDestination(icon: Icon(Icons.star), label: Text('Starred')),
                NavigationRailDestination(icon: Icon(Icons.share), label: Text('Gists')),
              ],
              trailing: Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(
                            Icons.settings,
                            color: _selectedIndex == 3 ? Theme.of(context).colorScheme.primary : null,
                          ),
                          onPressed: () => setState(() => _selectedIndex = 3),
                          tooltip: 'Settings',
                        ),
                        Text(
                          'Settings',
                          style: TextStyle(
                            fontSize: 12,
                            color: _selectedIndex == 3 
                              ? Theme.of(context).colorScheme.primary 
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(
            child: _selectedIndex == 0 || _selectedIndex == 1
              ? _buildNotesTab()
              : _selectedIndex == 2
              ? const GistsScreen()
              : const SettingsScreen(),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileLayout() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vaultnote'),
        actions: [
          Consumer<NotesProvider>(
            builder: (context, provider, _) {
              if (provider.isSyncing) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                );
              }
              return IconButton(
                icon: const Icon(Icons.sync),
                onPressed: provider.isGitHubConfigured ? () => provider.syncAll() : null,
                tooltip: 'Sync with GitHub',
              );
            },
          ),
        ],
      ),
      body: _selectedIndex == 0 || _selectedIndex == 1
        ? _buildNotesTab()
        : _selectedIndex == 2
        ? const GistsScreen()
        : const SettingsScreen(),
      floatingActionButton: (_selectedIndex == 0 || _selectedIndex == 1) ? FloatingActionButton(
        heroTag: 'fab_mobile',
        onPressed: _createNote,
        child: const Icon(Icons.add),
      ) : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) {
          setState(() {
            _selectedIndex = i;
            _showOnlyStarred = (i == 1); // Index 1 is Starred
          });
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.notes), label: 'All Notes'),
          NavigationDestination(icon: Icon(Icons.star_outline), label: 'Starred'),
          NavigationDestination(icon: Icon(Icons.share), label: 'Gists'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Consumer<NotesProvider>(
        builder: (context, provider, _) => Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocus,
                  decoration: InputDecoration(
                    hintText: 'Search ${provider.notes.length} notes...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchQuery.isNotEmpty 
                      ? IconButton(icon: const Icon(Icons.close), onPressed: () { _searchController.clear(); setState(() { _searchQuery = ''; _displayedCount = _pageSize; }); })
                      : null,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  onChanged: (value) => setState(() { _searchQuery = value; _displayedCount = _pageSize; }),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(_isGridView ? Icons.view_list : Icons.grid_view),
              onPressed: () => setState(() => _isGridView = !_isGridView),
              tooltip: _isGridView ? 'List view' : 'Grid view',
            ),
            // Only show sync button on desktop (mobile has it in app bar)
            if (_isDesktop)
              Consumer<NotesProvider>(
                builder: (context, provider, _) {
                  if (provider.isSyncing) {
                    return const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    );
                  }
                  return IconButton(
                    icon: const Icon(Icons.sync),
                    onPressed: provider.isGitHubConfigured ? () => provider.syncAll() : null,
                    tooltip: 'Sync with GitHub',
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChips() {
    final colors = Theme.of(context).colorScheme;
    final isWide = MediaQuery.of(context).size.width >= 600;
    
    return Selector<NotesProvider, (List<Note>, List<String>, List<String>)>(
      selector: (_, p) => (p.notes, p.allTags, p.allFolders),
      builder: (context, data, _) {
        final (notes, allTags, allFolders) = data;
        final noteCount = _filterAndSortNotes(notes).length;
        final hasFilters = _filterTags.isNotEmpty || _filterFolder != null;
        final activeFilterCount = _filterTags.length + (_filterFolder != null ? 1 : 0);
        
        return Container(
          padding: EdgeInsets.fromLTRB(12, 8, 12, isWide ? 8 : 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Active filter chips (show when filters applied)
              if (hasFilters) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (_filterFolder != null)
                      _buildActiveChip(Icons.folder, _filterFolder!, () => setState(() => _filterFolder = null)),
                    ..._filterTags.map((tag) => _buildActiveChip(Icons.label, tag, () => setState(() => _filterTags.remove(tag)))),
                    if (activeFilterCount > 1)
                      ActionChip(
                        label: const Text('Clear all', style: TextStyle(fontSize: 12)),
                        onPressed: () => setState(() { _filterTags.clear(); _filterFolder = null; }),
                        visualDensity: VisualDensity.compact,
                        side: BorderSide.none,
                        backgroundColor: colors.errorContainer,
                        labelStyle: TextStyle(color: colors.onErrorContainer),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              // Filter bar
              Row(
                children: [
                  // Sort
                  _buildCompactChip(
                    icon: _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                    label: _sortBy == 'updated' ? 'Updated' : _sortBy == 'created' ? 'Created' : 'Title',
                    onTap: _showSortSheet,
                  ),
                  const SizedBox(width: 6),
                  // Tags
                  if (allTags.isNotEmpty) ...[
                    _buildCompactChip(
                      icon: Icons.label_outline,
                      label: isWide ? 'Tags' : null,
                      badge: _filterTags.isNotEmpty ? '${_filterTags.length}' : '${allTags.length}',
                      isActive: _filterTags.isNotEmpty,
                      onTap: () => _showTagsSheet(allTags),
                    ),
                    const SizedBox(width: 6),
                  ],
                  // Folders
                  if (allFolders.isNotEmpty)
                    _buildCompactChip(
                      icon: Icons.folder_outlined,
                      label: isWide ? 'Folders' : null,
                      badge: _filterFolder != null ? '1' : '${allFolders.length}',
                      isActive: _filterFolder != null,
                      onTap: () => _showFolderSheet(allFolders),
                    ),
                  const Spacer(),
                  // Note count
                  Text(
                    '$noteCount ${isWide ? (noteCount == 1 ? 'note' : 'notes') : ''}',
                    style: TextStyle(fontSize: 13, color: colors.outline, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActiveChip(IconData icon, String label, VoidCallback onRemove) {
    final colors = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(icon, size: 16, color: colors.onPrimaryContainer),
      label: Text(label, style: TextStyle(fontSize: 12, color: colors.onPrimaryContainer)),
      deleteIcon: Icon(Icons.close, size: 16, color: colors.onPrimaryContainer),
      onDeleted: onRemove,
      backgroundColor: colors.primaryContainer,
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  Widget _buildCompactChip({required IconData icon, String? label, String? badge, bool isActive = false, required VoidCallback onTap}) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? colors.primaryContainer : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: isActive ? Border.all(color: colors.primary, width: 1.5) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: isActive ? colors.primary : colors.onSurfaceVariant),
            if (label != null) ...[
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 12, color: isActive ? colors.primary : colors.onSurfaceVariant, fontWeight: FontWeight.w500)),
            ],
            if (badge != null) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: isActive ? colors.primary : colors.outline.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(badge, style: TextStyle(fontSize: 10, color: isActive ? colors.onPrimary : colors.onSurfaceVariant, fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(padding: EdgeInsets.all(16), child: Text('Sort by', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
            ListTile(
              leading: const Icon(Icons.update),
              title: const Text('Updated'),
              trailing: _sortBy == 'updated' ? Icon(_sortAscending ? Icons.arrow_upward : Icons.arrow_downward) : null,
              selected: _sortBy == 'updated',
              onTap: () {
                setState(() {
                  if (_sortBy == 'updated') {
                    _sortAscending = !_sortAscending;
                  } else {
                    _sortBy = 'updated';
                    _sortAscending = false;
                  }
                });
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.calendar_today),
              title: const Text('Created'),
              trailing: _sortBy == 'created' ? Icon(_sortAscending ? Icons.arrow_upward : Icons.arrow_downward) : null,
              selected: _sortBy == 'created',
              onTap: () {
                setState(() {
                  if (_sortBy == 'created') {
                    _sortAscending = !_sortAscending;
                  } else {
                    _sortBy = 'created';
                    _sortAscending = false;
                  }
                });
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.sort_by_alpha),
              title: const Text('Title'),
              trailing: _sortBy == 'title' ? Icon(_sortAscending ? Icons.arrow_upward : Icons.arrow_downward) : null,
              selected: _sortBy == 'title',
              onTap: () {
                setState(() {
                  if (_sortBy == 'title') {
                    _sortAscending = !_sortAscending;
                  } else {
                    _sortBy = 'title';
                    _sortAscending = false;
                  }
                });
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showTagsSheet(List<String> tags) {
    final colors = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
                child: Row(
                  children: [
                    Icon(Icons.label_outline, size: 20, color: colors.primary),
                    const SizedBox(width: 8),
                    Text('Tags${_filterTags.isNotEmpty ? ' (${_filterTags.length})' : ''}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                    const Spacer(),
                    if (_filterTags.isNotEmpty)
                      TextButton(
                        onPressed: () { setState(() => _filterTags.clear()); setSheetState(() {}); },
                        child: const Text('Clear'),
                      ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.4),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: tags.length,
                  itemBuilder: (_, i) {
                    final tag = tags[i];
                    final isSelected = _filterTags.contains(tag);
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                        size: 22,
                        color: isSelected ? colors.primary : colors.onSurfaceVariant,
                      ),
                      title: Text(tag, style: TextStyle(fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal)),
                      selected: isSelected,
                      onTap: () {
                        setState(() {
                          if (isSelected) {
                            _filterTags.remove(tag);
                          } else {
                            _filterTags.add(tag);
                          }
                        });
                        setSheetState(() {});
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showFolderSheet(List<String> folders) {
    final colors = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                children: [
                  Icon(Icons.folder_outlined, size: 20, color: colors.primary),
                  const SizedBox(width: 8),
                  const Text('Folders', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                  const Spacer(),
                  if (_filterFolder != null)
                    TextButton(
                      onPressed: () { setState(() => _filterFolder = null); Navigator.pop(ctx); },
                      child: const Text('Clear'),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.4),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: folders.length,
                itemBuilder: (_, i) {
                  final folder = folders[i];
                  final isSelected = _filterFolder == folder;
                  return ListTile(
                    dense: true,
                    leading: Icon(Icons.folder, size: 20, color: isSelected ? colors.primary : colors.onSurfaceVariant),
                    title: Text(folder, style: TextStyle(fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal)),
                    trailing: isSelected ? Icon(Icons.check, color: colors.primary, size: 20) : null,
                    selected: isSelected,
                    onTap: () { setState(() => _filterFolder = isSelected ? null : folder); Navigator.pop(ctx); },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotesBody() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 100),
      child: Selector<NotesProvider, (List<Note>, bool)>(
        selector: (_, p) => (p.notes, p.isLoading),
        builder: (context, data, _) {
          final (allNotes, isLoading) = data;
          if (isLoading) return const Center(child: CircularProgressIndicator());
          
          final notes = _filterAndSortNotes(allNotes);
        if (notes.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.note_add, size: 64, color: Colors.grey[400]),
                const SizedBox(height: 16),
                Text('No notes yet', style: TextStyle(color: Colors.grey[600], fontSize: 18)),
                const SizedBox(height: 8),
                Text('Tap + to create one', style: TextStyle(color: Colors.grey[500])),
              ],
            ),
          );
        }
        
        // Show only paginated notes
        final displayedNotes = notes.take(_displayedCount).toList();
        final hasMore = notes.length > _displayedCount;
        
        if (_isGridView) {
          return NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollEndNotification &&
                  notification.metrics.pixels >= notification.metrics.maxScrollExtent - 200 &&
                  hasMore && !_isLoadingMore) {
                setState(() {
                  _isLoadingMore = true;
                  _displayedCount += _pageSize;
                  _isLoadingMore = false;
                });
              }
              return false;
            },
            child: MasonryGridView.count(
              padding: const EdgeInsets.all(12),
              crossAxisCount: _isDesktop 
                ? (MediaQuery.of(context).size.width / 270).floor().clamp(2, 4)
                : 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              itemCount: displayedNotes.length + (hasMore ? 1 : 0),
              itemBuilder: (_, i) {
                if (i == displayedNotes.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  );
                }
                return _buildGridCard(displayedNotes[i]);
              },
            ),
          );
        }
        
        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: displayedNotes.length,
          itemBuilder: (_, i) => _buildNoteCard(displayedNotes[i]),
        );
      },
    ),
    );
  }
  
  List<Note> _filterAndSortNotes(List<Note> allNotes) {
    // Single pass filter
    final q = _searchQuery.toLowerCase();
    final hasSearch = _searchQuery.isNotEmpty;
    
    final filtered = allNotes.where((n) {
      if (hasSearch && !n.title.toLowerCase().contains(q) && !n.content.toLowerCase().contains(q)) return false;
      // Multi-tag filter: note must have ALL selected tags
      if (_filterTags.isNotEmpty && !_filterTags.every((tag) => n.tags.contains(tag))) return false;
      if (_filterFolder != null && n.folder != _filterFolder) return false;
      // Starred filter: show only favorite notes
      if (_showOnlyStarred && !n.isFavorite) return false;
      return true;
    }).toList();
    
    // Sort with pinned priority built-in
    filtered.sort((a, b) {
      // Pinned first
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      // Then by selected sort
      int cmp;
      switch (_sortBy) {
        case 'title': cmp = a.title.compareTo(b.title); break;
        case 'created': cmp = a.createdAt.compareTo(b.createdAt); break;
        default: cmp = a.updatedAt.compareTo(b.updatedAt);
      }
      return _sortAscending ? cmp : -cmp;
    });
    
    return filtered;
  }

  Widget _buildGridCard(Note note) {
    final colors = Theme.of(context).colorScheme;
    final content = _decryptContent(note.id, note.content, note.folder);
    final preview = content.length > 150 ? content.substring(0, 150) : content;
    
    return GestureDetector(
      key: ValueKey(note.id),
      onTap: () => _openNote(note),
      onLongPress: () => _showNoteActions(note),
      child: Container(
        decoration: BoxDecoration(
          color: note.isPinned ? colors.primaryContainer.withAlpha(50) : colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: note.isPinned ? Border.all(color: colors.primary.withAlpha(100), width: 1.5) : null,
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title row
            Row(
              children: [
                if (note.isPinned) Icon(Icons.push_pin, size: 14, color: colors.primary),
                if (note.isPinned) const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    note.title.isEmpty ? 'Untitled' : note.title,
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: colors.onSurface),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                GestureDetector(
                  onTap: () => _toggleStar(note),
                  child: Icon(
                    note.isFavorite ? Icons.star : Icons.star_border,
                    size: 18,
                    color: note.isFavorite ? Colors.amber : colors.onSurface.withAlpha(150),
                  ),
                ),
              ],
            ),
            // Content preview - markdown clipped
            if (preview.isNotEmpty) ...[
              const SizedBox(height: 8),
              Flexible(
                child: MarkdownBody(
                  data: preview,
                  shrinkWrap: true,
                  fitContent: true,
                  styleSheet: MarkdownStyleSheet(
                    p: TextStyle(fontSize: 12, color: colors.onSurface.withAlpha(180), height: 1.3),
                    h1: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: colors.onSurface),
                    h2: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: colors.onSurface),
                    code: TextStyle(fontSize: 10, backgroundColor: colors.surfaceContainerHighest),
                  ),
                ),
              ),
            ],
            // Tags
            if (note.tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: note.tags.take(3).map((t) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: colors.secondaryContainer, borderRadius: BorderRadius.circular(8)),
                  child: Text(t, style: TextStyle(fontSize: 10, color: colors.onSecondaryContainer)),
                )).toList(),
              ),
            ],
            // Footer
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.access_time, size: 12, color: colors.outline),
                const SizedBox(width: 4),
                Text(_formatDate(note.updatedAt), style: TextStyle(fontSize: 10, color: colors.outline)),
                const Spacer(),
                Icon(note.isSynced ? Icons.cloud_done : Icons.cloud_off, size: 12, color: note.isSynced ? colors.primary : colors.outline),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showNoteActions(Note note) {
    final provider = context.read<NotesProvider>();
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(note.isPinned ? Icons.push_pin_outlined : Icons.push_pin),
              title: Text(note.isPinned ? 'Unpin' : 'Pin'),
              onTap: () { provider.togglePin(note.id); Navigator.pop(ctx); },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () { provider.deleteNote(note.id); Navigator.pop(ctx); },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoteCard(Note note) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final provider = context.read<NotesProvider>();
    
    return Dismissible(
      key: ValueKey(note.id),
      background: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            color: Colors.green,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 20),
            child: Icon(note.isPinned ? Icons.push_pin_outlined : Icons.push_pin, color: Colors.white),
          ),
        ),
      ),
      secondaryBackground: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            color: Colors.red,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
        ),
      ),
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          provider.togglePin(note.id);
          return false;
        }
        return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete Note'),
            content: const Text('Are you sure?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
            ],
          ),
        ) ?? false;
      },
      onDismissed: (_) => provider.deleteNote(note.id),
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        elevation: note.isPinned ? 2 : 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: note.isPinned ? colors.primary.withValues(alpha: 0.5) : colors.outlineVariant.withValues(alpha: 0.5), width: note.isPinned ? 1.5 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openNote(note),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left: Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Title
                      Row(
                        children: [
                          if (note.isPinned) Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Icon(Icons.push_pin, size: 14, color: colors.primary),
                          ),
                          Expanded(
                            child: Text(
                              note.title.isEmpty ? 'Untitled' : note.title,
                              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      // Preview - MarkdownBody clipped
                      if (note.content.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Builder(
                          builder: (context) {
                            final decrypted = _decryptContent(note.id, note.content, note.folder);
                            final preview = decrypted.length > 200 ? decrypted.substring(0, 200) : decrypted;
                            if (preview.trim().isEmpty) return const SizedBox.shrink();
                            return Flexible(
                              child: MarkdownBody(
                                data: preview,
                                shrinkWrap: true,
                                softLineBreak: true,
                                styleSheet: MarkdownStyleSheet(
                                  p: TextStyle(fontSize: 13, color: colors.onSurface.withAlpha(180), height: 1.3),
                                  h1: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: colors.onSurface),
                                  h2: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: colors.onSurface),
                                  code: TextStyle(fontSize: 11, backgroundColor: colors.surfaceContainerHighest),
                                  blockSpacing: 2,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                      // Tags + Date row
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          if (note.tags.isNotEmpty) ...[
                            ...note.tags.take(2).map((t) => Container(
                              margin: const EdgeInsets.only(right: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: colors.secondaryContainer, borderRadius: BorderRadius.circular(6)),
                              child: Text(t, style: TextStyle(fontSize: 10, color: colors.onSecondaryContainer)),
                            )),
                            if (note.tags.length > 2) Text('+${note.tags.length - 2}', style: TextStyle(fontSize: 10, color: colors.outline)),
                            const SizedBox(width: 8),
                          ],
                          Icon(Icons.access_time, size: 11, color: colors.outline),
                          const SizedBox(width: 3),
                          Text(_formatDate(note.updatedAt), style: TextStyle(fontSize: 10, color: colors.outline)),
                        ],
                      ),
                    ],
                  ),
                ),
                // Right: Star + Sync icon
                const SizedBox(width: 8),
                Column(
                  children: [
                    GestureDetector(
                      onTap: () => _toggleStar(note),
                      child: Icon(
                        note.isFavorite ? Icons.star : Icons.star_border,
                        size: 18,
                        color: note.isFavorite ? Colors.amber : colors.outline,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Icon(note.isSynced ? Icons.cloud_done : Icons.cloud_off, size: 16, color: note.isSynced ? colors.primary : colors.outline),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${date.day}/${date.month}';
  }

  Future<void> _openNote(Note note) async {
    // Notes are always plain text - no decryption needed
    _navigateToEditor(note, null);
  }

  void _navigateToEditor(Note note, String? password) {
    final useRich = context.read<ThemeProvider>().useRichEditor;
    final isMobile = MediaQuery.of(context).size.width < 600;
    
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => (useRich && !isMobile)
          ? RichEditorScreen(note: note)
          : NoteEditorScreen(note: note),
    ));
  }

  // Unused methods removed - encryption logic simplified

  void _showPasswordUpdateDialog(BuildContext ctx, NotesProvider provider) {
    final controller = TextEditingController();
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('Enter New Password'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Password'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              if (controller.text.isEmpty) {
                showAppSnackBar(ctx, 'Password required', isError: true);
                return;
              }
              final ok = await provider.handleRemotePasswordChange(controller.text);
              if (ctx.mounted) Navigator.pop(ctx);
              if (!ok && ctx.mounted) {
                showAppSnackBar(ctx, 'Wrong password', isError: true);
              }
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _createNote() {
    final note = Note(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: '',
      content: '',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      isFavorite: false,
    );
    _navigateToEditor(note, null);
  }

  void _toggleStar(Note note) {
    final provider = Provider.of<NotesProvider>(context, listen: false);
    provider.toggleFavorite(note.id);
  }
}
