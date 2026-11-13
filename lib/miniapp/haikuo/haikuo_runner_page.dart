import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../app_orientation.dart';
import '../../app_theme.dart';
import '../../network_speed.dart';
import '../../playback_preferences.dart';
import '../../player_controls.dart';
import '../../player_interactions.dart';
import '../../video_output_size.dart';
import 'haikuo_codec.dart';
import 'haikuo_program.dart';
import 'haikuo_runtime_html.dart';

/// 海阔小程序运行页。
///
/// 脚本放在本地 HTTP 服务里跑（和内置小程序容器同一套思路）：
/// 页面同源，脚本里的同步 `fetch()` 才能打到 `/__fetch` 由 Dart 侧代理，
/// 绕开 WebView 的跨域限制；点条目时用通道回到原生，媒体地址直接进播放器。
class HaikuoRunnerPage extends StatefulWidget {
  const HaikuoRunnerPage({super.key, required this.program});

  final HaikuoProgram program;

  @override
  State<HaikuoRunnerPage> createState() => _HaikuoRunnerPageState();
}

/// 播放器与运行页之间的递送通道：播放器已在栈顶时，切集解析出的新地址
/// 经它递给播放器，不再另推一页。播放器关闭后控制器失效。
/// 宿主（播放页下方的选集条）经 [requestEpisode] 请播放器切集，
/// 复用播放器内部的解析等待与防重入逻辑。
class HaikuoPlayerController {
  void Function({
    required String url,
    required String title,
    required int index,
  })?
  onDeliver;

  /// 播放器视图登记的切集入口（视图初始化时登记、销毁时清空）。
  Future<void> Function(int index)? onRequestEpisode;

  int currentIndex = 0;

  void deliver({
    required String url,
    required String title,
    required int index,
  }) {
    currentIndex = index;
    onDeliver?.call(url: url, title: title, index: index);
  }

  void requestEpisode(int index) {
    unawaited(onRequestEpisode?.call(index));
  }
}

/// play 消息的去向：播放器已打开时递送（切集），详情页发起时内嵌
/// （海报墙就地变播放器），其余（列表页发起）推一个新播放页。
enum HaikuoPlayRoute { deliver, inline, push }

HaikuoPlayRoute resolvePlayRoute({
  required bool fromDetail,
  required bool playerActive,
}) {
  if (playerActive) return HaikuoPlayRoute.deliver;
  if (fromDetail) return HaikuoPlayRoute.inline;
  return HaikuoPlayRoute.push;
}

/// 非全屏播放器槽位高度：按视频宽高比适配，竖屏视频不再被压进
/// 固定的 16:9 槽位里。上限取可用高度的 56%（与主播放器移动端
/// 同一比例），给下方的详情/选集留位置；宽高比未知或非法时
/// 回落 16:9（与旧行为一致）。
double haikuoSlotHeight({
  required double aspectRatio,
  required double maxWidth,
  required double maxHeight,
}) {
  final ratio = aspectRatio.isFinite && aspectRatio > 0
      ? aspectRatio
      : 16 / 9;
  return (maxWidth / ratio).clamp(0.0, maxHeight * 0.56);
}

/// 一次详情页内嵌播放的参数：播放器槽位据此建 [HaikuoPlayerView]。
class _InlinePlay {
  const _InlinePlay({
    required this.url,
    required this.title,
    required this.series,
    required this.episodes,
    required this.index,
  });

  final String url;
  final String title;
  final String series;
  final List<String> episodes;
  final int index;
}

