// ============================================================================
// NOTE EDITOR SCREEN
// ============================================================================
//
// Markdown note editor with:
// - Live preview mode (Ctrl+P)
// - Focus mode (distraction-free writing)
// - Markdown toolbar with formatting shortcuts
// - Folder and tag management
// - Gist sharing with password protection
// - Auto-save to GitHub on save
//
// ## Keyboard Shortcuts
// - Ctrl+S: Save note
// - Ctrl+P: Toggle preview
// - Esc: Exit focus/preview mode
//
// ============================================================================

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:highlight/highlight.dart' as highlight;
import 'package:markdown/markdown.dart' as md;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/notes_provider.dart';
import '../providers/theme_provider.dart';
import '../models/note.dart';
import '../utils/snackbar_helper.dart';

class _ShareResult {
  final bool isPublic;
  final String? password;
  _ShareResult({required this.isPublic, this.password});
}

/// Note editor screen with markdown support.
class NoteEditorScreen extends StatefulWidget {
  final Note note;
  const NoteEditorScreen({super.key, required this.note});

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

enum EditorMode { edit, preview }

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late TextEditingController _contentController;
  late TextEditingController _titleController;
  late TextEditingController _tagsController;
  late TextEditingController _folderController;
  List<String> _availableFolders = [];
  bool _isNewNote = false;
  bool _focusMode = false;
  bool _hasChanges = false;
  bool _showPreview = false;
  DateTime? _lastSaved;
  final FocusNode _contentFocus = FocusNode();
  final FocusNode _titleFocus = FocusNode();
  bool _isKeyboardVisible = false;
  
