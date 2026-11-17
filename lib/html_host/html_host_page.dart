import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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
        ),
        cache: SharedPreferencesHtmlCacheStore(
          'moyi_html_cache:${widget.entry.siteKey}:',
        ),
        sendToPage: _sendToPage,
        gatewayPort: server.port,
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
    } catch (error) {
      if (mounted) setState(() => _error = '宿主启动失败：$error');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_server?.close(force: true));
    super.dispose();
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
    return {
      'width': size.width,
      'height': size.height,
      'devicePixelRatio': dpr,
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
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) => unawaited(_onPopInvoked(didPop)),
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.entry.siteName),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: () => unawaited(_controller?.reload()),
            ),
          ],
        ),
        body: error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(error, textAlign: TextAlign.center),
                ),
              )
            : !_ready || _controller == null
            ? const Center(child: CircularProgressIndicator())
            : WebViewWidget(controller: _controller!),
      ),
    );
  }
}
