// ============================================================================
// BIOMETRIC SERVICE
// ============================================================================
//
// Handles fingerprint/face authentication for lock screen.
// Uses local_auth package for biometric verification.
//
// ## Platform Support
// - Android: Fingerprint, Face
// - iOS: Touch ID, Face ID
// - Windows: Windows Hello
// - Linux: Not supported (returns false)
//
// ## Flow
// 1. User enables biometric in Settings (when master password is set)
// 2. We store password in secure storage
// 3. On lock screen, user can tap fingerprint to authenticate
// 4. If biometric succeeds, we retrieve password and unlock
//
// ## Security
// - Password stored in platform secure storage
// - Cleared when master password changes
// ============================================================================

import 'dart:io';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class BiometricService {
  static final _auth = LocalAuthentication();
  static const _key = 'biometric_password';
  static const _enabledKey = 'biometric_enabled';
  
  // Configure storage with platform options
  static FlutterSecureStorage get _storage {
    if (Platform.isWindows) {
      return const FlutterSecureStorage(
        wOptions: WindowsOptions(),
      );
    }
    return const FlutterSecureStorage();
  }

  /// Check if device supports biometrics
  static Future<bool> isAvailable() async {
    // Linux desktop doesn't support biometrics well
    if (Platform.isLinux) return false;
    
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final isSupported = await _auth.isDeviceSupported();
      return canCheck || isSupported;
    } catch (e) {
      return false;
    }
  }

  /// Check if biometric is enabled by user
  static Future<bool> isEnabled() async {
    try {
      final enabled = await _storage.read(key: _enabledKey);
      return enabled == 'true';
    } catch (e) {
      return false;
    }
  }

  /// Enable biometric and store password
  static Future<bool> enable(String password) async {
    try {
      // Verify biometric first
      final authenticated = await authenticate();
      if (!authenticated) return false;
      
      // Store password securely
      await _storage.write(key: _key, value: password);
      await _storage.write(key: _enabledKey, value: 'true');
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Disable biometric and clear stored password
  static Future<void> disable() async {
    try {
      await _storage.delete(key: _key);
      await _storage.write(key: _enabledKey, value: 'false');
    } catch (e) {
      // Ignore errors
    }
  }

  /// Authenticate using biometrics
  static Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Authenticate to unlock Vaultnote',
        persistAcrossBackgrounding: true,
        biometricOnly: false, // Allow PIN/pattern as fallback
      );
    } catch (e) {
      return false;
    }
  }

  /// Authenticate and get stored password
  static Future<String?> authenticateAndGetPassword() async {
    try {
      final authenticated = await authenticate();
      if (!authenticated) return null;
      
      return await _storage.read(key: _key);
    } catch (e) {
      return null;
    }
  }

  /// Clear stored password (called when master password changes)
  static Future<void> clearPassword() async {
    try {
      await _storage.delete(key: _key);
      await _storage.write(key: _enabledKey, value: 'false');
    } catch (e) {
      // Ignore errors
    }
  }
}