  // Cache platform check (computed once)
  static final bool _isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  
  // Undo/Redo history (max 50 entries)
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];
  String _lastText = '';

  @override
  void initState() {
    super.initState();
    _contentController = TextEditingController(text: widget.note.content);
    _titleController = TextEditingController(text: widget.note.title);
    _lastText = widget.note.content;
    _tagsController = TextEditingController(text: widget.note.tags.join(', '));
    _folderController = TextEditingController(text: widget.note.folder);
    _isNewNote = widget.note.title.isEmpty && widget.note.content.isEmpty;
    
    _loadFolders();
    
    // Set default view mode from settings (only for existing notes)
    if (!_isNewNote) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final themeProvider = context.read<ThemeProvider>();
        setState(() => _showPreview = themeProvider.defaultPreviewMode);
      });
    }
    
    _titleController.addListener(_onChanged);
    _contentController.addListener(_onChanged);
    _contentFocus.addListener(_onFocusChange);
    _titleFocus.addListener(_onFocusChange);
  }

  /// Load available folders from existing notes.
  Future<void> _loadFolders() async {
    final provider = context.read<NotesProvider>();
    final folders = provider.notes.map((n) => n.folder).where((f) => f.isNotEmpty).toSet().toList();
    setState(() => _availableFolders = folders);
  }

  void _onChanged() {
    if (!_hasChanges) setState(() => _hasChanges = true);
    _saveToUndoStack();
  }
  
  /// Save current state to undo stack.
  void _saveToUndoStack() {
    final currentText = _contentController.text;
    if (currentText != _lastText) {
      _undoStack.add(_lastText);
      if (_undoStack.length > 50) _undoStack.removeAt(0);
      _redoStack.clear();
      _lastText = currentText;
    }
  }
  
  void _onFocusChange() {
    final visible = _contentFocus.hasFocus || _titleFocus.hasFocus;
    if (_isKeyboardVisible != visible) {
      setState(() => _isKeyboardVisible = visible);
    }
  }
  
  /// Format last edited time as human-readable string.
  String get _lastEditedText {
    final diff = DateTime.now().difference(widget.note.updatedAt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${widget.note.updatedAt.day}/${widget.note.updatedAt.month}';
  }

  /// Undo last text change.
  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_contentController.text);
    final previous = _undoStack.removeLast();
    _lastText = previous;
    _contentController.text = previous;
    _contentController.selection = TextSelection.collapsed(offset: previous.length);
    setState(() {});
  }

  /// Redo last undone change.
  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_contentController.text);
    final next = _redoStack.removeLast();
    _lastText = next;
    _contentController.text = next;
    _contentController.selection = TextSelection.collapsed(offset: next.length);
    setState(() {});
  }

  /// Insert markdown formatting at cursor position.
  /// If text is selected, wraps selection with prefix/suffix.
  void _insertMarkdown(String prefix, [String suffix = '']) {
    final text = _contentController.text;
    final sel = _contentController.selection;
    final start = sel.start < 0 ? text.length : sel.start;
    final end = sel.end < 0 ? text.length : sel.end;
    final selected = start == end ? '' : text.substring(start, end);
    final newText = text.replaceRange(start, end, '$prefix$selected$suffix');
    
    _contentController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + prefix.length + selected.length),
    );
    _contentFocus.requestFocus();
  }

  /// Show dialog to insert image URL.
  Future<void> _insertImage() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Insert Image'),
        content: SingleChildScrollView(
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'https://example.com/image.png',
              labelText: 'Image URL',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
            keyboardType: TextInputType.url,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Insert')),
        ],
      ),
    );
    
    if (result != null && result.isNotEmpty) {
      _insertMarkdown('![image]($result)');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    final isNarrow = MediaQuery.of(context).size.width < 600;

    Widget body = _focusMode ? _buildFocusMode(isDark) : _buildEditor(isNarrow);
    
    // Only add keyboard shortcuts on desktop
    if (_isDesktop) {
      body = CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _saveNote,
          const SingleActivator(LogicalKeyboardKey.keyP, control: true): () => setState(() => _showPreview = !_showPreview),
          const SingleActivator(LogicalKeyboardKey.escape): () => setState(() { _focusMode = false; _showPreview = false; }),
        },
        child: Focus(autofocus: true, child: body),
      );
    }

    return Scaffold(
      backgroundColor: _focusMode ? (isDark ? Colors.black : const Color(0xFFFAFAFA)) : null,
      appBar: _focusMode ? null : _buildAppBar(colors),
      body: body,
    );
  }

  PreferredSizeWidget _buildAppBar(ColorScheme colors) {
    return AppBar(
      title: Text(_isNewNote ? 'New Note' : 'Edit Note', style: const TextStyle(fontSize: 16)),
      actions: [
        // Save indicator
        if (_hasChanges)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Icon(Icons.circle, size: 8, color: Colors.orange),
          )
        else if (_lastSaved != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(Icons.cloud_done, size: 16, color: colors.primary),
          ),
        // Preview toggle
        IconButton(
          icon: Icon(_showPreview ? Icons.edit : Icons.visibility, size: 20),
          onPressed: () => setState(() => _showPreview = !_showPreview),
          tooltip: _showPreview ? 'Edit' : 'Preview',
        ),
        // Focus mode
        IconButton(
          icon: const Icon(Icons.fullscreen, size: 20),
          onPressed: () => setState(() => _focusMode = true),
          tooltip: 'Focus Mode',
        ),
        // Share (mobile) / Copy (desktop)
        IconButton(
          icon: Icon(_isDesktop ? Icons.copy : Icons.ios_share, size: 20),
          onPressed: _isDesktop ? _copyNote : _shareNote,
          tooltip: _isDesktop ? 'Copy' : 'Share',
        ),
        // Share as Gist
        Selector<NotesProvider, bool>(
          selector: (_, p) => p.isNoteShared(widget.note.id),
          builder: (context, isShared, _) {
            final provider = context.read<NotesProvider>();
            return IconButton(
              icon: Icon(
                isShared ? Icons.check_circle : Icons.share_outlined,
                size: 20,
                color: isShared ? Colors.green : null,
              ),
              onPressed: () => _shareAsGist(provider),
              tooltip: isShared ? 'Shared as Gist' : 'Share as Gist',
            );
          },
        ),
        // Save
        IconButton(
          icon: const Icon(Icons.check, size: 20),
          onPressed: _saveNote,
          tooltip: 'Save',
        ),
      ],
    );
  }

  void _copyNote() {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    if (title.isEmpty && content.isEmpty) {
      showAppSnackBar(context, 'Nothing to copy');
      return;
    }
    final text = title.isNotEmpty ? '$title\n\n$content' : content;
    Clipboard.setData(ClipboardData(text: text));
    showAppSnackBar(context, 'Copied to clipboard');
  }

  void _shareNote() {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    if (title.isEmpty && content.isEmpty) {
      showAppSnackBar(context, 'Nothing to share');
      return;
    }
    
    final text = title.isNotEmpty ? '$title\n\n$content' : content;
    
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_isDesktop)
              ListTile(
                leading: const Icon(Icons.share),
                title: const Text('Share'),
                onTap: () {
                  Navigator.pop(ctx);
                  SharePlus.instance.share(ShareParams(text: text, subject: title.isNotEmpty ? title : 'Note'));
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy to clipboard'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: text));
                showAppSnackBar(context, 'Copied to clipboard');
              },
            ),
          ],
        ),
      ),
    );
  }

  void _shareAsGist(NotesProvider provider) async {
    final isShared = provider.isNoteShared(widget.note.id);
    
    if (isShared) {
      // Already shared - show options
      final gistUrl = provider.getGistUrl(widget.note.id);
      if (gistUrl != null) {
        _showGistOptionsNew(gistUrl);
      }
      return;
    }
    
    // Not shared - show share dialog
    final result = await _showShareDialog();
    if (result == null) return;
    
    if (!mounted) return;
    showAppSnackBar(context, 'Creating gist...');
    
    final success = await provider.shareNoteAsGist(
      widget.note.id, 
      isPublic: result.isPublic,
      gistPassword: result.password,
    );
    
    if (!mounted) return;
    if (success) {
      final gistUrl = provider.getGistUrl(widget.note.id);
      if (gistUrl != null) {
        showAppSnackBar(context, 'Gist created! Link copied.');
        Clipboard.setData(ClipboardData(text: gistUrl));
      }
    } else {
      showAppSnackBar(context, 'Failed to create gist', isError: true);
    }
  }

  Future<_ShareResult?> _showShareDialog() async {
    final colors = Theme.of(context).colorScheme;
    bool isProtected = false;
    final passwordController = TextEditingController();
    
    return showModalBottomSheet<_ShareResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Padding(
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
                  Icon(Icons.share_outlined, color: colors.primary),
                  const SizedBox(width: 12),
                  const Text('Share as Gist', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 16),
              
              // Password protection toggle
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Password Protection'),
                subtitle: Text(isProtected ? 'Encrypted with password' : 'Anyone with link can view'),
                secondary: Icon(isProtected ? Icons.lock : Icons.lock_open, color: isProtected ? colors.primary : colors.outline),
                value: isProtected,
                onChanged: (v) => setState(() => isProtected = v),
              ),
              
              // Password field (if protected)
              if (isProtected) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    hintText: 'Enter password for this gist',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    prefixIcon: const Icon(Icons.key),
                  ),
                ),
                const SizedBox(height: 8),
                Text('Receiver needs this password to view', style: TextStyle(fontSize: 12, color: colors.outline)),
              ],
              
              const SizedBox(height: 20),
              
              // Share buttons
              if (!isProtected) ...[
                FilledButton.icon(
                  icon: const Icon(Icons.lock_outline, size: 18),
                  label: const Text('Private Link'),
                  onPressed: () => Navigator.pop(context, _ShareResult(isPublic: false)),
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.public, size: 18),
                  label: const Text('Public'),
                  onPressed: () => Navigator.pop(context, _ShareResult(isPublic: true)),
                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
              ] else ...[
                FilledButton.icon(
                  icon: const Icon(Icons.lock, size: 18),
                  label: const Text('Share Protected'),
                  onPressed: passwordController.text.isEmpty ? null : () => Navigator.pop(
                    context, 
                    _ShareResult(isPublic: false, password: passwordController.text),
                  ),
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
              ],
              
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Show gist options using URL string.
  void _showGistOptionsNew(String gistUrl) {
    if (!mounted) return;
    final isProtected = widget.note.gistPasswordProtected == true;
    final colors = Theme.of(context).colorScheme;
    
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy Link'),
              onTap: () {
                Navigator.pop(context);
                Clipboard.setData(ClipboardData(text: gistUrl));
                showAppSnackBar(context, 'Gist link copied');
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Open Gist'),
              onTap: () async {
                Navigator.pop(context);
                if (await canLaunchUrl(Uri.parse(gistUrl))) {
                  await launchUrl(Uri.parse(gistUrl), mode: LaunchMode.externalApplication);
                }
              },
            ),
            if (isProtected)
              ListTile(
                leading: Icon(Icons.refresh, color: colors.primary),
                title: Text('Re-share with New Password', style: TextStyle(color: colors.primary)),
                subtitle: const Text('Delete current and create new gist'),
                onTap: () {
                  Navigator.pop(context);
                  _reshareProtectedGist();
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: colors.error),
              title: Text('Unshare', style: TextStyle(color: colors.error)),
              onTap: () {
                Navigator.pop(context);
                _confirmUnshare();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _reshareProtectedGist() async {
    final provider = context.read<NotesProvider>();
    
    // First unshare
    showAppSnackBar(context, 'Removing old gist...');
    final unshared = await provider.unshareGist(widget.note.id);
    if (!unshared) {
      if (mounted) showAppSnackBar(context, 'Failed to remove old gist', isError: true);
      return;
    }
    
    // Then show share dialog again
    if (!mounted) return;
    final result = await _showShareDialog();
    if (result == null) return;
    
    if (!mounted) return;
    showAppSnackBar(context, 'Creating new gist...');
    
    final success = await provider.shareNoteAsGist(
      widget.note.id,
      isPublic: result.isPublic,
      gistPassword: result.password,
    );
    
    if (!mounted) return;
    if (success) {
      final gistUrl = provider.getGistUrl(widget.note.id);
      if (gistUrl != null) {
        showAppSnackBar(context, 'New gist created! Link copied.');
        Clipboard.setData(ClipboardData(text: gistUrl));
      }
    } else {
      showAppSnackBar(context, 'Failed to create gist', isError: true);
    }
  }

  void _confirmUnshare() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unshare Gist'),
        content: const Text('Are you sure you want to unshare this note?\n\nThis will delete the gist permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final provider = Provider.of<NotesProvider>(context, listen: false);
              final success = await provider.unshareGist(widget.note.id);
              
              if (!context.mounted) return;
              showAppSnackBar(context, success ? 'Gist unshared' : 'Failed to unshare', isError: !success);
            },
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Unshare'),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomToolbar(ColorScheme colors) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.3))),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              // Undo/Redo
              _bottomBtn(Icons.undo, 'Undo', _undo),
              _bottomBtn(Icons.redo, 'Redo', _redo),
              _divider(),
              // Text formatting
              _bottomBtn(Icons.format_bold, 'Bold', () => _insertMarkdown('**', '**')),
              _bottomBtn(Icons.format_italic, 'Italic', () => _insertMarkdown('*', '*')),
              _bottomBtn(Icons.format_strikethrough, 'Strike', () => _insertMarkdown('~~', '~~')),
              _divider(),
              // Headings
              _bottomBtn(Icons.title, 'H1', () => _insertMarkdown('# ')),
              _bottomBtn(Icons.format_size, 'H2', () => _insertMarkdown('## ')),
              _divider(),
              // Lists
              _bottomBtn(Icons.format_list_bulleted, 'List', () => _insertMarkdown('- ')),
              _bottomBtn(Icons.checklist, 'Task', () => _insertMarkdown('- [ ] ')),
              _bottomBtn(Icons.format_list_numbered, 'Num', () => _insertMarkdown('1. ')),
              _divider(),
              // Code & Links
              _bottomBtn(Icons.code, 'Code', () => _insertMarkdown('`', '`')),
              _bottomBtn(Icons.data_object, 'Block', () => _insertMarkdown('```\n', '\n```')),
              _bottomBtn(Icons.link, 'Link', () => _insertMarkdown('[', '](url)')),
              _bottomBtn(Icons.format_quote, 'Quote', () => _insertMarkdown('> ')),
              _divider(),
              // Other
              _bottomBtn(Icons.horizontal_rule, 'Line', () => _insertMarkdown('\n---\n')),
              _bottomBtn(Icons.image_outlined, 'Image', _insertImage),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomBtn(IconData icon, String label, VoidCallback onTap) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: colors.onSurface.withValues(alpha: 0.8)),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 9, color: colors.onSurface.withValues(alpha: 0.6))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _divider() => Container(
    width: 1,
    height: 32,
    margin: const EdgeInsets.symmetric(horizontal: 4),
    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3),
  );

  Widget _buildEditor(bool isNarrow) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        // Stats bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _statChip(Icons.history, _lastEditedText),
                const SizedBox(width: 16),
                Container(width: 1, height: 16, color: colors.outlineVariant),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        // Content
        Expanded(
          child: _showPreview ? _buildPreview() : _buildEditView(),
        ),
        // Toolbar above keyboard
        if (!_focusMode && !_showPreview && (!isNarrow || _isKeyboardVisible))
          _buildBottomToolbar(colors),
      ],
    );
  }

  Widget _statChip(IconData icon, String text) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: colors.onSurface.withValues(alpha: 0.5)),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.5))),
      ],
    );
  }

  Widget _previewChip(IconData icon, String text, ColorScheme colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colors.primary.withValues(alpha: 0.7)),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.7))),
        ],
      ),
    );
  }

  Widget _buildEditView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title
          TextField(
            controller: _titleController,
            focusNode: _titleFocus,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600, height: 1.3),
            decoration: const InputDecoration(
              hintText: 'Title',
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            maxLines: null,
          ),
          const SizedBox(height: 8),
          // Meta row
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildFolderSelector(),
              _metaChip(Icons.tag, _tagsController, 'Tags'),
            ],
          ),
          const SizedBox(height: 16),
          // Content
          TextField(
            controller: _contentController,
            focusNode: _contentFocus,
            style: const TextStyle(fontSize: 16, height: 1.7, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              hintText: 'Start writing...',
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            maxLines: null,
            minLines: 15,
          ),
        ],
      ),
    );
  }

  Widget _metaChip(IconData icon, TextEditingController controller, String hint) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(maxWidth: 180),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colors.onSurface.withValues(alpha: 0.5)),
          const SizedBox(width: 6),
          Flexible(
            child: TextField(
              controller: controller,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(fontSize: 13, color: colors.onSurface.withValues(alpha: 0.4)),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderSelector() {
    final colors = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => _showFolderMenu(),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: colors.outline.withValues(alpha: 0.2), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_outlined, size: 16, color: colors.onSurface.withValues(alpha: 0.6)),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _folderController.text.isEmpty ? 'Folder' : _folderController.text,
                style: TextStyle(
                  fontSize: 13,
                  color: _folderController.text.isEmpty ? colors.onSurface.withValues(alpha: 0.4) : colors.onSurface,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, size: 16, color: colors.onSurface.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }

  void _showFolderMenu() {
    final colors = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Select Folder', style: Theme.of(context).textTheme.titleMedium),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ..._availableFolders.map((folder) => ListTile(
                    leading: Icon(Icons.folder, size: 20, color: colors.primary),
                    title: Text(folder),
                    onTap: () {
                      setState(() => _folderController.text = folder);
                      Navigator.pop(ctx);
                    },
                  )),
                  Divider(height: 1, color: colors.outline.withValues(alpha: 0.2)),
                  ListTile(
                    leading: Icon(Icons.add_circle_outline, size: 20, color: colors.primary),
                    title: Text('Create New Folder', style: TextStyle(color: colors.primary, fontWeight: FontWeight.w500)),
                    onTap: () async {
                      Navigator.pop(ctx);
                      final name = await _askFolderName();
                      if (name != null && name.isNotEmpty) {
                        setState(() {
                          _folderController.text = name;
                          if (!_availableFolders.contains(name)) {
                            _availableFolders.add(name);
                          }
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _askFolderName() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Folder'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Folder name'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final content = _contentController.text.isEmpty ? '_No content yet_' : _contentController.text;
    
    return Container(
      color: isDark ? colors.surface : Colors.white,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            if (_titleController.text.isNotEmpty) ...[
              SelectableText(
                _titleController.text,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurface,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 12),
              // Meta info (folder & tags)
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (_folderController.text.isNotEmpty)
                    _previewChip(Icons.folder_outlined, _folderController.text, colors),
                  ..._tagsController.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).map(
                    (tag) => _previewChip(Icons.tag, tag, colors),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Divider(color: Color.alphaBlend(colors.outlineVariant.withAlpha(128), colors.surface)),
              const SizedBox(height: 16),
            ],
            // Markdown content
            MarkdownBody(
              data: content,
              selectable: true,
              onTapLink: (text, href, title) {
                if (href != null) _launchUrl(href);
              },
              builders: {
                'pre': _CodeBlockBuilder(
                  colors: colors,
                  isDark: isDark,
                  onCopy: (code) {
                    Clipboard.setData(ClipboardData(text: code));
                    showAppSnackBar(context, 'Code copied');
                  },
                ),
              },
              styleSheet: MarkdownStyleSheet(
                h1: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: colors.onSurface, height: 1.4),
                h2: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: colors.onSurface, height: 1.4),
                h3: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: colors.onSurface, height: 1.4),
                p: TextStyle(fontSize: 16, height: 1.7, color: colors.onSurface),
                a: TextStyle(color: colors.primary, decoration: TextDecoration.underline),
                listBullet: TextStyle(fontSize: 16, color: colors.onSurface),
                code: TextStyle(
                  backgroundColor: colors.surfaceContainerHighest,
                  color: colors.primary,
                  fontFamily: 'monospace',
                  fontSize: 14,
                ),
                codeblockPadding: EdgeInsets.zero,
                codeblockDecoration: const BoxDecoration(),
                blockquote: TextStyle(fontSize: 16, fontStyle: FontStyle.italic, color: colors.onSurfaceVariant, height: 1.6),
                blockquoteDecoration: BoxDecoration(
                  border: Border(left: BorderSide(color: colors.primary, width: 4)),
                  color: colors.primary.withAlpha(13),
                ),
                blockquotePadding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: colors.outlineVariant))),
                checkbox: TextStyle(color: colors.primary),
              ),
              checkboxBuilder: (checked) => Icon(
                checked ? Icons.check_box : Icons.check_box_outline_blank,
                size: 20,
                color: checked ? colors.primary : colors.outline,
              ),
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  void _launchUrl(String url) async {
    Clipboard.setData(ClipboardData(text: url));
    showAppSnackBar(context, 'Link copied: $url');
  }

  Widget _buildFocusMode(bool isDark) {
    final bgColor = isDark ? Colors.black : const Color(0xFFFAFAFA);
    final hintColor = isDark ? Colors.grey[700] : Colors.grey[400];
    final colors = Theme.of(context).colorScheme;
    final content = _contentController.text.isEmpty ? '_Start writing..._' : _contentController.text;
    
    return Container(
      color: bgColor,
      child: SafeArea(
        child: Column(
          children: [
            // Minimal header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => setState(() => _focusMode = false),
                    icon: Icon(Icons.close, size: 16, color: hintColor),
                    label: Text('Exit', style: TextStyle(color: hintColor, fontSize: 13)),
                  ),
                ],
              ),
            ),
            // Rendered markdown preview
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      child: MarkdownBody(
                        data: content,
                        selectable: true,
                        builders: {
                          'pre': _CodeBlockBuilder(
                            colors: colors,
                            isDark: isDark,
                            onCopy: (code) {
                              Clipboard.setData(ClipboardData(text: code));
                              showAppSnackBar(context, 'Code copied');
                            },
                          ),
                        },
                        styleSheet: MarkdownStyleSheet(
                          h1: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: colors.onSurface, height: 1.4),
                          h2: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: colors.onSurface, height: 1.4),
                          h3: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: colors.onSurface, height: 1.4),
                          p: TextStyle(fontSize: 18, height: 1.8, color: colors.onSurface),
                          code: TextStyle(backgroundColor: colors.surfaceContainerHighest, color: colors.primary, fontFamily: 'monospace', fontSize: 15),
                          codeblockPadding: EdgeInsets.zero,
                          codeblockDecoration: const BoxDecoration(),
                          blockquoteDecoration: BoxDecoration(border: Border(left: BorderSide(color: colors.primary, width: 4))),
                          blockquotePadding: const EdgeInsets.only(left: 16),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Save note to database and sync to GitHub.
  /// Notes are stored as plain text locally - encryption only for GitHub sync.
  void _saveNote() async {
    var title = _titleController.text.trim();
    var content = _contentController.text.trim();
    
    if (title.isEmpty && content.isEmpty) {
      Navigator.pop(context);
      return;
    }

    final tags = _tagsController.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    final folder = _folderController.text.trim();

    // Local storage is always plain text - encryption happens during GitHub sync
    final updatedNote = widget.note.copyWith(
      title: title.isEmpty ? 'Untitled' : title,
      content: content,
      tags: tags,
      folder: folder,
      updatedAt: DateTime.now(),
      isSynced: false,
    );

    if (!mounted) return;
    final provider = context.read<NotesProvider>();
    if (_isNewNote) {
      await provider.addNote(updatedNote);
      _isNewNote = false;
    } else {
      await provider.updateNote(updatedNote);
    }

    if (!mounted) return;
    setState(() {
      _hasChanges = false;
      _lastSaved = DateTime.now();
    });
    
    // Sync to GitHub immediately if configured
    if (provider.isGitHubConfigured) {
      provider.syncToGitHub();
    }
    
    if (!mounted) return;
    showAppSnackBar(context, 'Saved');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _tagsController.dispose();
    _folderController.dispose();
    _contentFocus.dispose();
    _titleFocus.dispose();
    super.dispose();
  }
}

/// Custom code block builder with syntax highlighting and copy button.
class _CodeBlockBuilder extends MarkdownElementBuilder {
  final ColorScheme colors;
  final bool isDark;
  final void Function(String) onCopy;

  _CodeBlockBuilder({required this.colors, required this.isDark, required this.onCopy});

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final code = element.textContent;
    String? language;
    if (element.children?.isNotEmpty == true) {
      final codeEl = element.children!.first;
      if (codeEl is md.Element && codeEl.attributes.containsKey('class')) {
        final cls = codeEl.attributes['class']!;
        if (cls.startsWith('language-')) language = cls.substring(9);
      }
    }

    final borderColor = isDark ? const Color(0xFF3E4451) : const Color(0xFFD0D0D0);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF282C34) : const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Stack(
        children: [
          SizedBox(
            width: double.infinity,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(16),
              child: Text.rich(
                TextSpan(children: _highlight(code, language ?? 'plaintext', isDark)),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5),
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              icon: Icon(Icons.copy, size: 18, color: colors.onSurface.withValues(alpha: 0.6)),
              onPressed: () => onCopy(code),
              tooltip: 'Copy code',
              style: IconButton.styleFrom(
                backgroundColor: colors.surface.withValues(alpha: 0.8),
                padding: const EdgeInsets.all(6),
                minimumSize: const Size(28, 28),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<TextSpan> _highlight(String code, String language, bool isDark) {
    try {
      final result = highlight.highlight.parse(code, language: language.isNotEmpty ? language : null, autoDetection: language.isEmpty);
      return _convertNodes(result.nodes ?? [], isDark);
    } catch (_) {
      return [TextSpan(text: code)];
    }
  }

  List<TextSpan> _convertNodes(List<highlight.Node> nodes, bool isDark) {
    final theme = isDark ? atomOneDarkTheme : atomOneLightTheme;
    return nodes.map((node) {
      if (node.value != null) {
        return TextSpan(text: node.value, style: theme[node.className]);
      } else if (node.children != null) {
        return TextSpan(children: _convertNodes(node.children!, isDark), style: theme[node.className]);
      }
      return const TextSpan();
    }).toList();
  }
}
