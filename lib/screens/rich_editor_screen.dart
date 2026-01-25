// ============================================================================
// RICH EDITOR SCREEN (AppFlowy - Notion-like)
// ============================================================================
//
// WYSIWYG rich text editor with:
// - Live formatting (no separate preview needed)
// - Slash commands (/) for inserting blocks
// - Markdown shortcuts (type **bold**, *italic*, etc.)
// - Mobile toolbar for formatting
// - Focus mode (distraction-free writing)
// - Preview mode (read-only view)
// - Gist sharing with password protection
// - GitHub sync on save
//
// ## Supported Markdown Shortcuts (type and it converts):
//
// **Text Formatting:**
// - **bold** or __bold__     → Bold text
// - *italic* or _italic_     → Italic text
// - ~~strikethrough~~        → Strikethrough
// - `code`                   → Inline code
// - [text](url)              → Link
//
// **Block Elements (start of line):**
// - # + space                → Heading 1
// - ## + space               → Heading 2
// - ### + space              → Heading 3
// - * or - + space           → Bullet list
// - 1. + space               → Numbered list
// - [] or -[] + space        → Unchecked todo
// - [x] or -[x] + space      → Checked todo
// - " + space                → Quote block
// - --- or *** or ___        → Divider
//
// **Slash Commands (type / then search):**
// - /text                    → Paragraph
// - /heading1, /h1           → Heading 1
// - /heading2, /h2           → Heading 2
// - /heading3, /h3           → Heading 3
// - /bullet                  → Bullet list
// - /numbered                → Numbered list
// - /todo, /checkbox         → Todo item
// - /quote                   → Quote block
// - /divider                 → Horizontal line
// - /code                    → Code block
// - /image                   → Image
// - /table                   → Table
//
// ## Keyboard Shortcuts (Desktop):
// - Ctrl+S                   → Save
// - Ctrl+P                   → Toggle preview
// - Ctrl+Z                   → Undo
// - Ctrl+Y                   → Redo
// - Ctrl+B                   → Bold
// - Ctrl+I                   → Italic
// - Ctrl+U                   → Underline
// - Escape                   → Exit focus/preview mode
//
// ============================================================================

import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
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
import '../widgets/code_block_component.dart';

class _ShareResult {
  final bool isPublic;
  final String? password;
  _ShareResult({required this.isPublic, this.password});
}

/// Rich text editor screen using AppFlowy Editor (Notion-like).
/// 
/// Features:
/// - WYSIWYG editing with live formatting
/// - Slash commands for block insertion
/// - Markdown shortcuts for inline formatting
/// - Mobile toolbar for touch devices
/// - Preview mode for read-only viewing
/// - Gist sharing with optional password protection
/// - Auto-sync to GitHub on save
class RichEditorScreen extends StatefulWidget {
  final Note note;
  const RichEditorScreen({super.key, required this.note});

  @override
  State<RichEditorScreen> createState() => _RichEditorScreenState();
}

class _RichEditorScreenState extends State<RichEditorScreen> {
  late EditorState _editorState;
  late TextEditingController _titleController;
  late TextEditingController _tagsController;
  late TextEditingController _folderController;
  late EditorScrollController _scrollController;
  List<String> _availableFolders = [];
  bool _isNewNote = false;
  bool _hasChanges = false;
  bool _focusMode = false;
  bool _showPreview = false;
  DateTime? _lastSaved;
  
  static final bool _isMobile = Platform.isAndroid || Platform.isIOS;
  static final bool _isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _tagsController = TextEditingController(text: widget.note.tags.join(', '));
    _folderController = TextEditingController(text: widget.note.folder);
    _isNewNote = widget.note.title.isEmpty && widget.note.content.isEmpty;
    
    final doc = widget.note.content.isEmpty
        ? Document.blank(withInitialText: true)
        : markdownToDocument(widget.note.content, markdownParsers: [const MarkdownCodeBlockParser()]);
    
