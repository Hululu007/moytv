import 'dart:async';

import 'app_page_route.dart';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'core_bridge.dart';
import 'models.dart';

/// 桌面 Chrome UA：Go 核默认用这一条发请求，隐藏浏览器解盾也用它。
const shieldUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36';

/// 手机 Chrome UA：有些站点只对移动端放行托管挑战（那种要勾选框的），
/// 桌面 UA 会一直转圈。验证页里留了切换按钮，两条都能试。
const shieldMobileUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36';

/// 盾已解开：value 是被解开的主机名。页面可以监听它做一次自动重载。
final ValueNotifier<String?> shieldClearedNotifier = ValueNotifier<String?>(null);

/// 人机校验页的正文特征（站点语言不同，认几组短句就够）。
/// 只有「标题命中」或「正文命中且带 Cloudflare 痕迹」才算，
/// 避免把正常页面里的一句「人机验证」误判成挑战页。
const kShieldBodyMarkers = <String>[
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

const kShieldHostMarkers = <String>[
  'cloudflare',
  'challenges.cloudflare.com',
  'cf-challenge',
  'cf_chl',
  'trunstile', // 站点拼错也认
  'turnstile',
];

/// 判断某个页面是不是 Cloudflare 一类的验证等待页。
///
/// 这套判断同时用在「Go 核上报」和「App 内浏览器撞盾」两条路上，
/// 所以保持纯函数、不依赖任何站点名。
bool looksLikeShieldPage(String title, String body) {
  final head = title.toLowerCase();
  final tail = body.length > 4000 ? body.substring(0, 4000) : body;
  final text = tail.toLowerCase();
  for (final marker in kShieldBodyMarkers) {
    if (head.contains(marker)) return true;
  }
  final hasMarker = kShieldBodyMarkers.any(text.contains);
  if (!hasMarker) return false;
  return kShieldHostMarkers.any(text.contains) ||
      head.contains('moment') ||
      head.contains('验证');
}

/// 打开站点验证页。
///
/// [challenge] 为空时取清关队列里最新的一条；传进来时直接验那一条
/// （App 内浏览器撞盾、用户点「过一下验证」走的就是这条）。
Future<void> openClearanceFlow(
  BuildContext context,
  AppRepository repository, {
  ClearanceChallenge? challenge,
}) async {
  var target = challenge;
  if (target == null) {
    List<ClearanceChallenge> pending;
    try {
      pending = await repository.clearanceNeeded();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('取验证队列失败：$error')));
      return;
    }
    if (!context.mounted) return;
    if (pending.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前没有待验证的站点')));
      return;
    }
    target = pending.first;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    appPageRoute<void>(
      builder: (_) =>
          ClearanceWebViewPage(repository: repository, challenge: target!),
    ),
  );
}

/// 站点验证页：把挑战页整屏摆出来让用户点。
///
/// Turnstile 那一类勾选框必须真人点（自动点击会被判为机器人），
/// 所以这里是唯一能过的路子，必须做到：能点、能刷新、能换 UA、
/// 能手动确认，通过后把票据连「签发时的 UA」一起回填。
class ClearanceWebViewPage extends StatefulWidget {
  const ClearanceWebViewPage({
    super.key,
    required this.repository,
    required this.challenge,
  });

  final AppRepository repository;
  final ClearanceChallenge challenge;

  @override
  State<ClearanceWebViewPage> createState() => _ClearanceWebViewPageState();
}

class _ClearanceWebViewPageState extends State<ClearanceWebViewPage> {
  late final WebViewController _controller;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();
  Timer? _timer;
  bool _checking = false;
  bool _done = false;
  bool _mobileUa = false;
  String _status = '请在页面里勾选「验证您是真人」，通过后会自动回填并返回。';

  /// 真正去解这道盾的 UA。默认跟 Go 核发请求的 UA 一致；
  /// 用户在页面里切到手机 UA 时跟着换，回填也换成同一个，
  /// 票和 UA 必须配对，否则票会被判无效。
  String get _userAgent {
    if (_mobileUa) return shieldMobileUserAgent;
    return widget.challenge.userAgent.isNotEmpty
        ? widget.challenge.userAgent
        : shieldUserAgent;
  }

  Uri get _challengeUri {
    final raw = widget.challenge.url.trim();
    final parsed = Uri.tryParse(raw);
    if (parsed != null && parsed.host.isNotEmpty) return parsed;
    return Uri.parse('https://${widget.challenge.host}/');
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_userAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            unawaited(_checkCookies());
          },
        ),
      );
    unawaited(_load());
    _timer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => unawaited(_checkCookies()),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await _controller.loadRequest(_challengeUri);
    } catch (_) {
      // 加载失败不致命：页面里有「重新加载」，用户点一下再试。
    }
  }

  bool _domainMatches(String domain) {
    final normalized = domain.startsWith('.') ? domain.substring(1) : domain;
    if (normalized.isEmpty) return true;
    final host = widget.challenge.host.toLowerCase();
    return host == normalized || host.endsWith('.$normalized');
  }

  /// 读本页所有 cookie。挑战页可能落在深层路径上，所以「按挑战地址读」
  /// 和「按站点根域读」都试一遍，合并去重。
  Future<List<WebViewCookie>> _readCookies() async {
    final seen = <String>{};
    final out = <WebViewCookie>[];
    final probes = <Uri>[
      _challengeUri,
      Uri.parse('https://${widget.challenge.host}/'),
    ];
    for (final probe in probes) {
      try {
        final cookies = await _cookieManager.getCookies(domain: probe);
        for (final cookie in cookies) {
          if (!_domainMatches(cookie.domain)) continue;
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

  Future<void> _checkCookies({bool manual = false}) async {
    if (_checking || _done) return;
    _checking = true;
    try {
      final matched = await _readCookies();
      final hasClearance = matched.any((c) => c.name == 'cf_clearance');
      if (!hasClearance) {
        if (manual && mounted) {
          setState(
            () => _status = '还没拿到通行证：先点页面里的勾选框，等它变成绿色的对勾再点「我已通过」。',
          );
        }
        return;
      }
      final header = matched
          .map((cookie) => '${cookie.name}=${cookie.value}')
          .join('; ');
      await widget.repository.setClearance(
        host: widget.challenge.host,
        cookie: header,
        ua: _userAgent,
      );
      _done = true;
      shieldClearedNotifier.value = widget.challenge.host;
      if (!mounted) return;
      setState(() => _status = '验证已完成，正在返回。');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('站点验证已回填，页面会自己刷新')));
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _status = '回填失败：$error');
    } finally {
      _checking = false;
    }
  }

  Future<void> _switchUa() async {
    setState(() {
      _mobileUa = !_mobileUa;
      _status = _mobileUa
          ? '已切到手机 UA，正在重新加载。有的站点只对手机放行。'
          : '已切回桌面 UA，正在重新加载。';
    });
    await _controller.setUserAgent(_userAgent);
    await _load();
  }

  Future<void> _reload() async {
    setState(() => _status = '正在重新加载验证页…');
    try {
      await _controller.clearCache();
    } catch (_) {}
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('站点验证 · ${widget.challenge.host}')),
      body: Column(
        children: [
          Expanded(child: WebViewWidget(controller: _controller)),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.verified_user_outlined,
                        size: 18,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _status,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => unawaited(_reload()),
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('重新加载'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => unawaited(_switchUa()),
                          icon: const Icon(Icons.phone_android, size: 18),
                          label: Text(_mobileUa ? '用桌面版' : '用手机版'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => unawaited(_checkCookies(manual: true)),
                          child: const Text('我已通过'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
