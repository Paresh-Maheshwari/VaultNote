// ============================================================================
// GISTS SCREEN
// ============================================================================
//
// Shows all notes shared as GitHub Gists.
//
// Features:
// - Filter by: All, Public, Secret, Protected
// - Copy gist link to clipboard
// - Unshare (delete) gists
// - Open password-protected gists
// - View gist content preview
//
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../models/note.dart';
import '../providers/notes_provider.dart';
import '../providers/theme_provider.dart';
import '../services/gist_service.dart';
import '../services/encryption_service.dart';
import '../utils/snackbar_helper.dart';
import 'note_editor_screen.dart';
import 'rich_editor_screen.dart';

/// Screen showing all shared gists with management options.
class GistsScreen extends StatefulWidget {
  const GistsScreen({super.key});

  @override
  State<GistsScreen> createState() => _GistsScreenState();
}

enum GistFilter { all, public, private, protected }

class _GistsScreenState extends State<GistsScreen> {
  GistFilter _filter = GistFilter.all;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    
    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        title: const Text('Shared Gists'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'fab_gists',
        onPressed: _openProtectedGist,
        icon: const Icon(Icons.lock_open),
        label: const Text('Open Protected'),
      ),
      body: Consumer<NotesProvider>(
        builder: (context, provider, _) {
          // Get notes that are shared as gists
          var sharedNotes = provider.notes.where((n) => n.isSharedAsGist).toList();
          
          // Apply filter
          if (_filter == GistFilter.public) {
            sharedNotes = sharedNotes.where((n) => n.gistPublic == true).toList();
          } else if (_filter == GistFilter.private) {
            sharedNotes = sharedNotes.where((n) => n.gistPublic != true && n.gistPasswordProtected != true).toList();
          } else if (_filter == GistFilter.protected) {
            sharedNotes = sharedNotes.where((n) => n.gistPasswordProtected == true).toList();
          }
          
          final allCount = provider.notes.where((n) => n.isSharedAsGist).length;
          
          if (allCount == 0) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.share_outlined,
                    size: 64,
                    color: colors.onSurface.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No shared gists yet',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colors.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Share a note to create your first gist',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            );
          }
          
