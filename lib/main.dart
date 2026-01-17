// ============================================================================
// VAULTNOTE - MAIN ENTRY POINT
// ============================================================================
//
// Encrypted markdown notes app with GitHub sync.
//
// Features:
// - Local SQLite storage with GitHub backup
// - AES-256 master encryption with biometric unlock
// - Rich editor (WYSIWYG) and Markdown editor
// - Gist sharing with password protection
// - Star/favorite and pin notes
// - Welcome notes for first-time users
//
// Startup flow:
// 1. Initialize database (SQLite FFI for desktop)
// 2. Check if master encryption is enabled
// 3. Show lock screen if encrypted, otherwise show notes list
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, FlutterError, PlatformDispatcher;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'dart:io' show Platform;
import 'dart:async';
import 'providers/notes_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/notes_list_screen.dart';
import 'screens/lock_screen.dart';
import 'services/encryption_service.dart';
import 'services/debug_service.dart';

void main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    
    // Catch Flutter framework errors
    FlutterError.onError = (details) {
      final msg = details.toString();
      // Suppress known Linux keyboard/DevTools issues
      if (msg.contains('_pressedKeys.containsKey') || 
          msg.contains('Unable to retrieve framework response')) {
        return;
      }
      DebugService.log('Flutter', details.exceptionAsString(), isError: true);
      if (details.stack != null) {
        DebugService.log('Stack', details.stack.toString().split('\n').take(5).join('\n'), isError: true);
      }
    };
    
    // Catch platform errors
    PlatformDispatcher.instance.onError = (error, stack) {
      final msg = error.toString();
      if (msg.contains('_pressedKeys.containsKey') || 
          msg.contains('Unable to retrieve framework response')) {
        return true;
      }
      DebugService.log('Platform', error.toString(), isError: true);
      DebugService.log('Stack', stack.toString().split('\n').take(5).join('\n'), isError: true);
      return true;
    };
    
    // Initialize SQLite FFI for desktop platforms
    if (!kIsWeb && (Platform.isLinux || Platform.isWindows)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    
    DebugService.log('App', 'Starting Vaultnote');
    
    final prefs = await SharedPreferences.getInstance();
    final needsUnlock = await EncryptionService.isMasterEncryptionEnabled();
    
    DebugService.log('App', 'Encryption: ${needsUnlock ? 'enabled' : 'disabled'}');
    
    runApp(NotesApp(prefs: prefs, needsUnlock: needsUnlock));
  }, (error, stack) {
    DebugService.log('Uncaught', error.toString(), isError: true);
    DebugService.log('Stack', stack.toString().split('\n').take(5).join('\n'), isError: true);
  });
}

/// Root app widget.
class NotesApp extends StatefulWidget {
  final SharedPreferences prefs;
  final bool needsUnlock;
  const NotesApp({super.key, required this.prefs, required this.needsUnlock});

  @override
  State<NotesApp> createState() => _NotesAppState();
}

class _NotesAppState extends State<NotesApp> {
  late bool _locked;

  @override
  void initState() {
    super.initState();
    _locked = widget.needsUnlock;
  }

  void _unlock() => setState(() => _locked = false);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => NotesProvider()..init()),
        ChangeNotifierProvider(create: (_) => ThemeProvider(widget.prefs)),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Vaultnote',
          localizationsDelegates: const [AppFlowyEditorLocalizations.delegate],
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: Brightness.light,
              surface: const Color(0xFFF5F5F5),
              surfaceContainerHighest: const Color(0xFFE8E8E8),
              outline: const Color(0xFFBBBBBB),
              outlineVariant: const Color(0xFFD0D0D0),
            ),
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(0xFFF5F5F5),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFFF5F5F5),
              scrolledUnderElevation: 0,
              surfaceTintColor: Colors.transparent,
            ),
            cardTheme: const CardThemeData(
              color: Colors.white,
            ),
            dividerTheme: const DividerThemeData(
              color: Color(0xFFD0D0D0),
            ),
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
            appBarTheme: AppBarTheme(
              scrolledUnderElevation: 0,
              surfaceTintColor: Colors.transparent,
              backgroundColor: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark).surface,
            ),
          ),
          themeMode: themeProvider.themeMode,
          home: _locked ? LockScreen(onUnlocked: _unlock) : const NotesListScreen(),
        ),
      ),
    );
  }
}
