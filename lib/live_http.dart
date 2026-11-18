import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'core_bridge.dart';
import 'live_models.dart';
import 'nexhub_scraper/network/network_config_service.dart';

const liveRequestTimeout = Duration(seconds: 14);

const _maxLiveBytes = 8 << 20;
const _deviceInfo = '{"t":"webPc","v":"1.0","ui":"0","ck":{"sessKeyAsp":""}}';

String get liveDeviceInfo => _deviceInfo;

/// 按主机隔离的 Cookie 罐：只把某台主机发的 Cookie 再发回同一台主机。
///
/// 原先 LiveHttp 用一张不分主机的表，所有 Cookie 发给所有主机——A 站的
/// 会话 Cookie 会被带到 B 站的请求上（错发凭证），且永不过期。罐内按
/// 主机分桶，Set-Cookie 带 Domain 且与请求主机不匹配时不收，Max-Age<=0
/// 或 Expires 已过时删除对应 Cookie。
class LiveCookieJar {
  final Map<String, Map<String, String>> _byHost = {};

  /// 记录 [host] 发回的 Set-Cookie 头。[now] 只供测试注入假时钟。
  void record(String host, List<String>? values, {DateTime? now}) {
    if (values == null || values.isEmpty || host.isEmpty) return;
    final current = now ?? DateTime.now();
    final jar = _byHost.putIfAbsent(host, () => {});
    for (final value in values) {
      final parts = value.split(';');
      if (parts.isEmpty) continue;
      final at = parts.first.indexOf('=');
      if (at <= 0) continue;
      final name = parts.first.substring(0, at).trim();
      if (name.isEmpty) continue;
      final cookieValue = parts.first.substring(at + 1).trim();
      var expired = false;
      var domainMismatch = false;
      for (final attr in parts.skip(1)) {
        final eq = attr.indexOf('=');
        final attrName = (eq < 0 ? attr : attr.substring(0, eq))
            .trim()
            .toLowerCase();
        final attrValue = eq < 0 ? '' : attr.substring(eq + 1).trim();
        if (attrName == 'max-age') {
          final seconds = int.tryParse(attrValue);
          if (seconds != null && seconds <= 0) expired = true;
        } else if (attrName == 'expires') {
          try {
            if (!HttpDate.parse(attrValue).isAfter(current)) expired = true;
          } catch (_) {}
        } else if (attrName == 'domain') {
          final domain = attrValue.toLowerCase().replaceFirst(
            RegExp(r'^\.'),
            '',
          );
          final hostLower = host.toLowerCase();
          if (domain.isNotEmpty &&
              hostLower != domain &&
              !hostLower.endsWith('.$domain')) {
            domainMismatch = true;
          }
        }
      }
      if (domainMismatch) continue;
      if (expired) {
        jar.remove(name);
      } else {
        jar[name] = cookieValue;
      }
    }
    if (jar.isEmpty) _byHost.remove(host);
  }

  /// 取发给 [host] 的 Cookie 头；该主机无 Cookie 时返回 null。
  String? headerFor(String host) {
    final jar = _byHost[host];
    if (jar == null || jar.isEmpty) return null;
    return jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  void clear() => _byHost.clear();
}

/// 直播取数客户端：直连。应用内代理机件已删（2026-11-17），不再按资源键
/// 选代理客户端；所有请求走同一个默认直连客户端。
class LiveHttp {
  LiveHttp();

  /// 共享客户端：与 ContentHttp 同款跟随机制——DNS 设置改后档案签名
  /// 变化，下次请求重建客户端，新解析立即生效，不用重启应用。
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

  final LiveCookieJar _cookies = LiveCookieJar();

  void close() {
    _client?.close(force: true);
    _client = null;
    _clientSignature = null;
  }

  Future<String> get(
    String url, {
    Map<String, String> headers = const {},
    Duration? timeout,
  }) async => _send(
    _currentClient,
    url,
    method: 'GET',
    headers: headers,
    timeout: timeout ?? liveRequestTimeout,
  );

  Future<String> postForm(
    String url,
    String body, {
    Map<String, String> headers = const {},
    Duration? timeout,
  }) async => _send(
    _currentClient,
    url,
    method: 'POST',
    body: body,
    headers: headers,
    timeout: timeout ?? liveRequestTimeout,
  );

  Future<String> postJson(
    String url,
    Object body, {
    Map<String, String> headers = const {},
    Duration? timeout,
  }) async => _send(
    _currentClient,
    url,
    method: 'POST',
    body: jsonEncode(body),
    contentType: 'application/json',
    headers: headers,
    timeout: timeout ?? liveRequestTimeout,
  );

  Future<String> _send(
    HttpClient client,
    String url, {
    required String method,
    String body = '',
    String contentType = '',
    Map<String, String> headers = const {},
    Duration timeout = liveRequestTimeout,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('直播源地址无效');
    }
    // 单一截止期：原先建连 / 等响应头 / 读正文各挂一个同样的 timeout，
    // 一次请求最长能拖到 3 倍超时（42 秒）才报超时。现全程共用一个
    // deadline，每段只剩 deadline 减已耗时间。
    final deadline = DateTime.now().add(timeout);
    Duration remaining() {
      final left = deadline.difference(DateTime.now());
      return left.isNegative ? Duration.zero : left;
    }

    try {
      final request = method == 'POST'
          ? await client.postUrl(uri).timeout(remaining())
          : await client.getUrl(uri).timeout(remaining());
      request.followRedirects = true;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        headers['User-Agent'] ?? liveUserAgent,
      );
      final cookieHeader = _cookies.headerFor(uri.host);
      if (cookieHeader != null) {
        request.headers.set(HttpHeaders.cookieHeader, cookieHeader);
      }
      headers.forEach((key, value) {
        final name = key.toLowerCase();
        if (name == 'user-agent' || name == 'cookie' || value.isEmpty) return;
        request.headers.set(key, value);
      });
      if (method == 'POST') {
        request.headers.contentType = ContentType.parse(
          contentType.isEmpty
              ? 'application/x-www-form-urlencoded; charset=UTF-8'
              : contentType,
        );
        request.write(body);
      }
      final response = await request.close().timeout(remaining());
      _rememberCookies(uri.host, response);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw AppFailure('直播源返回 ${response.statusCode}');
      }
      return _decode(await _collect(response).timeout(remaining()));
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      throw AppFailure('直播源连接超时');
    } on HandshakeException {
      throw AppFailure('直播源证书校验失败');
    } on SocketException {
      throw AppFailure('无法连接直播源');
    } on FormatException {
      throw AppFailure('直播源返回的内容无法识别');
    }
  }

  void _rememberCookies(String host, HttpClientResponse response) {
    _cookies.record(host, response.headers[HttpHeaders.setCookieHeader]);
  }

  static Future<Uint8List> _collect(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (builder.length > _maxLiveBytes) {
        throw AppFailure('直播源返回的数据过大');
      }
    }
    return builder.takeBytes();
  }

  static String _decode(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
}
