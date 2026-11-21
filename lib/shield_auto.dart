import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'clearance_bridge.dart'
    show openClearanceFlow, shieldClearedNotifier, shieldUserAgent;
import 'core_bridge.dart';
import 'models.dart';

// 解盾通知与验证页放在 clearance_bridge 里统一维护，
// 这里转出去，老的引用（shield_auto 的导入方）不用改。
export 'clearance_bridge.dart' show shieldClearedNotifier;

/// 通用自动过盾。
///
/// 任何站点（内置的、以后新加的、用户自己导入的）撞上 Cloudflare 一类的
/// 人机校验时，Go 核会把该主机上报到清关队列；这个组件在后台用一个
/// 1x1 的隐藏浏览器把校验跑完，拿到的通行证（cf_clearance + 签发时的 UA）
/// 回填进票据库，之后同一个主机的请求自动带上，用户全程无感。
///
/// 设计上有意「不认识任何站点」：只认「某主机被挑战了」这件事，
/// 所以新增站点不需要改这里，也不需要单独写补丁。
class ShieldAutoResolver extends StatefulWidget {
  const ShieldAutoResolver({
    super.key,
    required this.repository,
    required this.child,
    this.navigatorKey,
  });

  final AppRepository repository;
  final GlobalKey<NavigatorState>? navigatorKey;
  final Widget child;

  @override
  State<ShieldAutoResolver> createState() => _ShieldAutoResolverState();
}

class _ShieldAutoResolverState extends State<ShieldAutoResolver> {
  Timer? _poller;
  _ShieldJob? _active;
  final Set<String> _handled = <String>{};
  final Map<String, int> _attempts = <String, int>{};
  final Map<String, DateTime> _cooldown = <String, DateTime>{};
  bool _polling = false;

  /// 一个主机自动尝试的次数上限：超过就交给用户手动解一次，
  /// 免得在死站上反复起浏览器拖慢 App。
  static const _maxAttempts = 2;
  static const _cooldownSpan = Duration(minutes: 15);
  static const _jobTimeout = Duration(seconds: 32);

  @override
  void initState() {
    super.initState();
    _poller = Timer.periodic(const Duration(seconds: 4), (_) => _poll());
    WidgetsBinding.instance.addPostFrameCallback((_) => _poll());
  }

  @override
  void dispose() {
    _poller?.cancel();
    _active?.dispose();
    super.dispose();
  }

  bool _eligible(ClearanceChallenge challenge) {
    final host = challenge.host.toLowerCase();
    if (host.isEmpty) return false;
    if (_handled.contains(host)) return false;
    final until = _cooldown[host];
    if (until != null && DateTime.now().isBefore(until)) return false;
    if ((_attempts[host] ?? 0) >= _maxAttempts) return false;
    return true;
  }

  Future<void> _poll() async {
    if (_polling || _active != null) return;
    _polling = true;
    try {
      final pending = await widget.repository.clearanceNeeded();
      if (!mounted || pending.isEmpty) return;
      final next = pending.firstWhere(_eligible, orElse: () => pending.first);
      if (!_eligible(next)) return;
      final job = _ShieldJob(challenge: next);
      setState(() => _active = job);
      _handled.add(next.host.toLowerCase());
      _attempts[next.host.toLowerCase()] =
          (_attempts[next.host.toLowerCase()] ?? 0) + 1;
      unawaited(_run(job));
    } catch (_) {
      // 清关队列取不到不影响正常使用，下一轮再试。
    } finally {
      _polling = false;
    }
  }

