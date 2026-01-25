// ============================================================================
// SCRATCHPAD SCREEN
// ============================================================================
//
// Dynamic multi-tab scratchpad for quick note-taking and temporary content.
// Provides unlimited tabs with color coding and persistent storage.
//
// Features:
// - Unlimited tabs with editable names (15 char limit)
// - 8 color options for visual organization
// - Persistent storage via SharedPreferences
// - Export tabs to permanent notes
// - Keyboard shortcuts (Ctrl+Q open, Ctrl+N new tab, Ctrl+W close)
// - Live character count per tab
// - Auto-save content on changes
//
// Storage Structure:
// - scratchpad_tab_count: Number of tabs
// - scratchpad_tab_names: List of tab names
// - scratchpad_tab_colors: List of ARGB color values
// - scratchpad_tab_N: Content of tab N
//
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../providers/notes_provider.dart';
import '../models/note.dart';

/// Optimized dynamic scratchpad with editable tabs and colors
class ScratchpadScreen extends StatefulWidget {
  const ScratchpadScreen({super.key});

  @override
  State<ScratchpadScreen> createState() => _ScratchpadScreenState();
}

class _ScratchpadScreenState extends State<ScratchpadScreen> with TickerProviderStateMixin {
  late TabController _tabController;
  final List<TextEditingController> _controllers = [];
  final List<FocusNode> _focusNodes = [];
  final List<int> _charCounts = [];
  List<String> _tabNames = [];
  List<Color> _tabColors = [];
  int _currentTab = 0;
  int _nextTabId = 1;

  static const List<Color> _availableColors = [
    Colors.blue,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.red,
    Colors.teal,
    Colors.pink,
    Colors.indigo,
  ];

  @override
  void initState() {
    super.initState();
    _loadTabs();
  }

