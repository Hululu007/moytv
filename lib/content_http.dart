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