class _HaikuoRunnerPageState extends State<HaikuoRunnerPage> {
  HttpServer? _server;
  WebViewController? _controller;
  String? _error;
  bool _loading = true;
  // 规则去广告后存下的本地 m3u8（saveFile 发来的内容），由 /__files/<名> 提供给播放器。
  final Map<String, String> _savedFiles = {};
  // 播放器在栈顶时非空：play 消息改为经它递送（切集），不再新开一页。
  HaikuoPlayerController? _playerController;
  // 正在等待切集解析结果：pending 完成（或超时）前收到的 play 消息按此核对。
  Completer<bool>? _pendingEpisodeDelivery;
  int? _pendingEpisodeIndex;
  bool _pendingEpisodeDead = false;
  // 详情页内嵌播放：非空时播放器顶在 WebView 上方，海报墙由 JS 藏起。
  _InlinePlay? _inline;
  bool _inlineFullscreen = false;
  // 内嵌视频的宽高比（videoParams 到达前默认 16:9）：槽位按它算高，
  // 竖屏视频不再被压进 16:9 槽位。
  double _inlineAspectRatio = 16 / 9;
  // 代理请求共用一个 HttpClient：连接复用（keep-alive），反复取数
  // 不再每次重建 TCP+TLS；页面关闭时才关掉。
  HttpClient? _httpClient;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    final server = _server;
    _server = null;
    unawaited(server?.close(force: true));
    _httpClient?.close(force: true);
    _httpClient = null;
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      server.listen(_handleRequest);
      if (!mounted) return;
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF120B20))
        ..addJavaScriptChannel(
          'HaikuoNative',
          onMessageReceived: _onNativeMessage,
        )
        ..loadRequest(Uri.parse('http://127.0.0.1:${server.port}/'));
      setState(() {
        _controller = controller;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  void _onNativeMessage(JavaScriptMessage message) {
    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map) return;
      payload = {
        for (final entry in decoded.entries) '${entry.key}': entry.value,
      };
    } catch (_) {
      return;
    }
    switch ('${payload['type']}') {
      case 'toast':
        _snack('${payload['text'] ?? ''}');
      case 'saveFile':
        final name = '${payload['name'] ?? ''}';
        if (name.isNotEmpty) {
          _savedFiles[name] = '${payload['content'] ?? ''}';
        }
      case 'play':
        final url = '${payload['url'] ?? ''}';
        if (url.isEmpty) return;
        final title = '${payload['title'] ?? widget.program.name}';
        final series = '${payload['series'] ?? ''}';
        final episodes = switch (payload['episodes']) {
          final List list => <String>[
            for (final e in list) '$e',
          ],
          _ => <String>[],
        };
        final index = switch (payload['index']) {
          final num n => n.toInt(),
          final String s => int.tryParse(s),
          _ => null,
        };
        final controller = _playerController;
        final route = resolvePlayRoute(
          fromDetail: payload['detail'] == true,
          playerActive: controller != null,
        );
        if (route == HaikuoPlayRoute.deliver && controller != null) {
          // 播放器已在栈顶：这是切集解析的结果，递给播放器。
          final pending = _pendingEpisodeDelivery;
          final pendingIndex = _pendingEpisodeIndex;
          if (_pendingEpisodeDead) {
            // 超时后才到的迟到解析结果：丢弃，不打扰当前播放。
            _pendingEpisodeDead = false;
            _pendingEpisodeDelivery = null;
            _pendingEpisodeIndex = null;
            return;
          }
          if (pending != null &&
              pendingIndex != null &&
              index != null &&
              index != pendingIndex) {
            // 更新的切集请求已发出，这份是过期结果，丢弃。
            return;
          }
          _pendingEpisodeDelivery = null;
          _pendingEpisodeIndex = null;
          controller.deliver(
            url: url,
            title: title,
            index: index ?? pendingIndex ?? controller.currentIndex,
          );
          if (pending != null && !pending.isCompleted) pending.complete(true);
          return;
        }
        if (route == HaikuoPlayRoute.inline) {
          _openInlinePlayer(
            url,
            title,
            episodes: episodes,
            index: index ?? 0,
            series: series,
          );
          return;
        }
        _openPlayer(
          url,
          title,
          episodes: episodes,
          index: index ?? 0,
          series: series,
        );
      case 'open':
        final url = '${payload['url'] ?? ''}';
        if (url.isEmpty) return;
        _openLink(url, '${payload['title'] ?? ''}');
    }
  }

  void _snack(String text) {
    if (!mounted || text.isEmpty) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _openPlayer(
    String url,
    String title, {
    List<String> episodes = const [],
    int index = 0,
    String series = '',
  }) async {
    final controller = HaikuoPlayerController()..currentIndex = index;
    _playerController = controller;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HaikuoPlayPage(
          url: url,
          title: title,
          seriesTitle: series,
          episodes: episodes,
          initialIndex: index,
          controller: controller,
          onSelectEpisode: _selectEpisode,
        ),
      ),
    );
    // 播放器已关闭：控制器失效，未完成的切集等待直接判失败。
    if (identical(_playerController, controller)) {
      _playerController = null;
      final pending = _pendingEpisodeDelivery;
      _pendingEpisodeDelivery = null;
      _pendingEpisodeIndex = null;
      _pendingEpisodeDead = false;
      if (pending != null && !pending.isCompleted) pending.complete(false);
    }
  }

  /// 详情页内嵌播放：播放器就地顶在 WebView 上方，海报墙由 JS 藏起，
  /// 不推新页面。切集与等待复用同一套控制器/pending 机制。
  void _openInlinePlayer(
    String url,
    String title, {
    List<String> episodes = const [],
    int index = 0,
    String series = '',
  }) {
    final controller = HaikuoPlayerController()..currentIndex = index;
    _playerController = controller;
    setState(() {
      _inline = _InlinePlay(
        url: url,
        title: title,
        series: series,
        episodes: episodes,
        index: index,
      );
      _inlineFullscreen = false;
      // 新视频的宽高比未知：先回 16:9，videoParams 到达后再按实调。
      _inlineAspectRatio = 16 / 9;
    });
    unawaited(_setInlinePlaying(true));
  }

  void _closeInlinePlayer() {
    _playerController = null;
    final pending = _pendingEpisodeDelivery;
    _pendingEpisodeDelivery = null;
    _pendingEpisodeIndex = null;
    _pendingEpisodeDead = false;
    if (pending != null && !pending.isCompleted) pending.complete(false);
    if (!mounted) return;
    setState(() {
      _inline = null;
      _inlineFullscreen = false;
    });
    unawaited(_setInlinePlaying(false));
  }

  /// 通知运行时藏起/恢复详情头项海报墙。页面还没准备好时调用
  /// 失败无妨：只是海报墙显隐，不影响播放本身。
  Future<void> _setInlinePlaying(bool on) async {
    try {
      await _controller?.runJavaScript(
        'window.__haikuoSetInlinePlaying && '
        'window.__haikuoSetInlinePlaying($on);',
      );
    } catch (_) {
      // 忽略
    }
  }

  /// 播放器点选第 [index] 集：经运行时重走该集的 lazy 解析链路，
  /// 解析出的 play 消息回流到 [_onNativeMessage] 再递给播放器。
  /// 返回解析是否在 30 秒内递达（超时返回 false，迟到结果会被丢弃）。
  Future<bool> _selectEpisode(int index) async {
    final controller = _controller;
    if (controller == null || _playerController == null) return false;
    final completer = Completer<bool>();
    _pendingEpisodeDelivery = completer;
    _pendingEpisodeIndex = index;
    _pendingEpisodeDead = false;
    try {
      await controller.runJavaScript(
        'window.__haikuoPlayEpisode && window.__haikuoPlayEpisode($index);',
      );
    } catch (_) {
      if (identical(_pendingEpisodeDelivery, completer)) {
        _pendingEpisodeDelivery = null;
        _pendingEpisodeIndex = null;
      }
      return false;
    }
    try {
      return await completer.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      if (identical(_pendingEpisodeDelivery, completer)) {
        // 保留 pending 标记为已死：迟到的解析结果到达时丢弃。
        _pendingEpisodeDead = true;
      }
      return false;
    }
  }

  Future<void> _openLink(String url, String title) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _HaikuoWebPage(url: url, title: title),
      ),
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.uri.path == '/') {
        final payload = _programPayload();
        final encoded = base64Encode(utf8.encode(jsonEncode(payload)));
        final html = haikuoRuntimeHtml
            .replaceAll('__PROGRAM_B64__', encoded)
            .replaceAll(
              '__TITLE__',
              const HtmlEscape().convert(widget.program.name),
            );
        request.response.headers.contentType = ContentType.html;
        request.response.write(html);
        await request.response.close();
        return;
      }
      if (request.uri.path == '/__fetch') {
        await _proxy(request);
        return;
      }
      if (request.uri.path.startsWith('/__files/')) {
        final name = Uri.decodeComponent(
          request.uri.path.substring('/__files/'.length),
        );
        final content = _savedFiles[name];
        if (content == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
            charset: 'utf-8',
          );
          request.response.write(content);
        }
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {
        // 连接已经断了，忽略
      }
    }
  }

  Map<String, dynamic> _programPayload() {
    final program = widget.program;
    Map<String, dynamic> rule = const {};
    if (program.rawJson.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(program.rawJson);
        if (decoded is Map) {
          rule = {
            for (final entry in decoded.entries) '${entry.key}': entry.value,
          };
        }
      } catch (_) {
        rule = const {};
      }
    }
    return {
      'name': program.name,
      'script': program.script,
      'url': program.url,
      'kind': program.kind.name,
      'rule': rule,
    };
  }

  Future<void> _proxy(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final target = params['u'] ?? '';
    final method = (params['m'] ?? 'GET').toUpperCase();
    final body = params['b'] ?? '';
    Map<String, String> headers = const {};
    final rawHeaders = params['h'];
    if (rawHeaders != null && rawHeaders.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawHeaders);
        if (decoded is Map) {
          headers = {
            for (final entry in decoded.entries)
              '${entry.key}': '${entry.value}',
          };
        }
      } catch (_) {
        headers = const {};
      }
    }
    final response = request.response;
    response.headers.contentType = ContentType.json;
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      response.write(jsonEncode({'code': 0, 'body': ''}));
      await response.close();
      return;
    }
    final merged = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
      ...headers,
    };
    try {
      // 共用客户端：同一主机的连接复用，不再每次取数都重建 TCP+TLS。
      // UA 走下面逐请求的头设置，不再写客户端默认值（多请求会互相串）。
      final client = _httpClient ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..idleTimeout = const Duration(seconds: 15);
      final uri = Uri.parse(target);
      final req = await client.openUrl(method, uri).timeout(
        const Duration(seconds: 25),
      );
      merged.forEach((key, value) {
        if (value.isEmpty) return;
        if (key.toLowerCase() == 'content-length') return;
        try {
          req.headers.set(key, value);
        } catch (_) {
          // 个别头 WebView 设置不进去，跳过
        }
      });
      if (method != 'GET' && method != 'HEAD' && body.isNotEmpty) {
        req.add(utf8.encode(body));
      }
      final resp = await req.close().timeout(const Duration(seconds: 30));
      final bytes = await resp.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
      response.write(
        jsonEncode({
          'code': resp.statusCode,
          'body': HaikuoCodec.decodeText(bytes.takeBytes()),
        }),
      );
      await response.close();
    } catch (error) {
      response.write(jsonEncode({'code': 0, 'body': '', 'error': '$error'}));
      await response.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
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
        backgroundColor: const Color(0xFF120B20),
        // 内嵌全屏时顶栏连占位高度一起藏掉，播放器真正占满屏幕；
        // 退出全屏恢复。非全屏（包括内嵌非全屏）顶栏不动。
        appBar: _inlineFullscreen
            ? null
            : AppBar(
                title: Text(widget.program.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                actions: [
                  IconButton(
                    tooltip: '刷新',
                    icon: const Icon(Icons.refresh_rounded),
                    onPressed: () => _controller?.reload(),
                  ),
                ],
              ),
        body: _error != null
            ? _RunnerError(message: _error!)
            : _loading || _controller == null
            ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(
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
                                url: inline.url,
                                title: inline.title,
                                seriesTitle: inline.series,
                                episodes: inline.episodes,
                                initialIndex: inline.index,
                                controller: _playerController,
                                onSelectEpisode: _selectEpisode,
                                fullscreen: _inlineFullscreen,
                                onFullscreenChanged: (value) => setState(
                                  () => _inlineFullscreen = value,
                                ),
                                onClose: _closeInlinePlayer,
                                onAspectRatioChanged: (ratio) => setState(
                                  () => _inlineAspectRatio = ratio,
                                ),
                              ),
                      ),
                      Expanded(child: WebViewWidget(controller: _controller!)),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

class _RunnerError extends StatelessWidget {
  const _RunnerError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 42),
            const SizedBox(height: 12),
            Text('小程序没能启动：$message', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// 外部链接页：脚本里 `open(url)` 打开普通网页时用。
class _HaikuoWebPage extends StatefulWidget {
  const _HaikuoWebPage({required this.url, required this.title});

  final String url;
  final String title;

  @override
  State<_HaikuoWebPage> createState() => _HaikuoWebPageState();
}

class _HaikuoWebPageState extends State<_HaikuoWebPage> {
  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..loadRequest(Uri.parse(widget.url));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.title.isEmpty ? widget.url : widget.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    body: WebViewWidget(controller: _controller),
  );
}

/// 海阔播放器视图：播放器本体（media_kit + PlayerControls +
/// PlayerInteractions），不带脚手架。推页播放（[HaikuoPlayPage]）与
/// 详情页内嵌播放（运行页顶部的播放器槽位）共用同一套。
/// 全屏状态由宿主持有：宿主据此决定布局与返回键行为，视图只负责
/// 上报切换意图并在值变化时落地方向/系统 UI 副作用。
class HaikuoPlayerView extends StatefulWidget {
  const HaikuoPlayerView({
    super.key,
    required this.url,
    required this.title,
    this.seriesTitle = '',
    this.episodes = const [],
    this.initialIndex = 0,
    this.controller,
    this.onSelectEpisode,
    this.headers = const {},
    this.onStateChange,
    required this.fullscreen,
    required this.onFullscreenChanged,
    this.onClose,
    this.onCurrentChanged,
    this.onAspectRatioChanged,
    this.orientationMode = PlaybackOrientationMode.auto,
    this.playerFactory,
    this.videoBuilder,
  });

  final String url;
  final String title;

  /// 剧名（详情头项标题），有则显示在顶栏标题前。
  final String seriesTitle;

  /// 当前详情的全部选集标题（按序），为空表示只有一个可播地址。
  final List<String> episodes;

  final int initialIndex;
  final HaikuoPlayerController? controller;

  /// 点选第 index 集时调用：回到运行页解析该集地址，返回是否按时递达。
  final Future<bool> Function(int index)? onSelectEpisode;

  /// 取流请求头（蜘蛛回的 header 原样带上，如 Referer/UA）。
  final Map<String, String> headers;

  /// 播放状态变化回调（小程序播放桥用）：每次播/停切换与整秒
  /// 进度变化时上报 {opened, url, title, playing, positionMs,
  /// durationMs}；不传则不上报。
  final ValueChanged<Map<String, dynamic>>? onStateChange;

  /// 是否全屏：宿主持有并据此布局。
  final bool fullscreen;

  /// 全屏切换意图：点全屏/返回键退出全屏时上报，宿主改值后视图跟随。
  final ValueChanged<bool> onFullscreenChanged;

  /// 非全屏时点返回：传了就调它（内嵌播放关闭播放器），不传则退栈。
  final VoidCallback? onClose;

  /// 当前集/标题变化时通知宿主（播放页下方的选集条据此高亮）。
  final void Function(int index, String title)? onCurrentChanged;

  /// 视频宽高比变化时通知宿主（宿主据此调整非全屏槽位高度，
  /// 竖屏视频不再被压进 16:9 槽位）。未知时不报，宿主用默认 16:9。
  final ValueChanged<double>? onAspectRatioChanged;

  /// 全屏方向模式：与主播放器同一套设置（自动跟视频方向/强制
  /// 竖屏/强制横屏）。默认自动：竖屏视频全屏进竖屏、横屏进横屏。
  final PlaybackOrientationMode orientationMode;

  /// 测试注入播放器：默认直接 new Player()。
  final Player Function()? playerFactory;

  /// 测试注入视频画面：默认真实 Video + VideoController；传了它
  /// 就不建 VideoController（假播放器没有平台 handle）。
  final WidgetBuilder? videoBuilder;

  @override
  State<HaikuoPlayerView> createState() => _HaikuoPlayerViewState();
}

/// 媒体播放页：海阔小程序返回直链（m3u8 / mp4）时用它播。
/// 海阔规则播放页：复用点播区同一套控件层（PlayerControls +
/// PlayerInteractions），带选集面板、倍速、前后集、全屏、网速显示。
/// 选集上下文由运行时随 play 消息带上；切集时经 [onSelectEpisode] 回到
/// 运行页重走该集的 lazy 解析，解析出的地址由 [controller] 递回本页。
class HaikuoPlayPage extends StatefulWidget {
  const HaikuoPlayPage({
    super.key,
    required this.url,
    required this.title,
    this.seriesTitle = '',
    this.episodes = const [],
    this.initialIndex = 0,
    this.controller,
    this.onSelectEpisode,
    this.headers = const {},
    this.onStateChange,
    this.orientationMode = PlaybackOrientationMode.auto,
    this.playerFactory,
    this.videoBuilder,
  });

  final String url;
  final String title;

  /// 剧名（详情头项标题），有则显示在顶栏标题前。
  final String seriesTitle;

  /// 当前详情的全部选集标题（按序），为空表示只有一个可播地址。
  final List<String> episodes;

  final int initialIndex;
  final HaikuoPlayerController? controller;

  /// 点选第 index 集时调用：回到运行页解析该集地址，返回是否按时递达。
  final Future<bool> Function(int index)? onSelectEpisode;

  /// 取流请求头（蜘蛛回的 header 原样带上，如 Referer/UA）。
  final Map<String, String> headers;

  /// 播放状态变化回调（小程序播放桥用）：每次播/停切换与整秒
  /// 进度变化时上报 {opened, url, title, playing, positionMs,
  /// durationMs}；不传则不上报。
  final ValueChanged<Map<String, dynamic>>? onStateChange;

  /// 全屏方向模式：与主播放器同一套设置，默认自动跟视频方向。
  final PlaybackOrientationMode orientationMode;

  /// 测试注入播放器：默认直接 new Player()。
  final Player Function()? playerFactory;

  /// 测试注入视频画面：默认真实 Video + VideoController。
  final WidgetBuilder? videoBuilder;

  @override
  State<HaikuoPlayPage> createState() => _HaikuoPlayPageState();
}

class _HaikuoPlayerViewState extends State<HaikuoPlayerView> {
  static const List<double> _speeds = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
    3.0,
  ];

  late final Player _player = widget.playerFactory?.call() ?? Player();
  late final VideoController _video = VideoController(_player);
  late final PlayerInteractions _interactions = PlayerInteractions(
    player: _player,
    available: () => mounted && _error == null && !_panel,
    baseSpeed: () => _speed,
    onTogglePlayback: _togglePlayback,
    onFullscreen: _toggleFullscreen,
    onEpisode: _episodeHint,
    onSeek: (duration) => _player.seek(duration),
  );
  late final NetworkSpeedTracker _speedTracker = NetworkSpeedTracker(
    sample: () => fetchMpvNetworkSpeedSample(_player),
  );
  final FocusNode _focus = FocusNode();
  AppOrientationController? _orientation;
  StreamSubscription<String>? _errorSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<VideoParams>? _videoParamsSubscription;
  int _lastReportedSecond = -1;
  bool _lastReportedPlaying = false;

  late String _url = widget.url;
  late String _title = widget.title;
  late int _index = widget.initialIndex;
  // 视频宽高比：videoParams 到达前默认 16:9（与旧槽位一致），
  // 到达后按真实尺寸算，竖屏视频全屏进竖屏、槽位按比例加高。
  double _aspectRatio = 16 / 9;
  double _speed = 1.0;
  String? _error;
  bool _resolving = false;
  bool _panel = false;

  bool get _hasEpisodes => widget.episodes.isNotEmpty;
  bool get _hasPrev => _hasEpisodes && _index > 0;
  bool get _hasNext => _hasEpisodes && _index < widget.episodes.length - 1;

  String get _displayTitle {
    final series = widget.seriesTitle;
    if (series.isEmpty) return _title;
    if (_title.isEmpty || _title == series) return series;
    return '$series · $_title';
  }

  @override
  void initState() {
    super.initState();
    if (_index < 0 || _index >= widget.episodes.length) _index = 0;
    widget.controller?.onDeliver = _onDelivered;
    widget.controller?.onRequestEpisode = _switchEpisode;
    _errorSubscription = _player.stream.error.listen((error) {
      if (!mounted || _error != null) return;
      setState(() => _error = error);
    });
    _positionSubscription = _player.stream.position.listen((_) {
      unawaited(_speedTracker.tick());
      _reportState();
    });
    _completedSubscription = _player.stream.completed.listen((completed) {
      if (completed && _hasNext) _switchEpisode(_index + 1);
    });
    _playingSubscription = _player.stream.playing.listen((_) {
      _reportState();
    });
    _videoParamsSubscription = _player.stream.videoParams.listen((params) {
      final size = videoDisplaySize(params);
      if (size == null || !mounted) return;
      final ratio = size.width / size.height;
      if (ratio <= 0 || !ratio.isFinite || ratio == _aspectRatio) return;
      final wasLandscape = _aspectRatio >= 1;
      setState(() => _aspectRatio = ratio);
      widget.onAspectRatioChanged?.call(ratio);
      // 横竖边翻了、且正在全屏：重落方向，竖屏视频不再被锁横屏。
      if (widget.fullscreen && wasLandscape != (ratio >= 1)) {
        unawaited(_applyFullscreen(true));
      }
    });
    _open();
  }

  /// 给 onStateChange 上报当前状态：播/停切换必报，进度只在整秒
  /// 变化时报，避免每帧刷回调。
  void _reportState() {
    final report = widget.onStateChange;
    if (report == null || !mounted) return;
    final state = _player.state;
    final second = state.position.inSeconds;
    if (second == _lastReportedSecond && state.playing == _lastReportedPlaying) {
      return;
    }
    _lastReportedSecond = second;
    _lastReportedPlaying = state.playing;
    report(<String, dynamic>{
      'opened': true,
      'url': _url,
      'title': _displayTitle,
      'playing': state.playing,
      'positionMs': state.position.inMilliseconds,
      'durationMs': state.duration.inMilliseconds,
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _orientation ??= AppOrientationScope.maybeOf(context);
  }

  @override
  void didUpdateWidget(HaikuoPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fullscreen != oldWidget.fullscreen) {
      unawaited(_applyFullscreen(widget.fullscreen));
    }
  }

  @override
  void dispose() {
    widget.controller?.onDeliver = null;
    widget.controller?.onRequestEpisode = null;
    unawaited(_errorSubscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    unawaited(_completedSubscription?.cancel());
    unawaited(_playingSubscription?.cancel());
    unawaited(_videoParamsSubscription?.cancel());
    _interactions.dispose();
    _speedTracker.dispose();
    _focus.dispose();
    unawaited(_player.dispose());
    unawaited(_orientation?.releasePlayback(this) ?? Future<void>.value());
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _open() async {
    try {
      await _player.open(Media(_url, httpHeaders: widget.headers));
      await _player.setRate(_speed);
      _reportState();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  void _onDelivered({
    required String url,
    required String title,
    required int index,
  }) {
    if (!mounted) return;
    setState(() {
      _url = url;
      _title = title;
      _index = index;
      _resolving = false;
      _error = null;
    });
    widget.onCurrentChanged?.call(index, title);
    unawaited(_open());
  }

  Future<void> _togglePlayback() async {
    await _player.playOrPause();
  }

  Future<void> _seekTo(Duration position) async {
    await _player.seek(position);
  }

  // 全屏状态由宿主持有：这里只上报切换意图，方向与系统 UI 的
  // 副作用在 didUpdateWidget 收到新值后由 _applyFullscreen 落地；
  // 视图在全屏中被直接卸载时，dispose 里的 releasePlayback 兜底。
  Future<void> _toggleFullscreen() async {
    widget.onFullscreenChanged(!widget.fullscreen);
  }

  Future<void> _applyFullscreen(bool fullscreen) async {
    // 方向跟视频真实宽高比（与主播放器一致）：竖屏视频全屏进竖屏，
    // 横屏进横屏；以前写死 16:9，竖屏视频一律被锁横屏。
    if (fullscreen) {
      await _orientation?.setPlayback(
        this,
        fullscreen: true,
        aspectRatio: _aspectRatio,
        mode: widget.orientationMode,
      );
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await _orientation?.setPlayback(
        this,
        fullscreen: false,
        aspectRatio: _aspectRatio,
        mode: widget.orientationMode,
      );
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _back() {
    if (widget.fullscreen) {
      widget.onFullscreenChanged(false);
      return;
    }
    final close = widget.onClose;
    if (close != null) {
      close();
      return;
    }
    Navigator.of(context).maybePop();
  }

  /// 上下滑动切集手势的提示：direction 为 +1（下一集）/-1（上一集）。
  String _episodeHint(int direction) {
    final target = _index + direction;
    if (!_hasEpisodes) return '没有更多剧集';
    if (target < 0) return '已经是第一集';
    if (target >= widget.episodes.length) return '已经是最后一集';
    if (target == _index) return widget.episodes[target];
    unawaited(_switchEpisode(target));
    return '正在切换到${widget.episodes[target]}';
  }

  Future<void> _switchEpisode(int index) async {
    final select = widget.onSelectEpisode;
    if (_resolving || select == null) return;
    if (index < 0 || index >= widget.episodes.length) return;
    if (index == _index) return;
    setState(() => _resolving = true);
    final ok = await select(index);
    if (!mounted) return;
    if (!ok) {
      setState(() => _resolving = false);
      _toast('解析超时，请重试');
    }
    // 解析成功时地址经 controller 递回 _onDelivered，那里清 _resolving。
  }

  void _toast(String text) {
    if (!mounted || text.isEmpty) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _showEpisodes() async {
    if (!_hasEpisodes) {
      _toast('该内容只有一个可播地址');
      return;
    }
    setState(() => _panel = true);
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.seriesTitle.isEmpty
                          ? '选集'
                          : widget.seriesTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${widget.episodes.length} 集',
                    style: const TextStyle(color: Colors.white54),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.episodes.length,
                itemBuilder: (context, i) {
                  final current = i == _index;
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      current ? Icons.play_arrow : Icons.play_circle_outline,
                      color: current ? Colors.orangeAccent : Colors.white70,
                    ),
                    title: Text(
                      widget.episodes[i],
                      style: TextStyle(
                        color: current ? Colors.orangeAccent : Colors.white,
                      ),
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(i),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _panel = false);
    if (selected != null) unawaited(_switchEpisode(selected));
  }

  Future<void> _showSpeed() async {
    setState(() => _panel = true);
    final selected = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '倍速',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final rate in _speeds)
                    ListTile(
                      dense: true,
                      title: Text(
                        '${rate}x',
                        style: TextStyle(
                          color: rate == _speed
                              ? Colors.orangeAccent
                              : Colors.white,
                        ),
                      ),
                      trailing: rate == _speed
                          ? const Icon(
                              Icons.check,
                              color: Colors.orangeAccent,
                            )
                          : null,
                      onTap: () => Navigator.of(sheetContext).pop(rate),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _panel = false);
    if (selected == null) return;
    setState(() => _speed = selected);
    await _player.setRate(selected);
  }

  Widget _videoArea() {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.videoBuilder?.call(context) ??
            Video(
              controller: _video,
              fit: BoxFit.contain,
              controls: (_) => const SizedBox.shrink(),
            ),
        if (_error != null)
          Container(
            color: Colors.black54,
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '播放失败：$_error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () {
                      setState(() => _error = null);
                      unawaited(_open());
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          )
        else if (_resolving)
          const ColoredBox(
            color: Colors.black45,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('正在解析…', style: TextStyle(color: Colors.white70)),
                ],
              ),
            ),
          ),
        if (_error == null)
          Focus(
            focusNode: _focus,
            child: PlayerControls(
              player: _player,
              interactions: _interactions,
              enabled: !_resolving,
              panelOpen: _panel,
              fullscreen: widget.fullscreen,
              showOnPlaybackReady: false,
              title: _displayTitle,
              onTogglePlayback: _togglePlayback,
              swipeEnabled: true,
              onFullscreen: _toggleFullscreen,
              onBack: _back,
              onFocusSurface: _focus.requestFocus,
              onSeek: _seekTo,
              speed: _speed,
              networkSpeed: _speedTracker.speedText,
              qualityLabel: '默认',
              onEpisodes: _showEpisodes,
              onSpeed: _showSpeed,
              onQuality: () async => _toast('该站点只提供一种清晰度'),
              onPrevious: _hasPrev ? () => _switchEpisode(_index - 1) : null,
              onNext: _hasNext ? () => _switchEpisode(_index + 1) : null,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => _videoArea();
}

class _HaikuoPlayPageState extends State<HaikuoPlayPage> {
  bool _fullscreen = false;
  // 视频宽高比（videoParams 到达前默认 16:9）：槽位按它算高。
  double _aspectRatio = 16 / 9;
  late int _currentIndex = _clampIndex(widget.initialIndex);
  late String _currentTitle = widget.title;

  int _clampIndex(int value) {
    if (value < 0 || value >= widget.episodes.length) return 0;
    return value;
  }

  bool get _hasEpisodes => widget.episodes.isNotEmpty;

  String get _displayTitle {
    final series = widget.seriesTitle;
    if (series.isEmpty) return _currentTitle;
    if (_currentTitle.isEmpty || _currentTitle == series) return series;
    return '$series · $_currentTitle';
  }

  Widget _playerView() {
    return HaikuoPlayerView(
      url: widget.url,
      title: widget.title,
      seriesTitle: widget.seriesTitle,
      episodes: widget.episodes,
      initialIndex: widget.initialIndex,
      controller: widget.controller,
      onSelectEpisode: widget.onSelectEpisode,
      headers: widget.headers,
      onStateChange: widget.onStateChange,
      fullscreen: _fullscreen,
      onFullscreenChanged: (value) => setState(() => _fullscreen = value),
      onCurrentChanged: (index, title) => setState(() {
        _currentIndex = index;
        _currentTitle = title;
      }),
      onAspectRatioChanged: (ratio) => setState(() => _aspectRatio = ratio),
      orientationMode: widget.orientationMode,
      playerFactory: widget.playerFactory,
      videoBuilder: widget.videoBuilder,
    );
  }

  Widget _belowVideo() {
    if (!_hasEpisodes) {
      return const SizedBox.shrink();
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _displayTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < widget.episodes.length; i++)
                ChoiceChip(
                  label: Text(widget.episodes[i]),
                  selected: i == _currentIndex,
                  // 经控制器请播放器视图切集，复用视图的解析等待与防重入。
                  onSelected: (_) => widget.controller?.requestEpisode(i),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _fullscreen = false);
      },
      child: Theme(
        data: AppTheme.dark,
        child: Scaffold(
          backgroundColor: Colors.black,
          // 播放器视图固定在 Column 第 0 位、只改槽位高度，
          // 全屏切换不换树位置，Player 不重建、不重播。
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Column(
                  children: [
                    SizedBox(
                      height: _fullscreen
                          ? constraints.maxHeight
                          : haikuoSlotHeight(
                              aspectRatio: _aspectRatio,
                              maxWidth: constraints.maxWidth,
                              maxHeight: constraints.maxHeight,
                            ),
                      child: _playerView(),
                    ),
                    if (!_fullscreen) Expanded(child: _belowVideo()),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
