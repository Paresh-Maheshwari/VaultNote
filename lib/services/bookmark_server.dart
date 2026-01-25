// ============================================================================
// BOOKMARK SERVER
// ============================================================================
//
// Local HTTP server for browser extension communication.
// Provides REST API endpoints for bookmark management.
//
// Security:
// - Optional API key authentication via X-API-Key header
// - CORS enabled for browser extension access
// - Constant-time string comparison to prevent timing attacks
// - Request size limits and timeout handling
//
// Endpoints:
// - GET  /ping      - Health check and authentication status
// - POST /bookmark  - Save bookmark from extension
// - GET  /bookmarks - Get all bookmarks for sync
// - GET  /folders   - Get folder list for organization
//
// Default Port: 52525 (configurable in settings)
//
// ============================================================================

import 'dart:io';
import 'dart:convert';
import 'dart:async';
import '../services/debug_service.dart';

/// Constant-time string comparison to prevent timing attacks
bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  
  int result = 0;
  for (int i = 0; i < a.length; i++) {
    result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return result == 0;
}

/// Local HTTP server for browser extension communication.
/// 
/// Optional API key authentication via X-API-Key header.
/// If apiKey is set, all requests (except OPTIONS) require valid key.
/// 
/// Endpoints:
/// - GET  /ping      - Health check
/// - POST /bookmark  - Save bookmark
/// - GET  /bookmarks - Get all bookmarks
/// - GET  /folders   - Get folder list
class BookmarkServer {
  static const int defaultPort = 52525;
  
  final int port;
  final String host;
  final String? apiKey;
  final Function(Map<String, dynamic> data) onBookmark;
  final List<Map<String, dynamic>> Function() onGetAll;
  final List<String> Function() onGetFolders;
  HttpServer? _server;

  BookmarkServer({
    required this.onBookmark,
    required this.onGetAll,
    required this.onGetFolders,
    this.port = defaultPort,
    this.host = '0.0.0.0',
    this.apiKey,
  });

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(host, port);
      DebugService.log('Bookmarks', 'Server started on $host:$port${apiKey != null ? ' (auth enabled)' : ''}');
      _server!.listen(_handleRequest);
    } catch (e) {
      DebugService.log('Bookmarks', 'Failed to start server: $e', isError: true);
    }
  }

  void _handleRequest(HttpRequest request) async {
    request.response.headers
      ..add('Access-Control-Allow-Origin', '*')
      ..add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..add('Access-Control-Allow-Headers', 'Content-Type, X-API-Key')
      ..add('Content-Type', 'application/json');

    try {
      if (request.method == 'OPTIONS') {
        _send(request, 200, {'status': 'ok'});
        return;
      }

      // Check API key if enabled
      if (apiKey != null && apiKey!.isNotEmpty) {
        final requestKey = request.headers.value('X-API-Key');
        if (requestKey == null || !_constantTimeEquals(requestKey, apiKey!)) {
          _send(request, 401, {'error': 'Invalid API key'});
          return;
        }
      }

      switch ('${request.method} ${request.uri.path}') {
        case 'GET /ping':
          _send(request, 200, {'status': 'ok', 'app': 'VaultNote', 'auth': apiKey != null});
        case 'POST /bookmark':
          await _handleBookmark(request);
        case 'GET /bookmarks':
          _send(request, 200, onGetAll());
        case 'GET /folders':
          _send(request, 200, onGetFolders());
        default:
          _send(request, 404, {'error': 'Not found'});
      }
    } catch (e) {
      DebugService.log('Bookmarks', 'Request error: $e', isError: true);
      _send(request, 500, {'error': 'Internal server error'});
    }
  }

  Future<void> _handleBookmark(HttpRequest request) async {
    try {
      if (request.contentLength > 1024 * 1024) {
        _send(request, 413, {'error': 'Request too large'});
        return;
      }
      
      // Add timeout for reading request body
      final body = await utf8.decoder.bind(request).join()
          .timeout(const Duration(seconds: 5));
      
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['url'] == null || (data['url'] as String).isEmpty) {
        _send(request, 400, {'error': 'URL is required'});
        return;
      }
      
      // Validate URL format
      final url = data['url'] as String;
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) {
        _send(request, 400, {'error': 'Invalid URL format'});
        return;
      }
      
      onBookmark(data);
      _send(request, 200, {'success': true});
    } on FormatException {
      _send(request, 400, {'error': 'Invalid JSON'});
    } on TimeoutException {
      _send(request, 408, {'error': 'Request timeout'});
    } catch (e) {
      _send(request, 500, {'error': 'Server error'});
    }
  }

  void _send(HttpRequest request, int status, dynamic data) {
    request.response.statusCode = status;
    request.response.headers.set('Content-Type', 'application/json; charset=utf-8');
    request.response.add(utf8.encode(jsonEncode(data)));
    request.response.close();
  }

  void stop() {
    _server?.close();
    _server = null;
    DebugService.log('Bookmarks', 'Server stopped');
  }
}
