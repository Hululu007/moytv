import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'core_bridge.dart';
import 'live_models.dart';
import 'proxy_kernel_service.dart';
import 'socks5_proxy.dart';

const liveRequestTimeout = Duration(seconds: 14);

/// 线路预检超时。比正常请求短得多：预检只为排序，慢线路按「不可用」处理，
/// 不能让用户停在列表页等一条 14 秒的超时。
const liveRouteProbeTimeout = Duration(seconds: 4);
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
        final attrName = (eq < 0 ? attr : attr.substring(0, eq)).trim().toLowerCase();
        final attrValue = eq < 0 ? '' : attr.substring(eq + 1).trim();
        if (attrName == 'max-age') {
          final seconds = int.tryParse(attrValue);
          if (seconds != null && seconds <= 0) expired = true;
        } else if (attrName == 'expires') {
          try {
            if (!HttpDate.parse(attrValue).isAfter(current)) expired = true;
          } catch (_) {}
        } else if (attrName == 'domain') {
          final domain = attrValue.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
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

class LiveHttp {
  LiveHttp({
    this._proxyResourceKey,
    Socks5ProxyRouter? proxyRouter,
    Socks5ForwarderPool? forwarderPool,
  }) : _proxyRouter = proxyRouter ?? Socks5ProxyRouter.instance,
       _forwarderPool = forwarderPool ?? Socks5ForwarderPool.instance {
    _client.findProxy = ProxyKernelTraffic.findProxy;
  }

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  final LiveCookieJar _cookies = LiveCookieJar();

  /// 构造时绑定的默认资源键；每次请求也可用 [proxyResourceKey] 覆盖。
  /// 无分配时走默认客户端（代理内核全局链路），行为与以前一致。
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
  /// 等转发器起好的间隙里快照变了就按新快照重算，最多重试 3 次，
  /// 仍不一致时回默认客户端，绝不卡死。
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
    Duration? timeout,
    String? proxyResourceKey,
  }) async => _send(
    await _clientFor(proxyResourceKey),
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
    String? proxyResourceKey,
  }) async => _send(
    await _clientFor(proxyResourceKey),
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
    String? proxyResourceKey,
  }) async => _send(
    await _clientFor(proxyResourceKey),
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
    } on Socks5Failure catch (error) {
      throw AppFailure(error.message);
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
