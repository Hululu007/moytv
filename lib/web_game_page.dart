import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// 拳皇97 直达地址（小霸王游戏源 www.yikm.net 的街机页，已实测
/// 确认该页是拳皇97）与唯一放行主机：只出现在代码里，界面上
/// 任何地方都不显示。
const String kof97GameUrl = 'https://www.yikm.net/play?id=5326';
const String kof97GameHost = 'www.yikm.net';

/// 导航放行判定（纯函数，可单测）：只放行 [allowedHost] 内的跳转；
/// 跳出本站的导航一律拦截，不跳系统浏览器。子资源加载不走
/// 导航回调，不受这条限制影响。
bool webGameNavigationAllowed(String url, String allowedHost) {
  final host = Uri.tryParse(url)?.host.toLowerCase();
  return host == allowedHost.toLowerCase();
}

/// 网页游戏页（通用）：Win7/XP 桌面游戏窗口的窗口体，也是动作
/// 协议点卡打开的游戏窗（见 WebGameScreen）。无 AppBar、无地址
/// 栏、无网址字串；WebView 充满可用空间。
///
/// 加载/失败面板的 ValueKey 由 [keyPrefix] 派生（`$keyPrefix-loading`、
/// `$keyPrefix-retry-panel`、`$keyPrefix-retry-button`），不同游戏
/// 窗各用各的前缀，互不撞键。
///
/// 窗口常驻靠窗口管理器的 Offstage 槽位（见 home_screen 的
/// _win7WindowSlot）：最小化到任务栏时 WebView 实例留在树里，
/// 游戏不重载；关闭窗口才丢弃。
class WebGamePage extends StatefulWidget {
  const WebGamePage({
    super.key,
    required this.gameUrl,
    required this.allowedHost,
    this.headers = const {},
    this.keyPrefix = 'game',
  });

  /// 游戏页地址（首请求地址）。
  final String gameUrl;

  /// 唯一放行的导航主机（小写比较）。
  final String allowedHost;

  /// 首请求附带的请求头（动作协议自带头，如 UA）；只用于首次加载。
  final Map<String, String> headers;

  /// 加载/失败面板 ValueKey 的前缀。
  final String keyPrefix;

  @override
  State<WebGamePage> createState() => _WebGamePageState();
}

class _WebGamePageState extends State<WebGamePage> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _loading = true;
              _failed = false;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            // 只认主框架的加载失败：子资源（图/脚本）失败不弹面板。
            if (error.isForMainFrame != true || !mounted) return;
            setState(() {
              _loading = false;
              _failed = true;
            });
          },
          onNavigationRequest: (request) =>
              webGameNavigationAllowed(request.url, widget.allowedHost)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
        ),
      );
    unawaited(_boot());
  }

  /// Android 侧视口/媒体设置（webview_flutter_android 的真实 API，
  /// 先于首次加载生效）+ 加载游戏页。
  ///
  /// 实际生效的设置：
  /// - setUseWideViewPort(true)：宽视口，页面按自身 viewport
  ///   meta（width=device-width）自适应手机屏宽；
  /// - setLoadWithOverviewMode(true)：总览模式，内容缩放到
  ///   充满视口宽——这是 AndroidWebViewController 构造函数的
  ///   默认值，这里不重复设置；
  /// - setMediaPlaybackRequiresUserGesture(false)：游戏声音
  ///   无需手势即可播放；
  /// - enableZoom(false)：关缩放（setSupportZoom(false)），
  ///   触控只进游戏，不触发页面缩放；缩放控件默认就是关的
  ///   （setDisplayZoomControls(false) 也是构造函数默认值）。
  Future<void> _boot() async {
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      await platform.setUseWideViewPort(true);
      await platform.setMediaPlaybackRequiresUserGesture(false);
      await platform.enableZoom(false);
    }
    if (!mounted) return;
    await _controller.loadRequest(
      Uri.parse(widget.gameUrl),
      headers: widget.headers,
    );
  }

  void _retry() {
    setState(() {
      _loading = true;
      _failed = false;
    });
    unawaited(_controller.reload());
  }

  @override
  void dispose() {
    // WebViewController 在 webview_flutter 4.14.1 没有 dispose
    // 方法，平台视图的生命周期归 WebViewWidget 管；这里只靠
    // mounted 守卫挡住 dispose 后的异步回调，不多做事。
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        WebViewWidget(controller: _controller),
        if (_loading && !_failed) _loadingPanel(),
        if (_failed) _retryPanel(),
      ],
    );
  }

  /// 加载中遮罩：黑底 + 转圈 + 固定文案，不带网址。
  Widget _loadingPanel() {
    return ColoredBox(
      key: ValueKey('${widget.keyPrefix}-loading'),
      color: Colors.black,
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text(
              '正在加载游戏…',
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }

  /// 加载失败面板：黑底 + 固定文案 + 重试按钮，不带网址，
  /// 不显示系统错误描述（描述里可能含网址）。
  Widget _retryPanel() {
    return ColoredBox(
      key: ValueKey('${widget.keyPrefix}-retry-panel'),
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sports_esports, color: Colors.white, size: 48),
            const SizedBox(height: 16),
            const Text(
              '游戏加载失败',
              style: TextStyle(color: Colors.white, fontSize: 17),
            ),
            const SizedBox(height: 8),
            const Text(
              '请检查网络后重试',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 20),
            FilledButton(
              key: ValueKey('${widget.keyPrefix}-retry-button'),
              onPressed: _retry,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 带标题栏的网页游戏屏：动作协议点卡跳转的目标。标题栏只显示
/// 游戏名，不显示网址；返回即退出游戏页。
class WebGameScreen extends StatelessWidget {
  const WebGameScreen({
    super.key,
    required this.title,
    required this.gameUrl,
    required this.allowedHost,
    this.headers = const {},
    this.keyPrefix = 'game',
  });

  final String title;
  final String gameUrl;
  final String allowedHost;
  final Map<String, String> headers;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: WebGamePage(
        gameUrl: gameUrl,
        allowedHost: allowedHost,
        headers: headers,
        keyPrefix: keyPrefix,
      ),
    );
  }
}
