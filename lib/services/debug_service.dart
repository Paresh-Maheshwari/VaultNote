// ============================================================================
// DEBUG SERVICE
// ============================================================================
//
// In-memory logging for debugging. Logs are viewable in Settings > Debug Logs.
// Max 500 entries, oldest removed when limit reached.
// ============================================================================

import 'package:flutter/foundation.dart';

/// In-memory debug logging service.
class DebugService {
  static final List<LogEntry> _logs = [];
  static final ValueNotifier<int> logCount = ValueNotifier(0);
  
  static List<LogEntry> get logs => List.unmodifiable(_logs);
  
  /// Log a message with tag. Set isError=true for errors.
  static void log(String tag, String message, {bool isError = false}) {
    _logs.add(LogEntry(DateTime.now(), tag, message, isError));
    if (_logs.length > 500) _logs.removeAt(0);
    logCount.value = _logs.length;
    if (kDebugMode) print('[$tag] $message');
  }
  
  /// Clear all logs.
  static void clear() {
    _logs.clear();
    logCount.value = 0;
  }
}

/// Single log entry.
class LogEntry {
  final DateTime time;
  final String tag;
  final String message;
  final bool isError;
  LogEntry(this.time, this.tag, this.message, this.isError);
}
