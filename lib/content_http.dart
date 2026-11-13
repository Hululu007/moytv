import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'core_bridge.dart';
import 'legado_gbk.dart';
import 'proxy_kernel_service.dart';

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
  ContentHttp() {
    _client.findProxy = ProxyKernelTraffic.findProxy;
  }

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  void close() => _client.close(force: true);

  Future<String> get(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = contentTimeout,
  }) => _send(url, method: 'GET', headers: headers, timeout: timeout);

  /// GET 并返回原始响应（状态码/响应头/字节），非 200 不抛错。
  /// 与 [get] 同一条代理/超时/大小上限链路，仅错误语义不同。
  Future<ContentResponse> getRaw(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = contentTimeout,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('内容源地址无效');
    }
    try {
      final request = await _client.getUrl(uri).timeout(timeout);
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
    } on SocketException {
      throw AppFailure('无法连接内容源');
    }
  }

  Future<String> postForm(
    String url,
    Map<String, String> form, {
    Map<String, String> headers = const {},
    Duration timeout = contentTimeout,
  }) => _send(
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
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('内容源地址无效');
    }
    try {
      final request = await _client.postUrl(uri).timeout(timeout);
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
    } on SocketException {
      throw AppFailure('无法连接内容源');
    }
  }

  Future<Uint8List> getBytes(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('内容源地址无效');
    }
    try {
      final request = await _client.getUrl(uri).timeout(timeout);
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
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('内容源地址无效');
    }
    try {
      final request = method == 'POST'
          ? await _client.postUrl(uri).timeout(timeout)
          : await _client.getUrl(uri).timeout(timeout);
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
    } on SocketException {
      throw AppFailure('无法连接内容源');
    }
  }

  Future<String> _send(
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
          ? await _client.postUrl(uri).timeout(timeout)
          : await _client.getUrl(uri).timeout(timeout);
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
