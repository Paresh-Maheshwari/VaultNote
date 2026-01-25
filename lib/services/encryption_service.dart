// ============================================================================
// ENCRYPTION SERVICE (SIMPLIFIED)
// ============================================================================
//
// Simplified encryption service for VaultNote.
//
// ## Architecture Changes:
// - Removed folder-level encryption (only master encryption)
// - Removed GitHub verify tokens (local E2EE validation only)
// - Notes stored as plain text in database (encrypt only for GitHub sync)
//
// ## Encryption:
// - Master password only (no folder passwords)
// - Local HMAC-based validation (no GitHub dependency)
// - AES-256-CBC with PBKDF2 key derivation
//
// ============================================================================

import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:encrypt/encrypt.dart' as encrypt_lib;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/pointycastle.dart' show Pbkdf2Parameters;
import 'package:crypto/crypto.dart';
import 'debug_service.dart';

class EncryptionService {
  static const _storage = FlutterSecureStorage();
  
  // Storage keys
  static const _masterEnabledKey = 'master_encryption_enabled';
  static const _passwordHashKey = 'password_hash';
  
  // ============================================================================
  // SESSION PASSWORD (Memory Only)
  // ============================================================================
  
  /// Master password stored in memory after user enters it.
  /// Never persisted to disk - cleared when app closes.
  static String? _sessionPassword;
  
  /// Get master session password (null if not entered yet)
  static String? get sessionPassword => _sessionPassword;
  
  /// Set master session password after user enters it
  static void setSessionPassword(String password) => _sessionPassword = password;
  
  /// Clear session password (called on app close or logout)
  static void clearSession() {
    _sessionPassword = null;
  }
  
  // ============================================================================
  // CORE ENCRYPTION/DECRYPTION
  // ============================================================================
  