  Future<void> _run(_ShieldJob job) async {
    final challenge = job.challenge;
    final host = challenge.host.toLowerCase();
    // 隐藏浏览器用的是桌面 Chrome 的 UA：WebView 默认 UA 带着 "wv" 标记，
    // 部分站点的人机会直接判定为自动化。票据回填时也用它，UA 和票必须配对，
    // 否则票会被判无效。
    final ua = challenge.userAgent.isNotEmpty ? challenge.userAgent : shieldUserAgent;
    job.controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(ua);
    try {
      await job.controller.loadRequest(Uri.parse(challenge.url));
    } catch (_) {
      // 首次加载失败不致命，后面的轮询还可能补救。
    }

    final deadline = DateTime.now().add(_jobTimeout);
    while (mounted && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!mounted || _active != job) break;
      final cookie = await _readTicket(job, ua);
      if (cookie == null) continue;
      try {
        await widget.repository.setClearance(
          host: challenge.host,
          cookie: cookie,
          ua: ua,
        );
        shieldClearedNotifier.value = challenge.host;
        if (mounted) setState(() => _active = null);
        job.dispose();
        return;
      } catch (_) {
        // 回填失败：留到下一轮，别把队头堵死。
        break;
      }
    }

    _cooldown[host] = DateTime.now().add(_cooldownSpan);
    if (mounted) setState(() => _active = null);
    job.dispose();
    _offerManualClearance(challenge);
  }

  /// 自动解盾失败后的兜底：直接把人工验证窗摆到用户面前点一下。
  /// 大多数站点在隐藏浏览器里就能过；少数要真人点复选框的（Turnstile
  /// 交互态）走这里，点完同样回填票据，之后所有同类请求自动带票。
  void _offerManualClearance(ClearanceChallenge challenge) {
    if (!mounted) return;
    final ctx = widget.navigatorKey?.currentContext ?? context;
    if (!ctx.mounted) return;
    final host = challenge.host;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: ctx,
        builder: (dialogContext) => AlertDialog(
          title: const Text('这个站点要你点一下'),
          content: Text(
            '$host 的人机校验必须真人点那个勾选框，后台自动解不开。\n\n'
            '点「去验证」把页面打开，勾一下「验证您是真人」，通过后自动回填，'
            '这个站点以后就不用再点了。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('以后再说'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('去验证'),
            ),
          ],
        ),
      );
      if (go != true || !mounted || !ctx.mounted) return;
      await openClearanceFlow(ctx, widget.repository, challenge: challenge);
    });
  }

  Future<String?> _readTicket(_ShieldJob job, String ua) async {
    try {
      final cookies = await job.cookieManager.getCookies(
        domain: Uri.parse(job.challenge.url),
      );
      if (cookies.isEmpty) return null;
      final host = job.challenge.host.toLowerCase();
      final matched = <WebViewCookie>[
        for (final cookie in cookies)
          if (_domainMatches(host, cookie.domain)) cookie,
      ];
      if (matched.isEmpty) return null;
      if (!matched.any((c) => c.name == 'cf_clearance')) return null;
      return matched.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (_) {
      return null;
    }
  }

  bool _domainMatches(String host, String domain) {
    final normalized = domain.startsWith('.') ? domain.substring(1) : domain;
    if (normalized.isEmpty) return true;
    return host == normalized || host.endsWith('.$normalized');
  }

  @override
  Widget build(BuildContext context) {
    final job = _active;
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        if (job != null)
          Positioned(
            left: 0,
            top: 0,
            // 1x1 且不可点：不占版面、不抢焦点，但仍在渲染树里，
            // 隐藏浏览器会正常执行校验脚本。
            child: IgnorePointer(
              child: SizedBox(
                width: 1,
                height: 1,
                child: WebViewWidget(controller: job.controller),
              ),
            ),
          ),
      ],
    );
  }
}

class _ShieldJob {
  _ShieldJob({required this.challenge})
      : controller = WebViewController(),
        cookieManager = WebViewCookieManager();

  final ClearanceChallenge challenge;
  final WebViewController controller;
  final WebViewCookieManager cookieManager;

  void dispose() {
    // webview_flutter 没有显式销毁接口，控制器随 Widget 卸载回收；
    // 这里只切断引用，避免旧 job 的轮询继续跑。
  }
}
