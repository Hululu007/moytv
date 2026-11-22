import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core_bridge.dart';
import '../local_store.dart';
import 'html_bridge.dart';
import 'html_gateway.dart';
import 'html_sdk.dart';
import 'html_site.dart';

/// HTML 站源宿主页面：新通道 `MoyiHtmlNative` + 临时回环服务，
/// 与海阔运行时完全独立（不共用端口、通道与运行时状态）。
///
/// 两条路线：单文件首页（Route A，回环服务供页 + script 标签注入
/// 垫片）与原站注入增强（Route B，加载原站 + 加载完成后注入垫片
/// 与扩展）。两条路线共用同一 fm 桥与同一播放链路。
class HtmlHostPage extends StatefulWidget {
  const HtmlHostPage({
    super.key,
    required this.entry,
    required this.repository,
    required this.store,
    this.onOpenLive,
    this.onOpenKeep,
  });

  final HtmlSiteEntry entry;
  final AppRepository repository;
  final LocalStore store;
  final Future<bool> Function(Map<String, dynamic> params)? onOpenLive;
  final Future<bool> Function(Map<String, dynamic> params)? onOpenKeep;

  @override
  State<HtmlHostPage> createState() => _HtmlHostPageState();
}

class _HtmlHostPageState extends State<HtmlHostPage> with WidgetsBindingObserver {
  WebViewController? _controller;
  HttpServer? _server;
  HtmlBridge? _bridge;
  bool _ready = false;
  String? _error;
  String _lastInjectedUrl = '';

  Size? _lastViewport;
  bool _allowPop = false;

