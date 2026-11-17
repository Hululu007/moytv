import 'dart:convert';
import 'dart:io';

/// fm.res 资源网关：把页面要的资源地址包成回环地址，绕开页面跨域
/// 与请求头限制（视频/字幕直链经此中转进播放器）。
///
/// 请求形：`GET /__res?d=<base64url(JSON)>`，JSON 含 url / headers /
/// referer / method。响应转发状态码与关键头，支持 Range（原样转发
/// Range，206 回 Content-Range），补 CORS 头。只放 http/https。
String buildHtmlGatewayUrl({
  required int port,
  required Map<String, dynamic> payload,
}) {
  final encoded = base64Url.encode(utf8.encode(jsonEncode(payload)));
  return 'http://127.0.0.1:$port/__res?d=$encoded';
}

Map<String, dynamic>? decodeHtmlGatewayPayload(String encoded) {
  try {
    var normalized = encoded;
    final pad = normalized.length % 4;
    if (pad != 0) normalized += '=' * (4 - pad);
    final decoded = jsonDecode(utf8.decode(base64Url.decode(normalized)));
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  return null;
}

const _forwardResponseHeaders = {
  'content-type',
  'content-length',
  'content-range',
  'accept-ranges',
  'content-disposition',
  'cache-control',
  'etag',
  'last-modified',
};

const _skipRequestHeaders = {
  'host',
  'connection',
  'content-length',
  'transfer-encoding',
  'upgrade',
};

void _applyCors(HttpResponse response) {
  response.headers.set('access-control-allow-origin', '*');
  response.headers.set('access-control-allow-methods', 'GET, HEAD, OPTIONS');
  response.headers.set('access-control-allow-headers', '*');
  response.headers.set('access-control-expose-headers', '*');
}

Future<void> _fail(HttpRequest request, int status, String message) async {
  final response = request.response;
  _applyCors(response);
  response.statusCode = status;
  response.headers.contentType = ContentType.text;
  response.write(message);
  await response.close();
}

/// 处理一条网关请求；不是网关路径时返回 false（调用方继续分发）。
Future<bool> handleHtmlGatewayRequest(
  HttpRequest request, {
  HttpClient? client,
}) async {
  if (request.uri.path != '/__res') return false;
  final response = request.response;
  if (request.method == 'OPTIONS') {
    _applyCors(response);
    response.statusCode = HttpStatus.noContent;
    await response.close();
    return true;
  }
  if (request.method != 'GET' && request.method != 'HEAD') {
    await _fail(request, HttpStatus.methodNotAllowed, 'method not allowed');
    return true;
  }
  final encoded = request.uri.queryParameters['d'] ?? '';
  final payload = encoded.isEmpty ? null : decodeHtmlGatewayPayload(encoded);
  if (payload == null) {
    await _fail(request, HttpStatus.badRequest, 'bad gateway payload');
    return true;
  }
  final url = (payload['url']?.toString() ?? '').trim();
  if (url.isEmpty || !(url.startsWith('http://') || url.startsWith('https://'))) {
    await _fail(request, HttpStatus.badRequest, 'only http/https urls allowed');
    return true;
  }
  final method = (payload['method']?.toString() ?? 'GET').toUpperCase();
  if (method != 'GET' && method != 'HEAD') {
    await _fail(request, HttpStatus.badRequest, 'only GET/HEAD allowed');
    return true;
  }
  final http = client ?? HttpClient();
  final closeClient = client == null;
  try {
    final upstream = await http.openUrl(method, Uri.parse(url));
    final headers = payload['headers'];
    if (headers is Map) {
      headers.forEach((key, value) {
        final name = key.toString().toLowerCase();
        if (_skipRequestHeaders.contains(name)) return;
        upstream.headers.set(name, value.toString());
      });
    }
    final referer = payload['referer']?.toString() ?? '';
    if (referer.isNotEmpty) upstream.headers.set('referer', referer);
    final range = request.headers.value('range');
    if (range != null && range.isNotEmpty) upstream.headers.set('range', range);
    final upstreamResponse = await upstream.close();
    response.statusCode = upstreamResponse.statusCode;
    upstreamResponse.headers.forEach((name, values) {
      if (_forwardResponseHeaders.contains(name.toLowerCase())) {
        response.headers.set(name, values.join(', '));
      }
    });
    _applyCors(response);
    if (request.method != 'HEAD') {
      await response.addStream(upstreamResponse);
    }
    await response.close();
  } catch (error) {
    try {
      await _fail(request, HttpStatus.badGateway, 'upstream fetch failed: $error');
    } catch (_) {}
  } finally {
    if (closeClient) http.close();
  }
  return true;
}
