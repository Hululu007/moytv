import 'dart:convert';
import 'dart:io';

import 'mini_app_manifest.dart';

/// 图片代理取数回调：source 是内置 py 站 id，param 是 proxy://
/// rest 解出的参数。返回与 py 宿主 proxy 动作同一形状：
/// {status, mime, bodyBase64, headers}。
typedef MiniAppProxyFetch =
    Future<Map<String, dynamic>> Function(String source, Object? param);

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

  /// /pyproxy 路由的取数回调，由宿主页面在服务启动后设置
  /// （服务实例会被复用，每次打开都重设一次，幂等）。
  /// 未设置时 /pyproxy 回 404。
  MiniAppProxyFetch? proxyFetch;

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
      if (path == '/pyproxy') {
        await _handlePyProxyRequest(request);
        return;
      }
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

  /// /pyproxy：给 WebView 里的 <img> 用的图片代理。负载格式与
  /// NativeRepository 的 pyproxy 服务一致：?d=base64url(
  /// json({source, param}))。只接受本机请求（即使开了局域网
  /// 共享也不对外提供代理，与原 pyproxy 服务的回环口径一致），
  /// 取数走注入的回调（蜘蛛 localProxy 的现成路径），响应形态
  /// （status/mime/headers/body）与原服务一致。
  Future<void> _handlePyProxyRequest(HttpRequest request) async {
    final fetch = proxyFetch;
    if (fetch == null) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not Found');
      await request.response.close();
      return;
    }
    final remote = request.connectionInfo?.remoteAddress;
    if (remote != null && !remote.isLoopback) {
      request.response
        ..statusCode = HttpStatus.forbidden
        ..write('Forbidden');
      await request.response.close();
      return;
    }
    late final String source;
    late final Object? param;
    try {
      final payload = request.uri.queryParameters['d'] ?? '';
      if (payload.isEmpty) throw const FormatException('缺少 d 参数');
      final decoded = jsonDecode(utf8.decode(base64Url.decode(payload)));
      if (decoded is! Map) throw const FormatException('负载不是对象');
      final rawSource = decoded['source'];
      if (rawSource is! String || rawSource.isEmpty) {
        throw const FormatException('负载缺少 source');
      }
      source = rawSource;
      param = decoded['param'];
    } on FormatException {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Bad Request');
      await request.response.close();
      return;
    }
    try {
      final result = await fetch(source, param);
      final body = base64Decode(result['bodyBase64'] as String? ?? '');
      final response = request.response;
      response.statusCode = result['status'] as int? ?? 200;
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        result['mime'] as String? ?? 'application/octet-stream',
      );
      for (final entry in (result['headers'] as Map? ?? {}).entries) {
        response.headers.set(entry.key.toString(), entry.value.toString());
      }
      response.contentLength = body.length;
      if (request.method == 'GET') response.add(body);
      await response.close();
    } catch (error) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('py proxy failed: $error');
      await request.response.close();
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