    _editorState = EditorState(document: doc);
    _scrollController = EditorScrollController(editorState: _editorState);
    
    _editorState.transactionStream.listen((_) {
      if (!_hasChanges && mounted) setState(() => _hasChanges = true);
    });
    
    _titleController.addListener(_markChanged);
    _loadFolders();
    
    // Set default view mode from settings (only for existing notes)
    if (!_isNewNote) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final themeProvider = context.read<ThemeProvider>();
        setState(() => _showPreview = themeProvider.defaultPreviewMode);
      });
    }
  }

  void _markChanged() {
    if (!_hasChanges && mounted) setState(() => _hasChanges = true);
  }

  Future<void> _loadFolders() async {
    final provider = context.read<NotesProvider>();
    final folders = provider.notes.map((n) => n.folder).where((f) => f.isNotEmpty).toSet().toList();
    if (mounted) setState(() => _availableFolders = folders);
  }

  String get _lastEditedText {
    final diff = DateTime.now().difference(widget.note.updatedAt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${widget.note.updatedAt.day}/${widget.note.updatedAt.month}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Widget body = _focusMode ? _buildFocusMode(isDark, colors) : _buildMainEditor(isDark, colors);
    
    // Keyboard shortcuts on desktop
    if (_isDesktop) {
      body = CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _saveNote,
          const SingleActivator(LogicalKeyboardKey.keyP, control: true): () => setState(() => _showPreview = !_showPreview),
          const SingleActivator(LogicalKeyboardKey.escape): () => setState(() { _focusMode = false; _showPreview = false; }),
          const SingleActivator(LogicalKeyboardKey.keyY, control: true): () => _editorState.undoManager.redo(),
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
          const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.circle, size: 8, color: Colors.orange))
        else if (_lastSaved != null)
          Padding(padding: const EdgeInsets.all(12), child: Icon(Icons.cloud_done, size: 16, color: colors.primary)),
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
              icon: Icon(isShared ? Icons.check_circle : Icons.share_outlined, size: 20, color: isShared ? Colors.green : null),
              onPressed: () => _shareAsGist(provider),
              tooltip: isShared ? 'Shared as Gist' : 'Share as Gist',
            );
          },
        ),
        // Save
        IconButton(icon: const Icon(Icons.check, size: 20), onPressed: _saveNote, tooltip: 'Save'),
      ],
    );
  }

  Widget _buildMainEditor(bool isDark, ColorScheme colors) {
    return Column(
      children: [
        // Stats bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.history, size: 14, color: colors.onSurface.withValues(alpha: 0.5)),
              const SizedBox(width: 4),
              Text(_lastEditedText, style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.5))),
            ],
          ),
        ),
        const Divider(height: 1),
        // Title & meta (only in edit mode)
        if (!_showPreview) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _titleController,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(hintText: 'Title', border: InputBorder.none, contentPadding: EdgeInsets.zero),
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [_buildFolderChip(colors), _buildTagsChip(colors)]),
              ],
            ),
          ),
          const Divider(height: 1),
        ],
        Expanded(child: _showPreview ? _buildPreview(isDark, colors) : _buildEditor(isDark, colors)),
      ],
    );
  }

  String _toMarkdown() => documentToMarkdown(_editorState.document);

  Widget _buildPreview(bool isDark, ColorScheme colors) {
    final content = _toMarkdown();
    final displayContent = content.isEmpty ? '_No content yet_' : content;
    
    return Container(
      color: isDark ? colors.surface : Colors.white,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            if (_titleController.text.isNotEmpty) ...[
              SelectableText(_titleController.text, style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: colors.onSurface, height: 1.2)),
              const SizedBox(height: 12),
              // Meta info (folder & tags)
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (_folderController.text.isNotEmpty) _previewChip(Icons.folder_outlined, _folderController.text, colors),
                  ..._tagsController.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).map((tag) => _previewChip(Icons.tag, tag, colors)),
                ],
              ),
              const SizedBox(height: 24),
              Divider(color: colors.outlineVariant.withValues(alpha: 0.5)),
              const SizedBox(height: 16),
            ],
            // Markdown content
            MarkdownBody(
              data: displayContent,
              selectable: false,
              shrinkWrap: true,
              onTapLink: (text, href, title) { if (href != null) { Clipboard.setData(ClipboardData(text: href)); showAppSnackBar(context, 'Link copied: $href'); } },
              styleSheet: MarkdownStyleSheet(
                h1: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: colors.onSurface, height: 1.4),
                h2: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: colors.onSurface, height: 1.4),
                h3: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: colors.onSurface, height: 1.4),
                p: TextStyle(fontSize: 16, height: 1.7, color: colors.onSurface),
                a: TextStyle(color: colors.primary, decoration: TextDecoration.underline),
                listBullet: TextStyle(fontSize: 16, color: colors.onSurface),
                code: TextStyle(backgroundColor: colors.surfaceContainerHighest, color: colors.primary, fontFamily: 'monospace', fontSize: 14),
                codeblockPadding: EdgeInsets.zero,
                codeblockDecoration: const BoxDecoration(),
                blockquote: TextStyle(fontSize: 16, fontStyle: FontStyle.italic, color: colors.onSurfaceVariant, height: 1.6),
                blockquoteDecoration: BoxDecoration(border: Border(left: BorderSide(color: colors.primary, width: 4)), color: colors.primary.withAlpha(13)),
                blockquotePadding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: colors.outlineVariant))),
                checkbox: TextStyle(color: colors.primary),
              ),
              checkboxBuilder: (checked) => Icon(checked ? Icons.check_box : Icons.check_box_outline_blank, size: 20, color: checked ? colors.primary : colors.outline),
              builders: {
                'pre': _CodeBlockBuilder(colors: colors, isDark: isDark, onCopy: (code) { Clipboard.setData(ClipboardData(text: code)); showAppSnackBar(context, 'Code copied'); }),
              },
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  Widget _previewChip(IconData icon, String text, ColorScheme colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: colors.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12)),
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

  Widget _buildFocusMode(bool isDark, ColorScheme colors) {
    final bgColor = isDark ? Colors.black : const Color(0xFFFAFAFA);
    final hintColor = isDark ? Colors.grey[700] : Colors.grey[400];
    
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
            // Editor in focus mode
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: _buildEditor(isDark, colors),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _copyNote() {
    final title = _titleController.text.trim();
    final content = _toMarkdown();
    if (title.isEmpty && content.isEmpty) { showAppSnackBar(context, 'Nothing to copy'); return; }
    Clipboard.setData(ClipboardData(text: title.isNotEmpty ? '$title\n\n$content' : content));
    showAppSnackBar(context, 'Copied to clipboard');
  }

  void _shareNote() {
    final title = _titleController.text.trim();
    final content = _toMarkdown();
    if (title.isEmpty && content.isEmpty) { showAppSnackBar(context, 'Nothing to share'); return; }
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
                onTap: () { Navigator.pop(ctx); SharePlus.instance.share(ShareParams(text: text, subject: title.isNotEmpty ? title : 'Note')); },
              ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy to clipboard'),
              onTap: () { Navigator.pop(ctx); Clipboard.setData(ClipboardData(text: text)); showAppSnackBar(context, 'Copied to clipboard'); },
            ),
          ],
        ),
      ),
    );
  }

  void _shareAsGist(NotesProvider provider) async {
    final isShared = provider.isNoteShared(widget.note.id);
    
    if (isShared) {
      final gistUrl = provider.getGistUrl(widget.note.id);
      if (gistUrl != null) _showGistOptions(gistUrl);
      return;
    }
    
    final result = await _showShareDialog();
    if (result == null) return;
    
    if (!mounted) return;
    showAppSnackBar(context, 'Creating gist...');
    
    final success = await provider.shareNoteAsGist(widget.note.id, isPublic: result.isPublic, gistPassword: result.password);
    
    if (!mounted) return;
    if (success) {
      final gistUrl = provider.getGistUrl(widget.note.id);
      if (gistUrl != null) { showAppSnackBar(context, 'Gist created! Link copied.'); Clipboard.setData(ClipboardData(text: gistUrl)); }
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Padding(
          padding: EdgeInsets.only(left: 24, right: 24, top: 24, bottom: MediaQuery.of(context).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [Icon(Icons.share_outlined, color: colors.primary), const SizedBox(width: 12), const Text('Share as Gist', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))]),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Password Protection'),
                subtitle: Text(isProtected ? 'Encrypted with password' : 'Anyone with link can view'),
                secondary: Icon(isProtected ? Icons.lock : Icons.lock_open, color: isProtected ? colors.primary : colors.outline),
                value: isProtected,
                onChanged: (v) => setState(() => isProtected = v),
              ),
              if (isProtected) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(labelText: 'Password', hintText: 'Enter password for this gist', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), prefixIcon: const Icon(Icons.key)),
                ),
                const SizedBox(height: 8),
                Text('Receiver needs this password to view', style: TextStyle(fontSize: 12, color: colors.outline)),
              ],
              const SizedBox(height: 20),
              if (!isProtected) ...[
                FilledButton.icon(icon: const Icon(Icons.lock_outline, size: 18), label: const Text('Private Link'), onPressed: () => Navigator.pop(context, _ShareResult(isPublic: false)), style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14))),
                const SizedBox(height: 8),
                OutlinedButton.icon(icon: const Icon(Icons.public, size: 18), label: const Text('Public'), onPressed: () => Navigator.pop(context, _ShareResult(isPublic: true)), style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14))),
              ] else
                FilledButton.icon(icon: const Icon(Icons.lock, size: 18), label: const Text('Share Protected'), onPressed: passwordController.text.isEmpty ? null : () => Navigator.pop(context, _ShareResult(isPublic: false, password: passwordController.text)), style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14))),
              const SizedBox(height: 8),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ],
          ),
        ),
      ),
    );
  }

  void _showGistOptions(String gistUrl) {
    final isProtected = widget.note.gistPasswordProtected == true;
    final colors = Theme.of(context).colorScheme;
    
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.copy), title: const Text('Copy Link'), onTap: () { Navigator.pop(context); Clipboard.setData(ClipboardData(text: gistUrl)); showAppSnackBar(context, 'Gist link copied'); }),
            ListTile(leading: const Icon(Icons.open_in_new), title: const Text('Open Gist'), onTap: () async { 
              Navigator.pop(context); 
              if (mounted && await canLaunchUrl(Uri.parse(gistUrl))) {
                await launchUrl(Uri.parse(gistUrl), mode: LaunchMode.externalApplication);
              }
            }),
            if (isProtected)
              ListTile(leading: Icon(Icons.refresh, color: colors.primary), title: Text('Re-share with New Password', style: TextStyle(color: colors.primary)), subtitle: const Text('Delete current and create new gist'), onTap: () { Navigator.pop(context); _reshareProtectedGist(); }),
            ListTile(leading: Icon(Icons.delete_outline, color: colors.error), title: Text('Unshare', style: TextStyle(color: colors.error)), onTap: () { Navigator.pop(context); _confirmUnshare(); }),
          ],
        ),
      ),
    );
  }

  void _reshareProtectedGist() async {
    final provider = context.read<NotesProvider>();
    showAppSnackBar(context, 'Removing old gist...');
    final unshared = await provider.unshareGist(widget.note.id);
    if (!unshared) { if (mounted) showAppSnackBar(context, 'Failed to remove old gist', isError: true); return; }
    if (!mounted) return;
    final result = await _showShareDialog();
    if (result == null) return;
    if (!mounted) return;
    showAppSnackBar(context, 'Creating new gist...');
    final success = await provider.shareNoteAsGist(widget.note.id, isPublic: result.isPublic, gistPassword: result.password);
    if (!mounted) return;
    if (success) {
      final gistUrl = provider.getGistUrl(widget.note.id);
      if (gistUrl != null) { showAppSnackBar(context, 'New gist created! Link copied.'); Clipboard.setData(ClipboardData(text: gistUrl)); }
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
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

  Widget _buildEditor(bool isDark, ColorScheme colors) {
    final style = _isMobile
        ? EditorStyle.mobile(
            padding: EdgeInsets.symmetric(horizontal: _focusMode ? 24 : 16, vertical: 8),
            cursorColor: colors.primary,
            dragHandleColor: colors.primary,
            selectionColor: colors.primary.withValues(alpha: 0.3),
            textStyleConfiguration: TextStyleConfiguration(text: TextStyle(fontSize: _focusMode ? 18 : 16, height: _focusMode ? 1.8 : 1.6, color: colors.onSurface)),
          )
        : EditorStyle.desktop(
            padding: EdgeInsets.symmetric(horizontal: _focusMode ? 24 : 16, vertical: 8),
            cursorColor: colors.primary,
            selectionColor: colors.primary.withValues(alpha: 0.3),
            textStyleConfiguration: TextStyleConfiguration(text: TextStyle(fontSize: _focusMode ? 18 : 16, height: _focusMode ? 1.8 : 1.6, color: colors.onSurface)),
          );

    final blockBuilders = {...standardBlockComponentBuilderMap, CodeBlockKeys.type: CodeBlockComponentBuilder()};

    Widget editor = AppFlowyEditor(
      editorState: _editorState,
      editorScrollController: _scrollController,
      editorStyle: style,
      blockComponentBuilders: blockBuilders,
      characterShortcutEvents: _buildCharacterShortcuts(isDark),
      commandShortcutEvents: _isMobile ? [] : [codeBlockPasteCommand, codeBlockNewLineCommand, codeBlockExitCommand, ...standardCommandShortcutEvents],
    );

    // Add floating toolbar for desktop
    if (!_isMobile) {
      editor = FloatingToolbar(
        items: [
          paragraphItem,
          ...headingItems,
          ...markdownFormatItems,
          quoteItem,
          bulletedListItem,
          numberedListItem,
          linkItem,
        ],
        editorState: _editorState,
        editorScrollController: _scrollController,
        textDirection: ui.TextDirection.ltr,
        style: FloatingToolbarStyle(
          backgroundColor: isDark ? colors.surfaceContainerHighest : colors.surface,
          toolbarActiveColor: colors.primary,
          toolbarIconColor: colors.onSurface,
        ),
        child: editor,
      );
    }

    return editor;
  }

  /// Build character shortcuts with theme-aware slash menu.
  List<CharacterShortcutEvent> _buildCharacterShortcuts(bool isDark) {
    final shortcuts = [...standardCharacterShortcutEvents];
    shortcuts.removeWhere((e) => e.key == 'show the slash menu');
    shortcuts.add(customSlashCommand(
      [...standardSelectionMenuItems, codeBlockMenuItem, _dateMenuItem, _timeMenuItem],
      style: isDark ? SelectionMenuStyle.dark : SelectionMenuStyle.light,
    ));
    return shortcuts;
  }

  SelectionMenuItem get _dateMenuItem => SelectionMenuItem(
    getName: () => 'Date',
    icon: (_, isSelected, style) => SelectionMenuIconWidget(icon: Icons.calendar_today, isSelected: isSelected, style: style),
    keywords: ['date', 'today'],
    handler: (editorState, _, __) => _insertText(editorState, DateFormat('MMM d, yyyy').format(DateTime.now())),
  );

  SelectionMenuItem get _timeMenuItem => SelectionMenuItem(
    getName: () => 'Time',
    icon: (_, isSelected, style) => SelectionMenuIconWidget(icon: Icons.access_time, isSelected: isSelected, style: style),
    keywords: ['time', 'now', 'timestamp'],
    handler: (editorState, _, __) => _insertText(editorState, DateFormat('MMM d, yyyy h:mm a').format(DateTime.now())),
  );

  void _insertText(EditorState editorState, String text) {
    final selection = editorState.selection;
    if (selection == null) return;
    final node = editorState.getNodeAtPath(selection.end.path);
    if (node == null) return;
    editorState.apply(editorState.transaction..insertText(node, selection.end.offset, text));
  }

  Widget _buildFolderChip(ColorScheme colors) {
    return GestureDetector(
      onTap: _showFolderMenu,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: colors.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(16)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_outlined, size: 16, color: colors.onSurface.withValues(alpha: 0.6)),
            const SizedBox(width: 6),
            Flexible(child: Text(_folderController.text.isEmpty ? 'Folder' : _folderController.text, style: TextStyle(fontSize: 13, color: _folderController.text.isEmpty ? colors.onSurface.withValues(alpha: 0.4) : colors.onSurface), overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, size: 14, color: colors.onSurface.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }

  Widget _buildTagsChip(ColorScheme colors) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 160),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: colors.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(16)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.tag, size: 14, color: colors.onSurface.withValues(alpha: 0.5)),
          const SizedBox(width: 6),
          Flexible(child: TextField(controller: _tagsController, style: const TextStyle(fontSize: 13), decoration: InputDecoration(hintText: 'Tags', hintStyle: TextStyle(fontSize: 13, color: colors.onSurface.withValues(alpha: 0.4)), border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.zero))),
        ],
      ),
    );
  }

  void _showFolderMenu() {
    final colors = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Container(
        decoration: BoxDecoration(color: colors.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(padding: const EdgeInsets.all(16), child: Text('Select Folder', style: Theme.of(context).textTheme.titleMedium)),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ..._availableFolders.map((folder) => ListTile(leading: Icon(Icons.folder, size: 20, color: colors.primary), title: Text(folder), onTap: () { setState(() => _folderController.text = folder); Navigator.pop(ctx); })),
                  Divider(height: 1, color: colors.outline.withValues(alpha: 0.2)),
                  ListTile(leading: Icon(Icons.add_circle_outline, size: 20, color: colors.primary), title: Text('Create New Folder', style: TextStyle(color: colors.primary, fontWeight: FontWeight.w500)), onTap: () async { Navigator.pop(ctx); final name = await _askFolderName(); if (name != null && name.isNotEmpty && mounted) setState(() { _folderController.text = name; if (!_availableFolders.contains(name)) _availableFolders.add(name); }); }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _askFolderName() {
    final controller = TextEditingController();
    return showDialog<String>(context: context, builder: (ctx) => AlertDialog(title: const Text('New Folder'), content: TextField(controller: controller, decoration: const InputDecoration(hintText: 'Folder name'), autofocus: true), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Create'))]));
  }

  void _saveNote() async {
    final title = _titleController.text.trim();
    final content = _toMarkdown();
    
    if (title.isEmpty && content.trim().isEmpty) { Navigator.pop(context); return; }

    final tags = _tagsController.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    final folder = _folderController.text.trim();

    final updatedNote = widget.note.copyWith(title: title.isEmpty ? 'Untitled' : title, content: content, tags: tags, folder: folder, updatedAt: DateTime.now(), isSynced: false);

    if (!mounted) return;
    final provider = context.read<NotesProvider>();
    if (_isNewNote) { await provider.addNote(updatedNote); _isNewNote = false; } 
    else { await provider.updateNote(updatedNote); }

    if (!mounted) return;
    setState(() { _hasChanges = false; _lastSaved = DateTime.now(); });
    if (provider.isGitHubConfigured) provider.syncToGitHub();
    if (!mounted) return;
    showAppSnackBar(context, 'Saved');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _tagsController.dispose();
    _folderController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}


/// Custom code block builder with copy button and syntax highlighting for preview mode.
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

