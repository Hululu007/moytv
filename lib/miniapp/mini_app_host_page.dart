import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart'
    as android_webview;

import 'mini_app_ad_filter.dart';
import 'mini_app_bridge.dart';
import 'mini_app_manifest.dart';
import 'mini_app_runtime.dart';
import 'mini_app_sdk.dart';
import 'mini_app_settings.dart';
import 'mini_app_sources.dart';
import '../playback_sniffer.dart';
import 'haikuo/haikuo_runner_page.dart';

/// 一次内嵌播放的参数：播放器槽位据此建 [HaikuoPlayerView]。
/// 小程序侧不带选集表（详情页自己的选集按钮每次重新调 player.open），
/// 换源/切集走控制器的递送，不重建视图。
class _InlinePlay {
  const _InlinePlay({
    required this.url,
    required this.title,
    this.headers = const {},
  });

  final String url;
  final String title;

  /// 取流请求头（source.play 回的 header 原样带上，如 Referer/UA）。
  final Map<String, String> headers;
}

class MiniAppHostPage extends StatefulWidget {
  const MiniAppHostPage({
    super.key,
    required this.manifest,
    required this.runtime,
    required this.settings,
    this.launchOptions = const <String, dynamic>{},
    this.playerFactory,
    this.videoBuilder,
  });

  final MiniAppManifest manifest;
  final MiniAppRuntime runtime;
  final MiniAppSettings settings;
  final Map<String, dynamic> launchOptions;

  /// 测试注入播放器：默认内嵌视图直接 new Player()。
  final Player Function()? playerFactory;

  /// 测试注入视频画面：默认真实 Video + VideoController；传了它
  /// 就不建 VideoController（假播放器没有平台 handle）。
  final WidgetBuilder? videoBuilder;

  @override
  State<MiniAppHostPage> createState() => _MiniAppHostPageState();
}

