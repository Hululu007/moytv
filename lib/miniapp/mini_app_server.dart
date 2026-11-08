import 'dart:io';

import 'mini_app_manifest.dart';

const Map<String, String> kMiniAppMimeTypes = {
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.mp4': 'video/mp4',
  '.m3u8': 'application/vnd.apple.mpegurl',
  '.wasm': 'application/wasm',
  '.txt': 'text/plain; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
};

class MiniAppServer {
  MiniAppServer._(this._server, this.root, this.entry, this.sdkScript);

  final HttpServer _server;
  final Directory root;
  final String entry;
  final String sdkScript;

  int get port => _server.port;

  String get baseUrl => 'http://127.0.0.1:$port';

  String entryUrl() => '$baseUrl/$entry';

  static Future<MiniAppServer> start({
    required Directory root,
    required String entry,
    required String sdkScript,
    required int basePort,
    required Set<int> usedPorts,
    required bool lanShare,
  }) async {
    HttpServer? server;
    var port = basePort <= 0 ? 0 : basePort;
    Object? lastError;
    for (var attempt = 0; attempt < 64; attempt++) {
      final candidate = port == 0 ? 0 : basePort + attempt;
      if (candidate != 0 && usedPorts.contains(candidate)) continue;
      try {
        server = await HttpServer.bind(
          lanShare ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
          candidate,
        );
        break;
      } catch (error) {
        lastError = error;
        if (port == 0) break;
      }
    }
    final bound = server;
    if (bound == null) {
      throw StateError('本地服务启动失败：$lastError');
    }
    final instance = MiniAppServer._(bound, root, entry, sdkScript);
    bound.listen(instance._handleRequest);
    return instance;
  }

  Future<void> close() async {
    await _server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        request.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..write('Method Not Allowed');
        await request.response.close();
        return;
      }
      var path = request.uri.path;
      if (path.startsWith('/')) path = path.substring(1);
      if (path.isEmpty) path = entry;
      final filePath = safeJoinPath(root.path, Uri.decodeComponent(path));
      File? file;
      if (filePath != null) {
        final candidate = File(filePath);
        if (await candidate.exists()) {
          file = candidate;
        } else {
          final dir = Directory(filePath);
          if (await dir.exists()) {
            final index = File('$filePath/$entry');
            if (await index.exists()) file = index;
          }
        }
      }
      if (file == null) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('Not Found');
        await request.response.close();
        return;
      }
      final extension = _extensionOf(file.path);
      final mime =
          kMiniAppMimeTypes[extension] ?? 'application/octet-stream';
      final response = request.response;
      response.headers.set(HttpHeaders.contentTypeHeader, mime);
      if (request.method == 'HEAD') {
        response.contentLength = await file.length();
        await response.close();
        return;
      }
      if (extension == '.html' || extension == '.htm') {
        final html = await file.readAsString();
        response.write(_injectSdk(html));
      } else {
        await response.addStream(file.openRead());
      }
      await response.close();
    } catch (_) {
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('Internal Server Error');
        await request.response.close();
      } catch (_) {}
    }
  }

  String _injectSdk(String html) {
    final tag = '<script>$sdkScript</script>';
    final headIndex = html.indexOf('<head>');
    if (headIndex >= 0) {
      final insertAt = headIndex + '<head>'.length;
      return html.substring(0, insertAt) + tag + html.substring(insertAt);
    }
    final headOpen = RegExp(r'<head[^>]*>').firstMatch(html);
    if (headOpen != null) {
      return html.substring(0, headOpen.end) +
          tag +
          html.substring(headOpen.end);
    }
    return tag + html;
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return '';
    return path.substring(dot).toLowerCase();
  }
}
