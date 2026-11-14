/// 流媒体网关：CORS 补头、防盗链补头、m3u8 重写代理、Range 透传。
///
/// 对标 TVBox_Web gateway.js 的 /api/stream，本文件按机制自己实现。
/// 网关挂在局域网服务上（同一 HttpServer），局域网浏览器与应用内
/// 播放器共用同一套：局域网服务开启时，播放器 choke point 把符合
/// 条件的 http(s) 直链改写为本机网关地址（见 [shouldGatewayRewrite]）；
/// 服务关闭时播放链路与原来一模一样，零行为变化。
///
/// 安全边界：网关拒绝回环地址目标（防 SSRF 探手机自身服务），
/// 局域网私网地址放行（用户自己的局域网源）；网关不暴露凭证接口。
library;

import 'dart:convert';
import 'dart:io';

import '../models.dart';

/// 浏览器 UA（补头用：缺 UA 的请求补上，避免被防盗链拦）。
const gatewayUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// 局域网服务的运行时状态（播放器 choke point 读它决定是否改写）。
class LanGatewayState {
  /// 网关是否正在运行（局域网服务开启时为 true）。
  static bool active = false;

  /// 网关端口（回环地址用）。
  static int port = 8999;

  /// 回环网关基址（播放器改写用）。
  static String get loopbackBase => 'http://127.0.0.1:$port';
}

/// 播放计划是否应走网关改写：仅 http(s) 直链、无解密密钥、非回环。
///
/// 以下一律不改写（改写会破坏现有行为）：
/// - 非 http(s) 协议：novel://、pics://、磁力/torrent、hongguo-cenc 等；
/// - 带 decryptionKey 的计划（CENC 解密走 Go 中继，不进网关）；
/// - 已经是本机网关/回环地址（避免重复包一层）。
bool shouldGatewayRewrite(PlaybackPlan plan) {
  if (plan.decryptionKey.isNotEmpty) return false;
  final uri = Uri.tryParse(plan.url);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (isLoopbackHost(uri.host)) return false;
  return true;
}

/// 是否回环地址（localhost / 127.x / ::1）：网关不代理回环目标，
/// 防止局域网访客借网关探本机内网服务（SSRF 拦截）。
bool isLoopbackHost(String host) {
  final lower = host.toLowerCase();
  if (lower == 'localhost' || lower == '::1' || lower == '[::1]') return true;
  if (lower.startsWith('127.')) return true;
  return false;
}

/// 补头：缺 Referer 补目标源站，缺 UA 补浏览器 UA；已有的一律不动。
Map<String, String> gatewayHeadersFor(Uri target, Map<String, String> headers) {
  final result = Map<String, String>.from(headers);
  final lowerKeys = result.keys.map((k) => k.toLowerCase()).toSet();
  if (!lowerKeys.contains('referer')) {
    result['Referer'] = '${target.scheme}://${target.host}/';
  }
  if (!lowerKeys.contains('user-agent')) {
    result['User-Agent'] = gatewayUserAgent;
  }
  return result;
}

/// 拼网关地址：`<base>/stream?url=<目标>&headers=<base64url JSON>`。
/// headers 为空时不带 headers 参数。
String buildGatewayUrl(
  String gatewayBase,
  String targetUrl,
  Map<String, String> headers,
) {
  final query = <String, String>{'url': targetUrl};
  if (headers.isNotEmpty) {
    query['headers'] = base64Url.encode(utf8.encode(jsonEncode(headers)));
  }
  return Uri.parse(
    gatewayBase,
  ).replace(path: '/stream', queryParameters: query).toString();
}

// ---------------------------------------------------------------------------
// m3u8 重写
// ---------------------------------------------------------------------------

/// m3u8 播放列表重写：分片地址与 URI="..." 里的地址一律解析成绝对
/// 地址后包进网关（[proxyUrl] 负责包）；其余行原样保留。
///
/// 覆盖：`#EXT-X-KEY` / `#EXT-X-MAP` / `#EXT-X-MEDIA` 等标签里的
/// `URI="..."`，以及裸分片行（含变体列表的码率行）。
String rewriteM3u8(
  String playlist,
  Uri baseUri,
  String Function(Uri absolute) proxyUrl,
) {
  final uriAttr = RegExp(r'URI="([^"]*)"');
  final lines = playlist.split('\n');
  final out = <String>[];
  for (final rawLine in lines) {
    final line = rawLine.endsWith('\r')
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;
    if (line.startsWith('#')) {
      out.add(
        line.replaceAllMapped(uriAttr, (match) {
          final value = match.group(1)!;
          if (value.isEmpty) return match.group(0)!;
          return 'URI="${proxyUrl(baseUri.resolve(value))}"';
        }),
      );
    } else if (line.trim().isEmpty) {
      out.add(line);
    } else {
      out.add(proxyUrl(baseUri.resolve(line.trim())));
    }
  }
  return out.join('\n');
}

