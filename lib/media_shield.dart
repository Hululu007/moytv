import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'miniapp/haikuo/haikuo_shield.dart';

/// 播放层的通用过盾：媒体 CDN 被 Cloudflare 挡（403/挑战）时，
/// 用隐藏浏览器解一次，把通行证并进播放器请求头。
///
/// 为什么放在播放层而不是每个站各写一份：
/// 媒体域名（CDN）经常和站点域名不是一家，站点规则里管不到；
/// 而「被盾挡住」这件事对所有站来说都是同一件事。这里只认通用的
/// Cloudflare 特征，不认识任何具体站点，新站接进来不用再改。
///
/// 用法：播放页挂一个 [MediaShieldHost]（1 像素），开播前调
/// [headersFor] 把计划里的请求头过一遍即可。没有挂宿主时自动退化成
/// 原样返回，不影响其它页面。

/// 解盾用的 UA：桌面 Chrome。挑战票据绑 UA，播放器必须用同一个发请求。
const String mediaShieldUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// 一张通行证：Cookie 串 + 解盾时的 UA。
class MediaShieldTicket {
  MediaShieldTicket({
    required this.cookie,
    required this.userAgent,
    required this.issuedAt,
  });

  final String cookie;
  final String userAgent;
  final DateTime issuedAt;

  /// CF 票据默认 30 分钟，留余量按 20 分钟用。
  static const Duration ttl = Duration(minutes: 20);

  bool get fresh => DateTime.now().difference(issuedAt) < ttl;
}

class MediaShield {
  MediaShield._();

  /// 隐藏浏览器取页面的能力：由播放页挂的 [MediaShieldHost] 注册。
  static Future<String> Function(String url)? _browser;

  static final Map<String, MediaShieldTicket> _tickets =
      <String, MediaShieldTicket>{};
  // 不需要过盾的主机：探测过一次就够了，别再拖着开播。
  static final Map<String, DateTime> _cleanHosts = <String, DateTime>{};
  static const Duration _cleanTtl = Duration(minutes: 10);

  static void install(Future<String> Function(String url) browser) {
    _browser = browser;
  }

  static void uninstall(Future<String> Function(String url) browser) {
    if (identical(_browser, browser)) _browser = null;
  }

  /// 把播放计划里的请求头过一遍：需要过盾就补齐 Cookie + UA，
  /// 不需要就原样返回（零成本路径）。
  static Future<Map<String, String>> headersFor(
    String url,
    Map<String, String> headers,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return headers;
    }
    final host = uri.host;
    if (host.isEmpty) return headers;
    final ticket = _tickets[host];
    if (ticket != null && ticket.fresh) {
      return <String, String>{
        ...headers,
        'Cookie': ticket.cookie,
        'User-Agent': ticket.userAgent,
      };
    }
    final cleanAt = _cleanHosts[host];
    if (cleanAt != null && DateTime.now().difference(cleanAt) < _cleanTtl) {
      return headers;
    }
    final browser = _browser;
    // 没有宿主（非视频页/播放器未挂）：不做探测，原样播，不拖时间。
    if (browser == null) return headers;
    final needs = await _probeNeedsShield(uri, headers);
    if (!needs) {
      _cleanHosts[host] = DateTime.now();
      return headers;
    }
    try {
      // 打开该媒体域名的根地址，让挑战在真实内核里跑完。
      await browser('https://$host/');
    } catch (_) {
      return headers;
    }
    final cookie = await _readBrowserCookies(uri);
    if (cookie.isEmpty) return headers;
    final fresh = MediaShieldTicket(
      cookie: cookie,
      userAgent: mediaShieldUserAgent,
      issuedAt: DateTime.now(),
    );
    _tickets[host] = fresh;
    return <String, String>{
      ...headers,
      'Cookie': fresh.cookie,
      'User-Agent': fresh.userAgent,
    };
  }

  /// 探测一次：这个媒体地址是不是被盾挡着。
  ///
  /// 只取前 4KB（Range）——探测不该把整个分片拉下来。
  static Future<bool> _probeNeedsShield(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 5);
    try {
      final request = await client
          .openUrl('GET', uri)
          .timeout(const Duration(seconds: 10));
      request.followRedirects = true;
      request.headers.set('Range', 'bytes=0-4095');
      headers.forEach((key, value) {
        if (value.isEmpty) return;
        final name = key.toLowerCase();
        if (name == 'range' || name == 'content-length' || name == 'host') {
          return;
        }
        try {
          request.headers.set(key, value);
        } catch (_) {}
      });
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final map = <String, List<String>>{};
      response.headers.forEach((name, values) {
        map[name] = values;
      });
      if (response.statusCode < 400) {
        await response.drain<void>();
        return false;
      }
      final bytes = await response
          .fold<BytesBuilder>(
            BytesBuilder(copy: false),
            (builder, chunk) => builder..add(chunk),
          )
          .timeout(const Duration(seconds: 10));
      final raw = bytes.takeBytes();
      final text = String.fromCharCodes(raw.take(8192));
      return haikuoShieldCheck(
        status: response.statusCode,
        headers: map,
        body: text,
      ).blocked;
    } catch (_) {
      // 探测失败不等于被挡：宁可原样播，也不给播放器塞错的头。
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _readBrowserCookies(Uri uri) async {
    try {
      final cookies = await WebViewCookieManager().getCookies(domain: uri);
      return cookies.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (_) {
      return '';
    }
  }
}

/// 播放页用的隐藏浏览器宿主（1 像素大小，进树才能跑 JS）。
///
/// 平时什么都不做，只在 [MediaShield.headersFor] 判定需要解盾时被调用。
class MediaShieldHost extends StatefulWidget {
  const MediaShieldHost({super.key});

  @override
  State<MediaShieldHost> createState() => _MediaShieldHostState();
}

class _MediaShieldHostState extends State<MediaShieldHost> {
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    MediaShield.install(_solve);
  }

  @override
  void dispose() {
    MediaShield.uninstall(_solve);
    super.dispose();
  }

  /// 打开地址、等挑战跑完，回真页面正文（拿不到回空串）。
  Future<String> _solve(String url) async {
    if (!mounted) return '';
    if (!url.startsWith('http://') && !url.startsWith('https://')) return '';
    final controller = _controller ??= WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000));
    if (!mounted) return '';
    setState(() {});
    try {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await controller.setUserAgent(mediaShieldUserAgent);
      await controller.loadRequest(Uri.parse(url));
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        try {
          final raw = await controller.runJavaScriptReturningResult(
            'String($haikuoShieldPassJs)',
          );
          if ('$raw'.toLowerCase() == 'true') {
            final html = await controller.runJavaScriptReturningResult(
              'document.documentElement.outerHTML',
            );
            return '$html';
          }
        } catch (_) {
          // 页面还没好，下一拍再看
        }
      }
      return '';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox(width: 1, height: 1);
    return SizedBox(width: 1, height: 1, child: WebViewWidget(controller: controller));
  }
}
