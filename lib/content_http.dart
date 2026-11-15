import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'core_bridge.dart';
import 'legado_gbk.dart';
import 'proxy_kernel_service.dart';
import 'socks5_proxy.dart';

const contentUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0 Safari/537.36';
const contentTimeout = Duration(seconds: 20);
const _maxContentBytes = 64 << 20;

/// 原始响应：状态码 + 响应头 + 原始字节。不按状态码抛错，供需要自行判断
/// 状态码/验证页的调用方（移植爬取层、网址探站）使用；传输层失败仍抛 [AppFailure]。
class ContentResponse {
  const ContentResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List bodyBytes;
}

/// 按响应头/页面 meta 声明的字符集解码字节：显式 charset 优先，其次严格 UTF-8，
/// 失败回落 GBK（中文站常见）。供移植爬取层与网址探站共用。
String decodeContentBytes(List<int> bytes, {String? contentType}) {
  String? charset;
  final typeMatch = RegExp(
    "charset\\s*=\\s*[\"']?([A-Za-z0-9._-]+)",
    caseSensitive: false,
  ).firstMatch(contentType ?? '');
  charset = typeMatch?.group(1);
  if (charset == null || charset.isEmpty) {
    final head = latin1.decode(bytes.take(8192).toList());
    final metaMatch =
        RegExp(
              r'''<meta[^>]+charset\s*=\s*["']?\s*([A-Za-z0-9._-]+)''',
              caseSensitive: false,
            ).firstMatch(head) ??
            RegExp(
              r'''<meta[^>]+content\s*=\s*["'][^"']*charset\s*=\s*([A-Za-z0-9._-]+)''',
              caseSensitive: false,
            ).firstMatch(head);
    charset = metaMatch?.group(1);
  }
  if (charset != null && charset.isNotEmpty) {
    return decodeLegadoBytes(bytes, charset);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return decodeLegadoBytes(bytes, 'gbk');
  }
}

class ContentHttp {
  ContentHttp({
    this._proxyResourceKey,
    Socks5ProxyRouter? proxyRouter,
    Socks5ForwarderPool? forwarderPool,
  }) : _proxyRouter = proxyRouter ?? Socks5ProxyRouter.instance,
       _forwarderPool = forwarderPool ?? Socks5ForwarderPool.instance {
    _client.findProxy = ProxyKernelTraffic.findProxy;
  }

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  /// 构造时绑定的默认资源键（单资源调用方用）；每次请求也可用
  /// [proxyResourceKey] 具名参数覆盖。无分配时走默认客户端（代理内核
  /// 全局链路），行为与以前一致。
  final String? _proxyResourceKey;
  final Socks5ProxyRouter _proxyRouter;
  final Socks5ForwarderPool _forwarderPool;
  final Map<String, HttpClient> _routedClients = {};
  int _routedGeneration = -1;

  void _syncRoutedClients() {
    if (_proxyRouter.generation == _routedGeneration) return;
    for (final client in _routedClients.values) {
      client.close(force: true);
    }
    _routedClients.clear();
    _routedGeneration = _proxyRouter.generation;
  }