// ---------------------------------------------------------------------------
// 广告分片识别与剔除
// ---------------------------------------------------------------------------

/// 广告分片的显式 URI 模式（只认这些，不猜）。
///
/// 命中任一即判为广告分片：已知广告域名、以及路径里的广告段。
/// 误判可能：极少数正经分片路径里带 `/ads/` 字样会被误剔；
/// 剔除数写进响应头 `X-Moyi-AdSegments-Dropped`，便于发现与排障。
/// `#EXT-X-CUE-OUT` / `CUE-IN` 插播标记不处理（无法可靠定界，
/// 乱删会破坏时间轴），已在回报里如实说明。
const _adUriPatterns = <String>[
  'doubleclick.net',
  'googlesyndication.com',
  'amazon-adsystem.com',
  'adnxs.com',
  'scorecardresearch.com',
  'moatads.com',
  '/ads/',
  '/ad/',
  '/advert/',
  'preroll',
  'midroll',
  'postroll',
];

/// URI 是否命中广告模式（大小写不敏感）。
bool isAdSegmentUri(String uri) {
  final lower = uri.toLowerCase();
  return _adUriPatterns.any(lower.contains);
}

/// 剔除广告分片：删掉命中的分片行与其前一行的 `#EXTINF`；
/// `#EXT-X-DISCONTINUITY` 保留（删了会破坏时间轴）。
/// 返回（新播放列表，剔除数）。
({String playlist, int dropped}) stripAdSegments(String playlist) {
  final lines = playlist.split('\n');
  final kept = <String>[];
  var dropped = 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();
    if (!trimmed.startsWith('#') &&
        trimmed.isNotEmpty &&
        isAdSegmentUri(trimmed)) {
      // 删掉前一行的 #EXTINF（如果刚写入的上一行是它）。
      if (kept.isNotEmpty && kept.last.startsWith('#EXTINF')) {
        kept.removeLast();
      }
      dropped++;
      continue;
    }
    kept.add(line);
  }
  return (playlist: kept.join('\n'), dropped: dropped);
}

// ---------------------------------------------------------------------------
// 流代理（HttpServer 里的 /stream 处理）
// ---------------------------------------------------------------------------

/// m3u8 正文上限（超过则不重写、原样流式转发，避免内存暴涨）。
const _m3u8MaxBytes = 4 * 1024 * 1024;

class LanStreamProxy {
  LanStreamProxy({HttpClient? httpClient})
    : _client = httpClient ?? HttpClient();

  final HttpClient _client;

  void close() => _client.close(force: true);

