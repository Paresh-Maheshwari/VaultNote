// ============================================================================
// GITHUB AUTH SERVICE
// ============================================================================
//
// GitHub OAuth Device Flow authentication.
// Uses OAuth App for multi-device support (tokens don't expire).
//
// Flow:
// 1. Request device code from GitHub
// 2. User visits github.com/login/device and enters code
// 3. Poll for access token until user authorizes
// 4. Store token securely for API calls
//
// Scopes: repo (for notes sync), gist (for sharing)
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// GitHub OAuth authentication service.
class GitHubAuthService {
  static const String _clientId = String.fromEnvironment('GITHUB_CLIENT_ID', defaultValue: 'Ov23liOhehTpNoqOmhGP'); // OAuth App for multi-device
  static const String _tokenKey = 'github_access_token';
  static const String _ownerKey = 'github_owner';
  static const String _repoKey = 'github_repo';
  static const String _branchKey = 'github_branch';
  
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  
  String? _accessToken;
  String? _owner;
  String? _repo;
  String? _branch;

  bool get isConfigured => _accessToken != null && _owner != null && _repo != null && _branch != null;
  String? get owner => _owner;
  String? get repo => _repo;
  String? get branch => _branch;
  String? get accessToken => _accessToken;

  /// Load saved config from secure storage.
  Future<void> loadConfig() async {
    _accessToken = await _storage.read(key: _tokenKey);
    _owner = await _storage.read(key: _ownerKey);
    _repo = await _storage.read(key: _repoKey);
    _branch = await _storage.read(key: _branchKey);
  }

  /// Save selected repository.
  Future<void> saveRepo(String owner, String repo, String branch) async {
    _owner = owner;
    _repo = repo;
    _branch = branch;
    await _storage.write(key: _ownerKey, value: owner);
    await _storage.write(key: _repoKey, value: repo);
    await _storage.write(key: _branchKey, value: branch);
  }

  /// Update branch only.
  Future<void> updateBranch(String branch) async {
    _branch = branch;
    await _storage.write(key: _branchKey, value: branch);
  }

  /// Clear all stored config (disconnect).
  Future<void> clearConfig() async {
    _accessToken = null;
    _owner = null;
    _repo = null;
    await _storage.deleteAll();
  }

  /// Step 1: Request device and user codes from GitHub.
  Future<DeviceCodeResponse?> requestDeviceCode() async {
    final response = await http.post(
      Uri.parse('https://github.com/login/device/code'),
      headers: {'Accept': 'application/json'},
      body: {'client_id': _clientId, 'scope': 'repo gist'},
    );

    if (response.statusCode == 200) {
      return DeviceCodeResponse.fromJson(jsonDecode(response.body));
    }
    return null;
  }

  /// Step 2: Poll for access token after user authorizes.
  /// Returns token on success, null on timeout/error.
  Future<String?> pollForToken(String deviceCode, int interval) async {
    final timeout = DateTime.now().add(const Duration(minutes: 10));
    
    while (DateTime.now().isBefore(timeout)) {
      await Future.delayed(Duration(seconds: interval));
      
      final response = await http.post(
        Uri.parse('https://github.com/login/oauth/access_token'),
        headers: {'Accept': 'application/json'},
        body: {
          'client_id': _clientId,
          'device_code': deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        if (data['access_token'] != null) {
          _accessToken = data['access_token'];
          await _storage.write(key: _tokenKey, value: _accessToken);
          return _accessToken;
        }
        
        if (data['error'] == 'authorization_pending') continue;
        if (data['error'] == 'slow_down') {
          await Future.delayed(const Duration(seconds: 5));
          continue;
        }
        if (data['error'] == 'expired_token' || data['error'] == 'access_denied') {
          return null;
        }
      }
    }
    return null;
  }

  /// Fetch user's repositories.
  Future<List<Map<String, String>>> fetchUserRepos() async {
    if (_accessToken == null) return [];
    
    final response = await http.get(
      Uri.parse('https://api.github.com/user/repos?per_page=100&sort=updated'),
      headers: headers,
    );
    
    if (response.statusCode == 200) {
      final List<dynamic> repos = jsonDecode(response.body);
      return repos.map<Map<String, String>>((r) => {
        'full_name': r['full_name'],
        'name': r['name'],
        'private': r['private'].toString(),
        'default_branch': r['default_branch'],
      }).toList();
    }
    return [];
  }

  /// Fetch branches for a repository.
  Future<List<String>> fetchBranches(String owner, String repo) async {
    if (_accessToken == null) return [];
    
    final response = await http.get(
      Uri.parse('https://api.github.com/repos/$owner/$repo/branches'),
      headers: headers,
    );
    
    if (response.statusCode == 200) {
      final List<dynamic> branches = jsonDecode(response.body);
      return branches.map<String>((b) => b['name'] as String).toList();
    }
    return [];
  }

  /// HTTP headers for GitHub API calls.
  Map<String, String> get headers => {
    'Authorization': 'Bearer $_accessToken',
    'Accept': 'application/vnd.github+json',
    'Content-Type': 'application/json',
  };
}

/// Response from device code request.
class DeviceCodeResponse {
  final String deviceCode;
  final String userCode;       // Code user enters on GitHub
  final String verificationUri; // URL to visit
  final int expiresIn;
  final int interval;          // Polling interval in seconds

  DeviceCodeResponse({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  factory DeviceCodeResponse.fromJson(Map<String, dynamic> json) {
    return DeviceCodeResponse(
      deviceCode: json['device_code'],
      userCode: json['user_code'],
      verificationUri: json['verification_uri'],
      expiresIn: json['expires_in'],
      interval: json['interval'],
    );
  }
}
