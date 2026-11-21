import 'package:webview_flutter/webview_flutter.dart';

import 'clearance_bridge.dart';
import 'core_bridge.dart';

/// 在 App 自己的浏览器里撞上人机校验时用的通用捕获器。
///
/// 场景就是那张截图：站点直接把 Cloudflare 那种「请勾选验证您是真人」
/// 的页面塞进 WebView。用户点一下勾选框其实就过了，但票留在那个
/// WebView 里，Go 核之后的请求还是被拦。这里把票捞出来回填票池，
/// 顺手通知页面刷新，用户只需要点一次。
///
/// 只认「主机 + cf_clearance」这件事，不认识任何具体站点。
class ShieldCapture {
  ShieldCapture({
    required this.repository,
    required this.controller,
    required this.host,
    required this.url,
  });

  final AppRepository repository;
  final WebViewController controller;
  final String host;
  final String url;

  final WebViewCookieManager _cookies = WebViewCookieManager();

  static const _probeMarkers = <String>[
    'just a moment',
    'checking your browser',
    'verifying you are human',
    'enable javascript and cookies',
    'attention required',
    '正在进行安全验证',
    '正在进行安全检查',
    '验证您是人类',
    '验证您是真人',
    '请完成安全验证',
  ];

  /// 当前页面是不是验证等待页。判定逻辑与 [looksLikeShieldPage] 一致，
  /// 只是放在页面里跑，省一次把整页正文搬回 Dart。
  Future<bool> detect() async {
    final markers = _probeMarkers.map((m) => "'$m'").join(',');
    const hosts = "'cloudflare','challenges.cloudflare.com','cf-challenge','cf_chl','turnstile'";
    final script =
        '''
(function(){
  try {
    var t = (document.title || '').toLowerCase();
    var b = ((document.body && document.body.innerText) || '').toLowerCase();
    var bm = [$markers];
    var hm = [$hosts];
    var hit = bm.some(function(m){ return t.indexOf(m) >= 0; });
    if (!hit) {
      var anyBody = bm.some(function(m){ return b.indexOf(m) >= 0; });
      if (anyBody) {
        hit = hm.some(function(m){ return b.indexOf(m) >= 0; }) ||
              t.indexOf('moment') >= 0 || t.indexOf('验证') >= 0;
      }
    }
    return hit ? '1' : '0';
  } catch (e) { return '0'; }
})()
''';
    try {
      final raw = await controller.runJavaScriptReturningResult(script);
      return raw.toString().replaceAll('"', '').trim() == '1';
    } catch (_) {
      return false;
    }
  }

  Future<List<WebViewCookie>> _readCookies() async {
    final seen = <String>{};
    final out = <WebViewCookie>[];
    final probes = <Uri>[
      Uri.tryParse(url) ?? Uri.parse('https://$host/'),
      Uri.parse('https://$host/'),
    ];
    for (final probe in probes) {
      if (probe.host.isEmpty) continue;
      try {
        final cookies = await _cookies.getCookies(domain: probe);
        for (final cookie in cookies) {
          final domain = cookie.domain.startsWith('.')
              ? cookie.domain.substring(1)
              : cookie.domain;
          final lower = host.toLowerCase();
          if (domain.isNotEmpty &&
              lower != domain &&
              !lower.endsWith('.$domain')) {
            continue;
          }
          final key = '${cookie.domain}|${cookie.path}|${cookie.name}';
          if (!seen.add(key)) continue;
          out.add(cookie);
        }
      } catch (_) {
        // 单个探针失败继续下一个。
      }
    }
    return out;
  }

  /// 试一次：票已经在页面里了就直接回填并返回 true。
  Future<bool> captureIfReady() async {
    try {
      final cookies = await _readCookies();
      if (!cookies.any((c) => c.name == 'cf_clearance')) return false;
      final cookie = cookies
          .map((c) => '${c.name}=${c.value}')
          .join('; ');
      var ua = shieldUserAgent;
      try {
        final live = await controller.getUserAgent();
        if (live != null && live.isNotEmpty) ua = live;
      } catch (_) {}
      await repository.setClearance(host: host, cookie: cookie, ua: ua);
      shieldClearedNotifier.value = host;
      return true;
    } catch (_) {
      return false;
    }
  }
}