  /// 处理一个 /stream 请求：`?url=<目标>&headers=<base64url JSON>`。
  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    _addCors(response);
    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }
    final targetRaw = request.uri.queryParameters['url'] ?? '';
    final target = Uri.tryParse(targetRaw);
    if (target == null ||
        (target.scheme != 'http' && target.scheme != 'https') ||
        isLoopbackHost(target.host)) {
      response.statusCode = HttpStatus.badRequest;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'error': 'url 参数无效或不允许代理该地址'}));
      await response.close();
      return;
    }
    var forwardHeaders = <String, String>{};
    final headersParam = request.uri.queryParameters['headers'];
    if (headersParam != null && headersParam.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(base64Url.decode(headersParam)));
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value is String) forwardHeaders[key.toString()] = value;
          });
        }
      } catch (_) {
        // headers 参数损坏时忽略，不让整个请求失败。
      }
    }
    await proxyTarget(request, target, forwardHeaders);
  }

  /// 代理一个已解析的目标地址（/cover 封面代理复用同一套转发逻辑）。
  Future<void> proxyTarget(
    HttpRequest request,
    Uri target,
    Map<String, String> headers,
  ) async {
    final response = request.response;
    _addCors(response);
    var forwardHeaders = gatewayHeadersFor(target, headers);
    // 客户端的 Range 头原样透传（断点续传/拖进度用）。
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null && range.isNotEmpty) {
      forwardHeaders[HttpHeaders.rangeHeader] = range;
    }
    try {
      await _proxy(request, target, forwardHeaders);
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badGateway;
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'error': '上游请求失败'}));
        await response.close();
      } catch (_) {
        // 响应已发送或已关闭时不再补写。
      }
    }
  }

  Future<void> _proxy(
    HttpRequest request,
    Uri target,
    Map<String, String> headers,
  ) async {
    var current = target;
    HttpClientResponse? upstream;
    // 跳转被截断（回环/非 http(s)）时上游响应已被 drain，流不能
    // 再被 addStream 复听——复听会抛错并挂起本次请求。
    var upstreamDrained = false;
    for (var hop = 0; hop <= 5; hop++) {
      final req = await _client.getUrl(current);
      req.followRedirects = false;
      headers.forEach(req.headers.set);
      upstream = await req.close().timeout(const Duration(seconds: 30));
      final status = upstream.statusCode;
      final location = upstream.headers.value(HttpHeaders.locationHeader);
      if (status >= 300 &&
          status < 400 &&
          location != null &&
          location.isNotEmpty &&
          hop < 5) {
        await upstream.drain<void>().catchError((_) {});
        upstreamDrained = true;
        final next = current.resolve(location);
        if (next.scheme != 'http' && next.scheme != 'https') break;
        if (isLoopbackHost(next.host)) break;
        current = next;
        upstreamDrained = false;
        continue;
      }
      break;
    }
    final response = request.response;
    final finalUpstream = upstream!;
    final contentType = finalUpstream.headers.contentType?.mimeType ?? '';
    final isM3u8 =
        contentType.contains('mpegurl') ||
        contentType.contains('x-mpegurl') ||
        current.path.toLowerCase().endsWith('.m3u8');
    final contentLength = finalUpstream.headers.contentLength;
    if (isM3u8 &&
        !upstreamDrained &&
        (contentLength < 0 || contentLength <= _m3u8MaxBytes)) {
      // 有界收集：超过上限就改原样流式转发（已收的前缀 + 剩余流），
      // 不重写，避免内存暴涨。
      final collected = <int>[];
      var overCap = false;
      await for (final chunk in finalUpstream.timeout(
        const Duration(seconds: 30),
      )) {
        if (collected.length + chunk.length > _m3u8MaxBytes) {
          overCap = true;
          collected.addAll(chunk);
          break;
        }
        collected.addAll(chunk);
      }
      if (!overCap) {
        final text = utf8.decode(collected, allowMalformed: true);
        final stripped = stripAdSegments(text);
        final gatewayBase =
            'http://${request.headers.host ?? '127.0.0.1:${request.connectionInfo?.localPort ?? LanGatewayState.port}'}/stream';
        final rewritten = rewriteM3u8(
          stripped.playlist,
          current,
          (absolute) =>
              buildGatewayUrl(gatewayBase, absolute.toString(), headers),
        );
        final outBytes = utf8.encode(rewritten);
        response.statusCode = finalUpstream.statusCode;
        response.headers.contentType = ContentType.parse(
          'application/vnd.apple.mpegurl; charset=utf-8',
        );
        response.headers.set(HttpHeaders.contentLengthHeader, outBytes.length);
        response.headers.set(
          'X-Moyi-AdSegments-Dropped',
          '${stripped.dropped}',
        );
        response.add(outBytes);
        await response.close();
        return;
      }
      // 超大 m3u8：原样转发（前缀 + 剩余流），不再重写。
      response.statusCode = finalUpstream.statusCode;
      _copyPassthroughHeaders(finalUpstream, response);
      response.add(collected);
      await response.addStream(finalUpstream);
      await response.close();
      return;
    }
    response.statusCode = finalUpstream.statusCode;
    _copyPassthroughHeaders(finalUpstream, response);
    // 已 drain 的跳转响应没有可转发的正文（流已复听不得），只发
    // 状态行与头（含 Location，客户端可自行跟随）。
    if (!upstreamDrained) {
      await response.addStream(finalUpstream);
    }
    await response.close();
  }

  void _copyRangeHeaders(HttpClientResponse upstream, HttpResponse response) {
    for (final name in [
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
    ]) {
      final value = upstream.headers.value(name);
      if (value != null) response.headers.set(name, value);
    }
  }

  void _copyPassthroughHeaders(
    HttpClientResponse upstream,
    HttpResponse response,
  ) {
    final contentType = upstream.headers.contentType;
    if (contentType != null) response.headers.contentType = contentType;
    final contentLength = upstream.headers.contentLength;
    if (contentLength >= 0) {
      response.headers.set(HttpHeaders.contentLengthHeader, contentLength);
    }
    // 跳转响应原样返回时把 Location 透传，客户端可自行跟随。
    final location = upstream.headers.value(HttpHeaders.locationHeader);
    if (location != null && location.isNotEmpty) {
      response.headers.set(HttpHeaders.locationHeader, location);
    }
    _copyRangeHeaders(upstream, response);
  }

  void _addCors(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', '*');
    response.headers.set(
      'Access-Control-Expose-Headers',
      'Content-Length, Content-Range, Accept-Ranges',
    );
  }
}
