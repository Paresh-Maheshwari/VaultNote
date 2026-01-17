// ============================================================================
// DEBUG LOGS SCREEN
// ============================================================================
//
// Shows in-memory debug logs for troubleshooting.
// Supports filtering by errors only and search.
// Logs can be copied to clipboard for sharing.
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/debug_service.dart';

/// Debug logs viewer with search and filter.
class DebugLogsScreen extends StatefulWidget {
  const DebugLogsScreen({super.key});

  @override
  State<DebugLogsScreen> createState() => _DebugLogsScreenState();
}

class _DebugLogsScreenState extends State<DebugLogsScreen> {
  bool _errorsOnly = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<LogEntry> _getFilteredLogs() {
    final allLogs = DebugService.logs;
    final q = _searchQuery.toLowerCase();
    final hasSearch = _searchQuery.isNotEmpty;
    
    // Single pass filter, iterate in reverse
    final result = <LogEntry>[];
    for (int i = allLogs.length - 1; i >= 0; i--) {
      final l = allLogs[i];
      if (_errorsOnly && !l.isError) continue;
      if (hasSearch && !l.message.toLowerCase().contains(q) && !l.tag.toLowerCase().contains(q)) continue;
      result.add(l);
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        title: const Text('Terminal'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 20),
            onPressed: () {
              final logs = _getFilteredLogs();
              final text = logs.map((l) => _formatLogLine(l)).join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Copied ${logs.length} logs'), behavior: SnackBarBehavior.floating),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            onPressed: () { DebugService.clear(); setState(() {}); },
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: DebugService.logCount,
        builder: (_, __, ___) {
          final logs = _getFilteredLogs();
          final total = DebugService.logs.length;
          final errorCount = DebugService.logs.where((l) => l.isError).length;
          
          return Column(
            children: [
              // Search & filter
              Container(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        style: TextStyle(color: colors.onSurface, fontFamily: 'monospace', fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'grep...',
                          hintStyle: TextStyle(color: colors.onSurface.withAlpha(100)),
                          prefixIcon: Icon(Icons.search, size: 18, color: colors.onSurface.withAlpha(150)),
                          suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(icon: Icon(Icons.close, size: 16, color: colors.onSurface), onPressed: () { _searchController.clear(); setState(() => _searchQuery = ''); })
                            : null,
                          filled: true,
                          fillColor: colors.surfaceContainerHighest,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() => _searchQuery = v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => setState(() => _errorsOnly = !_errorsOnly),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _errorsOnly ? colors.error : colors.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('ERR', style: TextStyle(fontSize: 11, color: _errorsOnly ? colors.onError : colors.error, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
              
              // Stats
              Container(
                color: colors.surfaceContainerHighest,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                width: double.infinity,
                child: Text(
                  '> total: $total | errors: $errorCount | showing: ${logs.length}${_searchQuery.isNotEmpty ? " | filter: \"$_searchQuery\"" : ""}',
                  style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: colors.primary),
                ),
              ),
              
              // Logs
              Expanded(
                child: logs.isEmpty
                  ? Center(child: Text('> no logs_', style: TextStyle(color: colors.onSurface.withAlpha(100), fontFamily: 'monospace')))
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(8),
                      itemCount: logs.length,
                      itemBuilder: (_, i) => _buildLogLine(logs[i], colors, isDark),
                    ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLogLine(LogEntry log, ColorScheme colors, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: SelectableText.rich(
        TextSpan(
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.5),
          children: [
            TextSpan(text: _formatTime(log.time), style: TextStyle(color: colors.outline)),
            const TextSpan(text: ' '),
            TextSpan(text: '[${log.tag}]', style: TextStyle(color: _getTagColor(log.tag, colors, isDark))),
            const TextSpan(text: ' '),
            TextSpan(text: log.message, style: TextStyle(color: log.isError ? colors.error : colors.onSurface)),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';
  
  String _formatLogLine(LogEntry l) => '${_formatTime(l.time)} [${l.tag}] ${l.message}';

  Color _getTagColor(String tag, ColorScheme colors, bool isDark) {
    switch (tag) {
      case 'App': return colors.primary;
      case 'Sync': return colors.tertiary;
      case 'GitHub': return colors.secondary;
      case 'DB': return isDark ? Colors.orange[300]! : Colors.orange[700]!;
      case 'Flutter': return isDark ? Colors.lightBlue[300]! : Colors.lightBlue[700]!;
      case 'Platform': return isDark ? Colors.purple[300]! : Colors.purple[700]!;
      case 'Uncaught': case 'Stack': return colors.error;
      case 'Notes': return isDark ? Colors.teal[300]! : Colors.teal[700]!;
      default: return colors.outline;
    }
  }
}
