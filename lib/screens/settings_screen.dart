// ============================================================================
// SETTINGS SCREEN
// ============================================================================
//
// App settings and configuration UI.
//
// Sections:
// - GitHub: Connect/disconnect, sync status, branch selection
// - Appearance: Theme (light/dark/system), default view, editor type
// - Security: Master encryption, biometric unlock
// - Data: Export/import notes, clear database
// - Shortcuts: Keyboard shortcuts reference (desktop)
// - About: Version info, debug logs
//
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'dart:convert';
import 'dart:io';
import '../providers/notes_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/bookmarks_provider.dart';
import '../services/encryption_service.dart';
import '../services/biometric_service.dart';
import '../models/note.dart';
import 'github_setup_screen.dart';
import 'debug_logs_screen.dart';

/// Settings screen with GitHub, encryption, and app configuration.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Widget _syncStat(BuildContext context, IconData icon, String value, String label, {bool isWarning = false}) {
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: isWarning ? Colors.orange : colors.primary),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: isWarning ? Colors.orange : colors.onSurface)),
          Text(label, style: TextStyle(fontSize: 9, color: colors.outline)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 600;
    
    return Scaffold(
      appBar: isDesktop ? AppBar(title: const Text('Settings')) : null,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // GitHub Section
          _buildGitHubSection(context),
          const SizedBox(height: 16),
          
          // Appearance Section
          _buildSectionCard(
            context,
            icon: Icons.palette_outlined,
            title: 'Appearance',
            children: [
              Consumer<ThemeProvider>(
                builder: (context, themeProvider, _) => _buildSettingTile(
                  icon: Icons.brightness_6,
                  title: 'Theme',
                  trailing: SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.settings_suggest, size: 18)),
                      ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode, size: 18)),
                      ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode, size: 18)),
                    ],
                    selected: {themeProvider.themeMode},
                    onSelectionChanged: (s) => themeProvider.setThemeMode(s.first),
                    showSelectedIcon: false,
                  ),
                ),
              ),
              const Divider(height: 1),
              Consumer<ThemeProvider>(
                builder: (context, themeProvider, _) => _buildSettingTile(
                  icon: Icons.visibility,
                  title: 'Default Note View',
                  trailing: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Edit')),
                      ButtonSegment(value: true, label: Text('Preview')),
                    ],
                    selected: {themeProvider.defaultPreviewMode},
                    onSelectionChanged: (s) => themeProvider.setDefaultPreviewMode(s.first),
                    showSelectedIcon: false,
                  ),
                ),
              ),
              if (isDesktop) const Divider(height: 1),
              if (isDesktop)
                Consumer<ThemeProvider>(
                  builder: (context, themeProvider, _) => _buildSettingTile(
                    icon: Icons.edit_note,
                    title: 'Editor Type (Desktop)',
                    subtitle: themeProvider.useRichEditor ? 'WYSIWYG editor' : 'Markdown editor',
                    trailing: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, label: Text('Rich')),
                        ButtonSegment(value: false, label: Text('Markdown')),
                      ],
                      selected: {themeProvider.useRichEditor},
                      onSelectionChanged: (s) => themeProvider.setUseRichEditor(s.first),
                      showSelectedIcon: false,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          
          // Security Section
          _EncryptionSection(),
          const SizedBox(height: 16),
          
          // Data Section
          Consumer<BookmarksProvider>(
            builder: (context, bookmarksProvider, _) => _buildSectionCard(
              context,
              icon: Icons.storage_outlined,
              title: 'Data',
              children: [
                _buildSettingTile(
                  icon: Icons.bookmark_outline,
                  title: 'Total Bookmarks',
                  subtitle: '${bookmarksProvider.count} bookmarks stored',
                ),
                const Divider(height: 1),
                _buildSettingTile(
                  icon: Icons.file_download_outlined,
                  title: 'Export Notes',
                  subtitle: 'Save all notes as JSON',
                  onTap: () => _exportNotes(context),
                ),
                const Divider(height: 1),
                _buildSettingTile(
                  icon: Icons.file_upload_outlined,
                  title: 'Import Notes',
                  subtitle: 'Load notes from JSON file',
                  onTap: () => _importNotes(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          
          // Browser Extension Section (desktop only)
          if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
            _buildExtensionSection(context),
          if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
            const SizedBox(height: 16),
          
          // Shortcuts Section (desktop only)
          if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) ...[
            _buildSectionCard(
              context,
              icon: Icons.keyboard_outlined,
              title: 'Keyboard Shortcuts',
              children: [
                _buildShortcutTile('Ctrl + N', 'Create new note'),
                const Divider(height: 1),
                _buildShortcutTile('Ctrl + S', 'Save current note'),
                const Divider(height: 1),
                _buildShortcutTile('Ctrl + P', 'Toggle preview mode'),
                const Divider(height: 1),
                _buildShortcutTile('Ctrl + F', 'Focus search'),
                const Divider(height: 1),
                _buildShortcutTile('Esc', 'Exit focus mode'),
              ],
            ),
            const SizedBox(height: 16),
          ],
          
          // Clear Database Section
          _buildClearDatabaseSection(context),
          const SizedBox(height: 16),
          
          // About Section
          _buildSectionCard(
            context,
            icon: Icons.info_outline,
            title: 'About',
            children: [
              FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snapshot) {
                  final version = snapshot.data?.version ?? '...';
                  final build = snapshot.data?.buildNumber ?? '';
                  return _buildSettingTile(
                    icon: Icons.notes,
                    title: 'Vaultnote',
                    subtitle: 'Version $version${build.isNotEmpty ? ' ($build)' : ''}',
                  );
                },
              ),
              const Divider(height: 1),
              _buildSettingTile(
                icon: Icons.bug_report_outlined,
                title: 'Debug Logs',
                subtitle: 'View app logs for troubleshooting',
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DebugLogsScreen())),
              ),
              const Divider(height: 1),
              _buildSettingTile(
                icon: Icons.code,
                title: 'Source Code',
                subtitle: 'View on GitHub',
                onTap: () async {
                  final url = Uri.parse('https://github.com/Paresh-Maheshwari/VaultNote');
                  if (await canLaunchUrl(url)) {
                    await launchUrl(url, mode: LaunchMode.externalApplication);
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGitHubSection(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    
    return Consumer<NotesProvider>(
      builder: (context, provider, _) {
        final isConnected = provider.isGitHubConfigured;
        
        return Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: isConnected ? colors.primary.withValues(alpha: 0.5) : colors.outlineVariant.withValues(alpha: 0.5),
              width: isConnected ? 1.5 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.cloud_outlined, size: 20, color: colors.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('GitHub Sync', style: theme.textTheme.titleSmall?.copyWith(
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      )),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: isConnected ? Colors.green.withValues(alpha: 0.15) : Colors.grey.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isConnected ? Icons.check_circle : Icons.circle_outlined,
                            size: 12,
                            color: isConnected ? Colors.green : Colors.grey,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isConnected ? 'Connected' : 'Disconnected',
                            style: TextStyle(
                              fontSize: 11,
                              color: isConnected ? Colors.green : Colors.grey,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (isConnected) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.folder_outlined, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${provider.repoOwner}/${provider.repoName}',
                                style: const TextStyle(fontWeight: FontWeight.w500)),
                              Text('Branch: ${provider.repoBranch}',
                                style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6))),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.open_in_new, size: 20),
                          onPressed: () => _openGitHubRepo(provider),
                          tooltip: 'Open on GitHub',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Sync status summary
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        _syncStat(context, Icons.note, '${provider.notes.length}', 'Total'),
                        _syncStat(context, Icons.cloud_done, '${provider.notes.where((n) => n.isSynced).length}', 'Synced'),
                        _syncStat(context, Icons.cloud_off, '${provider.notes.where((n) => !n.isSynced).length}', 'Pending'),
                        if (provider.conflictCount > 0)
                          _syncStat(context, Icons.warning, '${provider.conflictCount}', 'Conflicts', isWarning: true),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _showChangeBranchDialog(context, provider),
                          icon: const Icon(Icons.swap_horiz, size: 18),
                          label: const Text('Change Branch'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _disconnect(context, provider),
                          icon: const Icon(Icons.link_off, size: 18),
                          label: const Text('Disconnect'),
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await provider.markAllForSync();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('All notes marked for sync')),
                              );
                            }
                          },
                          icon: const Icon(Icons.sync, size: 18),
                          label: const Text('Re-sync All Notes'),
                        ),
                      ),
                      if (provider.conflictCount > 0) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              provider.clearConflicts();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Conflicts cleared')),
                              );
                            },
                            icon: const Icon(Icons.clear, size: 18),
                            label: const Text('Clear Conflicts'),
                            style: OutlinedButton.styleFrom(foregroundColor: Colors.orange),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Auto-sync interval
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.timer_outlined, size: 18, color: colors.primary),
                            const SizedBox(width: 8),
                            const Text('Auto-sync', style: TextStyle(fontWeight: FontWeight.w500)),
                            const Spacer(),
                            Text(
                              provider.syncIntervalMinutes == 0 ? 'Off' : '${provider.syncIntervalMinutes} min',
                              style: TextStyle(fontSize: 12, color: colors.primary, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<int>(
                            segments: const [
                              ButtonSegment(value: 0, label: Text('Off')),
                              ButtonSegment(value: 2, label: Text('2m')),
                              ButtonSegment(value: 5, label: Text('5m')),
                              ButtonSegment(value: 10, label: Text('10m')),
                            ],
                            selected: {provider.syncIntervalMinutes == 1 ? 2 : (provider.syncIntervalMinutes == 30 ? 10 : provider.syncIntervalMinutes)},
                            onSelectionChanged: (v) => provider.setSyncInterval(v.first),
                            showSelectedIcon: false,
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  Text(
                    'Connect to GitHub to sync your notes across devices',
                    style: TextStyle(color: colors.onSurface.withValues(alpha: 0.6)),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GitHubSetupScreen())),
                    icon: const Icon(Icons.login),
                    label: const Text('Connect GitHub'),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildClearDatabaseSection(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    
    return Consumer<NotesProvider>(
      builder: (context, provider, _) {
        return Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.5)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.storage, size: 18, color: colors.primary),
                    const SizedBox(width: 8),
                    Text('Local Database', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: colors.onSurface)),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _showClearDatabaseDialog(context, provider),
                    icon: const Icon(Icons.delete_sweep, size: 18),
                    label: const Text('Clear Local Database'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showChangeBranchDialog(BuildContext context, NotesProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) => _BranchDialog(provider: provider),
    );
  }

  void _disconnect(BuildContext context, NotesProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Disconnect GitHub?'),
        content: const Text('Your notes will remain on this device but won\'t sync anymore.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () { provider.disconnectGitHub(); Navigator.pop(ctx); },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
  }

  Widget _buildExtensionSection(BuildContext context) {
    return Consumer<BookmarksProvider>(
      builder: (context, provider, _) => _buildSectionCard(
        context,
        icon: Icons.extension_outlined,
        title: 'Browser Extension',
        children: [
          SwitchListTile(
            secondary: Icon(provider.extensionServerEnabled ? Icons.power : Icons.power_off),
            title: const Text('Enable Extension Server'),
            subtitle: Text(provider.isServerRunning 
                ? 'Running on ${provider.extensionServerHost}:${provider.extensionServerPort}' 
                : 'Server stopped'),
            value: provider.extensionServerEnabled,
            onChanged: (v) => provider.setExtensionServerEnabled(v),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server Host'),
            subtitle: Text(provider.extensionServerHost == '0.0.0.0' 
                ? 'All interfaces (network accessible)' 
                : 'Localhost only'),
            trailing: const Icon(Icons.chevron_right),
            enabled: provider.extensionServerEnabled,
            onTap: provider.extensionServerEnabled 
                ? () => _showHostDialog(context, provider) 
                : null,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.numbers),
            title: const Text('Server Port'),
            subtitle: Text('Current: ${provider.extensionServerPort}'),
            trailing: const Icon(Icons.chevron_right),
            enabled: provider.extensionServerEnabled,
            onTap: provider.extensionServerEnabled 
                ? () => _showPortDialog(context, provider) 
                : null,
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(provider.extensionApiKey != null ? Icons.lock : Icons.lock_open),
            title: const Text('API Key Authentication'),
            subtitle: Text(provider.extensionApiKey != null ? 'Enabled' : 'Disabled (open access)'),
            trailing: const Icon(Icons.chevron_right),
            enabled: provider.extensionServerEnabled,
            onTap: provider.extensionServerEnabled 
                ? () => _showApiKeyDialog(context, provider) 
                : null,
          ),
        ],
      ),
    );
  }

  void _showApiKeyDialog(BuildContext context, BookmarksProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('API Key Authentication'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (provider.extensionApiKey != null) ...[
                const Text('Current API Key:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          provider.extensionApiKey ?? 'No API key set',
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: provider.extensionApiKey!));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('API key copied'), duration: Duration(seconds: 1)),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text('Copy this key to your browser extension settings.', 
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              ] else
                const Text('Enable API key to require authentication for extension sync.'),
            ],
          ),
          actions: [
            if (provider.extensionApiKey != null) ...[
              TextButton(
                onPressed: () {
                  provider.setExtensionApiKey(null);
                  Navigator.pop(ctx);
                },
                child: const Text('Disable'),
              ),
              TextButton(
                onPressed: () {
                  provider.setExtensionApiKey(provider.generateApiKey());
                  setState(() {});
                },
                child: const Text('Regenerate'),
              ),
            ] else
              FilledButton(
                onPressed: () {
                  provider.setExtensionApiKey(provider.generateApiKey());
                  setState(() {});
                },
                child: const Text('Enable & Generate Key'),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        ),
      ),
    );
  }

  void _showHostDialog(BuildContext context, BookmarksProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Server Host'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(provider.extensionServerHost == '127.0.0.1' ? Icons.radio_button_checked : Icons.radio_button_off, color: Theme.of(context).primaryColor),
              title: const Text('Localhost only'),
              subtitle: const Text('127.0.0.1 - Same device only'),
              onTap: () {
                provider.setExtensionServerHost('127.0.0.1');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: Icon(provider.extensionServerHost == '0.0.0.0' ? Icons.radio_button_checked : Icons.radio_button_off, color: Theme.of(context).primaryColor),
              title: const Text('All interfaces'),
              subtitle: const Text('0.0.0.0 - Network accessible'),
              onTap: () {
                provider.setExtensionServerHost('0.0.0.0');
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ],
      ),
    );
  }

  void _showPortDialog(BuildContext context, BookmarksProvider provider) {
    final controller = TextEditingController(text: provider.extensionServerPort.toString());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Server Port'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Port number',
            hintText: '52525',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final port = int.tryParse(controller.text);
              if (port != null && port > 1024 && port < 65536) {
                provider.setExtensionServerPort(port);
                Navigator.pop(ctx);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Invalid port (1025-65535)')),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard(BuildContext context, {
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Icon(icon, size: 20, color: colors.primary),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.titleSmall?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w600,
                )),
              ],
            ),
          ),
          ...children,
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildSettingTile({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      trailing: trailing ?? (onTap != null ? const Icon(Icons.chevron_right) : null),
      onTap: onTap,
    );
  }

  Widget _buildShortcutTile(String shortcut, String description) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(shortcut, style: const TextStyle(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
              fontSize: 13,
            )),
          ),
          const SizedBox(width: 16),
          Text(description),
        ],
      ),
    );
  }

  Future<void> _exportNotes(BuildContext context) async {
    final provider = context.read<NotesProvider>();
    final notes = provider.notes;
    final messenger = ScaffoldMessenger.of(context);
    
    // Notes are always plain text - no decryption needed for export
    List<Note> exportNotes = notes;
    
    final json = jsonEncode(exportNotes.map((n) => n.toJson()).toList());
    final bytes = utf8.encode(json);
    String? path;
    
    if (!context.mounted) return;
    
    // Use file picker with Linux fallback
    if (Platform.isLinux) {
      // Try file picker first, fallback to path input if it fails
      try {
        path = await FilePicker.platform.saveFile(
          dialogTitle: 'Export Notes',
          fileName: 'notes_export.json',
          type: FileType.custom,
          allowedExtensions: ['json'],
        );
      } catch (e) {
        // Fallback to manual path input on Linux
        if (!context.mounted) return;
        final controller = TextEditingController(text: '${Directory.current.path}/notes_export.json');
        path = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Export Notes'),
            content: TextField(controller: controller, decoration: const InputDecoration(labelText: 'Save path', border: OutlineInputBorder()), autofocus: true),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Export')),
            ],
          ),
        );
      }
    } else if (Platform.isAndroid || Platform.isIOS) {
      // Android/iOS require bytes parameter
      path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Notes',
        fileName: 'notes_export.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: Uint8List.fromList(bytes),
      );
      // On Android/iOS, saveFile writes the file directly when bytes provided
      if (path != null) {
        messenger.showSnackBar(SnackBar(content: Text('Exported ${notes.length} notes to $path')));
      }
      return;
    } else {
      path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Notes',
        fileName: 'notes_export.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
    }
    
    if (path == null || path.isEmpty) return;
    try {
      await File(path).writeAsString(json);
      messenger.showSnackBar(SnackBar(content: Text('Exported ${notes.length} notes to $path')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  // Unused export password method removed - notes are always plain text

  Future<void> _importNotes(BuildContext context) async {
    final provider = context.read<NotesProvider>();
    final messenger = ScaffoldMessenger.of(context);
    String? path;
    
    // Use file picker with Linux fallback
    if (Platform.isLinux) {
      // Try file picker first, fallback to path input if it fails
      try {
        final result = await FilePicker.platform.pickFiles(
          dialogTitle: 'Import Notes',
          type: FileType.custom,
          allowedExtensions: ['json'],
        );
        path = result?.files.single.path;
      } catch (e) {
        // Fallback to manual path input on Linux
        if (!context.mounted) return;
        final controller = TextEditingController();
        path = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Import Notes'),
            content: TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: '/path/to/notes.json',
                labelText: 'JSON file path',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Import')),
            ],
          ),
        );
      }
    } else {
      try {
        final result = await FilePicker.platform.pickFiles(
          dialogTitle: 'Import Notes',
          type: FileType.custom,
          allowedExtensions: ['json'],
        );
        path = result?.files.single.path;
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('File picker error: $e')));
        return;
      }
    }
    
    if (path == null || path.isEmpty) return;
    
    try {
      final file = File(path);
      if (!await file.exists()) {
        messenger.showSnackBar(const SnackBar(content: Text('File not found')));
        return;
      }
      
      final json = await file.readAsString();
      final data = jsonDecode(json);
      
      if (data is! List) {
        messenger.showSnackBar(const SnackBar(content: Text('Invalid format: expected a list of notes')));
        return;
      }
      
      // Notes are imported as plain text - no local encryption needed
      int count = 0;
      for (final item in data) {
        if (item is! Map<String, dynamic> || !item.containsKey('id') || !item.containsKey('title')) {
          continue;
        }
        
        await provider.importNote(item);
        count++;
      }
      
      messenger.showSnackBar(SnackBar(content: Text('Imported $count notes')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  // Unused import password method removed - notes are always plain text

  void _openGitHubRepo(NotesProvider provider) async {
    final url = Uri.parse('https://github.com/${provider.repoOwner}/${provider.repoName}');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }
}

class _BranchDialog extends StatefulWidget {
  final NotesProvider provider;
  const _BranchDialog({required this.provider});

  @override
  State<_BranchDialog> createState() => _BranchDialogState();
}

class _BranchDialogState extends State<_BranchDialog> {
  List<String> _branches = [];
  String? _selected;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _selected = widget.provider.repoBranch;
    _load();
  }

  Future<void> _load() async {
    try {
      final auth = widget.provider.authService;
      final owner = widget.provider.repoOwner;
      final repo = widget.provider.repoName;
      if (auth == null || owner == null || repo == null) {
        if (mounted) Navigator.pop(context);
        return;
      }
      final branches = await auth.fetchBranches(owner, repo);
      if (mounted) setState(() { _branches = branches; _loading = false; });
    } catch (e) {
      if (mounted) { Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e'))); }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: const SizedBox(height: 60, child: Center(child: CircularProgressIndicator())),
      );
    }

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Change Branch'),
      content: SingleChildScrollView(
        child: DropdownButtonFormField<String>(
          initialValue: _selected,
          decoration: InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          items: _branches.map((b) => DropdownMenuItem(value: b, child: Text(b))).toList(),
          onChanged: (v) => setState(() => _selected = v),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () { if (_selected != null) widget.provider.updateBranch(_selected!); Navigator.pop(context); },
          child: const Text('Save'),
        ),
      ],
    );
  }
}