class _MiniAppHostPageState extends State<MiniAppHostPage> {
  WebViewController? _controller;
  MiniAppInstance? _instance;
  MiniAppBridge? _bridge;
  Map<String, dynamic> _playerState = const {'opened': false};
  String? _error;
  bool _loading = true;
  bool _showLoadingOverlay = false;
  String _loadingMessage = '';
  // 详情页内嵌播放：非空时播放器顶在 WebView 上方，详情页保持
  // 可见可滑，不推新页面（与片库详情页的钉顶播放器同一布局）。
  _InlinePlay? _inline;
  // 内嵌播放器的递送控制器：已在播时新的 player.open 经它换源。
  HaikuoPlayerController? _playerController;
  bool _inlineFullscreen = false;
  // 内嵌视频的宽高比（videoParams 到达前默认 16:9）：槽位按它算高。
  double _inlineAspectRatio = 16 / 9;
  // 内嵌播放会话序号：每次新建播放器加一，视图以它为 key——
  // 关闭后同帧内重开也不会复用旧视图状态；递送换源不加一，
  // 视图状态保持、只换媒体。
  int _playerSession = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    widget.runtime.markBackground(widget.manifest.appId);
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final instance = await widget.runtime.ensureRunning(widget.manifest);
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      // 封面改写与图片代理共用同一个 provider：改写指向本实例
      // 的服务基址（WebView 已在用的地址），/pyproxy 路由走
      // provider 的 proxyFetch（蜘蛛 localProxy 现成路径）。
      final sourceProvider = HostMiniAppSourceProvider(
        imageBaseUrl: instance.baseUrl,
      );
      instance.server.proxyFetch = sourceProvider.proxyFetch;
      late final MiniAppBridge bridge;
      bridge = MiniAppBridge(
        manifest: widget.manifest,
        appDir: instance.dir,
        prefs: prefs,
        sourceProvider: sourceProvider,
        launchOptions: widget.launchOptions,
        callbacks: MiniAppBridgeCallbacks(
          evaluateJavascript: (js) async {
            final controller = _controller;
            if (controller != null) {
              await controller.runJavaScript(js);
            }
          },
          showToast: (message) {
            if (!mounted || message.isEmpty) return;
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(content: Text(message)),
            );
          },
          showLoading: (message) {
            if (!mounted) return;
            setState(() {
              _showLoadingOverlay = true;
              _loadingMessage = message ?? '';
            });
          },
          hideLoading: () {
            if (!mounted) return;
            setState(() => _showLoadingOverlay = false);
          },
          confirm: ({required title, required content}) async {
            if (!mounted) return false;
            final result = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(title),
                content: Text(content),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('确定'),
                  ),
                ],
              ),
            );
            return result ?? false;
          },
          actionSheet: (items) async {
            if (!mounted) return -1;
            final result = await showModalBottomSheet<int>(
              context: context,
              builder: (context) => SafeArea(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (context, index) => ListTile(
                    title: Text(items[index]),
                    onTap: () => Navigator.pop(context, index),
                  ),
                ),
              ),
            );
            return result ?? -1;
          },
          navigateTo: (path) async {
            final controller = _controller;
            final base = _instance?.baseUrl;
            if (controller == null || base == null) return;
            final clean = path.startsWith('/') ? path.substring(1) : path;
            await controller.loadRequest(Uri.parse('$base/$clean'));
          },
          navigateBack: () async {
            final controller = _controller;
            if (controller == null) return;
            if (await controller.canGoBack()) {
              await controller.goBack();
            } else if (mounted) {
              Navigator.pop(context);
            }
          },
          exit: () {
            if (mounted) Navigator.pop(context);
          },
          openMiniApp: (appId) async {
            if (!mounted) return;
            final base = await widget.runtime.resolveUrl(appId);
            if (!mounted) return;
            if (base == null) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(content: Text('目标小程序未安装')),
              );
              return;
            }
            final installed = await widget.runtime.store.listInstalled();
            final target = installed.where((e) => e.appId == appId).firstOrNull;
            if (target == null || !mounted) return;
            await Navigator.push<void>(
              context,
              MaterialPageRoute<void>(
                builder: (_) => MiniAppHostPage(
                  manifest: target,
                  runtime: widget.runtime,
                  settings: widget.settings,
                ),
              ),
            );
          },
          resolveMiniAppUrl: (appId) => widget.runtime.resolveUrl(appId),
          log: (message) => debugPrint(message),
          openPlayer: _openPlayer,
          playerState: () => Map<String, dynamic>.from(_playerState),
        ),
      );
      _bridge = bridge;
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent)
        ..addJavaScriptChannel(
          MiniAppSdkScript.channelName,
          onMessageReceived: (message) {
            unawaited(bridge.handleChannelMessage(message.message));
          },
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) => _decideNavigation(request.url),
            onPageStarted: (_) {
              unawaited(_injectSdk());
            },
            onPageFinished: (_) async {
              if (!mounted) return;
              setState(() => _loading = false);
              await _injectSdk();
              await bridge.emit('app.show');
            },
            onWebResourceError: (error) {
              debugPrint('小程序页面资源错误：${error.description}');
            },
          ),
        )
        ..loadRequest(Uri.parse(instance.server.entryUrl()));
      if (!mounted) return;
      setState(() {
        _instance = instance;
        _controller = controller;
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  /// 播放器桥的宿主实现：直链直接内嵌播；网页/解析线路先过
  /// 嗅探页找到流，回到本页内嵌播。内嵌播放器与海阔共用同一套
  /// 控件层（HaikuoPlayerView），详情页保持可见可滑，不跳页。
  /// 已在播时新的 player.open（选集/清晰度切换）经控制器递送换源，
  /// 不重建视图、不重载详情页。返回 true 表示确实打开了播放器；
  /// 嗅探页被用户取消时返回 false。
  Future<bool> _openPlayer(MiniAppPlayTarget target) async {
    if (!mounted) return false;
    var url = target.url;
    if (target.isSniff) {
      final found = await _sniffPlayTarget(target);
      if (found == null || found.isEmpty) return false;
      url = found;
    }
    if (!mounted) return false;
    final controller = _playerController;
    if (controller != null &&
        _inline != null &&
        controller.onDeliver != null) {
      // 内嵌播放器已就绪：递送换源。快照先同步新地址，视图的
      // onStateChange 随后会按真实进度刷新。
      controller.deliver(
        url: url,
        title: target.title,
        index: 0,
        headers: target.headers,
      );
      _playerState = <String, dynamic>{
        'opened': true,
        'url': url,
        'title': target.title,
        'playing': false,
        'positionMs': 0,
        'durationMs': 0,
      };
      setState(() {
        _inline = _InlinePlay(
          url: url,
          title: target.title,
          headers: target.headers,
        );
        // 新视频宽高比未知：先回 16:9，videoParams 到达后再按实调。
        _inlineAspectRatio = 16 / 9;
      });
      return true;
    }
    final next = HaikuoPlayerController();
    _playerController = next;
    _playerState = <String, dynamic>{
      'opened': true,
      'url': url,
      'title': target.title,
      'playing': false,
      'positionMs': 0,
      'durationMs': 0,
    };
    setState(() {
      _playerSession++;
      _inline = _InlinePlay(
        url: url,
        title: target.title,
        headers: target.headers,
      );
      _inlineFullscreen = false;
      _inlineAspectRatio = 16 / 9;
    });
    return true;
  }

  /// 关闭内嵌播放器：播放器区收起、详情页恢复整页；桥事件
  /// player.close 与状态快照与旧的推页行为保持一致。
  void _closeInlinePlayer() {
    final inline = _inline;
    if (inline == null) return;
    _playerController = null;
    if (!mounted) return;
    setState(() {
      _inline = null;
      _inlineFullscreen = false;
    });
    _playerState = const {'opened': false};
    unawaited(_bridge?.emit('player.close', {'url': inline.url}));
  }

  /// 嗅探页找流：自动播放模式，第一个候选地址一出现就回填并关页；
  /// 用户直接返回则回 null（不播、不报错）。
  Future<String?> _sniffPlayTarget(MiniAppPlayTarget target) async {
    final completer = Completer<String?>();
    var active = true;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SniffWebViewPage(
          pageUrl: target.url,
          headers: target.headers,
          autoPlay: true,
          onMediaFound: (found) {
            if (!completer.isCompleted) completer.complete(found);
            if (active && mounted) {
              active = false;
              Navigator.pop(context);
            }
          },
        ),
      ),
    );
    active = false;
    if (!completer.isCompleted) completer.complete(null);
    return completer.future;
  }

  Future<NavigationDecision> _decideNavigation(String url) async {
    if (url.startsWith('miniapp://')) {
      final rest = url.substring('miniapp://'.length);
      final appId = rest.split('/').first;
      if (appId.isNotEmpty) {
        final base = await widget.runtime.resolveUrl(appId);
        if (!mounted) return NavigationDecision.prevent;
        if (base == null) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('目标小程序未安装')),
          );
          return NavigationDecision.prevent;
        }
        final installed = await widget.runtime.store.listInstalled();
        final target = installed.where((e) => e.appId == appId).firstOrNull;
        if (target != null && mounted) {
          await Navigator.push<void>(
            context,
            MaterialPageRoute<void>(
              builder: (_) => MiniAppHostPage(
                manifest: target,
                runtime: widget.runtime,
                settings: widget.settings,
              ),
            ),
          );
        }
      }
      return NavigationDecision.prevent;
    }
    if (widget.settings.adFilter && miniAppShouldBlockUrl(url)) {
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  Future<void> _injectSdk() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.runJavaScript(MiniAppSdkScript.script);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return PopScope(
      // 内嵌播放器开着时返回键先关播放器（全屏时先退全屏），
      // 播放器关了再返回才退出小程序，不一次返回丢详情页。
      canPop: _inline == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_inlineFullscreen) {
          setState(() => _inlineFullscreen = false);
          return;
        }
        _closeInlinePlayer();
      },
      child: Scaffold(
        // 内嵌全屏时顶栏连占位高度一起藏掉，播放器真正占满屏幕。
        appBar: _inlineFullscreen
            ? null
            : AppBar(
                title: Text(widget.manifest.name),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded),
                    tooltip: '刷新',
                    onPressed: controller == null
                        ? null
                        : () => unawaited(controller.reload()),
                  ),
                ],
              ),
        body: _buildBody(controller),
      ),
    );
  }

  Widget _buildBody(WebViewController? controller) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 48),
              const SizedBox(height: 12),
              const Text('小程序启动失败'),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _error = null;
                    _loading = true;
                  });
                  _start();
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final webView = defaultTargetPlatform == TargetPlatform.android
        ? WebViewWidget.fromPlatformCreationParams(
            params: android_webview.AndroidWebViewWidgetCreationParams(
              controller: controller.platform,
              displayWithHybridComposition:
                  widget.settings.hybridComposition,
            ),
          )
        : WebViewWidget(controller: controller);
    return LayoutBuilder(
      builder: (context, constraints) {
        final inline = _inline;
        return Column(
          children: [
            // 播放器槽位始终在树里（未播放时高度为 0），保证
            // WebView 的树位置不变，切入切出内嵌播放不重载页面。
            SizedBox(
              height: inline == null
                  ? 0
                  : _inlineFullscreen
                  ? constraints.maxHeight
                  : haikuoSlotHeight(
                      aspectRatio: _inlineAspectRatio,
                      maxWidth: constraints.maxWidth,
                      maxHeight: constraints.maxHeight,
                    ),
              child: inline == null
                  ? null
                  : HaikuoPlayerView(
                      key: ValueKey<int>(_playerSession),
                      url: inline.url,
                      title: inline.title,
                      controller: _playerController,
                      headers: inline.headers,
                      onStateChange: (state) {
                        _playerState = Map<String, dynamic>.from(state);
                        unawaited(
                          _bridge?.emit('player.stateChange', _playerState),
                        );
                      },
                      fullscreen: _inlineFullscreen,
                      onFullscreenChanged: (value) =>
                          setState(() => _inlineFullscreen = value),
                      // 播放器内返回键即关闭入口：停播收起、详情页恢复整页。
                      onClose: _closeInlinePlayer,
                      onAspectRatioChanged: (ratio) =>
                          setState(() => _inlineAspectRatio = ratio),
                      playerFactory: widget.playerFactory,
                      videoBuilder: widget.videoBuilder,
                    ),
            ),
            Expanded(
              child: Stack(
                children: [
                  webView,
                  if (_loading)
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(),
                    ),
                  if (_showLoadingOverlay)
                    Container(
                      color: Colors.black45,
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(
                            color: Colors.white,
                          ),
                          if (_loadingMessage.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Text(
                              _loadingMessage,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