  /// Derive 256-bit key from password using PBKDF2.
  static Uint8List _deriveKey(String password, Uint8List salt) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, 10000, 32));
    return pbkdf2.process(Uint8List.fromList(utf8.encode(password)));
  }

  /// Generate cryptographically secure random salt (16 bytes)
  static Uint8List _generateSalt() {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
  }

  /// Encrypt plaintext with password using AES-256-CBC.
  /// Returns format: `ENC:base64(salt):base64(iv):base64(ciphertext)`
  static String encrypt(String plainText, String password, {Uint8List? salt}) {
    if (plainText.isEmpty || password.isEmpty) return plainText;
    
    salt ??= _generateSalt();
    final key = encrypt_lib.Key(_deriveKey(password, salt));
    final iv = encrypt_lib.IV.fromSecureRandom(16);
    final encrypter = encrypt_lib.Encrypter(encrypt_lib.AES(key, mode: encrypt_lib.AESMode.cbc));
    final encrypted = encrypter.encrypt(plainText, iv: iv);
    
    return 'ENC:${base64Encode(salt)}:${iv.base64}:${encrypted.base64}';
  }

  /// Decrypt ciphertext with password.
  /// Returns decrypted plaintext, or null if wrong password/corrupted data.
  static String? decrypt(String encryptedText, String password) {
    if (password.isEmpty) return null;
    
    try {
      String data = encryptedText;
      
      // Remove ENC: prefix if present
      if (data.startsWith('ENC:') && data.length > 4) {
        data = data.substring(4);
      }
      
      final parts = data.split(':');
      if (parts.length != 3) return null;
      
      final salt = base64Decode(parts[0]);
      final iv = encrypt_lib.IV.fromBase64(parts[1]);
      final encrypted = encrypt_lib.Encrypted.fromBase64(parts[2]);
      final key = encrypt_lib.Key(_deriveKey(password, Uint8List.fromList(salt)));
      final encrypter = encrypt_lib.Encrypter(encrypt_lib.AES(key, mode: encrypt_lib.AESMode.cbc));
      
      return encrypter.decrypt(encrypted, iv: iv);
    } catch (e) {
      return null;
    }
  }

  /// Check if text is encrypted.
  static bool isEncrypted(String text) {
    if (text.isEmpty) return false;
    
    if (text.startsWith('ENC:') && text.length > 4) {
      final parts = text.substring(4).split(':');
      if (parts.length != 3) return false;
      try {
        base64Decode(parts[0]);
        base64Decode(parts[1]);
        base64Decode(parts[2]);
        return true;
      } catch (_) {
        return false;
      }
    }
    
    return false;
  }

  // ============================================================================
  // MASTER ENCRYPTION (SIMPLIFIED)
  // ============================================================================
  
  // Storage keys
  static const _versionKey = 'encryption_version';
  
  /// Check if master encryption is enabled
  static Future<bool> isMasterEncryptionEnabled() async {
    try {
      return await _storage.read(key: _masterEnabledKey) == 'true';
    } catch (e) {
      DebugService.log('Encryption', 'Error reading master encryption status: $e', isError: true);
      return false;
    }
  }

  /// Generate HMAC-based password hash for local validation
  static String _generatePasswordHash(String password) {
    final key = utf8.encode('vaultnote_master_key');
    final bytes = utf8.encode(password);
    final hmac = Hmac(sha256, key);
    final digest = hmac.convert(bytes);
    return digest.toString();
  }

  /// Get current encryption version (for multi-device sync)
  static Future<int> getEncryptionVersion() async {
    final version = await _storage.read(key: _versionKey);
    return int.tryParse(version ?? '0') ?? 0;
  }

  /// Set encryption version (for multi-device sync)
  static Future<void> setEncryptionVersion(int version) async {
    await _storage.write(key: _versionKey, value: version.toString());
  }

  /// Enable master encryption with password.
  /// Uses local HMAC validation and version tracking for multi-device sync.
  static Future<void> enableMasterEncryption(String password) async {
    try {
      final passwordHash = _generatePasswordHash(password);
      final newVersion = await getEncryptionVersion() + 1;
      
      await _storage.write(key: _masterEnabledKey, value: 'true');
      await _storage.write(key: _passwordHashKey, value: passwordHash);
      await setEncryptionVersion(newVersion);
    } catch (e) {
      DebugService.log('Encryption', 'Error enabling master encryption: $e', isError: true);
      rethrow;
    }
  }

  /// Verify master password using local HMAC validation
  static Future<bool> verifyMasterPassword(String password) async {
    try {
      final storedHash = await _storage.read(key: _passwordHashKey);
      if (storedHash == null) return false;
      
      final inputHash = _generatePasswordHash(password);
      return storedHash == inputHash;
    } catch (e) {
      DebugService.log('Encryption', 'Error verifying master password: $e', isError: true);
      return false;
    }
  }

  /// Change master password and increment version for multi-device sync
  static Future<void> changeMasterPassword(String newPassword) async {
    try {
      final newHash = _generatePasswordHash(newPassword);
      final newVersion = await getEncryptionVersion() + 1;
      
      await _storage.write(key: _passwordHashKey, value: newHash);
      await setEncryptionVersion(newVersion);
      setSessionPassword(newPassword);
    } catch (e) {
      DebugService.log('Encryption', 'Error changing master password: $e', isError: true);
      rethrow;
    }
  }

  // ============================================================================
  // VERSION LOCKING (Multi-Device Coordination)
  // ============================================================================
  
  /// Generate unique device ID for locking
  static String _getDeviceId() {
    // Simple device ID based on timestamp and random
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = Random().nextInt(999999);
    return '${timestamp}_$random';
  }

  /// Lock encryption changes (prevents other devices from changing)
  /// Returns lock data to store on GitHub: {"locked": true, "device": "device_id", "timestamp": "iso_date"}
  static Map<String, dynamic> createVersionLock() {
    return {
      'locked': true,
      'device': _getDeviceId(),
      'timestamp': DateTime.now().toIso8601String(),
    };
  }

  /// Check if lock is expired (older than 5 minutes)
  static bool isLockExpired(Map<String, dynamic> lockData) {
    try {
      final timestamp = DateTime.parse(lockData['timestamp']);
      final now = DateTime.now();
      final difference = now.difference(timestamp).inMinutes;
      return difference > 5; // Lock expires after 5 minutes
    } catch (e) {
      return true; // Invalid timestamp = expired
    }
  }

  /// Disable master encryption completely
  static Future<void> disableMasterEncryption() async {
    try {
      final newVersion = await getEncryptionVersion() + 1;
      
      await _storage.delete(key: _masterEnabledKey);
      await _storage.delete(key: _passwordHashKey);
      await setEncryptionVersion(newVersion);
      clearSession();
    } catch (e) {
      DebugService.log('Encryption', 'Error disabling master encryption: $e', isError: true);
      rethrow;
    }
  }

  // ============================================================================
  // GITHUB SYNC ENCRYPTION (Only for remote storage)
  // ============================================================================
  
  /// Encrypt content for GitHub sync only
  static String? encryptForSync(String content) {
    if (_sessionPassword == null) return null;
    return encrypt(content, _sessionPassword!);
  }

  /// Decrypt content from GitHub sync
  static String? decryptFromSync(String encryptedContent) {
    if (_sessionPassword == null) return null;
    if (!isEncrypted(encryptedContent)) return encryptedContent;
    return decrypt(encryptedContent, _sessionPassword!);
  }

  // ============================================================================
  // PASSWORD-PROTECTED GIST ENCRYPTION (PENC prefix)
  // ============================================================================

  static const _pencPrefix = 'PENC:';

  /// Check if content is password-protected gist encrypted
  static bool isProtectedGist(String content) {
    return content.contains(_pencPrefix);
  }

  /// Extract PENC: encrypted data from gist content
  static String? _extractPencData(String content) {
    final match = RegExp(r'PENC:[^\s]+').firstMatch(content);
    return match?.group(0);
  }

  /// Encrypt content for password-protected gist sharing
  static String encryptForProtectedGist(String content, String password) {
    final encrypted = encrypt(content, password);
    if (encrypted.length <= 4) return encrypted;
    return '$_pencPrefix${encrypted.substring(4)}'; // Replace ENC: with PENC:
  }

  /// Decrypt password-protected gist content
  static String? decryptProtectedGist(String content, String password) {
    final pencData = _extractPencData(content);
    if (pencData == null || pencData.length <= 5) return null;
    // Convert PENC: to ENC: for decryption
    final encData = 'ENC:${pencData.substring(5)}';
    return decrypt(encData, password);
  }
}
