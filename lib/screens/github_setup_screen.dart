// ============================================================================
// GITHUB SETUP SCREEN
// ============================================================================
//
// GitHub OAuth Device Flow setup wizard.
//
// ## Steps
// 1. Start device authorization flow (auto-starts)
// 2. User copies code and enters at github.com/login/device
// 3. Poll for access token until authorized
// 4. Select repository and branch for sync
// 5. Handle encryption sync (if remote has encryption)
//
// ## Encryption Handling
// - needsPassword: Remote has encryption, prompt for password
// - versionMismatch: Password changed on another device
// - disabledRemotely: Encryption was disabled remotely
//
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/notes_provider.dart';
import '../services/github_auth_service.dart';

/// GitHub setup wizard with device flow authentication.
class GitHubSetupScreen extends StatefulWidget {
  const GitHubSetupScreen({super.key});

  @override
  State<GitHubSetupScreen> createState() => _GitHubSetupScreenState();
}

class _GitHubSetupScreenState extends State<GitHubSetupScreen> {
  final GitHubAuthService _authService = GitHubAuthService();
  
  int _step = 1; // 1=authorize, 2=polling, 3=select repo
  DeviceCodeResponse? _deviceCode;
  bool _isLoading = false;
  String? _error;
  bool _isPolling = false;
  List<Map<String, String>> _repos = [];
  String? _selectedRepo;
  List<String> _branches = [];
  String? _selectedBranch;
  String? _defaultBranch;

  @override
  void initState() {
    super.initState();
    _startDeviceFlow(); // Auto-start device flow
  }

  /// Start OAuth device flow.
  Future<void> _startDeviceFlow() async {
    setState(() { _isLoading = true; _error = null; });

    try {
      final deviceCode = await _authService.requestDeviceCode();
      if (deviceCode != null) {
        setState(() { _deviceCode = deviceCode; _step = 1; });
      } else {
        setState(() { _error = 'Failed to start authentication'; });
      }
    } catch (e) {
      setState(() { _error = 'Error: $e'; });
    } finally {
      setState(() { _isLoading = false; });
    }
  }