  /// 按资源键选客户端：fallback 用默认客户端（内核链路），direct 用
  /// 专用直连客户端，via 用该 SOCKS5 代理的转发器端口客户端。
  /// 路由快照 generation 变化时丢弃已缓存的按代理客户端，避免复用
  /// 改过/删掉的代理配置；等转发器起好的间隙里快照变了就按新快照
  /// 重算，最多重试 3 次，仍不一致时回默认客户端，绝不卡死。
  Future<HttpClient> _clientFor(String? callKey) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      _syncRoutedClients();
      final route = _proxyRouter.resolve(callKey ?? _proxyResourceKey);
      switch (route.kind) {
        case Socks5RouteKind.fallback:
          return _client;
        case Socks5RouteKind.direct:
          return _routedClients.putIfAbsent(
            route.clientKey,
            () => HttpClient()
              ..connectionTimeout = const Duration(seconds: 10)
              ..findProxy = (_) => 'DIRECT',
          );
        case Socks5RouteKind.via:
          final cached = _routedClients[route.clientKey];
          if (cached != null) return cached;
          final port = await _forwarderPool.ensurePort(route.entry!);
          if (_proxyRouter.generation != _routedGeneration) continue;
          final built = buildForwardedHttpClient(
            port,
            connectionTimeout: const Duration(seconds: 10),
          );
          final existing = _routedClients[route.clientKey];
          if (existing != null) {
            built.close(force: true);
            return existing;
          }
          _routedClients[route.clientKey] = built;
          return built;
      }
    }
    return _client;
  }

  void close() {
    _client.close(force: true);
    for (final client in _routedClients.values) {
      client.close(force: true);
    }
    _routedClients.clear();
  }

  Future<String> get(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = contentTimeout,
    String? proxyResourceKey,
  }) async => _send(
    await _clientFor(proxyResourceKey),
    url,
    method: 'GET',
    headers: headers,
    timeout: timeout,
  );

  /// GET 并返回原始响应（状态码/响应头/字节），非 200 不抛错。
  /// 与 [get] 同一条代理/超时/大小上限链路，仅错误语义不同。
  Future<ContentResponse> getRaw(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = contentTimeout,
    String? proxyResourceKey,
  }) async {
    final client = await _clientFor(proxyResourceKey);
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('内容源地址无效');
    }
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.followRedirects = true;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        headers['User-Agent'] ?? contentUserAgent,
      );
      headers.forEach((key, value) {
        if (key.toLowerCase() == 'user-agent' || value.isEmpty) return;
        request.headers.set(key, value);
      });
      final response = await request.close().timeout(timeout);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
        if (builder.length > _maxContentBytes) {
          throw AppFailure('内容源返回的数据过大');
        }
      }
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        if (values.isNotEmpty) responseHeaders[name] = values.join(', ');
      });
      return ContentResponse(
        statusCode: response.statusCode,
        headers: responseHeaders,
        bodyBytes: builder.takeBytes(),
      );
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      throw AppFailure('内容源连接超时');
    } on HandshakeException {
      throw AppFailure('内容源证书校验失败');
    } on Socks5Failure catch (error) {
      throw AppFailure(error.message);
    } on SocketException {
      throw AppFailure('无法连接内容源');
    }
  }

  Future<String> postForm(
    String url,
    Map<String, String> form, {
    Map<String, String> headers = const {},
    Duration timeout = contentTimeout,
    String? proxyResourceKey,
  }) async => _send(
    await _clientFor(proxyResourceKey),
    url,
    method: 'POST',
    body: form.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&'),
    headers: headers,
    timeout: timeout,
  );

  Future<String> postJson(
    String url,
    Map<String, dynamic> json, {
    Map<String, String> headers = const {},
    Duration timeout = contentTimeout,
    String? proxyResourceKey,
  }) async {
    final client = await _clientFor(proxyResourceKey);
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('内容源地址无效');
    }
    try {
      final request = await client.postUrl(uri).timeout(timeout);
      request.followRedirects = true;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        headers['User-Agent'] ?? contentUserAgent,
      );
      headers.forEach((key, value) {
        if (key.toLowerCase() == 'user-agent' || value.isEmpty) return;
        request.headers.set(key, value);
      });
      request.headers.contentType = ContentType.parse(
        'application/json; charset=UTF-8',
      );
      request.write(jsonEncode(json));
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw AppFailure('内容源返回 ${response.statusCode}');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
        if (builder.length > _maxContentBytes) {
          throw AppFailure('内容源返回的数据过大');
        }
      }
      final bytes = builder.takeBytes();
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return utf8.decode(bytes, allowMalformed: true);
      }
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      throw AppFailure('内容源连接超时');
    } on Socks5Failure catch (error) {
      throw AppFailure(error.message);
    } on SocketException {
      throw AppFailure('无法连接内容源');
    }
  }

  Future<Uint8List> getBytes(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 90),
    String? proxyResourceKey,
  }) async {
    final client = await _clientFor(proxyResourceKey);
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('内容源地址无效');
    }
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.followRedirects = true;
      request.headers.set(HttpHeaders.userAgentHeader, contentUserAgent);
      headers.forEach((key, value) {
        if (value.isNotEmpty) request.headers.set(key, value);
      });
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw AppFailure('内容源返回 ${response.statusCode}');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
        if (builder.length > _maxContentBytes) {
          throw AppFailure('内容源返回的数据过大');
        }
      }
      return builder.takeBytes();
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      throw AppFailure('内容源连接超时');
    } on Socks5Failure catch (error) {
      throw AppFailure(error.message);
    } on SocketException {
      throw AppFailure('无法连接内容源');
    }
  }

  Future<String> fetchDecoded(
    String url, {
    String method = 'GET',
    String body = '',
    String? contentType,
    Map<String, String> headers = const {},
    String charset = 'utf-8',
    Duration timeout = contentTimeout,
    String? proxyResourceKey,
  }) async {
    final client = await _clientFor(proxyResourceKey);
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('内容源地址无效');
    }
    try {
      final request = method == 'POST'
          ? await client.postUrl(uri).timeout(timeout)
          : await client.getUrl(uri).timeout(timeout);
      request.followRedirects = true;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        headers['User-Agent'] ?? contentUserAgent,
      );
      headers.forEach((key, value) {
        if (key.toLowerCase() == 'user-agent' || value.isEmpty) return;
        request.headers.set(key, value);
      });
      if (method == 'POST') {
        request.headers.contentType = ContentType.parse(
          contentType ?? 'application/x-www-form-urlencoded; charset=UTF-8',
        );
        request.write(body);
      }
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw AppFailure('内容源返回 ${response.statusCode}');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
        if (builder.length > _maxContentBytes) {
          throw AppFailure('内容源返回的数据过大');
        }
      }
      return decodeLegadoBytes(builder.takeBytes(), charset);
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      throw AppFailure('内容源连接超时');
    } on HandshakeException {
      throw AppFailure('内容源证书校验失败');
    } on Socks5Failure catch (error) {
      throw AppFailure(error.message);
    } on SocketException {
      throw AppFailure('无法连接内容源');
    }
  }

  Future<String> _send(
    HttpClient client,
    String url, {
    required String method,
    String body = '',
    Map<String, String> headers = const {},
    required Duration timeout,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('内容源地址无效');
    }
    try {
      final request = method == 'POST'
          ? await client.postUrl(uri).timeout(timeout)
          : await client.getUrl(uri).timeout(timeout);
      request.followRedirects = true;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        headers['User-Agent'] ?? contentUserAgent,
      );
      headers.forEach((key, value) {
        if (key.toLowerCase() == 'user-agent' || value.isEmpty) return;
        request.headers.set(key, value);
      });
      if (method == 'POST') {
        request.headers.contentType = ContentType.parse(
          'application/x-www-form-urlencoded; charset=UTF-8',
        );
        request.write(body);
      }
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw AppFailure('内容源返回 ${response.statusCode}');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
        if (builder.length > _maxContentBytes) {
          throw AppFailure('内容源返回的数据过大');
        }
      }
      final bytes = builder.takeBytes();
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return utf8.decode(bytes, allowMalformed: true);
      }
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      throw AppFailure('内容源连接超时');
    } on HandshakeException {
      throw AppFailure('内容源证书校验失败');
    } on Socks5Failure catch (error) {
      throw AppFailure(error.message);
    } on SocketException {
      throw AppFailure('无法连接内容源');
    }
  }
}

Map<String, dynamic> contentJsonObject(String text) {
  final value = jsonDecode(text);
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw AppFailure('内容源返回的数据无法识别');
}
