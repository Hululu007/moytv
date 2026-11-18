import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// 游戏地址：只出现在代码里，界面上任何地方都不显示（标题栏、
/// 加载提示、失败面板一律不带网址字串，也不把系统错误描述
/// 原样显示出来，描述里可能含网址）。
const String _gameUrl = 'https://game.ra2web.com/';

/// 唯一放行的主机：站内跳转只认它。
const String _gameHost = 'game.ra2web.com';

/// 导航放行判定（纯函数，可单测）：只放行本站主机内的跳转；
/// 跳出本站的导航一律拦截，不跳系统浏览器。子资源加载不走
/// 导航回调，不受这条限制影响。
bool ra2NavigationAllowed(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase();
  return host == _gameHost;
}

/// 网页游戏页（红警2）：Win7/XP 桌面游戏窗口的窗口体。
/// 无 AppBar、无地址栏、无网址字串；WebView 充满窗口可用空间。
///
/// 窗口常驻靠窗口管理器的 Offstage 槽位（见 home_screen 的
/// _win7WindowSlot）：最小化到任务栏时 WebView 实例留在树里，
/// 游戏不重载；关闭窗口才丢弃。
class Ra2GamePage extends StatefulWidget {
  const Ra2GamePage({super.key});

  @override
  State<Ra2GamePage> createState() => _Ra2GamePageState();
}

class _Ra2GamePageState extends State<Ra2GamePage> {
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
              ra2NavigationAllowed(request.url)
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
    await _controller.loadRequest(Uri.parse(_gameUrl));
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
    return const ColoredBox(
      key: ValueKey('ra2-loading'),
      color: Colors.black,
      child: Center(
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
      key: const ValueKey('ra2-retry-panel'),
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
              key: const ValueKey('ra2-retry-button'),
              onPressed: _retry,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