  Future<void> _openGitHubAuth() async {
    if (_deviceCode != null) {
      final uri = Uri.parse(_deviceCode!.verificationUri);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }

  Future<void> _waitForAuth() async {
    if (_deviceCode == null) return;
    setState(() { _isPolling = true; _error = null; _step = 2; });

    try {
      final token = await _authService.pollForToken(_deviceCode!.deviceCode, _deviceCode!.interval);
      if (!mounted) return;
      
      if (token != null) {
        setState(() => _isLoading = true);
        _repos = await _authService.fetchUserRepos();
        if (!mounted) return;
        setState(() { _isLoading = false; _step = 3; _isPolling = false; });
      } else {
        setState(() { _error = 'Authentication failed or timed out'; _step = 1; _isPolling = false; });
      }
    } catch (e) {
      if (mounted) setState(() { _error = 'Error: $e'; _isPolling = false; });
    }
  }

  Future<void> _onRepoSelected(String? repoFullName) async {
    if (repoFullName == null) return;
    setState(() { _selectedRepo = repoFullName; _isLoading = true; _branches = []; _selectedBranch = null; });

    final repo = _repos.where((r) => r['full_name'] == repoFullName).firstOrNull;
    if (repo == null) {
      setState(() { _isLoading = false; _error = 'Repository not found'; });
      return;
    }
    _defaultBranch = repo['default_branch'];
    final parts = repoFullName.split('/');
    if (parts.length < 2) {
      setState(() { _isLoading = false; _error = 'Invalid repo format'; });
      return;
    }
    final branches = await _authService.fetchBranches(parts[0], parts[1]);
    
    setState(() { _branches = branches; _selectedBranch = _defaultBranch; _isLoading = false; });
  }

  Future<void> _completeSetup() async {
    if (_selectedRepo == null || _selectedBranch == null) return;
    setState(() { _isLoading = true; _error = null; });

    try {
      final parts = _selectedRepo!.split('/');
      if (parts.length < 2) {
        setState(() { _isLoading = false; _error = 'Invalid repo format'; });
        return;
      }
      await _authService.saveRepo(parts[0], parts[1], _selectedBranch!);
      if (!mounted) return;
      
      final provider = context.read<NotesProvider>();
      final syncResult = await provider.initGitHub(_authService);
      if (!mounted) return;
      
      if (syncResult == EncryptionSyncResult.needsPassword) {
        // Remote has encryption, need password - new device setup
        final password = await _askRemotePassword();
        if (!mounted) return;
        if (password == null) {
          setState(() { _error = 'Password required for encrypted repo'; _isLoading = false; });
          return;
        }
        // Verify password by decrypting a note
        final valid = await provider.verifyPasswordWithRemoteNote(password);
        if (!mounted) return;
        if (!valid) {
          setState(() { _error = 'Wrong password'; _isLoading = false; });
          return;
        }
        await provider.setupEncryptionFromRemote(password);
      } else if (syncResult == EncryptionSyncResult.versionMismatch) {
        // Local key doesn't match remote - password changed on another device
        final password = await _askRemotePassword(message: 'Password was changed on another device. Enter current password:');
        if (!mounted) return;
        if (password == null) {
          setState(() { _error = 'Password required'; _isLoading = false; });
          return;
        }
        // Verify password by decrypting a note
        final valid = await provider.verifyPasswordWithRemoteNote(password);
        if (!mounted) return;
        if (!valid) {
          setState(() { _error = 'Wrong password'; _isLoading = false; });
          return;
        }
        await provider.setupEncryptionFromRemote(password);
      } else if (syncResult == EncryptionSyncResult.disabledRemotely) {
        // Encryption was disabled on another device - already handled, just notify
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Encryption was disabled on another device')),
          );
        }
      }
      
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() { _error = 'Setup failed: $e'; });
    } finally {
      if (mounted) setState(() { _isLoading = false; });
    }
  }

  Future<String?> _askRemotePassword({String? message}) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Encrypted Repository'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message ?? 'This repository has encryption enabled. Enter the master password:'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Master Password', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Unlock')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connect GitHub'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: _buildCurrentStep(theme, colors),
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentStep(ThemeData theme, ColorScheme colors) {
    switch (_step) {
      case 2: return _buildStep2Polling(theme, colors);
      case 3: return _buildStep3(theme, colors);
      default: return _buildStep1(theme, colors);
    }
  }

  Widget _buildStep1(ThemeData theme, ColorScheme colors) {
    return Column(
      children: [
        Text('Enter Code on GitHub', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          'Copy this code and enter it at GitHub',
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 28),
        
        // Code display
        GestureDetector(
          onTap: () async {
            if (_deviceCode != null) {
              await Clipboard.setData(ClipboardData(text: _deviceCode!.userCode));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Code copied!'), duration: Duration(seconds: 1)),
                );
              }
            }
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24),
            decoration: BoxDecoration(
              color: colors.primaryContainer.withAlpha(50),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colors.primary.withAlpha(50)),
            ),
            child: Column(
              children: [
                Text(
                  _deviceCode?.userCode ?? '',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 6,
                    fontFamily: 'monospace',
                    color: colors.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
        
        const SizedBox(height: 16),
        
        // Copy buttons row
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  if (_deviceCode != null) {
                    await Clipboard.setData(ClipboardData(text: _deviceCode!.userCode));
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Code copied!'), duration: Duration(seconds: 1)),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy Code'),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  if (_deviceCode != null) {
                    await Clipboard.setData(ClipboardData(text: _deviceCode!.verificationUri));
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Link copied!'), duration: Duration(seconds: 1)),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.link, size: 16),
                label: const Text('Copy Link'),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
        
        const SizedBox(height: 16),
        if (_error != null) _buildError(),
        
        // Open GitHub button
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            onPressed: _openGitHubAuth,
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Open GitHub'),
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: OutlinedButton(
            onPressed: _isPolling ? null : _waitForAuth,
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('I\'ve Entered the Code'),
          ),
        ),
      ],
    );
  }

  Widget _buildStep2Polling(ThemeData theme, ColorScheme colors) {
    return Column(
      children: [
        const SizedBox(height: 40),
        
        // Animated waiting indicator
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colors.primaryContainer.withAlpha(50),
          ),
          child: const SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
        ),
        const SizedBox(height: 28),
        Text('Waiting for authorization...', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(
          'Complete the authorization on GitHub\nThis page will update automatically',
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
        ),
      ],
    );
  }

  Widget _buildStep3(ThemeData theme, ColorScheme colors) {
    return Column(
      children: [
        // Success icon
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.green.withAlpha(30),
          ),
          child: const Icon(Icons.check_rounded, color: Colors.green, size: 36),
        ),
        const SizedBox(height: 20),
        Text('Connected!', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Select a repository for your notes', style: TextStyle(color: colors.onSurfaceVariant)),
        const SizedBox(height: 28),
        
        // Repository selection
        if (_repos.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.errorContainer.withAlpha(50),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: colors.error),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No repositories found. Make sure you granted access during installation.',
                    style: TextStyle(color: colors.error, fontSize: 13),
                  ),
                ),
              ],
            ),
          )
        else
          _buildSelectionCard(
            icon: Icons.folder_outlined,
            label: 'Repository',
            value: _selectedRepo,
            hint: 'Select repository',
            items: _repos.map((r) => r['full_name'] ?? '').toList(),
            onTap: () => _showRepoSelector(colors),
            colors: colors,
          ),
        
        if (_branches.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildSelectionCard(
            icon: Icons.account_tree_outlined,
            label: 'Branch',
            value: _selectedBranch,
            hint: 'Select branch',
            items: _branches,
            onTap: () => _showBranchSelector(colors),
            colors: colors,
            suffix: _selectedBranch == _defaultBranch ? ' (default)' : null,
          ),
        ],
        
        if (_isLoading) 
          const Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(strokeWidth: 2)),
        
        if (_error != null) ...[
          const SizedBox(height: 16),
          _buildError(),
        ],
        
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton(
            onPressed: _isLoading || _selectedRepo == null || _selectedBranch == null ? null : _completeSetup,
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Complete Setup'),
          ),
        ),
      ],
    );
  }

  Widget _buildSelectionCard({
    required IconData icon,
    required String label,
    required String? value,
    required String hint,
    required List<String> items,
    required VoidCallback onTap,
    required ColorScheme colors,
    String? suffix,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.outlineVariant.withAlpha(100)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.primary.withAlpha(20),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20, color: colors.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontSize: 12, color: colors.outline)),
                  const SizedBox(height: 2),
                  Text(
                    value != null ? '$value${suffix ?? ''}' : hint,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: value != null ? FontWeight.w500 : FontWeight.normal,
                      color: value != null ? colors.onSurface : colors.outline,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.keyboard_arrow_down_rounded, color: colors.outline),
          ],
        ),
      ),
    );
  }

  void _showRepoSelector(ColorScheme colors) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.folder_outlined, size: 20, color: colors.primary),
                  const SizedBox(width: 8),
                  Text('Select Repository', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('${_repos.length} repos', style: TextStyle(fontSize: 12, color: colors.outline)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: _repos.length,
                itemBuilder: (_, i) {
                  final repo = _repos[i];
                  final fullName = repo['full_name'] ?? '';
                  final repoName = repo['name'] ?? '';
                  final isPrivate = repo['private'] == 'true';
                  final selected = fullName == _selectedRepo;
                  
                  return ListTile(
                    leading: Icon(
                      isPrivate ? Icons.lock_outline : Icons.folder_outlined, 
                      color: selected ? colors.primary : colors.outline,
                      size: 20,
                    ),
                    title: Text(
                      repoName, 
                      style: TextStyle(
                        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Text(
                      isPrivate ? 'Private • $fullName' : fullName,
                      style: TextStyle(fontSize: 11, color: colors.outline),
                    ),
                    trailing: selected ? Icon(Icons.check_circle, color: colors.primary, size: 20) : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      _onRepoSelected(fullName);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showBranchSelector(ColorScheme colors) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Select Branch', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _branches.length,
                itemBuilder: (_, i) {
                  final branch = _branches[i];
                  final selected = branch == _selectedBranch;
                  final isDefault = branch == _defaultBranch;
                  return ListTile(
                    leading: Icon(Icons.account_tree_outlined, color: selected ? colors.primary : colors.outline),
                    title: Text(branch, style: TextStyle(fontWeight: selected ? FontWeight.w600 : FontWeight.normal)),
                    subtitle: isDefault ? Text('default', style: TextStyle(fontSize: 12, color: colors.outline)) : null,
                    trailing: selected ? Icon(Icons.check_circle, color: colors.primary) : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      setState(() => _selectedBranch = branch);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(_error!, style: const TextStyle(color: Colors.red))),
        ],
      ),
    );
  }
}