          return Column(
            children: [
              // Filter chips
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _filterChip('All', GistFilter.all, colors),
                      const SizedBox(width: 8),
                      _filterChip('Public', GistFilter.public, colors),
                      const SizedBox(width: 8),
                      _filterChip('Private', GistFilter.private, colors),
                      const SizedBox(width: 8),
                      _filterChip('Protected', GistFilter.protected, colors),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // List
              Expanded(
                child: sharedNotes.isEmpty
                  ? Center(
                      child: Text(
                        'No ${_filter.name} gists',
                        style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5)),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: sharedNotes.length,
                      itemBuilder: (context, index) => _buildGistCard(context, sharedNotes[index], colors, provider),
                    ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _filterChip(String label, GistFilter filter, ColorScheme colors) {
    final selected = _filter == filter;
    return FilterChip(
      label: Text(label, style: TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (_) => setState(() => _filter = filter),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }

  Widget _buildGistCard(BuildContext context, Note note, ColorScheme colors, NotesProvider provider) {
    final isPublic = note.gistPublic ?? false;
    final isProtected = note.gistPasswordProtected == true;
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: isProtected ? Colors.orange.withValues(alpha: 0.5) : colors.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _editNote(context, note),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      note.title.isEmpty ? 'Untitled' : note.title,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isProtected) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.key, size: 14, color: Colors.orange),
                          SizedBox(width: 4),
                          Text('Protected', style: TextStyle(fontSize: 12, color: Colors.orange, fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isPublic ? Colors.green.withValues(alpha: 0.1) : colors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isPublic ? Icons.public : Icons.lock_outline,
                          size: 14,
                          color: isPublic ? Colors.green : colors.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isPublic ? 'Public' : 'Private',
                          style: TextStyle(
                            fontSize: 12,
                            color: isPublic ? Colors.green : colors.primary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (note.tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 4,
                  children: note.tags.take(3).map((tag) => Chip(
                    label: Text(tag),
                    labelStyle: const TextStyle(fontSize: 11),
                    padding: EdgeInsets.zero,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  )).toList(),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text('Copy Link'),
                      onPressed: () => _copyGistUrl(context, note.gistUrl!),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: Icon(Icons.delete_outline, size: 16, color: colors.error),
                    label: Text('Unshare', style: TextStyle(color: colors.error)),
                    onPressed: () => _confirmUnshare(context, provider, note),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(color: colors.error.withValues(alpha: 0.5)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _copyGistUrl(BuildContext context, String url) {
    Clipboard.setData(ClipboardData(text: url));
    showAppSnackBar(context, 'Gist link copied');
  }

  void _confirmUnshare(BuildContext context, NotesProvider provider, Note note) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unshare Gist'),
        content: Text('Are you sure you want to unshare "${note.title}"?\n\nThis will delete the gist permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              provider.unshareGist(note.id);
            },
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Unshare'),
          ),
        ],
      ),
    );
  }

  void _openProtectedGist() async {
    final colors = Theme.of(context).colorScheme;
    final urlController = TextEditingController();
    final passwordController = TextEditingController();
    
    final result = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: 24, right: 24, top: 24,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.lock_open, color: colors.primary),
                const SizedBox(width: 12),
                const Text('Open Protected Gist', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              controller: urlController,
              decoration: InputDecoration(
                labelText: 'Gist URL',
                hintText: 'https://gist.github.com/...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.key),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.pop(context, {
                'url': urlController.text.trim(),
                'password': passwordController.text,
              }),
              child: const Text('Open'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
    
    if (result == null || result['url']!.isEmpty) return;
    
    // Extract gist ID from URL
    final gistId = _extractGistId(result['url']!);
    if (gistId == null) {
      if (mounted) showAppSnackBar(context, 'Invalid gist URL', isError: true);
      return;
    }
    
    if (!mounted) return;
    showAppSnackBar(context, 'Fetching gist...');
    
    // Fetch and decrypt
    final content = await GistService.fetchGistContent(gistId);
    if (content == null) {
      if (mounted) showAppSnackBar(context, 'Gist not found or does not exist', isError: true);
      return;
    }
    
    // Check if protected
    if (!EncryptionService.isProtectedGist(content)) {
      if (mounted) showAppSnackBar(context, 'This gist is not password-protected', isError: true);
      return;
    }
    
    // Decrypt
    final decrypted = EncryptionService.decryptProtectedGist(content, result['password']!);
    if (decrypted == null) {
      if (mounted) showAppSnackBar(context, 'Wrong password', isError: true);
      return;
    }
    
    if (!mounted) return;
    _showDecryptedGist(decrypted, gistId);
  }

  String? _extractGistId(String url) {
    // Handle: https://gist.github.com/user/id or just the id
    final uri = Uri.tryParse(url);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.last;
    }
    // Maybe it's just the ID
    if (url.length == 32 && !url.contains('/')) return url;
    return null;
  }

  void _showDecryptedGist(String content, String gistId) {
    final colors = Theme.of(context).colorScheme;
    final provider = context.read<NotesProvider>();
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.lock_open, color: colors.primary),
                  const SizedBox(width: 12),
                  const Expanded(child: Text('Protected Gist', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
                  IconButton(
                    icon: const Icon(Icons.copy),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: content));
                      showAppSnackBar(context, 'Copied to clipboard');
                    },
                    tooltip: 'Copy',
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Markdown(
                controller: scrollController,
                padding: const EdgeInsets.all(16),
                data: content,
                selectable: true,
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                icon: const Icon(Icons.save),
                label: const Text('Save to My Notes'),
                onPressed: () {
                  final now = DateTime.now();
                  final note = Note(
                    id: now.millisecondsSinceEpoch.toString(),
                    title: '',
                    content: content,
                    createdAt: now,
                    updatedAt: now,
                    isFavorite: false,
                  );
                  provider.addNote(note);
                  Navigator.pop(context);
                  showAppSnackBar(context, 'Saved to notes');
                  _navigateToEditor(context, note);
                },
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _editNote(BuildContext context, Note note) async {
    _navigateToEditor(context, note);
  }

  void _navigateToEditor(BuildContext context, Note note) {
    final useRich = context.read<ThemeProvider>().useRichEditor;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => useRich ? RichEditorScreen(note: note) : NoteEditorScreen(note: note),
    ));
  }
}
