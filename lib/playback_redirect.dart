/// 播放前 302 预解析：播放器拿到会跳转的地址时，先在 Dart 层把
/// 跳转跟到最终地址，再把最终地址交给三条播放路径（原生/ijk/
/// media_kit），三条路径的行为就此一致——不再依赖各播放器内核
/// 各自的跳转实现（Exo 默认不跟跨协议跳转，ijk/mpv 跟跳转时
/// 透传自定义头与 Cookie 的行为各不相同，且真机上无法单测）。
///
/// 失败时一律 fail-open：返回原始地址与原始头，行为与原来完全
/// 一致（“服务关闭时行为不变”天然成立：本解析不依赖任何服务）。
/// 跳转链有上限（默认 5 跳），循环跳转返回原始地址，绝不死循环。
///
/// 与网盘客户端的 resolveRedirects 是亲戚（同一手动跟随思路，
/// 共用 [mergeCookieHeader] 合并 Cookie），但契约不同：这里是
/// Range 探头（不下载正文）、带循环检测、失败返回原始地址，
/// 专供播放链路；不要把两者混成一个。
library;

import 'dart:async';

import 'package:http/http.dart' as http;

import 'cloud_drive/cloud_providers.dart' show mergeCookieHeader;
import 'lan_web/stream_gateway.dart' show isLoopbackHost;
import 'models.dart';

/// 预解析结果：最终地址 + 沿途合并后的请求头。
typedef ResolvedPlaybackUrl = ({String url, Map<String, String> headers});

/// 是否应对该播放计划做跳转预解析：仅 http(s) 直链、非本地文件、
/// 无解密密钥、非回环地址。网关改写的判定口径与此相同，两处保持一致。
bool shouldPreResolveRedirects(PlaybackPlan plan) {
  if (plan.local) return false;
  if (plan.decryptionKey.isNotEmpty) return false;
  final uri = Uri.tryParse(plan.url);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (isLoopbackHost(uri.host)) return false;
  return true;
}

/// 跟随跳转到最终地址。
///
/// - 每跳发一个 `Range: bytes=0-0` 的 GET 探头，正文不下载；
/// - 每跳的请求头都带上原始头 + 沿途 set-cookie 合并后的 Cookie；
/// - 非跳转响应（2xx/4xx/5xx）即停，返回当前地址；
/// - 跳数用尽仍是跳转时，返回最后一次的 Location（播放器决定）；
/// - 循环跳转、超时、网络异常、地址非法时返回原始地址与原始头。
Future<ResolvedPlaybackUrl> resolvePlaybackRedirects(
  String url,
  Map<String, String> headers, {
  http.Client? client,
  int maxHops = 5,
  Duration totalTimeout = const Duration(seconds: 5),
}) async {
  final original = (url: url, headers: Map<String, String>.from(headers));
  final start = Uri.tryParse(url);
  if (start == null) return original;
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final deadline = DateTime.now().add(totalTimeout);
    var current = start;
    final visited = <String>{current.toString()};
    var currentHeaders = Map<String, String>.from(headers);
    for (var hop = 0; hop <= maxHops; hop++) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return original;
      final request = http.Request('GET', current)
        ..headers.addAll(currentHeaders)
        ..headers['Range'] = 'bytes=0-0'
        ..followRedirects = false;
      http.StreamedResponse response;
      try {
        response = await httpClient.send(request).timeout(remaining);
      } catch (_) {
        return original;
      }
      final setCookie = response.headers['set-cookie'];
      if (setCookie != null && setCookie.isNotEmpty) {
        currentHeaders = _withMergedCookies(currentHeaders, setCookie);
      }
      final status = response.statusCode;
      final location = response.headers['location'];
      final isRedirect =
          status >= 300 &&
          status < 400 &&
          location != null &&
          location.isNotEmpty;
      await response.stream.listen(null).cancel().catchError((_) {});
      if (!isRedirect) {
        return (url: current.toString(), headers: currentHeaders);
      }
      final next = current.resolve(location);
      if (next.scheme != 'http' && next.scheme != 'https') return original;
      if (!visited.add(next.toString())) return original;
      if (hop == maxHops) {
        return (url: next.toString(), headers: currentHeaders);
      }
      current = next;
    }
    return original;
  } catch (_) {
    return original;
  } finally {
    if (owned) httpClient.close();
  }
}

/// 把一跳的 set-cookie 合并进 Cookie 头（同名覆盖，复用网盘那套
/// 合并实现，Expires 里的逗号不会切错）。
Map<String, String> _withMergedCookies(
  Map<String, String> headers,
  String setCookie,
) {
  final result = Map<String, String>.from(headers);
  String? cookieKey;
  for (final key in result.keys) {
    if (key.toLowerCase() == 'cookie') {
      cookieKey = key;
      break;
    }
  }
  final merged = mergeCookieHeader(
    cookieKey == null ? '' : result[cookieKey]!,
    setCookie,
  );
  result[cookieKey ?? 'Cookie'] = merged;
  return result;
}
