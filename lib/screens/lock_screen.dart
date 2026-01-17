// ============================================================================
// LOCK SCREEN
// ============================================================================
//
// Shown at app startup when master encryption is enabled.
// User must enter master password to access notes.
//
// ## Flow
//
// 1. App starts → main.dart checks if master encryption enabled
// 2. If enabled → Show LockScreen
// 3. User enters password → verifyMasterPassword() (HMAC validation)
// 4. If valid → Save to session memory → Call onUnlocked callback
// 5. App shows NotesListScreen
//
// ## Features
// - Biometric unlock (fingerprint/face) if enabled
// - Shake animation on wrong password
// - Auto-prompt biometric on start
//
// ## Security
// - Password is NEVER stored on disk
// - Password saved to session memory only (cleared on app close)
// - HMAC-based password validation (no decrypt needed)
// - Biometric stores password in platform secure storage
//
// ============================================================================

import 'package:flutter/material.dart';
import '../services/encryption_service.dart';
import '../services/biometric_service.dart';

class LockScreen extends StatefulWidget {
  /// Callback when user successfully unlocks with correct password
  final VoidCallback onUnlocked;
  
  const LockScreen({super.key, required this.onUnlocked});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _loading = false;
  bool _obscure = true;
  String? _error;
  int _attempts = 0;
  late AnimationController _shakeController;
  bool _biometricAvailable = false;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _checkBiometric();
  }

  Future<void> _checkBiometric() async {
    final available = await BiometricService.isAvailable();
    final enabled = await BiometricService.isEnabled();
    if (available && enabled) {
      setState(() => _biometricAvailable = true);
      // Auto-prompt biometric on start
      _unlockWithBiometric();
    }
  }

  Future<void> _unlockWithBiometric() async {
    final password = await BiometricService.authenticateAndGetPassword();
    if (password != null && password.isNotEmpty) {
      final valid = await EncryptionService.verifyMasterPassword(password);
      if (valid) {
        EncryptionService.setSessionPassword(password);
        widget.onUnlocked();
      } else {
        // Password changed - clear biometric
        await BiometricService.clearPassword();
        setState(() => _biometricAvailable = false);
        if (mounted) {
          setState(() => _error = 'Password changed. Please enter new password.');
        }
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  /// Attempt to unlock with entered password.
  Future<void> _unlock() async {
    if (_controller.text.isEmpty) {
      setState(() => _error = 'Please enter password');
      return;
    }
    setState(() { _loading = true; _error = null; });
    
    final valid = await EncryptionService.verifyMasterPassword(_controller.text);
    
    if (valid) {
      EncryptionService.setSessionPassword(_controller.text);
      widget.onUnlocked();
    } else {
      _attempts++;
      _shakeController.forward(from: 0);
      _controller.clear();
      _focusNode.requestFocus();
      setState(() { 
        _error = _attempts >= 3 ? 'Incorrect password. Try again.' : 'Wrong password';
        _loading = false; 
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark 
              ? [colors.surface, colors.surface]
              : [colors.primary.withAlpha(15), colors.surface],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: AnimatedBuilder(
                animation: _shakeController,
                builder: (context, child) {
                  final shake = _shakeController.isAnimating
                    ? (1 - _shakeController.value) * 10 * ((_shakeController.value * 8).floor() % 2 == 0 ? 1 : -1)
                    : 0.0;
                  return Transform.translate(offset: Offset(shake, 0), child: child);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // App icon/logo
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.primary.withAlpha(25),
                        border: Border.all(color: colors.primary.withAlpha(50), width: 2),
                      ),
                      child: Icon(Icons.lock_rounded, size: 40, color: colors.primary),
                    ),
                    const SizedBox(height: 28),
                    
                    // App name
                    Text(
                      'Vaultnote',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colors.onSurface,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Enter master password to unlock',
                      style: TextStyle(color: colors.onSurfaceVariant, fontSize: 14),
                    ),
                    const SizedBox(height: 36),
                    
                    // Password field
                    Container(
                      constraints: const BoxConstraints(maxWidth: 300),
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        obscureText: _obscure,
                        autofocus: true,
                        onSubmitted: (_) => _unlock(),
                        style: const TextStyle(fontSize: 16, letterSpacing: 2),
                        textAlign: TextAlign.center,
                        decoration: InputDecoration(
                          hintText: 'Password',
                          hintStyle: TextStyle(color: colors.outline, letterSpacing: 0),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, 
                              size: 20,
                              color: colors.outline,
                            ),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                          prefixIcon: Icon(Icons.key_rounded, size: 20, color: colors.outline),
                          filled: true,
                          fillColor: colors.surfaceContainerHighest.withAlpha(80),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide(color: colors.primary, width: 2),
                          ),
                          errorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide(color: colors.error, width: 2),
                          ),
                          focusedErrorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide(color: colors.error, width: 2),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        ),
                      ),
                    ),
                    
                    // Error message
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(color: colors.error, fontSize: 13),
                      ),
                    ],
                    
                    const SizedBox(height: 20),
                    
                    // Unlock button
                    Container(
                      constraints: const BoxConstraints(maxWidth: 300),
                      width: double.infinity,
                      height: 50,
                      child: FilledButton(
                        onPressed: _loading ? null : _unlock,
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                        ),
                        child: _loading 
                          ? SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: colors.onPrimary))
                          : const Text('Unlock', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    
                    // Biometric button
                    if (_biometricAvailable) ...[
                      const SizedBox(height: 16),
                      IconButton(
                        onPressed: _unlockWithBiometric,
                        icon: Icon(Icons.fingerprint, size: 40, color: colors.primary),
                        tooltip: 'Unlock with fingerprint',
                      ),
                    ],
                    
                    const SizedBox(height: 48),
                    
                    // Security badge
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHighest.withAlpha(60),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.verified_user_outlined, size: 14, color: colors.outline),
                          const SizedBox(width: 6),
                          Text(
                            'End-to-end encrypted',
                            style: TextStyle(color: colors.outline, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
