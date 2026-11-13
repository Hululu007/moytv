import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
import '../playback_sniffer.dart';
import 'haikuo/haikuo_runner_page.dart';

class MiniAppHostPage extends StatefulWidget {
  const MiniAppHostPage({
    super.key,
    required this.manifest,
    required this.runtime,
    required this.settings,
    this.launchOptions = const <String, dynamic>{},
  });

  final MiniAppManifest manifest;
  final MiniAppRuntime runtime;
  final MiniAppSettings settings;
  final Map<String, dynamic> launchOptions;

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
      late final MiniAppBridge bridge;
      bridge = MiniAppBridge(
        manifest: widget.manifest,
        appDir: instance.dir,
        prefs: prefs,
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

  /// 播放器桥的宿主实现：直链直接进播放页；网页/解析线路先过
  /// 嗅探页找到流再播。播放页与海阔共用同一套控件层（HaikuoPlayPage）。
  /// 返回 true 表示确实打开了播放器；嗅探页被用户取消时返回 false。
  Future<bool> _openPlayer(MiniAppPlayTarget target) async {
    if (!mounted) return false;
    var url = target.url;
    if (target.isSniff) {
      final found = await _sniffPlayTarget(target);
      if (found == null || found.isEmpty) return false;
      url = found;
    }
    if (!mounted) return false;
    _playerState = <String, dynamic>{
      'opened': true,
      'url': url,
      'title': target.title,
      'playing': false,
      'positionMs': 0,
      'durationMs': 0,
    };
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => HaikuoPlayPage(
          url: url,
          title: target.title,
          headers: target.headers,
          onStateChange: (state) {
            _playerState = Map<String, dynamic>.from(state);
            unawaited(_bridge?.emit('player.stateChange', _playerState));
          },
        ),
      ),
    );
    _playerState = const {'opened': false};
    unawaited(_bridge?.emit('player.close', {'url': url}));
    return true;
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
    return Scaffold(
      appBar: AppBar(
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
    return Stack(
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
                const CircularProgressIndicator(color: Colors.white),
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
    );
  }
}