  /// fm.ui.setChrome 的当前模式：normal（顶栏在位）/ edge（顶栏隐藏、
  /// 系统栏保留）/ immersive（顶栏与系统栏都隐藏）。restoreChrome
  /// 回到最近一次 setChrome 之前的模式。
  String _chromeMode = 'normal';
  String _chromeModeBefore = 'normal';
  String _restoreAffordance = 'auto';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_boot());
  }

  Future<void> _boot() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      setState(() => _error = '当前平台不支持 HTML 站源');
      return;
    }
    // startup 偏好：页面上次以 startup:true 存下的 normal/edge 在
    // 下次打开本站时直接生效（immersive 从不存启动偏好）。
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(
        'moyi_html_chrome:${widget.entry.siteKey}',
      );
      if (saved != null && (saved == 'edge' || saved == 'normal')) {
        _chromeMode = saved;
        _chromeModeBefore = saved;
      }
    } catch (_) {}
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      server.listen(_handleHttp);
      final bridge = HtmlBridge(
        siteKey: widget.entry.siteKey,
        siteName: widget.entry.siteName,
        repository: widget.repository,
        store: widget.store,
        host: HtmlBridgeHost(
          pushPage: _pushPage,
          showToast: _showToast,
          popPage: _popPage,
          canGoBack: () async => _controller?.canGoBack() ?? false,
          goBack: () async => _controller?.goBack(),
          reloadPage: () async {
            await _controller?.clearCache();
            await _controller?.reload();
          },
          viewport: _viewport,
          precacheArtwork: _precacheArtwork,
          onOpenLive: widget.onOpenLive,
          onOpenKeep: widget.onOpenKeep,
          setChrome: _setChrome,
          restoreChrome: _restoreChrome,
          exitPage: _exitPage,
        ),
        cache: SharedPreferencesHtmlCacheStore(
          'moyi_html_cache:${widget.entry.siteKey}:',
        ),
        sendToPage: _sendToPage,
        gatewayPort: server.port,
        // fm.req 默认 UA 取本 WebView 的 UA，与解题票据绑定的 UA
        // 一致，否则 cf_clearance 带上也会被重拦（见桥 _req）。
        // 闭包每次现取 _controller：桥建在 controller 之前。
        userAgentReader: () async {
          final controller = _controller;
          if (controller == null) return null;
          try {
            return await controller.getUserAgent();
          } catch (_) {
            return null;
          }
        },
      );
      _bridge = bridge;
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(onPageFinished: _onPageFinished),
        )
        ..addJavaScriptChannel(
          'MoyiHtmlNative',
          onMessageReceived: (message) {
            final target = _bridge;
            if (target != null) {
              unawaited(target.handleMessage(message.message));
            }
          },
        );
      _controller = controller;
      final entry = widget.entry;
      if (entry.isSingleFile) {
        await controller.loadRequest(
          Uri.parse('http://127.0.0.1:${server.port}/__page'),
        );
      } else {
        await controller.loadRequest(Uri.parse(entry.siteUrl));
      }
      if (mounted) setState(() => _ready = true);
      _applySystemUiForMode(_chromeMode, const {});
    } catch (error) {
      if (mounted) setState(() => _error = '宿主启动失败：$error');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 离开页面必把系统栏还给整应用的默认 edgeToEdge（main.dart
    // 启动时所设），否则沉浸模式会漏到壳的其它页面。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    unawaited(_server?.close(force: true));
    super.dispose();
  }

  /// fm.ui.setChrome：normal/edge/immersive 三档。startup:true 时
  /// 只持久化 normal/edge；scrim 暂不处理（系统栏默认透明）。
  Future<String> _setChrome(
    String mode,
    Map<String, dynamic> options,
  ) async {
    if (!mounted) return _chromeMode;
    if (options['startup'] == true && (mode == 'normal' || mode == 'edge')) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'moyi_html_chrome:${widget.entry.siteKey}',
          mode,
        );
      } catch (_) {}
      if (!mounted) return _chromeMode;
    }
    setState(() {
      _chromeModeBefore = _chromeMode;
      _chromeMode = mode;
      _restoreAffordance =
          options['restoreAffordance']?.toString() ?? 'auto';
    });
    _applySystemUiForMode(mode, options);
    _bridge?.dispatchPageEvent('fmviewport', _viewport());
    return mode;
  }

  /// fm.ui.restoreChrome：回到最近一次 setChrome 之前的模式。
  Future<String> _restoreChrome() async {
    if (!mounted) return _chromeMode;
    final target = _chromeModeBefore;
    setState(() {
      _chromeMode = target;
      _restoreAffordance = 'auto';
    });
    _applySystemUiForMode(target, const {});
    _bridge?.dispatchPageEvent('fmviewport', _viewport());
    return target;
  }

  void _applySystemUiForMode(String mode, Map<String, dynamic> options) {
    SystemChrome.setEnabledSystemUIMode(
      mode == 'immersive'
          ? SystemUiMode.immersiveSticky
          : SystemUiMode.edgeToEdge,
    );
    final statusStyle = options['statusBarStyle']?.toString() ?? '';
    final navStyle = options['navigationBarStyle']?.toString() ?? '';
    if (statusStyle.isEmpty && navStyle.isEmpty) return;
    // light = 浅色图标（配深色背景），dark = 深色图标（配浅色背景），
    // auto 跟当前主题深浅。
    Brightness? iconBrightness(String style) {
      switch (style) {
        case 'light':
          return Brightness.light;
        case 'dark':
          return Brightness.dark;
        case 'auto':
          return Theme.of(context).brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark;
        default:
          return null;
      }
    }

    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarIconBrightness: statusStyle.isEmpty
            ? null
            : iconBrightness(statusStyle),
        systemNavigationBarIconBrightness: navStyle.isEmpty
            ? null
            : iconBrightness(navStyle),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bridge = _bridge;
    if (bridge == null) return;
    if (state == AppLifecycleState.resumed) {
      bridge.dispatchPageEvent('fmresume', {});
    } else if (state == AppLifecycleState.paused) {
      bridge.dispatchPageEvent('fmpause', {});
    }
  }

  @override
  void didChangeMetrics() {
    final size = MediaQuery.maybeSizeOf(context);
    if (size == null || size == _lastViewport) return;
    _lastViewport = size;
    _bridge?.dispatchPageEvent('fmviewport', _viewport());
  }

  Map<String, dynamic> _viewport() {
    final size = MediaQuery.maybeSizeOf(context) ?? Size.zero;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final padding = MediaQuery.maybePaddingOf(context) ?? EdgeInsets.zero;
    return {
      'width': size.width,
      'height': size.height,
      'devicePixelRatio': dpr,
      'chromeMode': _chromeMode,
      'safeArea': {
        'top': padding.top,
        'bottom': padding.bottom,
        'left': padding.left,
        'right': padding.right,
      },
    };
  }

  void _sendToPage(String javaScript) {
    final controller = _controller;
    if (controller == null || !mounted) return;
    unawaited(controller.runJavaScript(javaScript).catchError((_) {}));
  }

  void _pushPage(Widget page) {
    if (!mounted) return;
    unawaited(
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => page)),
    );
  }

  void _showToast(String message) {
    if (!mounted || message.isEmpty) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _popPage() {
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  /// 强制退出（fm.openLive 用）：先放行 PopScope 再退栈，与
  /// _onPopInvoked 的退栈路径一致；直接 pop 会被 PopScope 拦下
  /// 改走 WebView 历史，退不出去。
  void _exitPage() {
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _precacheArtwork(List<String> urls) async {
    if (!mounted) return;
    for (final url in urls) {
      if (!mounted) return;
      try {
        await precacheImage(NetworkImage(url), context);
      } catch (_) {}
    }
  }

  Future<void> _handleHttp(HttpRequest request) async {
    if (await handleHtmlGatewayRequest(request)) return;
    final response = request.response;
    try {
      if (request.uri.path == '/__sdk.js') {
        response.headers.contentType = ContentType(
          'application',
          'javascript',
          charset: 'utf-8',
        );
        response.write(kMoyiHtmlSdkShim);
        await response.close();
        return;
      }
      if (request.uri.path == '/__page' && widget.entry.isSingleFile) {
        response.headers.contentType = ContentType.html;
        response.write(_injectSdk(widget.entry.entryHtml));
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.notFound;
      await response.close();
    } catch (_) {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  String _injectSdk(String html) {
    final siteInfo = jsonEncode({
      'siteKey': widget.entry.siteKey,
      'siteName': widget.entry.siteName,
      // 垫片 fm.res 同步算网关地址用（见 html_sdk.dart）。
      'gatewayPort': _server?.port ?? 0,
    });
    final tag =
        '<script>window.__moyiSiteInfo=$siteInfo;</script>'
        '<script src="/__sdk.js"></script>';
    final lower = html.toLowerCase();
    final bodyClose = lower.lastIndexOf('</body>');
    if (bodyClose >= 0) {
      return html.substring(0, bodyClose) + tag + html.substring(bodyClose);
    }
    final htmlClose = lower.lastIndexOf('</html>');
    if (htmlClose >= 0) {
      return html.substring(0, htmlClose) + tag + html.substring(htmlClose);
    }
    return html + tag;
  }

  void _onPageFinished(String url) {
    _bridge?.dispatchPageEvent('fmviewport', _viewport());
    if (!widget.entry.isSingleFile && url != _lastInjectedUrl) {
      _lastInjectedUrl = url;
      unawaited(_injectRouteB());
    }
  }

  /// Route B 注入：垫片 + 各扩展（document-end；runAt=start 暂无
  /// 原生钩子，同样在 end 注入；runAt=idle 延后约 600ms）。
  /// 远程 js 网络优先、无缓存，取不到则该扩展跳过并报 fmexterror。
  Future<void> _injectRouteB() async {
    final controller = _controller;
    final bridge = _bridge;
    if (controller == null || bridge == null || !mounted) return;
    final siteInfo = jsonEncode({
      'siteKey': widget.entry.siteKey,
      'siteName': widget.entry.siteName,
      // 垫片 fm.res 同步算网关地址用（见 html_sdk.dart）。
      'gatewayPort': _server?.port ?? 0,
    });
    try {
      await controller.runJavaScript('window.__moyiSiteInfo=$siteInfo;');
      await controller.runJavaScript(kMoyiHtmlSdkShim);
    } catch (_) {
      return;
    }
    for (final extension in widget.entry.extensions) {
      if (!mounted) return;
      if (!extension.enabled || !extension.hasCode) continue;
      if (extension.runAt == 'idle') {
        await Future.delayed(const Duration(milliseconds: 600));
        if (!mounted) return;
      }
      var code = extension.code;
      if (code.isEmpty && extension.js.isNotEmpty) {
        code = await _fetchRemoteScript(extension.js) ?? '';
        if (code.isEmpty) {
          bridge.dispatchPageEvent('fmexterror', {
            'id': extension.id,
            'message': 'remote script fetch failed',
          });
          continue;
        }
      }
      if (code.isEmpty) continue;
      final wrapped =
          'try{\n$code\n}catch(e){'
          'window.__moyiExtError(${jsonEncode(extension.id)},'
          'String(e&&e.message||e));}';
      try {
        await controller.runJavaScript(wrapped);
        bridge.dispatchPageEvent('fmextload', {
          'id': extension.id,
          'name': extension.name,
        });
      } catch (error) {
        bridge.dispatchPageEvent('fmexterror', {
          'id': extension.id,
          'message': error.toString(),
        });
      }
    }
  }

  Future<String?> _fetchRemoteScript(String url) async {
    if (!(url.startsWith('http://') || url.startsWith('https://'))) return null;
    final client = HttpClient();
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != 200) return null;
      const maxBytes = 2 * 1024 * 1024;
      final chunks = <List<int>>[];
      var total = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        total += chunk.length;
        if (total > maxBytes) return null;
        chunks.add(chunk);
      }
      return utf8.decode(chunks.expand((c) => c).toList(), allowMalformed: true);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  Future<void> _onPopInvoked(bool didPop) async {
    if (didPop) return;
    if (await (_controller?.canGoBack() ?? false)) {
      await _controller?.goBack();
      return;
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    final content = error != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(error, textAlign: TextAlign.center),
            ),
          )
        : !_ready || _controller == null
        ? const Center(child: CircularProgressIndicator())
        : WebViewWidget(controller: _controller!);
    final body = content;
    // 沉浸模式的原生恢复入口：页面自绘返回（restoreAffordance none）
    // 时不叠加；其余情况右上角给一个半透明恢复钮，点按回到
    // 进入沉浸前的模式。返回键仍优先走 WebView 历史（见 _onPopInvoked）。
    final showRestoreAffordance =
        _chromeMode == 'immersive' && _restoreAffordance != 'none';
    final padding = MediaQuery.maybePaddingOf(context) ?? EdgeInsets.zero;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) => unawaited(_onPopInvoked(didPop)),
      child: Scaffold(
        appBar: _chromeMode == 'normal'
            ? AppBar(
                title: Text(widget.entry.siteName),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: '刷新',
                    onPressed: () => unawaited(_controller?.reload()),
                  ),
                ],
              )
            : null,
        body: showRestoreAffordance
            ? Stack(
                children: [
                  body,
                  Positioned(
                    top: padding.top + 8,
                    right: 8,
                    child: Material(
                      color: Colors.black45,
                      shape: const CircleBorder(),
                      child: IconButton(
                        icon: const Icon(
                          Icons.fullscreen_exit,
                          color: Colors.white,
                        ),
                        tooltip: '恢复界面',
                        onPressed: () => unawaited(_restoreChrome()),
                      ),
                    ),
                  ),
                ],
              )
            : body,
      ),
    );
  }
}