  Future<void> _loadTabs() async {
    final prefs = await SharedPreferences.getInstance();
    final tabCount = prefs.getInt('scratchpad_tab_count') ?? 1;
    final tabNames = prefs.getStringList('scratchpad_tab_names') ?? ['Tab 1'];
    final tabColorValues = prefs.getStringList('scratchpad_tab_colors') ?? ['4280391411'];
    
    _tabNames = List.from(tabNames);
    _tabColors = tabColorValues.map((c) => Color(int.tryParse(c) ?? 0xFF2196F3)).toList();
    
    // Ensure arrays are synchronized
    while (_tabColors.length < _tabNames.length) {
      _tabColors.add(Colors.blue);
    }
    
    _nextTabId = tabCount + 1;
    _tabController = TabController(length: _tabNames.length, vsync: this);
    
    // Initialize controllers and load content
    for (int i = 0; i < _tabNames.length; i++) {
      final controller = TextEditingController();
      final focusNode = FocusNode();
      
      _controllers.add(controller);
      _focusNodes.add(focusNode);
      _charCounts.add(0);
      
      final content = prefs.getString('scratchpad_tab_$i') ?? '';
      controller.text = content;
      
      // Capture index in closure to avoid late binding issues
      final capturedIndex = i;
      controller.addListener(() => _updateCharCount(capturedIndex));
      _updateCharCount(capturedIndex);
    }
    
    _setupTabListener();
    setState(() {});
    
    // Auto-focus first tab
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_focusNodes.isNotEmpty) _focusNodes[0].requestFocus();
    });
  }

  void _setupTabListener() {
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) {
        setState(() => _currentTab = _tabController.index);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_currentTab < _focusNodes.length) {
            _focusNodes[_currentTab].requestFocus();
          }
        });
      }
    });
  }

  Future<void> _saveTabs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('scratchpad_tab_count', _tabNames.length);
    await prefs.setStringList('scratchpad_tab_names', _tabNames);
    await prefs.setStringList('scratchpad_tab_colors', 
      _tabColors.map((c) => c.toARGB32().toString()).toList());
  }

  Future<void> _saveContent(int index) async {
    if (index >= _controllers.length) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('scratchpad_tab_$index', _controllers[index].text);
  }

  void _updateCharCount(int index) {
    if (index < _charCounts.length && index < _controllers.length) {
      setState(() => _charCounts[index] = _controllers[index].text.length);
      _saveContent(index);
    }
  }

  void _addNewTab() {
    final newTabName = 'Tab $_nextTabId';
    final newColor = _availableColors[(_nextTabId - 1) % _availableColors.length];
    _nextTabId++;
    
    // Add new data
    final controller = TextEditingController();
    final focusNode = FocusNode();
    
    _controllers.add(controller);
    _focusNodes.add(focusNode);
    _charCounts.add(0);
    _tabNames.add(newTabName);
    _tabColors.add(newColor);
    
    controller.addListener(() => _updateCharCount(_controllers.length - 1));
    
    // Recreate TabController
    _tabController.dispose();
    _tabController = TabController(length: _tabNames.length, vsync: this);
    _setupTabListener();
    
    setState(() {});
    _saveTabs();
    
    // Navigate to new tab
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tabController.animateTo(_tabNames.length - 1);
    });
  }

  void _removeTab(int index) {
    if (_tabNames.length <= 1) return;
    
    // Dispose resources
    _controllers[index].dispose();
    _focusNodes[index].dispose();
    
    // Remove from arrays
    _tabNames.removeAt(index);
    _tabColors.removeAt(index);
    _controllers.removeAt(index);
    _focusNodes.removeAt(index);
    _charCounts.removeAt(index);
    
    // Adjust current tab
    if (_currentTab >= _tabNames.length) {
      _currentTab = _tabNames.length - 1;
    }
    
    // Recreate TabController
    _tabController.dispose();
    _tabController = TabController(
      length: _tabNames.length, 
      vsync: this, 
      initialIndex: _currentTab
    );
    _setupTabListener();
    
    setState(() {});
    _saveTabs();
    _reindexTabs();
  }

  Future<void> _reindexTabs() async {
    final prefs = await SharedPreferences.getInstance();
    for (int i = 0; i < _controllers.length; i++) {
      await prefs.setString('scratchpad_tab_$i', _controllers[i].text);
    }
  }

  void _editTabName(int index) {
    final controller = TextEditingController(text: _tabNames[index]);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Tab Name'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Tab name',
            counterText: '',
          ),
          maxLength: 15,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx), 
            child: const Text('Cancel')
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                setState(() => _tabNames[index] = name);
                _saveTabs();
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _changeTabColor(int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose Color'),
        content: Wrap(
          spacing: 8,
          children: _availableColors.map((color) => GestureDetector(
            onTap: () {
              setState(() {
                // Ensure array is large enough
                while (_tabColors.length <= index) {
                  _tabColors.add(Colors.blue);
                }
                _tabColors[index] = color;
              });
              _saveTabs();
              Navigator.pop(ctx);
            },
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: (index < _tabColors.length && _tabColors[index] == color)
                  ? Border.all(color: Colors.white, width: 3)
                  : null,
              ),
            ),
          )).toList(),
        ),
      ),
    );
  }

  Future<void> _exportToNote() async {
    if (_currentTab >= _controllers.length) return;
    
    final content = _controllers[_currentTab].text.trim();
    if (content.isEmpty) return;
    
    final provider = context.read<NotesProvider>();
    final note = Note(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: 'From ${_tabNames[_currentTab]}',
      content: content,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      isFavorite: false,
    );
    
    await provider.addNote(note);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Exported to notes')),
      );
    }
  }

  @override
  void dispose() {
    for (int i = 0; i < _controllers.length; i++) {
      _saveContent(i);
      _controllers[i].dispose();
      _focusNodes[i].dispose();
    }
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_tabNames.isEmpty) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator())
      );
    }
    
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _addNewTab,
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): () => _removeTab(_currentTab),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      appBar: AppBar(
        title: const Text('Scratchpad'),
        actions: [
          Text(
            '${_currentTab >= 0 && _currentTab < _charCounts.length ? _charCounts[_currentTab] : 0} chars', 
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.note_add),
            onPressed: _exportToNote,
            tooltip: 'Export to note',
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () {
              if (_currentTab < _controllers.length) {
                _controllers[_currentTab].clear();
                _updateCharCount(_currentTab);
              }
            },
            tooltip: 'Clear',
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _addNewTab,
            tooltip: 'New tab',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: _tabNames.asMap().entries.map((entry) {
            final index = entry.key;
            final name = entry.value;
            final color = index < _tabColors.length ? _tabColors[index] : Colors.blue;
            
            return Tab(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: color.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () => _changeTabColor(index),
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () => _editTabName(index),
                      child: Text(name, style: TextStyle(color: color)),
                    ),
                    if (_tabNames.length > 1) ...[
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () => _removeTab(index),
                        child: Icon(Icons.close, size: 14, color: color),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: _tabNames.asMap().entries.map((entry) {
          final index = entry.key;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: index < _controllers.length 
                ? _controllers[index] 
                : TextEditingController(),
              focusNode: index < _focusNodes.length 
                ? _focusNodes[index] 
                : FocusNode(),
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: InputDecoration(
                hintText: 'Start typing in ${_tabNames[index]}...',
                border: InputBorder.none,
              ),
              style: const TextStyle(fontSize: 16, height: 1.5),
            ),
          );
        }).toList(),
      ),
        ),
      ),
    );
  }
}