// Encryption Section Widget
class _EncryptionSection extends StatefulWidget {
  @override
  State<_EncryptionSection> createState() => _EncryptionSectionState();
}

class _EncryptionSectionState extends State<_EncryptionSection> {
  bool _masterEnabled = false;
  bool _loading = true;
  bool _loadingRemote = false;
  bool _remoteEncrypted = false;
  bool _biometricAvailable = false;
  bool _biometricEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    // Load local state first (fast)
    _masterEnabled = await EncryptionService.isMasterEncryptionEnabled();
    _biometricAvailable = await BiometricService.isAvailable();
    _biometricEnabled = await BiometricService.isEnabled();
    
    if (!mounted) return;
    // Show local state immediately
    setState(() => _loading = false);
    
    final provider = context.read<NotesProvider>();
    _remoteEncrypted = false;
    
    // Then check GitHub in background (slow) - always fetch fresh
    if (provider.isGitHubConfigured) {
      setState(() => _loadingRemote = true);
      // Fetch directly from GitHub, not database cache
      final remoteConfig = await provider.getEncryptionStatusFromGitHub();
      if (!mounted) return;
      
      if (remoteConfig != null && remoteConfig['enabled'] == true) {
        _remoteEncrypted = true;
      }
      if (mounted) setState(() => _loadingRemote = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    
    if (_loading) return const SizedBox.shrink();
    
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: colors.outlineVariant)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lock_outline, color: colors.primary),
                const SizedBox(width: 12),
                Text('Security', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.onSurface)),
                if (_loadingRemote) ...[
                  const SizedBox(width: 8),
                  SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ],
            ),
            const SizedBox(height: 16),
            
            // Remote encryption warning
            if (_remoteEncrypted && !_masterEnabled) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Encryption detected', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          const SizedBox(height: 2),
                          Text('Notes are encrypted from another device', style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.7))),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _unlockExistingEncryption,
                icon: const Icon(Icons.key, size: 18),
                label: const Text('Enter Existing Password'),
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
            ],
            
            // Master Encryption Toggle
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(_masterEnabled ? Icons.lock : Icons.lock_open, color: _masterEnabled ? colors.primary : colors.outline),
              title: const Text('Master Encryption'),
              subtitle: Text(_masterEnabled ? 'All notes encrypted' : 'Notes stored as plain text'),
              trailing: Switch(
                value: _masterEnabled, 
                onChanged: (v) => v ? _enableMasterEncryption() : _disableMasterEncryption(),
              ),
            ),
            // Change Password (only if encryption enabled)
            if (_masterEnabled) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.key, color: colors.primary),
                title: const Text('Change Password'),
                subtitle: const Text('Update master encryption password'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _changePassword,
              ),
              // Biometric unlock option
              if (_biometricAvailable)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.fingerprint, color: _biometricEnabled ? colors.primary : colors.outline),
                  title: const Text('Biometric Unlock'),
                  subtitle: Text(_biometricEnabled ? 'Fingerprint enabled' : 'Use fingerprint to unlock'),
                  trailing: Switch(
                    value: _biometricEnabled,
                    onChanged: (v) => v ? _enableBiometric() : _disableBiometric(),
                  ),
                ),
              if (context.read<NotesProvider>().isGitHubConfigured)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.sync, color: colors.primary),
                  title: const Text('Force Encryption Sync'),
                  subtitle: const Text('Re-upload all notes with encryption'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _forceEncryptionSync,
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _unlockExistingEncryption() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter Existing Password'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Your notes are already encrypted from another device. Enter the same password to unlock.', 
                style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7))),
              const SizedBox(height: 16),
              TextField(controller: controller, obscureText: true, autofocus: true, decoration: const InputDecoration(labelText: 'Master Password', border: OutlineInputBorder())),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final provider = context.read<NotesProvider>();
              final remoteConfig = await provider.getRemoteEncryptionConfig();
              
              if (remoteConfig != null && remoteConfig['enabled'] == true) {
                // Verify password first
                final valid = await EncryptionService.verifyMasterPassword(controller.text);
                if (!valid) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Wrong password')));
                  }
                  return;
                }
                
                // Remote has encryption - enable locally with same password
                await EncryptionService.enableMasterEncryption(controller.text);
                EncryptionService.setSessionPassword(controller.text);
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) {
                  setState(() { _masterEnabled = true; _remoteEncrypted = false; });
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Encryption unlocked! ✓')));
                }
                return;
              }
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Wrong password')));
              }
            },
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
  }

  void _enableMasterEncryption() async {
    final provider = context.read<NotesProvider>();
    final messenger = ScaffoldMessenger.of(context);
    
    // Check if remote already has encryption
    if (provider.isGitHubConfigured) {
      final remoteEnabled = await provider.isRemoteEncryptionEnabled();
      if (remoteEnabled) {
        if (!mounted) return;
        messenger.showSnackBar(
          const SnackBar(content: Text('Repository already encrypted. Enter existing password to unlock.')),
        );
        _promptExistingPassword();
        return;
      }
    }
    
    if (!mounted) return;
    
    final controller = TextEditingController();
    final confirmController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enable Encryption'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('⚠️ Warning: If you forget this password, your notes cannot be recovered!', style: TextStyle(color: Colors.orange)),
              const SizedBox(height: 16),
              TextField(controller: controller, obscureText: true, decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: confirmController, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm Password', border: OutlineInputBorder())),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (controller.text.isEmpty || controller.text.length < 6) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password must be at least 6 characters')));
                return;
              }
              if (controller.text != confirmController.text) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Passwords do not match')));
                return;
              }
              
              // Close dialog first, then enable encryption
              Navigator.pop(ctx);
              if (mounted) {
                await _encryptAllNotes(controller.text);
              }
            },
            child: const Text('Enable'),
          ),
        ],
      ),
    );
  }

  void _promptExistingPassword() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter Existing Password'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Master Password', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final provider = context.read<NotesProvider>();
              // Setup and verify password against remote notes
              final success = await provider.setupEncryptionFromRemote(controller.text);
              if (!ctx.mounted) return;
              if (!success) {
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Wrong password')));
                return;
              }
              Navigator.pop(ctx);
              setState(() => _masterEnabled = true);
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Encryption unlocked')));
            },
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
  }

  Future<void> _enableBiometric() async {
    final password = EncryptionService.sessionPassword;
    if (password == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please unlock with password first')),
      );
      return;
    }
    
    final success = await BiometricService.enable(password);
    if (!mounted) return;
    
    if (success) {
      setState(() => _biometricEnabled = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Biometric unlock enabled')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to enable biometric')),
      );
    }
  }

  Future<void> _disableBiometric() async {
    await BiometricService.disable();
    if (!mounted) return;
    setState(() => _biometricEnabled = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Biometric unlock disabled')),
    );
  }

  void _changePassword() {
    final oldController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change Password'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: oldController, obscureText: true, decoration: const InputDecoration(labelText: 'Current Password', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: newController, obscureText: true, decoration: const InputDecoration(labelText: 'New Password', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: confirmController, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm New Password', border: OutlineInputBorder())),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (newController.text.isEmpty || newController.text.length < 6) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password must be at least 6 characters')));
                return;
              }
              if (newController.text != confirmController.text) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Passwords do not match')));
                return;
              }
              Navigator.pop(ctx);
              final provider = context.read<NotesProvider>();
              final result = await provider.changePassword(oldController.text, newController.text);
              if (!mounted) return;
              
              switch (result) {
                case ChangePasswordResult.success:
                  // Clear biometric when password changes
                  await BiometricService.clearPassword();
                  _biometricEnabled = false;
                  if (!mounted) return;
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password changed successfully ✓')));
                  break;
                case ChangePasswordResult.wrongPassword:
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Wrong current password')));
                  break;
                case ChangePasswordResult.lockedByAnotherDevice:
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Another device is changing password. Try again later.')));
                  break;
                case ChangePasswordResult.error:
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Network error. Check connection.')));
                  break;
              }
            },
            child: const Text('Change'),
          ),
        ],
      ),
    );
  }

  void _forceEncryptionSync() async {
    final provider = context.read<NotesProvider>();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Force syncing encryption and re-uploading notes...'))
    );
    await provider.forceEncryptionSync();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Encryption sync complete ✓'))
      );
    }
  }

  void _disableMasterEncryption() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disable Encryption'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('⚠️ Notes will be stored as plain text on GitHub.'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Enter Password', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (!mounted) return;
              
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Disabling encryption...')));
              final provider = context.read<NotesProvider>();
              final result = await provider.disableEncryptionAndSync(controller.text);
              
              if (!mounted) return;
              switch (result) {
                case ChangePasswordResult.success:
                  setState(() => _masterEnabled = false);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Encryption disabled ✓')));
                  break;
                case ChangePasswordResult.wrongPassword:
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Wrong password')));
                  break;
                case ChangePasswordResult.lockedByAnotherDevice:
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Another device is changing password. Try again later.')));
                  break;
                case ChangePasswordResult.error:
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to disable encryption')));
                  break;
              }
            },
            child: const Text('Disable'),
          ),
        ],
      ),
    );
  }

  Future<void> _encryptAllNotes(String password) async {
    // Enable encryption config only - notes stay plain text locally
    await EncryptionService.enableMasterEncryption(password);
    EncryptionService.setSessionPassword(password);
    
    // Update state IMMEDIATELY
    if (mounted) setState(() => _masterEnabled = true);
    
    if (!mounted) return;
    
    // Ask to clear GitHub history and sync config
    final provider = context.read<NotesProvider>();
    if (provider.isGitHubConfigured && mounted) {
      final clear = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Clear GitHub History?'),
          content: const Text('Old unencrypted notes are still in GitHub history. Delete and re-upload encrypted versions?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Skip')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear & Re-upload')),
          ],
        ),
      );
      if (clear == true) {
        // Clean orphan commit - history truly cleared
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Clearing GitHub history...')));
        if (!mounted) return;
        final bookmarksProvider = Provider.of<BookmarksProvider>(context, listen: false);
        await provider.clearGitHubAndReupload(bookmarks: bookmarksProvider.bookmarks);
        await bookmarksProvider.markAllSynced();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('GitHub history cleared and notes re-uploaded ✓'))
          );
        }
      } else {
        // Delete files and re-upload (history kept)
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Re-uploading with encryption...')));
        await provider.deleteAndReuploadEncrypted();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Notes re-uploaded with encryption ✓'))
          );
        }
      }
    } else {
      // No GitHub configured - just show success
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Master encryption enabled ✓'))
        );
      }
    }
  }
}

void _showClearDatabaseDialog(BuildContext context, NotesProvider provider) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Clear Local Database'),
      content: const Text(
        'This will permanently delete ALL local notes and data. '
        'This action cannot be undone.\n\n'
        'Make sure your notes are synced to GitHub if you want to keep them.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () async {
            Navigator.pop(ctx);
            await _clearLocalDatabase(provider, context);
          },
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          child: const Text('Clear Database'),
        ),
      ],
    ),
  );
}

Future<void> _clearLocalDatabase(NotesProvider provider, BuildContext context) async {
  try {
    // Also clear bookmarks from memory
    final bookmarksProvider = Provider.of<BookmarksProvider>(context, listen: false);
    
    await provider.clearAllLocalData();
    bookmarksProvider.clearAllBookmarks();
    
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Local database cleared successfully')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error clearing database: $e')),
      );
    }
  }
}
