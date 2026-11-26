import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'core_bridge.dart';
import 'legado_gbk.dart';
import 'nexhub_scraper/network/network_config_service.dart';

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

/// 内容取数客户端：直连。应用内代理机件已删（2026-11-17），不再按资源键
/// 选代理客户端；所有请求走同一个默认直连客户端。
class ContentHttp {
  ContentHttp();

  /// 共享客户端：建时按当时全局网络档案定型（DNS 配置快照在
  /// connectionFactory 闭包里）。DNS 设置改后，档案签名变化，
  /// 下次请求重建客户端，新解析立即生效，不用重启应用。
  HttpClient? _client;
  String? _clientSignature;

  HttpClient get _currentClient {
    final signature = NetworkConfigService.instance.globalProfile.signature;
    final existing = _client;
    if (existing != null && _clientSignature == signature) return existing;
    existing?.close(force: true);
    final created = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _client = created;
    _clientSignature = signature;
    return created;
  }

  void close() {
    _client?.close(force: true);
    _client = null;
    _clientSignature = null;
  }

  /// 把调用方请求头写到请求上。默认行为（既有调用方不变）：UA 没传
  /// 时补 [contentUserAgent]，空值头跳过不发。
  /// [preserveEmptyHeaders] 为 true 时空值头也照原样发——只给云盘直链
  /// 这条链用：115 直链契约要求取流 UA 与取链时一样是空串，空值头被
  /// 吞掉换成默认 UA 会被 CDN 拒（403）。别在其它内容源上打开。
  void _applyHeaders(
    HttpClientRequest request,
    Map<String, String> headers, {
    bool preserveEmptyHeaders = false,
  }) {
    request.headers.set(
      HttpHeaders.userAgentHeader,
      headers['User-Agent'] ?? contentUserAgent,
    );
    headers.forEach((key, value) {
      if (key.toLowerCase() == 'user-agent') return;
      if (value.isEmpty && !preserveEmptyHeaders) return;
      request.headers.set(key, value);
    });
  }

  Future<String> get(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = contentTimeout,
    bool preserveEmptyHeaders = false,
  }) async => _send(
    _currentClient,
    url,
    method: 'GET',
    headers: headers,
    timeout: timeout,
    preserveEmptyHeaders: preserveEmptyHeaders,
  );

  /// GET 并返回原始响应（状态码/响应头/字节），非 200 不抛错。
  /// 与 [get] 同一条超时/大小上限链路，仅错误语义不同。
  Future<ContentResponse> getRaw(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = contentTimeout,
    bool preserveEmptyHeaders = false,
  }) async {
    final client = _currentClient;
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('内容源地址无效');
    }
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.followRedirects = true;
      _applyHeaders(
        request,
        headers,
        preserveEmptyHeaders: preserveEmptyHeaders,
      );
      final response = await request.close().timeout(timeout);
      final builder = BytesBuilder(copy: false);
      // 正文空闲超时：数据流动中每次来块重置计时，超过 timeout 无新数据才抛超时。
      await for (final chunk in response.timeout(timeout)) {
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
    bool preserveEmptyHeaders = false,
  }) async => _send(
    _currentClient,
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
    preserveEmptyHeaders: preserveEmptyHeaders,
  );

  Future<String> postJson(
    String url,
    Map<String, dynamic> json, {
    Map<String, String> headers = const {},
    Duration timeout = contentTimeout,
    bool preserveEmptyHeaders = false,
  }) async {
    final client = _currentClient;
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('内容源地址无效');
    }
    try {
      final request = await client.postUrl(uri).timeout(timeout);
      request.followRedirects = true;
      _applyHeaders(
        request,
        headers,
        preserveEmptyHeaders: preserveEmptyHeaders,
      );
      request.headers.contentType = ContentType.parse(
        'application/json; charset=UTF-8',
      );
      request.write(jsonEncode(json));
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().timeout(timeout);
        throw AppFailure('内容源返回 ${response.statusCode}');
      }
      final builder = BytesBuilder(copy: false);
      // 正文空闲超时：数据流动中每次来块重置计时，超过 timeout 无新数据才抛超时。
      await for (final chunk in response.timeout(timeout)) {
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
    bool preserveEmptyHeaders = false,
  }) async {
    final client = _currentClient;
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('内容源地址无效');
    }
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.followRedirects = true;
      if (preserveEmptyHeaders) {
        _applyHeaders(request, headers, preserveEmptyHeaders: true);
      } else {
        request.headers.set(HttpHeaders.userAgentHeader, contentUserAgent);
        headers.forEach((key, value) {
          if (value.isNotEmpty) request.headers.set(key, value);
        });
      }
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().timeout(timeout);
        throw AppFailure('内容源返回 ${response.statusCode}');
      }
      final builder = BytesBuilder(copy: false);
      // 正文空闲超时：数据流动中每次来块重置计时，超过 timeout 无新数据才抛超时。
      await for (final chunk in response.timeout(timeout)) {
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
    bool preserveEmptyHeaders = false,
  }) async {
    final client = _currentClient;
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('内容源地址无效');
    }
    try {
      final request = method == 'POST'
          ? await client.postUrl(uri).timeout(timeout)
          : await client.getUrl(uri).timeout(timeout);
      request.followRedirects = true;
      _applyHeaders(
        request,
        headers,
        preserveEmptyHeaders: preserveEmptyHeaders,
      );
      if (method == 'POST') {
        request.headers.contentType = ContentType.parse(
          contentType ?? 'application/x-www-form-urlencoded; charset=UTF-8',
        );
        request.write(body);
      }
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().timeout(timeout);
        throw AppFailure('内容源返回 ${response.statusCode}');
      }
      final builder = BytesBuilder(copy: false);
      // 正文空闲超时：数据流动中每次来块重置计时，超过 timeout 无新数据才抛超时。
      await for (final chunk in response.timeout(timeout)) {
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
    HttpClient client,
    String url, {
    required String method,
    String body = '',
    Map<String, String> headers = const {},
    required Duration timeout,
    bool preserveEmptyHeaders = false,
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
      _applyHeaders(
        request,
        headers,
        preserveEmptyHeaders: preserveEmptyHeaders,
      );
      if (method == 'POST') {
        request.headers.contentType = ContentType.parse(
          'application/x-www-form-urlencoded; charset=UTF-8',
        );
        request.write(body);
      }
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().timeout(timeout);
        throw AppFailure('内容源返回 ${response.statusCode}');
      }
      final builder = BytesBuilder(copy: false);
      // 正文空闲超时：数据流动中每次来块重置计时，超过 timeout 无新数据才抛超时。
      await for (final chunk in response.timeout(timeout)) {
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
