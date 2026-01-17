// ============================================================================
// THEME PROVIDER
// ============================================================================
//
// Manages app theme settings (light/dark/system) and editor preferences.
// Settings are persisted to SharedPreferences.
// ============================================================================

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Theme and display settings provider.
class ThemeProvider extends ChangeNotifier {
  final SharedPreferences _prefs;
  ThemeMode _themeMode = ThemeMode.system;
  bool _defaultPreviewMode = false;  // Open notes in preview mode by default
  bool _useRichEditor = true;  // Use rich editor (AppFlowy) by default

  ThemeProvider(this._prefs) {
    _themeMode = ThemeMode.values[_prefs.getInt('themeMode') ?? 0];
    _defaultPreviewMode = _prefs.getBool('defaultPreviewMode') ?? false;
    _useRichEditor = _prefs.getBool('useRichEditor') ?? true;
  }

  ThemeMode get themeMode => _themeMode;
  bool get defaultPreviewMode => _defaultPreviewMode;
  bool get useRichEditor => _useRichEditor;

  /// Set theme mode (light/dark/system).
  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    _prefs.setInt('themeMode', mode.index);
    notifyListeners();
  }

  /// Set default editor mode (edit/preview).
  void setDefaultPreviewMode(bool preview) {
    _defaultPreviewMode = preview;
    _prefs.setBool('defaultPreviewMode', preview);
    notifyListeners();
  }

  /// Set editor type (rich/markdown).
  void setUseRichEditor(bool rich) {
    _useRichEditor = rich;
    _prefs.setBool('useRichEditor', rich);
    notifyListeners();
  }
}
