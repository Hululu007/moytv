import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:enough_convert/enough_convert.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../app_build.dart';
import '../../app_orientation.dart';
import '../../app_theme.dart';
import '../../network_speed.dart';
import '../../nonvideo_content.dart';
import '../../playback_preferences.dart';
import '../../player_controls.dart';
import '../../player_interactions.dart';
import '../../video_output_size.dart';
import 'haikuo_codec.dart';
import 'haikuo_cloud6.dart';
import 'haikuo_danmu.dart';
import 'haikuo_helpers.dart';
import 'haikuo_paste_bridge.dart';
import 'haikuo_program.dart';
import 'haikuo_runtime_html.dart';
import 'haikuo_store.dart';
import 'haikuo_zip_import.dart';

/// 海阔小程序运行页。
///
/// 脚本放在本地 HTTP 服务里跑（和内置小程序容器同一套思路）：
/// 页面同源，脚本里的同步 `fetch()` 才能打到 `/__fetch` 由 Dart 侧代理，
/// 绕开 WebView 的跨域限制；点条目时用通道回到原生，媒体地址直接进播放器。
class HaikuoRunnerPage extends StatefulWidget {
  const HaikuoRunnerPage({
    super.key,
    required this.program,
    this.initialSearchKeyword,
    this.initialDetailUrl,
    this.initialShowSearch = false,
  });

  final HaikuoProgram program;

  /// 打开后自动跑一次搜索（跨规则 hiker://search 的 rule 参数用）。
  final String? initialSearchKeyword;

  /// 打开后自动进详情（跨规则打开条目用）。
  final String? initialDetailUrl;

  /// 打开后直接展开搜索栏（长按操作表“搜索内容”用）：只展开，不跑搜索。
  final bool initialShowSearch;

  @override
  State<HaikuoRunnerPage> createState() => _HaikuoRunnerPageState();
}

/// 播放 JSON 的一条线路：名 + 地址 + 该条专用的头。
/// JS 侧 `sendPlay` 组装 `payload.lines` 时下标对齐，缺名已补默认名。
class HaikuoPlayLine {
  const HaikuoPlayLine({
    required this.name,
    required this.url,
    this.headers = const {},
  });

  final String name;
  final String url;
  final Map<String, String> headers;

  @override
  bool operator ==(Object other) =>
      other is HaikuoPlayLine &&
      other.name == name &&
      other.url == url &&
      mapEquals(other.headers, headers);

  @override
  int get hashCode => Object.hash(name, url, headers);

  @override
  String toString() => 'HaikuoPlayLine($name, $url)';
}

/// 解析 play 消息的 `lines` 字段：缺省/空/无有效地址时回落为
/// 单条（名为空串、地址与头取 play 消息的主字段），行为与旧版一致。
List<HaikuoPlayLine> parseHaikuoPlayLines(
  Object? raw, {
  required String fallbackUrl,
  required Map<String, String> fallbackHeaders,
}) {
  final fallback = [
    HaikuoPlayLine(name: '', url: fallbackUrl, headers: fallbackHeaders),
  ];
  if (raw is! List || raw.isEmpty) return fallback;
  final lines = <HaikuoPlayLine>[];
  for (var i = 0; i < raw.length; i++) {
    final entry = raw[i];
    if (entry is! Map) continue;
    final url = '${entry['url'] ?? ''}';
    if (url.isEmpty) continue;
    final name = '${entry['name'] ?? ''}';
    final headers = switch (entry['headers']) {
      final Map map => <String, String>{
        for (final e in map.entries) '${e.key}': '${e.value}',
      },
      _ => const <String, String>{},
    };
    lines.add(
      HaikuoPlayLine(
        name: name.isEmpty ? '线路${i + 1}' : name,
        url: url,
        headers: headers,
      ),
    );
  }
  return lines.isEmpty ? fallback : lines;
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
    String subtitleUrl,
    Map<String, String> headers,
    List<HaikuoPlayLine> lines,
    String danmuUrl,
  })?
  onDeliver;

  /// 播放器视图登记的切集入口（视图初始化时登记、销毁时清空）。
  Future<void> Function(int index)? onRequestEpisode;

  int currentIndex = 0;

  void deliver({
    required String url,
    required String title,
    required int index,
    String subtitleUrl = '',
    Map<String, String> headers = const {},
    List<HaikuoPlayLine> lines = const [],
    String danmuUrl = '',
  }) {
    currentIndex = index;
    onDeliver?.call(
      url: url,
      title: title,
      index: index,
      subtitleUrl: subtitleUrl,
      headers: headers,
      lines: lines,
      danmuUrl: danmuUrl,
    );
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

/// 小程序播放消息的内容分流：小说进阅读视图、图片集进图片浏览，
/// 其余进视频播放器。判定只认规则实际返回的 novel:// 与 pics://
/// 载荷（与壳内其它区同一解析函数），不按扩展名猜。
enum HaikuoPlayContent { video, novel, pics }

HaikuoPlayContent classifyHaikuoPlayContent(String url) {
  final content = parseNonVideoUrl(url);
  if (content == null) return HaikuoPlayContent.video;
  return content.isNovel ? HaikuoPlayContent.novel : HaikuoPlayContent.pics;
}

/// 跟随重定向后的最终地址：按重定向链逐级解析（Dart 的
/// HttpClientResponse.redirects 只记每次跳转的 location）。
Uri haikuoResolveFinalUri(Uri original, Iterable<Uri> redirectLocations) {
  var current = original;
  for (final location in redirectLocations) {
    current = current.resolve(location.toString());
  }
  return current;
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
  final ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9;
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
    this.subtitleUrl = '',
    this.headers = const {},
    this.lines = const [],
    this.danmuUrl = '',
  });

  final String url;
  final String title;
  final String series;
  final List<String> episodes;
  final int index;

  /// 条目自带的字幕地址（没有就是空串，播放器不加载字幕）。
  final String subtitleUrl;

  /// 取流请求头（播放 JSON / lazy 结果里带的 headers 原样传播放器）。
  final Map<String, String> headers;

  /// 多线路表（播放 JSON 的 urls/names；空表示只有单条地址）。
  final List<HaikuoPlayLine> lines;

  /// 弹幕地址（播放 JSON 的 danmu；空串表示无弹幕）。
  final String danmuUrl;
}

/// 一次排队中的原生对话框请求：JS 同步 XHR 等着 completer 的结果。
class _PendingDialog {
  const _PendingDialog(this.params, this.completer);

  final Map<String, String> params;
  final Completer<Map<String, dynamic>> completer;
}

/// 一次嗅探会话的参数与状态。
class _SniffSession {
  _SniffSession({
    required this.id,
    required this.url,
    required this.js,
    required this.mode,
    required this.videoRules,
    required this.excludeRules,
    required this.blockRules,
    required this.ua,
    required this.referer,
    required this.deadline,
    this.pageJs = '',
  });

  final String id;
  final String url;
  final String js;
  final String mode;
  final List<String> videoRules;
  final List<String> excludeRules;
  final List<String> blockRules;
  final String ua;
  final String referer;
  final DateTime deadline;

  /// video 模式下页面加载完跑一次的注入脚本（extra.js 形态）。
  final String pageJs;

  bool done = false;
  bool pageJsDone = false;
}

/// G11 原生 x5 行的会话：JS 侧 `x5RowHtml` 发来的整行配置。
/// 字段可变——同一 controller 在页面切换/重渲染时复用，只更新
/// 配置（URL 变了才重载）；NavigationDelegate 闭包捕获同一对象，
/// 配置更新后拦截/注入自动用新值。
class _X5RowSession {
  _X5RowSession({
    required this.url,
    required this.desc,
    required this.ua,
    required this.referer,
    required this.js,
    required this.jsLoadingInject,
    required this.blockRules,
    required this.urlInterceptor,
    required this.canBack,
    required this.floatVideo,
    required this.showProgress,
    required this.index,
    required this.topOffset,
  });

  /// 行地址（首载地址；行内导航后 [currentUrl] 才变）。
  String url;

  /// desc 原串（高度/模式换算在 build 时经 [haikuoX5RowLayout] 做）。
  String desc;

  /// extra.ua（空串/缺失 = 不调 setUserAgent；只认 ua 键）。
  String ua;

  /// extra.referer（首载 Referer 头；0 条规则用，预留一行）。
  String referer;

  /// extra.js：每次加载完都跑一遍的注入代码。
  String js;

  /// extra.jsLoadingInject：为 true 时加载开始也注入一次（跑两次）。
  bool jsLoadingInject;

  /// extra.blockRules（归一后的非空规则表）：导航级拦截。
  List<String> blockRules;

  /// extra.urlInterceptor：规则上下文求值的拦截代码（IIFE 串）。
  String urlInterceptor;

  /// extra.canBack：返回键先退行内历史。
  bool canBack;

  /// extra.floatVideo：W6 悬浮嗅探播放的门（严格 true 才开；
  /// false/缺失时零行为，与 W5 完工态一致）。
  bool floatVideo;

  /// extra.showProgress：false 藏进度条（默认显示）。
  bool showProgress;

  /// 行下标（JS 侧条目 index，原样透传，暂只作调试用）。
  int index;

  /// JS 侧实测的规则顶栏高（CSS px；0 = 测不到，布局回落 48）。
  double topOffset;

  /// 当前页地址（onPageStarted/onPageFinished 更新，取 Cookie 用）。
  String currentUrl = '';

  /// 是否在界面上显示（x5rowClear 只藏不毁，复用 controller）。
  bool visible = true;

  /// 加载进度 0–100（onProgress 维护，showProgress 时画进度条）。
  int progress = 0;

  /// 下一个主框导航是本次 loadRequest 的首载：跳过拦截器求值
  /// （拦截器只拦行内跳转，不拦行自身的加载）。
  bool expectInitialNavigation = true;

  /// 页内桥 hideLoading 已请求：进度条不再显示。
  bool hideLoadingRequested = false;
}

class _HaikuoRunnerPageState extends State<HaikuoRunnerPage>
    with WidgetsBindingObserver {
  HttpServer? _server;
  WebViewController? _controller;
  String? _error;
  bool _loading = true;
  // 规则存下的本地文件（saveFile 发来的内容），由 /__files/<名> 提供
  // 给播放器与运行时。字节存，内容类型按扩展名定。
  final Map<String, Uint8List> _savedFiles = {};
  // E33 会话变量表（静态，随进程生死，全部规则页共享；绝不写盘）。
  static final HaikuoSessionVars _sessionVars = HaikuoSessionVars();
  // 本次运行页的 Cookie 罐：代理取数时自动带上同主机 Cookie，
  // 响应里的 Set-Cookie 也存进来；规则的 getCookie/setCookie 读写它。
  final HaikuoCookieJar _cookieJar = HaikuoCookieJar();
  // 规则 proxy 字段归一后的代理地址（没有就是 null）。
  String? _ruleProxy;
  // 搜索栏：显示与否 + 预填关键词；nonce 让每次打开都重建输入框。
  bool _showSearch = false;
  String _searchKeyword = '';
  int _searchNonce = 0;
  // 原生对话框排队：JS 同步 XHR 一次只放一个对话框，用户点完才
  // 处理下一个；页面关了，排队的按默认结果回掉。
  final List<_PendingDialog> _dialogQueue = [];
  bool _dialogBusy = false;
  // 嗅探会话：隐藏 WebView + 轮询定时器，同一时间只跑一个。
  _SniffSession? _sniffSession;
  WebViewController? _sniffController;
  Timer? _sniffTimer;
  // 播放器在栈顶时非空：play 消息改为经它递送（切集），不再新开一页。
  HaikuoPlayerController? _playerController;
  // 正在等待切集解析结果：pending 完成（或超时）前收到的 play 消息按此核对。
  Completer<bool>? _pendingEpisodeDelivery;
  int? _pendingEpisodeIndex;
  bool _pendingEpisodeDead = false;
  // 详情页内嵌播放：非空时播放器顶在 WebView 上方，海报墙由 JS 藏起。
  _InlinePlay? _inline;
  bool _inlineFullscreen = false;
  // 页面级沉浸（#fullTheme#/#gameTheme#，JS 经 setPageImmersive 消息
  // 告知）：与播放器 _inlineFullscreen 取“或”决定系统 UI 模式与
  // SafeArea，两者状态各自独立、互不干扰。
  bool _pageImmersive = false;
  // 内嵌视频的宽高比（videoParams 到达前默认 16:9）：槽位按它算高，
  // 竖屏视频不再被压进 16:9 槽位。
  double _inlineAspectRatio = 16 / 9;
  // 代理请求共用一个 HttpClient：连接复用（keep-alive），反复取数
  // 不再每次重建 TCP+TLS；页面关闭时才关掉。
  HttpClient? _httpClient;
  // 规则库（跨规则取页/收藏/历史/导入用，默认自给自足）。
  final HaikuoStore _store = HaikuoStore();
  // 初始搜索/详情只触发一次（页面加载完成时）。
  bool _initialActionDone = false;
  // 预置模块清单缓存（/__files/ 回退用）与文件字节缓存。
  Map<String, List<String>>? _presetManifest;
  final Map<String, Uint8List> _presetModuleCache = {};
  // 备份导入的规则私有文件缓存（规则标题 + 文件名 → 字节），
  // 与 _presetModuleCache 同一生：当次运行页会话内有效。
  final Map<String, Uint8List> _ruleFileCache = {};
  // fetchCodeByWebView 用的隐藏 WebView：独立槽位，请求结束卸载。
  WebViewController? _webviewFetchController;
  // G11 原生 x5 行：独立槽位（同 _sniffSession/_webviewFetchController
  // 的槽位模式），页面切换/重渲染复用同一 controller，只换 URL；
  // 规则页销毁时随 state 一起丢掉（WebViewController 无 dispose）。
  WebViewController? _x5RowController;
  _X5RowSession? _x5RowSession;
  // 原生 x5 行当前是否可后退（canBack 且行内有历史且行可见）：
  // 系统返回键与规则顶栏返回键都看它，由 _updateX5CanGoBack 维护。
  bool _x5CanGoBack = false;
  // urlInterceptor 求值串行链：导航决策须同步等待规则求值，且
  // 求值时 input 的存取不可交错（参照 /__dialog 排队模式）。
  Future<void> _x5InterceptorChain = Future<void>.value();
  // 页内桥只写变量的操作串行链：连续写同一键时按发送序处理。
  Future<void> _x5VarChain = Future<void>.value();
  // W6 floatVideo 悬浮嗅探播放：只在当前行 extra.floatVideo===true
  // 时轮询；检出后弹悬浮播放层并暂停页内视频；任一环节失败静默
  // 回落只显示网页（W5 行为）。定时器与检出状态随行/页导航重置。
  Timer? _floatVideoTimer;
  String _floatVideoUrl = '';
  _X5RowSession? _floatVideoSession;
  bool _floatVideoDismissed = false;
  bool _floatVideoTickBusy = false;
  int _floatVideoFailures = 0;
  bool _floatVideoFullscreen = false;
  // floatVideo 代次：每次重置 +1；在途求值回包时凭它认出旧页结果，
  // 不得把导航前一页的资源地址弹到新页上。
  int _floatVideoGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.initialShowSearch) {
      _showSearch = true;
      _searchNonce++;
    }
    _start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // 切后台：嗅探与悬浮视频轮询都停掉，不在后台每 250ms 跨桥跑 JS。
      // 会话本身留着（_sniffSession 不清），回前台再续上；
      // 30 秒死线已过的话，下一拍 _sniffTick 会自行按失败回掉。
      _sniffTimer?.cancel();
      _sniffTimer = null;
      _stopFloatVideoPolling();
    } else if (state == AppLifecycleState.resumed) {
      final session = _sniffSession;
      if (session != null && !session.done && _sniffTimer == null) {
        _sniffTimer = Timer.periodic(
          const Duration(milliseconds: 250),
          (_) => unawaited(_sniffTick(session)),
        );
      }
      _syncFloatVideoPolling();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sniffTimer?.cancel();
    _sniffTimer = null;
    _sniffSession = null;
    _sniffController = null;
    _stopFloatVideoPolling();
    _floatVideoUrl = '';
    _floatVideoSession = null;
    _floatVideoDismissed = false;
    _floatVideoFullscreen = false;
    _x5RowSession = null;
    _x5RowController = null;
    _x5CanGoBack = false;
    // 页面级沉浸退出时强制恢复状态栏（与播放器 dispose 同款兜底）。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    for (final pending in _dialogQueue) {
      if (!pending.completer.isCompleted) {
        pending.completer.complete(_dialogDefault(pending.params));
      }
    }
    _dialogQueue.clear();
    final server = _server;
    _server = null;
    unawaited(server?.close(force: true));
    _httpClient?.close(force: true);
    _httpClient = null;
    super.dispose();
  }

  Future<void> _start() async {
    try {
      // 固定端口优先：WebView 的源（origin）稳定，localStorage 里的
      // 规则变量/存储/远程模块缓存才能跨重启留下来；端口被占时顺延，
      // 都占了才回落随机端口（那次会话里存储只活当次）。
      HttpServer? server;
      for (var port = 18081; port <= 18090; port++) {
        try {
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
          break;
        } catch (_) {
          // 被占了，试下一个
        }
      }
      server ??= await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      // fileSelect:// 挑过的文件副本（_fileSelect_ 前缀）：下次启动清理。
      unawaited(_cleanupFileSelectCopies());
      final payload = _programPayload();
      final ruleMap = payload['rule'];
      _ruleProxy = parseHaikuoProxy(
        ruleMap is Map ? ruleMap['proxy']?.toString() : null,
      );
      server.listen(_handleRequest);
      if (!mounted) return;
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFF120B20))
        ..setNavigationDelegate(
          NavigationDelegate(onPageFinished: (_) => _runInitialAction()),
        )
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

  /// 初始动作（跨规则打开时带进来的搜索/详情）：页面加载完成
  /// 后只跑一次，详情优先于搜索。
  Future<void> _runInitialAction() async {
    if (_initialActionDone) return;
    _initialActionDone = true;
    final detailUrl = widget.initialDetailUrl;
    final keyword = widget.initialSearchKeyword;
    if ((detailUrl == null || detailUrl.isEmpty) &&
        (keyword == null || keyword.isEmpty)) {
      return;
    }
    // 等运行时 boot 完成（规则首页已跑起来）再触发。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    try {
      if (detailUrl != null && detailUrl.isNotEmpty) {
        await _controller?.runJavaScript(
          'window.__haikuoOpenDetail && window.__haikuoOpenDetail('
          '${jsonEncode(detailUrl)});',
        );
      } else if (keyword != null && keyword.isNotEmpty) {
        await _runSearch(keyword);
      }
    } catch (_) {
      // 页面已不在，忽略
    }
  }

  /// 清理上次 fileSelect:// 挑文件时留下的 _fileSelect_ 副本。
  Future<void> _cleanupFileSelectCopies() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/haikuo/fileSelect');
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        final name = entity.path.split('/').last;
        if (name.startsWith('_fileSelect_') && entity is File) {
          await entity.delete();
        }
      }
    } catch (_) {
      // 清理失败不影响运行
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
      case 'copy':
        unawaited(
          Clipboard.setData(ClipboardData(text: '${payload['text'] ?? ''}')),
        );
        _snack('已复制');
      case 'saveFile':
        final name = '${payload['name'] ?? ''}';
        if (name.isNotEmpty) {
          unawaited(
            _storeSavedFile(
              name,
              Uint8List.fromList(utf8.encode('${payload['content'] ?? ''}')),
            ),
          );
        }
      case 'deleteFile':
        final name = '${payload['name'] ?? ''}';
        if (name.isNotEmpty) {
          unawaited(_deleteSavedFile(name));
        }
      case 'download':
      case 'downloadFile':
        final url = '${payload['url'] ?? ''}';
        if (url.isNotEmpty) {
          unawaited(_downloadToDocs(url, '${payload['name'] ?? ''}'));
        }
      case 'saveImage':
        // 按 urls 顺序逐个尝试，存下一个就停（回退链）。
        final urls = switch (payload['urls']) {
          final List list => <String>[for (final e in list) '$e'],
          _ => <String>[],
        };
        final single = '${payload['url'] ?? ''}';
        final candidates = [
          ...urls.where((u) => u.isNotEmpty),
          if (single.isNotEmpty) single,
        ];
        if (candidates.isNotEmpty) {
          unawaited(_saveImageWithFallback(candidates));
        }
      case 'openSearch':
        final rule = '${payload['rule'] ?? ''}';
        if (rule.isNotEmpty &&
            matchRuleTitle(rule, [widget.program.name]) == null) {
          // 搜别的规则：切规则再搜（auto 时自动跑）。
          unawaited(
            _openRule(
              rule,
              searchKeyword: '${payload['keyword'] ?? ''}',
              auto: payload['auto'] == true,
            ),
          );
        } else {
          _showSearchBar(
            keyword: '${payload['keyword'] ?? ''}',
            auto: payload['auto'] == true,
          );
        }
      case 'openRule':
        unawaited(
          _openRule(
            '${payload['rule'] ?? ''}',
            detailUrl: '${payload['url'] ?? ''}',
          ),
        );
      case 'importCode':
        final code = '${payload['code'] ?? ''}';
        if (code.isNotEmpty) unawaited(_importRuleCode(code));
      case 'pickFile':
        unawaited(_pickFile('${payload['code'] ?? ''}'));
      case 'sniff':
        _startSniff(payload);
      case 'x5row':
        _handleX5Row(payload);
      case 'x5rowClear':
        _hideX5Row();
      case 'x5rowRefresh':
        _refreshX5Row(payload);
      case 'x5rowBack':
        unawaited(_x5RowBack());
      case 'x5fetchResult':
        // 页内桥 fetch 的回传：兑现 x5 页内等着的 Promise。
        final id = (payload['id'] as num?)?.toInt() ?? 0;
        final controller = _x5RowController;
        if (controller != null) {
          unawaited(
            controller.runJavaScript(
              'window.__hkX5ResolveFetch && window.__hkX5ResolveFetch('
              '$id, ${jsonEncode('${payload['result'] ?? ''}')});',
            ),
          );
        }
      case 'setPageImmersive':
        // C09/C11：页面级沉浸（#fullTheme#/#gameTheme#），状态独立于
        // 播放器全屏，_applyRunnerSystemUi 里取“或”。
        if (mounted) {
          final value = payload['immersive'] == true;
          if (value != _pageImmersive) {
            setState(() => _pageImmersive = value);
            _applyRunnerSystemUi();
          }
        }
      case 'share':
        unawaited(_handleShare('${payload['target'] ?? ''}'));
      case 'pop':
        if (mounted) Navigator.of(context).maybePop();
      // 规则顶栏的壳子动作钮（壳子 AppBar 已拿掉，按钮在运行时 header 里）：
      // 收藏当前页 / 展开搜索栏 / 重载页面，与旧顶栏行为一致。
      case 'shellFavorite':
        _toggleFavorite();
      case 'shellSearch':
        if (mounted) {
          setState(() {
            _showSearch = true;
            _searchNonce++;
          });
        }
      case 'shellReload':
        _controller?.reload();
      case 'play':
        final url = '${payload['url'] ?? ''}';
        if (url.isEmpty) return;
        final title = '${payload['title'] ?? widget.program.name}';
        final series = '${payload['series'] ?? ''}';
        final subtitleUrl = '${payload['subtitle'] ?? ''}';
        final headers = switch (payload['headers']) {
          final Map map => <String, String>{
            for (final entry in map.entries) '${entry.key}': '${entry.value}',
          },
          _ => const <String, String>{},
        };
        final episodes = switch (payload['episodes']) {
          final List list => <String>[for (final e in list) '$e'],
          _ => <String>[],
        };
        final lines = parseHaikuoPlayLines(
          payload['lines'],
          fallbackUrl: url,
          fallbackHeaders: headers,
        );
        // 弹幕地址：播放 JSON 的 danmu 透传（空串按无弹幕）；`web://`
        // 形态原样透传，播放器侧不解释、不取数、不渲染。
        final danmuUrl = '${payload['danmaku'] ?? ''}';
        final index = switch (payload['index']) {
          final num n => n.toInt(),
          final String s => int.tryParse(s),
          _ => null,
        };
        // 非视频内容分流：小说/图片集进对应查看器，不进视频播放器。
        final nonVideo = parseNonVideoUrl(url, headers: headers);
        if (nonVideo != null) {
          _openNonVideo(nonVideo, title);
          return;
        }
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
            subtitleUrl: subtitleUrl,
            headers: headers,
            lines: lines,
            danmuUrl: danmuUrl,
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
            subtitleUrl: subtitleUrl,
            headers: headers,
            lines: lines,
            danmuUrl: danmuUrl,
          );
          return;
        }
        _openPlayer(
          url,
          title,
          episodes: episodes,
          index: index ?? 0,
          series: series,
          subtitleUrl: subtitleUrl,
          headers: headers,
          lines: lines,
          danmuUrl: danmuUrl,
        );
      case 'open':
        final url = '${payload['url'] ?? ''}';
        if (url.isEmpty) return;
        final openNonVideo = parseNonVideoUrl(url);
        if (openNonVideo != null) {
          _openNonVideo(openNonVideo, '${payload['title'] ?? ''}');
          return;
        }
        _openLink(url, '${payload['title'] ?? ''}');
    }
  }

  /// 系统 UI 模式：页面沉浸与内嵌全屏取“或”。播放器视图在
  /// didUpdateWidget/dispose 里也会写系统 UI（它只认自己的全屏
  /// 状态），所以全屏切换与播放器关闭后要经
  /// [_reapplyRunnerSystemUiSoon] 在下一帧再压一次，否则页面沉浸
  /// 会被播放器的 edgeToEdge 恢复盖掉。
  void _applyRunnerSystemUi() {
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        haikuoImmersiveUi(
              pageImmersive: _pageImmersive,
              inlineFullscreen: _inlineFullscreen,
            )
            ? SystemUiMode.immersiveSticky
            : SystemUiMode.edgeToEdge,
      ),
    );
  }

  void _reapplyRunnerSystemUiSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyRunnerSystemUi();
    });
  }

  void _snack(String text) {
    if (!mounted || text.isEmpty) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  /// 非视频内容查看页：复用壳内已有的小说阅读视图与图片浏览视图，
  /// 标题优先用载荷自带的标题，其次用规则条目的标题。
  Future<void> _openNonVideo(NonVideoContent content, String title) async {
    final label = content.title.isNotEmpty ? content.title : title;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text(label.isEmpty ? widget.program.name : label),
          ),
          body: content.isNovel
              ? NovelReaderView(content: content, title: label)
              : PicsViewerView(content: content, title: label),
        ),
      ),
    );
  }

  Future<void> _openPlayer(
    String url,
    String title, {
    List<String> episodes = const [],
    int index = 0,
    String series = '',
    String subtitleUrl = '',
    Map<String, String> headers = const {},
    List<HaikuoPlayLine> lines = const [],
    String danmuUrl = '',
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
          subtitleUrl: subtitleUrl,
          headers: headers,
          lines: lines,
          danmuUrl: danmuUrl,
        ),
      ),
    );
    // 播放器已关闭：控制器失效，未完成的切集等待直接判失败。
    // 推页播放器 dispose 时会恢复 edgeToEdge，回来后按页面沉浸重压一次。
    _reapplyRunnerSystemUiSoon();
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
    String subtitleUrl = '',
    Map<String, String> headers = const {},
    List<HaikuoPlayLine> lines = const [],
    String danmuUrl = '',
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
        subtitleUrl: subtitleUrl,
        headers: headers,
        lines: lines,
        danmuUrl: danmuUrl,
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
    _reapplyRunnerSystemUiSoon();
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
        builder: (_) => HaikuoWebPage(url: url, title: title),
      ),
    );
  }

  /// 打开顶栏搜索栏：预填关键词；auto（hiker://search 的
  /// simple=false 形态）时有词就直接跑搜索。
  void _showSearchBar({required String keyword, required bool auto}) {
    if (!mounted) return;
    setState(() {
      _showSearch = true;
      _searchKeyword = keyword;
      _searchNonce++;
    });
    if (auto && keyword.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runSearch(keyword));
    }
  }

  /// 执行一次搜索：关键词交给运行时的 __haikuoSearch（第 1 页）。
  Future<void> _runSearch(String keyword) async {
    final word = keyword.trim();
    if (word.isEmpty) return;
    try {
      await _controller?.runJavaScript(
        'window.__haikuoSearch && window.__haikuoSearch('
        '${jsonEncode(word)}, 1);',
      );
    } catch (_) {
      // 页面还没准备好，忽略
    }
  }

  /// fileSelect://：让用户挑一个文件，拷一份带 _fileSelect_ 前缀
  /// 的副本到 haikuo/fileSelect/，把副本路径当 input 交回规则代码。
  /// 副本在下次启动时清理（见 _cleanupFileSelectCopies）。
  Future<void> _pickFile(String code) async {
    String? path;
    try {
      final files = await FilePicker.pickFiles();
      path = files.isEmpty ? null : files.first.path;
    } catch (_) {
      path = null;
    }
    if (path == null || path.isEmpty) return;
    var deliverPath = path;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/haikuo/fileSelect');
      await dir.create(recursive: true);
      final baseName = path.split('/').last;
      final copy = File('${dir.path}/_fileSelect_$baseName');
      await File(path).copy(copy.path);
      deliverPath = copy.path;
    } catch (_) {
      // 拷贝失败时回原路径，不耽误规则
    }
    try {
      await _controller?.runJavaScript(
        'window.__haikuoFileSelected && window.__haikuoFileSelected('
        '${jsonEncode(deliverPath)}, ${jsonEncode(code)});',
      );
    } catch (_) {
      // 页面已不在，忽略
    }
  }

  /// download/downloadFile/saveImage：把文件存到应用文档目录下的
  /// haikuo_downloads/，存完提示路径；失败也如实提示。
  Future<void> _downloadToDocs(String url, String name) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      _snack('下载地址不对，存不了');
      return;
    }
    var fileName = name.trim();
    if (fileName.isEmpty && uri.pathSegments.isNotEmpty) {
      fileName = uri.pathSegments.last;
    }
    if (fileName.isEmpty) fileName = 'download';
    fileName = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    try {
      final client = _httpClient ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..idleTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 60));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        _snack('下载失败：HTTP ${resp.statusCode}');
        return;
      }
      final bytes = await resp.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/haikuo_downloads');
      await dir.create(recursive: true);
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes.takeBytes());
      _snack('已保存：${file.path}');
    } catch (error) {
      _snack('下载失败：$error');
    }
  }

  /// saveImage：按顺序逐个下载，存下一个就停；全失败才提示。
  Future<void> _saveImageWithFallback(List<String> urls) async {
    for (final url in urls) {
      if (await _tryDownloadToDocs(url)) return;
    }
    _snack('图片保存失败');
  }

  /// 下载一个地址到 haikuo_downloads/，成功回 true。saveImage 回退链用。
  Future<bool> _tryDownloadToDocs(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return false;
    }
    var fileName = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
    if (fileName.isEmpty) fileName = 'image';
    fileName = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    try {
      final client = _httpClient ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..idleTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 60));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return false;
      final bytes = await resp.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/haikuo_downloads');
      await dir.create(recursive: true);
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes.takeBytes());
      _snack('已保存：${file.path}');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// H22 `share://`：partial 实现——消息 + 落盘 + 回落复制，尚无
  /// 系统分享面板。原因：share_plus 10.1.4（pub 缓存唯一版本）要
  /// win32 ^5.5.3，与 wakelock_plus 1.8.1 要的 win32 ^6.0.1 冲突，
  /// `flutter pub get --offline` 解析失败；降级 wakelock 或强行
  /// override win32 都会动无关依赖，未经编译验证的 Kotlin 也不写。
  /// 等 share_plus 出兼容 win32 6 的版本（或离线可得）后，在此处
  /// 把落盘文件/文本交给分享面板即可，JS 侧消息形态不用改。
  Future<void> _handleShare(String target) async {
    if (target.isEmpty) {
      _snack('没有可分享的内容');
      return;
    }
    try {
      if (haikuoIsHikerFilesTarget(target)) {
        final bytes = await _shareFileBytes(target);
        if (bytes == null) {
          _snack('文件不存在');
          return;
        }
        final staged = await _stageShareFile(target, bytes);
        if (staged != null) {
          _snack('已保存到分享目录：${staged.path}，请手动分享');
        } else {
          _snack('文件已找到，但保存到分享目录失败');
        }
        return;
      }
      await _fallbackShareCopy(target);
    } catch (_) {
      await _fallbackShareCopy(target);
    }
  }

  /// 分享回落：复制目标文本 + 提示（旧 share:// 分支的行为）。
  Future<void> _fallbackShareCopy(String target) async {
    try {
      await Clipboard.setData(ClipboardData(text: target));
    } catch (_) {
      // 剪贴板不可用时只提示，不抛错
    }
    _snack('链接已复制，可分享给他人');
  }

  /// 按 /__files/ 同源查找取文件字节：_savedFiles 全键 + basename、
  /// 规则私有文件、预置模块回退。找不到返回 null。
  Future<Uint8List?> _shareFileBytes(String target) async {
    final key = haikuoShareFileKey(target);
    if (key.isEmpty) return null;
    final base = haikuoSafeFileName(key);
    final ruleTitle = widget.program.name;
    return _savedFiles[key] ??
        (base == null ? null : _savedFiles[base]) ??
        await _persistedFileBytes(key) ??
        (base == null ? null : await _ruleFileBytes(base, ruleTitle)) ??
        await _ruleFileBytes(key, ruleTitle) ??
        (base == null ? null : await _presetModuleBytes(base, ruleTitle)) ??
        await _presetModuleBytes(key, ruleTitle);
  }

  /// 把待分享的文件字节写到文档目录 `haikuo_share/<basename>`，
  /// 供用户手动分享（系统面板接通后改由此处调面板）。
  Future<File?> _stageShareFile(String target, Uint8List bytes) async {
    final base = haikuoSafeFileName(haikuoShareFileKey(target));
    if (base == null) return null;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/haikuo_share');
      await dir.create(recursive: true);
      final file = File('${dir.path}/$base');
      await file.writeAsBytes(bytes);
      return file;
    } catch (_) {
      return null;
    }
  }

  /// 跨规则打开：按标题在规则库里找（精确 → 去 🔞 → 归一化），
  /// 找到就推一个新运行页，带上详情地址或搜索关键词。
  Future<void> _openRule(
    String title, {
    String detailUrl = '',
    String searchKeyword = '',
    bool auto = false,
  }) async {
    if (title.isEmpty) return;
    final programs = await _store.list();
    final matched = matchRuleTitle(title, [
      for (final program in programs) program.name,
    ]);
    HaikuoProgram? found;
    if (matched != null) {
      for (final program in programs) {
        if (program.name == matched) {
          found = program;
          break;
        }
      }
    }
    if (found == null) {
      _snack('没找到规则：$title');
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HaikuoRunnerPage(
          program: found!,
          initialDetailUrl: detailUrl.isEmpty ? null : detailUrl,
          // 非 auto 时只开搜索栏不自动跑：交给运行页的初始搜索
          // （auto 才带关键词自动跑，否则只打开规则首页）。
          initialSearchKeyword: auto && searchKeyword.isNotEmpty
              ? searchKeyword
              : null,
        ),
      ),
    );
  }

  /// rule:// 点击导入：口令/JSON 文本经仓库导入，报结果。
  Future<void> _importRuleCode(String code) async {
    try {
      final result = await _store.importText(code, origin: 'rule:// 导入');
      if (result.cancelled) {
        _snack('导入已取消');
      } else if (result.added.isEmpty && result.updated.isEmpty) {
        _snack('没有可导入的规则');
      } else {
        _snack('已导入 ${result.added.length} 个，更新 ${result.updated.length} 个');
      }
    } catch (error) {
      _snack('导入失败：$error');
    }
  }

  /// 顶栏收藏按钮：取当前页信息，开关收藏，报结果。
  Future<void> _toggleFavorite() async {
    try {
      final raw = await _controller?.runJavaScriptReturningResult(
        'window.__haikuoCurrentPage ? window.__haikuoCurrentPage() : "{}";',
      );
      var text = _sniffResultText(raw);
      if (text.isEmpty) text = '{}';
      final info = jsonDecode(text);
      if (info is! Map) return;
      final url = '${info['url'] ?? ''}';
      if (url.isEmpty) {
        _snack('当前页面没有可收藏的内容');
        return;
      }
      final added = await _store.toggleFavorite({
        'rule': '${info['rule'] ?? widget.program.name}',
        'url': url,
        'title': '${info['title'] ?? ''}',
        'pic': '${info['pic'] ?? ''}',
      });
      _snack(added ? '已收藏' : '已取消收藏');
    } catch (_) {
      _snack('收藏失败');
    }
  }

  // ---------- 嗅探（隐藏 WebView + 250ms 轮询，最长 30 秒） ----------

  /// E111-F2：取某地址的当前 Cookie（`k=v; ...` 串），供垫片的
  /// `getCookie` 回。取不到回空串（垫片回空，规则走原有无 Cookie 路）。
  Future<String> _pageCookiesFor(String url) async {
    try {
      final cookies = await WebViewCookieManager().getCookies(
        domain: Uri.parse(url),
      );
      return cookies.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (_) {
      return '';
    }
  }

  /// E111-F2：收走垫片 `writeFile` 攒进 `__hkWriteFiles` 的条目，按
  /// saveFile 语义落入 `_savedFiles`（basename 扁平化；与官方
  /// `rules/` 目录语义的差异已在垫片文档注明）并写穿落盘。
  /// 先读后清：清数组在处理之前，避免中途出错造成重复落盘。
  Future<void> _drainBridgeWriteFiles(WebViewController controller) async {
    try {
      final raw = await controller.runJavaScriptReturningResult(
        'JSON.stringify(window.__hkWriteFiles||[])',
      );
      await controller.runJavaScript('window.__hkWriteFiles=[];');
      final text = _sniffResultText(raw);
      if (text.isEmpty) return;
      final decoded = jsonDecode(text);
      if (decoded is! List) return;
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final base = haikuoSafeFileName('${entry['path'] ?? ''}');
        if (base == null) continue;
        await _storeSavedFile(
          base,
          Uint8List.fromList(utf8.encode('${entry['content'] ?? ''}')),
        );
      }
    } catch (_) {
      // 收不到就跳过这一拍，数组已清，不重复
    }
  }

  void _startSniff(Map<String, dynamic> payload) {
    final id = '${payload['id'] ?? ''}';
    final url = '${payload['url'] ?? ''}';
    if (id.isEmpty) return;
    // 上一个还没跑完：先按失败回掉，再开新的。
    final previous = _sniffSession;
    if (previous != null) _finishSniff(previous, '');
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      unawaited(_deliverSniffResult(id, ''));
      return;
    }
    List<String> asList(Object? value) => switch (value) {
      final List list => <String>[for (final e in list) '$e'],
      _ => <String>[],
    };
    final session = _SniffSession(
      id: id,
      url: url,
      js: '${payload['js'] ?? ''}',
      mode: '${payload['mode'] ?? 'video'}',
      videoRules: asList(payload['videoRules']),
      excludeRules: asList(payload['videoExcludeRules']),
      blockRules: asList(payload['blockRules']),
      ua: '${payload['ua'] ?? ''}',
      referer: '${payload['referer'] ?? ''}',
      deadline: DateTime.now().add(const Duration(seconds: 30)),
      pageJs: '${payload['pageJs'] ?? ''}',
    );
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF120B20));
    controller.setNavigationDelegate(
      NavigationDelegate(
        // blockRules 只拦主框架导航（子资源请求 WebView 拦不了）。
        onNavigationRequest: (request) {
          final blocked = session.blockRules.any(
            (rule) => wildcardContains(request.url, rule),
          );
          return blocked
              ? NavigationDecision.prevent
              : NavigationDecision.navigate;
        },
        onPageFinished: (_) {
          // video 模式的 extra.js：页面加载完跑一次。
          if (session.pageJs.isNotEmpty && !session.pageJsDone) {
            session.pageJsDone = true;
            unawaited(controller.runJavaScript(session.pageJs));
          }
        },
      ),
    );
    if (session.ua.isNotEmpty) {
      unawaited(controller.setUserAgent(session.ua));
    }
    final headers = <String, String>{};
    if (session.referer.isNotEmpty) headers['Referer'] = session.referer;
    unawaited(controller.loadRequest(Uri.parse(url), headers: headers));
    _sniffSession = session;
    _sniffController = controller;
    setState(() {});
    _sniffTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(_sniffTick(session)),
    );
  }

  /// 嗅探轮询一拍：webRule 形态跑规则 JS 取结果；video 形态从
  /// 资源加载记录里挑可播地址；超时按失败回掉。
  Future<void> _sniffTick(_SniffSession session) async {
    if (!identical(_sniffSession, session) || session.done) return;
    final controller = _sniffController;
    if (controller == null) return;
    if (DateTime.now().isAfter(session.deadline)) {
      _finishSniff(session, '');
      return;
    }
    try {
      if (session.mode == 'webRule' && session.js.isNotEmpty) {
        // 垫片与取码路径共用同一构造（haikuoBridgePadScript）；结果
        // 仍回原字符串（嗅探要的是地址本身，不用 checkJs 哨兵）。
        final pad = haikuoBridgePadScript(await _pageCookiesFor(session.url));
        final script =
            '(function(){try{$pad}catch(e){}var __r="";try{__r=(0,eval)('
            '${jsonEncode(session.js)});}catch(e){__r="";}return typeof __r==='
            '"string"?__r:(__r==null?"":String(__r));})()';
        final raw = await controller.runJavaScriptReturningResult(script);
        await _drainBridgeWriteFiles(controller);
        final text = _sniffResultText(raw);
        if (text.isNotEmpty) {
          _finishSniff(session, text);
          return;
        }
      } else {
        // 资源枚举脚本与 floatVideo 轮询共用同一常量（不得各写一份）。
        final script = haikuoResourceEntriesScript;
        final raw = await controller.runJavaScriptReturningResult(script);
        final entries = _sniffUrlList(raw);
        final picked = pickSniffedVideoUrl(
          entries,
          includeRules: session.videoRules,
          excludeRules: [...session.excludeRules, ...session.blockRules],
        );
        if (picked.isNotEmpty) {
          _finishSniff(session, picked);
          return;
        }
      }
    } catch (_) {
      // 页面还没加载完，这一拍跳过
    }
  }

  /// runJavaScriptReturningResult 的返回值归一：Android 侧字符串
  /// 结果带一层 JSON 引号，这里剥掉；null/undefined/空都当没结果。
  String _sniffResultText(Object? raw) {
    if (raw == null) return '';
    var text = '$raw'.trim();
    if (text.isEmpty || text == 'null' || text == 'undefined') return '';
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is String) text = decoded;
      } catch (_) {
        // 不是 JSON 串，原样用
      }
    }
    return text == 'null' || text == 'undefined' ? '' : text;
  }

  List<String> _sniffUrlList(Object? raw) {
    if (raw == null) return const [];
    final text = '$raw'.trim();
    if (text.isEmpty) return const [];
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) return <String>[for (final e in decoded) '$e'];
    } catch (_) {
      // 不是 JSON 数组，忽略
    }
    return const [];
  }

  void _finishSniff(_SniffSession session, String result) {
    if (session.done) return;
    session.done = true;
    if (identical(_sniffSession, session)) {
      _sniffSession = null;
      _sniffController = null;
      _sniffTimer?.cancel();
      _sniffTimer = null;
      if (mounted) setState(() {});
    }
    unawaited(_deliverSniffResult(session.id, result));
  }

  Future<void> _deliverSniffResult(String id, String result) async {
    try {
      await _controller?.runJavaScript(
        'window.__haikuoSniffResult && window.__haikuoSniffResult('
        '${jsonEncode(id)}, ${jsonEncode(result)});',
      );
    } catch (_) {
      // 页面已不在，忽略
    }
  }

  // ---------- G11 原生 x5 行 ----------

  /// 规则 `x5RowHtml` 发来的行配置：首建 controller，或复用已有
  /// controller 只更新配置（URL 变了才重载）。建行失败/地址非法
  /// 时回落 iframe（[__haikuoX5Fallback]），不得白屏。
  void _handleX5Row(Map<String, dynamic> payload) {
    final url = '${payload['url'] ?? ''}';
    final desc = '${payload['desc'] ?? ''}';
    final extra = payload['extra'];
    final extraMap = extra is Map
        ? {for (final e in extra.entries) '${e.key}': e.value}
        : <String, dynamic>{};
    final blockRules = switch (extraMap['blockRules']) {
      final List list => <String>[
        for (final e in list)
          if ('$e'.trim().isNotEmpty) '$e',
      ],
      _ => <String>[],
    };
    if (url.isEmpty ||
        (!url.startsWith('http://') &&
            !url.startsWith('https://') &&
            !url.startsWith('about:'))) {
      _x5RowFallback();
      return;
    }
    final existing = _x5RowSession;
    final existingController = _x5RowController;
    if (existing != null && existingController != null) {
      final urlChanged = url != existing.url;
      final uaChanged = '${extraMap['ua'] ?? ''}' != existing.ua;
      existing
        ..url = url
        ..desc = desc
        ..ua = '${extraMap['ua'] ?? ''}'
        ..referer = '${extraMap['referer'] ?? ''}'
        ..js = '${extraMap['js'] ?? ''}'
        ..jsLoadingInject = extraMap['jsLoadingInject'] == true
        ..blockRules = blockRules
        ..urlInterceptor = '${extraMap['urlInterceptor'] ?? ''}'
        ..canBack = extraMap['canBack'] == true
        ..floatVideo = haikuoFloatVideoGate(extraMap['floatVideo'])
        ..showProgress = extraMap['showProgress'] != false
        ..index = (payload['index'] as num?)?.toInt() ?? existing.index
        ..topOffset =
            (payload['topOffset'] as num?)?.toDouble() ?? existing.topOffset
        ..visible = true
        ..hideLoadingRequested = false;
      if (uaChanged && existing.ua.isNotEmpty) {
        unawaited(existingController.setUserAgent(existing.ua));
      }
      if (urlChanged) {
        existing
          ..progress = 0
          ..currentUrl = ''
          ..expectInitialNavigation = true;
        final headers = <String, String>{};
        if (existing.referer.isNotEmpty) headers['Referer'] = existing.referer;
        try {
          unawaited(
            existingController
                .loadRequest(Uri.parse(url), headers: headers)
                .catchError((_) => _x5RowFallback()),
          );
        } catch (_) {
          _x5RowFallback();
          return;
        }
      }
      if (urlChanged) _resetFloatVideoState();
      if (mounted) setState(() {});
      unawaited(_updateX5CanGoBack());
      _syncFloatVideoPolling();
      return;
    }
    final session = _X5RowSession(
      url: url,
      desc: desc,
      ua: '${extraMap['ua'] ?? ''}',
      referer: '${extraMap['referer'] ?? ''}',
      js: '${extraMap['js'] ?? ''}',
      jsLoadingInject: extraMap['jsLoadingInject'] == true,
      blockRules: blockRules,
      urlInterceptor: '${extraMap['urlInterceptor'] ?? ''}',
      canBack: extraMap['canBack'] == true,
      floatVideo: haikuoFloatVideoGate(extraMap['floatVideo']),
      showProgress: extraMap['showProgress'] != false,
      index: (payload['index'] as num?)?.toInt() ?? 0,
      topOffset: (payload['topOffset'] as num?)?.toDouble() ?? 0,
    );
    try {
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFFFFFFFF))
        ..addJavaScriptChannel(
          'HaikuoX5Bridge',
          onMessageReceived: _onX5BridgeMessage,
        );
      controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) async {
            // blockRules 导航级拦截（与嗅探/取码同口径；子资源
            // 拦不了是 WebView 固有限制）。
            if (session.blockRules.any(
              (rule) => wildcardContains(request.url, rule),
            )) {
              return NavigationDecision.prevent;
            }
            if (!request.isMainFrame) return NavigationDecision.navigate;
            // 行自身的首载不经过拦截器（拦截器只拦行内跳转）。
            if (session.expectInitialNavigation) {
              session.expectInitialNavigation = false;
              return NavigationDecision.navigate;
            }
            if (session.urlInterceptor.isEmpty) {
              return NavigationDecision.navigate;
            }
            final decision = await _decideX5Navigation(session, request.url);
            if (decision.action == 'exec') {
              unawaited(_execX5InterceptorCode(session, decision.code));
              return NavigationDecision.prevent;
            }
            return decision.action == 'block'
                ? NavigationDecision.prevent
                : NavigationDecision.navigate;
          },
          onPageStarted: (startedUrl) {
            unawaited(_x5PageStarted(session, controller, startedUrl));
          },
          onPageFinished: (finishedUrl) {
            unawaited(_x5PageFinished(session, controller, finishedUrl));
          },
          onProgress: (progress) {
            session.progress = progress;
            if (session.showProgress && session.visible && mounted) {
              setState(() {});
            }
          },
          onWebResourceError: (error) {
            // 主框加载失败：回落 iframe 显示错误页，不得白屏。
            // 只认当前会话的 controller，旧会话的迟到错误不碰新行。
            if (error.isForMainFrame == true &&
                identical(_x5RowSession, session)) {
              _x5RowFallback();
            }
          },
        ),
      );
      _x5RowSession = session;
      _x5RowController = controller;
      _resetFloatVideoState();
      if (session.ua.isNotEmpty) {
        unawaited(controller.setUserAgent(session.ua));
      }
      final headers = <String, String>{};
      if (session.referer.isNotEmpty) headers['Referer'] = session.referer;
      unawaited(
        controller
            .loadRequest(Uri.parse(url), headers: headers)
            .catchError((_) => _x5RowFallback()),
      );
      if (mounted) setState(() {});
      _syncFloatVideoPolling();
    } catch (_) {
      _x5RowFallback();
    }
  }

  /// 藏起原生行（只藏不毁，controller 留着复用；行内视频先暂停，
  /// 免得藏起来还继续出声）。渲染入口与加载态都会发 x5rowClear。
  void _hideX5Row() {
    final session = _x5RowSession;
    if (session == null || !session.visible) return;
    session.visible = false;
    // 行藏起时停轮询（检出状态保留，复显后层仍在、未检出则重轮询）。
    _stopFloatVideoPolling();
    final controller = _x5RowController;
    if (controller != null) {
      unawaited(controller.runJavaScript(haikuoPausePageVideosScript));
      unawaited(_drainBridgeWriteFiles(controller));
    }
    if (mounted) setState(() {});
    unawaited(_updateX5CanGoBack());
  }

  /// `refreshX5WebView`/`refreshX5Desc` 的原生侧：无行时忽略
  /// （即旧空实现）。url 空串 = 重载当前行；desc 只改布局。
  void _refreshX5Row(Map<String, dynamic> payload) {
    final session = _x5RowSession;
    final controller = _x5RowController;
    if (session == null || controller == null) return;
    var changed = false;
    if (payload.containsKey('desc')) {
      final desc = '${payload['desc'] ?? ''}';
      if (desc != session.desc) {
        session.desc = desc;
        changed = true;
      }
    }
    if (payload.containsKey('url')) {
      final url = '${payload['url'] ?? ''}';
      if (url.isEmpty) {
        // 重载 = 刷新：旧检出作废，加载开始后重检。
        _resetFloatVideoState();
        unawaited(controller.reload());
      } else if (url != session.url &&
          (url.startsWith('http://') ||
              url.startsWith('https://') ||
              url.startsWith('about:'))) {
        // 换地址：旧检出属于旧页，作废后重检。
        _resetFloatVideoState();
        session
          ..url = url
          ..progress = 0
          ..currentUrl = ''
          ..expectInitialNavigation = true
          ..visible = true;
        final headers = <String, String>{};
        if (session.referer.isNotEmpty) headers['Referer'] = session.referer;
        try {
          unawaited(
            controller
                .loadRequest(Uri.parse(url), headers: headers)
                .catchError((_) => _x5RowFallback()),
          );
        } catch (_) {
          _x5RowFallback();
          return;
        }
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  /// x5 行内后退（规则顶栏返回键/系统返回键/页内桥 back 共用）：
  /// 行内无历史时什么都不做（调用方已按 [_x5CanGoBack] 分流，
  /// 绝不替规则页再 pop 一次）。
  Future<void> _x5RowBack() async {
    final controller = _x5RowController;
    if (controller == null || _x5RowSession == null) return;
    try {
      if (await controller.canGoBack()) await controller.goBack();
    } catch (_) {
      // 行已不在，忽略
    }
    await _updateX5CanGoBack();
  }

  /// 实测行内 canGoBack，同步 [_x5CanGoBack] 与规则页的
  /// `window.__haikuoX5CanGoBack` 标志（变化时才写，避免反复求值）。
  Future<void> _updateX5CanGoBack() async {
    final controller = _x5RowController;
    final session = _x5RowSession;
    var can = false;
    if (controller != null &&
        session != null &&
        session.canBack &&
        session.visible) {
      try {
        can = await controller.canGoBack();
      } catch (_) {
        can = false;
      }
    }
    if (can != _x5CanGoBack) {
      _x5CanGoBack = can;
      if (mounted) setState(() {});
      unawaited(
        _evalRuleJs('window.__haikuoX5CanGoBack = ${can ? 'true' : 'false'};'),
      );
    }
  }

  /// 加载开始：注入桥垫片 + `$$$` 序列化器；jsLoadingInject 为
  /// true 时再跑一次 extra.js（与加载完那次合计两次，规则自去重）。
  Future<void> _x5PageStarted(
    _X5RowSession session,
    WebViewController controller,
    String startedUrl,
  ) async {
    if (!identical(_x5RowSession, session)) return;
    session.currentUrl = startedUrl;
    session.progress = 0;
    // 导航/刷新开始：旧检出作废，本页加载后重检（与 js 注入链路
    // 无关，只清 floatVideo 自身状态，不动桥与 extra.js 的执行）。
    _resetFloatVideoState();
    await _injectX5Bridge(session, controller, startedUrl);
    if (session.jsLoadingInject && session.js.isNotEmpty) {
      try {
        await controller.runJavaScript(session.js);
        await _drainBridgeWriteFiles(controller);
      } catch (_) {
        // 页还没好，加载完那次还会再跑
      }
    }
    if (mounted && session.showProgress && session.visible) setState(() {});
    _syncFloatVideoPolling();
  }

  /// 加载完成：注入桥垫片 + `$$$` 序列化器，跑 extra.js（每次
  /// 加载完都跑，about:blank 行同样跑），收 writeFile，回推后退态。
  Future<void> _x5PageFinished(
    _X5RowSession session,
    WebViewController controller,
    String finishedUrl,
  ) async {
    if (!identical(_x5RowSession, session)) return;
    session.currentUrl = finishedUrl;
    session.progress = 100;
    await _injectX5Bridge(session, controller, finishedUrl);
    if (session.js.isNotEmpty) {
      try {
        await controller.runJavaScript(session.js);
      } catch (_) {
        // 注入代码出错不影响行显示
      }
    }
    await _drainBridgeWriteFiles(controller);
    if (mounted) setState(() {});
    _syncFloatVideoPolling();
    await _updateX5CanGoBack();
  }

  /// 桥注入：垫片复用 [haikuoBridgePadScript]（与嗅探/取码同一构造，
  /// 不得另写一份），其后拼 [haikuoX5BridgeScript]（`$$$` + 通道方法）。
  /// Cookie 取当前页地址的快照（与垫片既有滞后语义一致）。
  Future<void> _injectX5Bridge(
    _X5RowSession session,
    WebViewController controller,
    String pageUrl,
  ) async {
    try {
      final cookies = await _pageCookiesFor(
        pageUrl.isEmpty ? session.url : pageUrl,
      );
      await controller.runJavaScript(
        haikuoBridgePadScript(cookies) + haikuoX5BridgeScript(),
      );
    } catch (_) {
      // 页还没好，下一拍还会再注
    }
  }

  /// urlInterceptor 决策：串行求值（input 存取不交错），同步等待
  /// 结果再回导航决策，不得放行后再补拦。求值超时 5 秒按放行。
  Future<({String action, String code})> _decideX5Navigation(
    _X5RowSession session,
    String url,
  ) {
    final run = _x5InterceptorChain.then(
      (_) => _evalUrlInterceptorNow(session, url),
    );
    _x5InterceptorChain = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<({String action, String code})> _evalUrlInterceptorNow(
    _X5RowSession session,
    String url,
  ) async {
    if (!identical(_x5RowSession, session)) {
      return (action: 'allow', code: '');
    }
    final controller = _controller;
    if (controller == null || !mounted) return (action: 'allow', code: '');
    try {
      final raw = await controller
          .runJavaScriptReturningResult(
            'window.__haikuoUrlInterceptor && window.__haikuoUrlInterceptor('
            '${jsonEncode(session.urlInterceptor)}, ${jsonEncode(url)});',
          )
          .timeout(const Duration(seconds: 5));
      return haikuoParseX5Intercept(_sniffResultText(raw));
    } catch (_) {
      return (action: 'allow', code: '');
    }
  }

  /// 拦截器回代码串：先确保桥在位，再在当前页内执行该串
  /// （原导航已被拦住；串里的 `fba.open` 等走桥通道）。
  Future<void> _execX5InterceptorCode(
    _X5RowSession session,
    String code,
  ) async {
    final controller = _x5RowController;
    if (controller == null || !identical(_x5RowSession, session)) return;
    try {
      await _injectX5Bridge(session, controller, session.currentUrl);
      await controller.runJavaScript(code);
      await _drainBridgeWriteFiles(controller);
    } catch (_) {
      // 执行失败静默（规则侧有 try/catch 与 && 守卫兜底）
    }
  }

  /// x5 页内桥通道（HaikuoX5Bridge）：JSON `{method,args,id}`，
  /// 仅异步，无同步返回值。投递失败记日志 + 空操作。
  void _onX5BridgeMessage(JavaScriptMessage message) {
    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map) return;
      payload = {
        for (final entry in decoded.entries) '${entry.key}': entry.value,
      };
    } catch (error) {
      debugPrint('HaikuoX5Bridge: bad message: $error');
      return;
    }
    final method = '${payload['method'] ?? ''}';
    final args = payload['args'] is List
        ? (payload['args'] as List)
        : const <Object?>[];
    Object? argAt(int i) => i < args.length ? args[i] : null;
    try {
      switch (method) {
        case 'open':
          // open(JSON 串 {title,url} 或裸地址)：复用规则点击链；
          // 规则页已不在且是 http(s) 时才直开网页。
          final raw = '${argAt(0) ?? ''}';
          var title = '';
          var url = raw;
          try {
            final decoded = jsonDecode(raw);
            if (decoded is Map && decoded['url'] != null) {
              url = '${decoded['url']}';
              title = '${decoded['title'] ?? ''}';
            }
          } catch (_) {
            // 不是 JSON，当裸地址
          }
          if (url.isEmpty) return;
          if (_controller != null) {
            unawaited(
              _evalRuleJs(
                'window.__haikuoX5Open && window.__haikuoX5Open('
                '${jsonEncode(title)}, ${jsonEncode(url)});',
              ),
            );
          } else if (url.startsWith('http://') || url.startsWith('https://')) {
            unawaited(_openLink(url, title));
          }
        case 'playVideo':
          final url = '${argAt(0) ?? ''}';
          if (url.isNotEmpty) {
            unawaited(
              _evalRuleJs(
                'window.__haikuoX5Play && window.__haikuoX5Play('
                '${jsonEncode(url)});',
              ),
            );
          }
        case 'parseLazyRule':
        case 'parseLazyRuleAsync':
          // Async 形态与同步形态同一路：求值结果走规则侧正常
          // 出口（播/开/toast），回调不阻塞页内 JS（无回调 plumbing，
          // 语料里 parseLazyRuleAsync 未见回调形态）。
          final lazy = '${argAt(0) ?? ''}';
          if (lazy.isNotEmpty) {
            unawaited(
              _evalRuleJs(
                'window.__haikuoX5ParseLazy && window.__haikuoX5ParseLazy('
                '${jsonEncode(lazy)});',
              ),
            );
          }
        case 'putVar':
        case 'clearVar':
        case 'putMyVar':
        case 'clearMyVar':
          // 只写操作：串行链保发送序。clear 系 key 为 null 时清全部。
          final key = argAt(0);
          final value = argAt(1);
          _x5VarChain = _x5VarChain.then(
            (_) => _evalRuleJs(
              'window.__haikuoX5Var && window.__haikuoX5Var('
              '${jsonEncode(method)}, ${jsonEncode(key)}, '
              '${jsonEncode(value == null ? '' : '$value')});',
            ),
            onError: (_) {},
          );
        case 'setWebUa':
          final ua = '${argAt(0) ?? ''}';
          final controller = _x5RowController;
          if (ua.isNotEmpty && controller != null) {
            _x5RowSession?.ua = ua;
            unawaited(controller.setUserAgent(ua));
          }
        case 'hideLoading':
          final session = _x5RowSession;
          if (session != null && !session.hideLoadingRequested) {
            session.hideLoadingRequested = true;
            if (mounted) setState(() {});
          }
        case 'refreshPage':
          // 页内 refreshPage：刷新 x5 行自身（规则页刷新另有
          // 规则侧 refreshPage，与此无关）。
          unawaited(_x5RowController?.reload());
        case 'back':
          unawaited(_x5RowBack());
        case 'fetch':
          // 规则 fetch 同步求值，结果经 x5fetchResult 回传兑现 Promise。
          final id = (payload['id'] as num?)?.toInt() ?? 0;
          final url = '${argAt(0) ?? ''}';
          final opts = argAt(1);
          if (url.isNotEmpty) {
            unawaited(
              _evalRuleJs(
                'window.__haikuoX5Fetch && window.__haikuoX5Fetch('
                '$id, ${jsonEncode(url)}, ${jsonEncode(opts)});',
              ),
            );
          }
        case 'toast':
          _snack('${argAt(0) ?? ''}');
        default:
          debugPrint('HaikuoX5Bridge: unknown method: $method');
      }
    } catch (error) {
      debugPrint('HaikuoX5Bridge: $method failed: $error');
    }
  }

  /// 在规则 WebView 里求值一段 JS（失败静默：页已不在时不报错）。
  Future<void> _evalRuleJs(String script) async {
    try {
      await _controller?.runJavaScript(script);
    } catch (_) {
      // 页面已不在，忽略
    }
  }

  /// 原生行建不起来/主框加载失败：撤掉原生行，规则页把占位
  /// 换成旧 iframe 显示，不得白屏。
  void _x5RowFallback() {
    _resetFloatVideoState();
    _x5RowSession = null;
    _x5RowController = null;
    _x5CanGoBack = false;
    if (mounted) setState(() {});
    unawaited(
      _evalRuleJs(
        'window.__haikuoX5Fallback && window.__haikuoX5Fallback();'
        'window.__haikuoX5CanGoBack = false;',
      ),
    );
  }

  // ---------- W6 floatVideo 悬浮嗅探播放 ----------

  /// 停掉 floatVideo 轮询定时器（只停定时器，不动检出状态）。
  void _stopFloatVideoPolling() {
    _floatVideoTimer?.cancel();
    _floatVideoTimer = null;
  }

  /// 重置全部 floatVideo 状态：新行/换地址/刷新/导航/回落时调用，
  /// 旧页检出的地址不再属于新页，导航后重检（不得沿用旧层）。
  void _resetFloatVideoState() {
    final hadLayer = _floatVideoUrl.isNotEmpty;
    _stopFloatVideoPolling();
    _floatVideoUrl = '';
    _floatVideoSession = null;
    _floatVideoDismissed = false;
    _floatVideoTickBusy = false;
    _floatVideoFailures = 0;
    _floatVideoFullscreen = false;
    _floatVideoGeneration++;
    if (hadLayer && mounted) setState(() {});
  }

  /// 按当前门控/可见/检出状态决定轮询的启停（幂等，各入口都可调）。
  /// 门关了（floatVideo 非 true）或行已不在时，已弹出的层一并收掉，
  /// 只显示网页；行仅被藏起（x5rowClear）时层保留，复显后仍在。
  void _syncFloatVideoPolling() {
    try {
      final session = _x5RowSession;
      if (session == null || !haikuoFloatVideoGate(session.floatVideo)) {
        _stopFloatVideoPolling();
        if (_floatVideoUrl.isNotEmpty) _resetFloatVideoState();
        return;
      }
      if (!session.visible) {
        _stopFloatVideoPolling();
        return;
      }
      if (!haikuoFloatVideoShouldPoll(
        floatVideo: session.floatVideo,
        visible: session.visible,
        hasVideo: _floatVideoUrl.isNotEmpty,
        dismissed: _floatVideoDismissed,
        consecutiveFailures: _floatVideoFailures,
      )) {
        _stopFloatVideoPolling();
        return;
      }
      _floatVideoTimer ??= Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => unawaited(_floatVideoTick(session)),
      );
    } catch (_) {
      // 同步过程绝不能炸到 x5 行：停轮询、静默回落只显示网页。
      _stopFloatVideoPolling();
    }
  }

  /// floatVideo 轮询一拍：复用嗅探现成件——与 [_sniffTick] 同一
  /// 资源枚举脚本（[haikuoResourceEntriesScript]）+ 同一地址归一
  /// （[_sniffUrlList]）+ 同一挑地址函数（[haikuoFloatVideoPick]，
  /// 即 [pickSniffedVideoUrl]），不得另写一套嗅探器。检出后暂停
  /// 页内视频、弹悬浮层；单拍失败跳过，连续失败超上限停轮询。
  Future<void> _floatVideoTick(_X5RowSession session) async {
    if (!identical(_x5RowSession, session) || _floatVideoTickBusy) return;
    final controller = _x5RowController;
    if (controller == null) return;
    if (_floatVideoUrl.isNotEmpty ||
        _floatVideoDismissed ||
        !haikuoFloatVideoGate(session.floatVideo)) {
      _stopFloatVideoPolling();
      return;
    }
    _floatVideoTickBusy = true;
    final generation = _floatVideoGeneration;
    try {
      final raw = await controller.runJavaScriptReturningResult(
        haikuoResourceEntriesScript,
      );
      if (!identical(_x5RowSession, session) ||
          generation != _floatVideoGeneration) {
        return;
      }
      final picked = haikuoFloatVideoPick(
        _sniffUrlList(raw),
        session.blockRules,
      );
      if (picked.isEmpty) {
        _floatVideoFailures = 0;
        return;
      }
      _floatVideoFailures = 0;
      // 已有播放器在播/内嵌时不抢：本页按已处理计，不再弹层。
      if (_inline != null || _playerController != null) {
        _floatVideoDismissed = true;
        _stopFloatVideoPolling();
        return;
      }
      _floatVideoUrl = picked;
      _floatVideoSession = session;
      _stopFloatVideoPolling();
      try {
        await controller.runJavaScript(haikuoPausePageVideosScript);
      } catch (_) {
        // 暂停失败不影响弹层（页内视频可能已由行隐藏逻辑暂停）。
      }
      if (mounted &&
          identical(_x5RowSession, session) &&
          generation == _floatVideoGeneration &&
          _floatVideoUrl.isNotEmpty) {
        setState(() {});
      }
    } catch (_) {
      // 这一拍失败跳过（页还没加载完是常态）；连续失败超上限则
      // 停轮询，静默回落只显示网页，不得阻塞 x5 行。
      _floatVideoFailures++;
      if (_floatVideoFailures >= haikuoFloatVideoMaxFailures) {
        _stopFloatVideoPolling();
      }
    } finally {
      _floatVideoTickBusy = false;
    }
  }

  /// 关闭悬浮层：回落只显示网页；本页不再重弹（导航/刷新后重检）。
  /// 页内视频不恢复播放（关闭只是收起浮层，不替用户点播）。
  void _closeFloatVideo() {
    if (_floatVideoUrl.isEmpty && !_floatVideoFullscreen) return;
    _floatVideoUrl = '';
    _floatVideoSession = null;
    _floatVideoFullscreen = false;
    _floatVideoDismissed = true;
    _stopFloatVideoPolling();
    if (mounted) setState(() {});
  }

  /// 悬浮播放层：复用壳内现有播放器视图 [HaikuoPlayerView]（与内嵌
  /// 播放同一件，播/停/进度/全屏全由它提供），外加一个显式关闭钮；
  /// 不动任何共享播放器核心文件。全屏时占满屏幕，否则浮在底部。
  /// 取流头只带行配置的 Referer（与嗅探递送口径一致，不另拼 UA）。
  Widget _buildFloatVideoOverlay() {
    final session = _x5RowSession!;
    final headers = <String, String>{};
    if (session.referer.isNotEmpty) headers['Referer'] = session.referer;
    final player = HaikuoPlayerView(
      key: ValueKey<String>(_floatVideoUrl),
      url: _floatVideoUrl,
      title: widget.program.name,
      headers: headers,
      fullscreen: _floatVideoFullscreen,
      onFullscreenChanged: (value) {
        if (mounted) setState(() => _floatVideoFullscreen = value);
      },
      onClose: _closeFloatVideo,
    );
    if (_floatVideoFullscreen) {
      return Positioned.fill(
        child: Container(color: Colors.black, child: player),
      );
    }
    return Positioned(
      left: 8,
      right: 8,
      bottom: 16,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        color: Colors.black,
        child: Stack(
          children: [
            AspectRatio(aspectRatio: 16 / 9, child: player),
            Positioned(
              top: 4,
              right: 4,
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: IconButton(
                  tooltip: '关闭悬浮播放',
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  onPressed: _closeFloatVideo,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 原生 x5 行的叠放布局：规则 WebView 内容区上方的一层。
  /// list 模式贴内容区顶部（随页面滚动错位是已知局限，见 NOTES）；
  /// float 模式贴底；top 模式贴顶栏下方（状态栏 + 实测顶栏高，
  /// 不写死 120px）。高度/模式换算复用 [haikuoX5RowLayout]。
  Widget _buildX5RowOverlay(BuildContext context) {
    final session = _x5RowSession!;
    final controller = _x5RowController!;
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final immersive = haikuoImmersiveUi(
      pageImmersive: _pageImmersive,
      inlineFullscreen: _inlineFullscreen,
    );
    final contentTop = immersive ? 0.0 : padding.top;
    final headerHeight = session.topOffset > 0 ? session.topOffset : 48.0;
    final availableHeight = size.height - contentTop < 0
        ? 0.0
        : size.height - contentTop;
    final layout = haikuoX5RowLayout(
      desc: session.desc,
      viewportHeight: availableHeight,
      viewportWidth: size.width,
      topOffset: headerHeight,
    );
    final showProgress =
        session.showProgress &&
        !session.hideLoadingRequested &&
        session.progress < 100;
    final body = Container(
      color: const Color(0xFFFFFFFF),
      child: Column(
        children: [
          if (showProgress)
            LinearProgressIndicator(
              value: session.progress / 100,
              minHeight: 2,
            ),
          Expanded(child: WebViewWidget(controller: controller)),
        ],
      ),
    );
    if (layout.topMode) {
      return Positioned(
        top: contentTop + headerHeight,
        left: 0,
        right: 0,
        height: layout.height,
        child: body,
      );
    }
    if (layout.floatMode) {
      return Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        height: layout.height,
        child: body,
      );
    }
    return Positioned(
      top: contentTop,
      left: 0,
      right: 0,
      height: layout.height,
      child: body,
    );
  }

  // ---------- 原生对话框（/__dialog 的排队与展示） ----------

  Future<void> _handleDialog(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final completer = Completer<Map<String, dynamic>>();
    _dialogQueue.add(_PendingDialog(params, completer));
    unawaited(_pumpDialogs());
    final result = await completer.future;
    try {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
      await request.response.close();
    } catch (_) {
      // 连接已断（页面关了），忽略
    }
  }

  Future<void> _pumpDialogs() async {
    if (_dialogBusy) return;
    _dialogBusy = true;
    try {
      while (_dialogQueue.isNotEmpty) {
        if (!mounted) {
          for (final pending in _dialogQueue) {
            if (!pending.completer.isCompleted) {
              pending.completer.complete(_dialogDefault(pending.params));
            }
          }
          _dialogQueue.clear();
          break;
        }
        final pending = _dialogQueue.removeAt(0);
        final result = await _showNativeDialog(pending.params);
        if (!pending.completer.isCompleted) {
          pending.completer.complete(result);
        }
      }
    } finally {
      _dialogBusy = false;
    }
  }

  Map<String, dynamic> _dialogDefault(Map<String, String> params) {
    return switch (params['type']) {
      'confirm' => {'result': false},
      'input' => {'result': null},
      'select' => {'result': null},
      _ => {'result': true},
    };
  }

  Future<Map<String, dynamic>> _showNativeDialog(
    Map<String, String> params,
  ) async {
    final type = params['type'] ?? '';
    final title = params['title'] ?? '';
    final content = params['content'] ?? '';
    switch (type) {
      case 'confirm':
        final ok = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: title.isEmpty ? null : Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('确定'),
              ),
            ],
          ),
        );
        return {'result': ok ?? false};
      case 'alert':
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: title.isEmpty ? null : Text(title),
            content: Text(content),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
        return {'result': true};
      case 'input':
        final controller = TextEditingController(text: params['value'] ?? '');
        final value = await showDialog<String?>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: title.isEmpty ? null : Text(title),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(hintText: params['hint'] ?? ''),
              onSubmitted: (text) => Navigator.of(dialogContext).pop(text),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(null),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(controller.text),
                child: const Text('确定'),
              ),
            ],
          ),
        );
        controller.dispose();
        return {'result': value};
      case 'select':
        List<String> options = const [];
        try {
          final decoded = jsonDecode(params['options'] ?? '[]');
          if (decoded is List) {
            options = <String>[for (final e in decoded) '$e'];
          }
        } catch (_) {
          options = const [];
        }
        // select:// 对话框列数缺省为 3（指南默认值）；显式 col 不变。
        final cols = (int.tryParse(params['col'] ?? '') ?? 3).clamp(1, 6);
        final index = await showDialog<int?>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: title.isEmpty ? null : Text(title),
            content: SizedBox(
              width: double.maxFinite,
              child: cols > 1
                  ? ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 400),
                      child: GridView.builder(
                        shrinkWrap: true,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          childAspectRatio: 2.6,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: options.length,
                        itemBuilder: (itemContext, i) => OutlinedButton(
                          onPressed: () => Navigator.of(dialogContext).pop(i),
                          child: Text(
                            options[i],
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < options.length; i++)
                            ListTile(
                              title: Text(options[i]),
                              onTap: () => Navigator.of(dialogContext).pop(i),
                            ),
                        ],
                      ),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(null),
                child: const Text('取消'),
              ),
            ],
          ),
        );
        return {'result': index};
      default:
        return {'result': null};
    }
  }

  // ---------- 摘要与 Cookie 端点 ----------

  /// /__crypto：摘要与 HMAC。q 参数是 JSON：{op, text?, hex?,
  /// keyHex?, msgHex?}。op 为 md5/sha1/sha256/sha512 或
  /// hmac-md5/hmac-sha1/hmac-sha256/hmac-sha512，
  /// 或 pbkdf2（passwordHex/saltHex/iterations/keyBytes/hash）
  /// 或 md5file（name：已存文件的 MD5）
  /// 或 gunzip/gzip（hex 入参，base64 出参：Java GZIP 流走它）
  /// 或 inflate（hex 入参，base64 出参：Java InflaterInputStream 走它）。
  Future<void> _handleCrypto(HttpRequest request) async {
    String result = '';
    try {
      final payload = jsonDecode(request.uri.queryParameters['q'] ?? '{}');
      if (payload is Map) {
        final op = '${payload['op'] ?? ''}';
        if (op == 'pbkdf2') {
          final iterations = ((payload['iterations'] as num?)?.toInt() ?? 1)
              .clamp(1, 10000)
              .toInt();
          final keyBytes = ((payload['keyBytes'] as num?)?.toInt() ?? 16)
              .clamp(1, 1024)
              .toInt();
          final derived = haikuoPbkdf2(
            password: haikuoHexToBytes('${payload['passwordHex'] ?? ''}'),
            salt: haikuoHexToBytes('${payload['saltHex'] ?? ''}'),
            iterations: iterations,
            keyBytes: keyBytes,
            hash: '${payload['hash'] ?? 'sha1'}',
          );
          result = derived
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
        } else if (op == 'md5file') {
          final name = '${payload['name'] ?? ''}';
          final bytes =
              _savedFiles[name] ??
              await _persistedFileBytes(name) ??
              await _presetModuleBytes(name, null);
          if (bytes != null) result = haikuoHashHex('md5', bytes);
        } else if (op == 'gunzip') {
          try {
            result = base64Encode(
              haikuoGunzipBytes(haikuoHexToBytes('${payload['hex'] ?? ''}')),
            );
          } catch (_) {
            result = '';
          }
        } else if (op == 'gzip') {
          try {
            result = base64Encode(
              haikuoGzipBytes(haikuoHexToBytes('${payload['hex'] ?? ''}')),
            );
          } catch (_) {
            result = '';
          }
        } else if (op == 'inflate') {
          try {
            result = base64Encode(
              haikuoInflateBytes(haikuoHexToBytes('${payload['hex'] ?? ''}')),
            );
          } catch (_) {
            result = '';
          }
        } else if (op.startsWith('hmac-')) {
          result = haikuoHmacHex(
            op.substring('hmac-'.length),
            haikuoHexToBytes('${payload['keyHex'] ?? ''}'),
            haikuoHexToBytes('${payload['msgHex'] ?? ''}'),
          );
        } else {
          final hex = payload['hex'];
          final bytes = hex is String
              ? haikuoHexToBytes(hex)
              : utf8.encode('${payload['text'] ?? ''}');
          result = haikuoHashHex(op, bytes);
        }
      }
    } catch (_) {
      result = '';
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'result': result}));
    await request.response.close();
  }

  /// /__cookie：规则的 getCookie/setCookie。op=get 时回罐子里的
  /// Cookie 头；op=set 时把 c 写进该主机的罐子。
  Future<void> _handleCookie(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final host = Uri.tryParse(params['u'] ?? '')?.host ?? '';
    if (params['op'] == 'set') {
      _cookieJar.setCookie(host, params['c'] ?? '');
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'cookie': _cookieJar.headerFor(host)}));
    await request.response.close();
  }

  // ---------- 新增端点（图片/存文件/跨规则/设备信息/收藏历史） ----------

  /// /__img：图片代理。u=原地址，h=请求头 JSON（JS 侧已合并默认头）。
  /// 字节原样回，Content-Type 透传；失败回 404。
  Future<void> _handleImage(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final target = params['u'] ?? '';
    final response = request.response;
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
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
    try {
      final uri = Uri.parse(target);
      final merged = <String, String>{...headers};
      final hasCookieHeader = merged.keys.any(
        (key) => key.toLowerCase() == 'cookie',
      );
      if (!hasCookieHeader) {
        final jarCookie = _cookieJar.headerFor(uri.host);
        if (jarCookie.isNotEmpty) merged['Cookie'] = jarCookie;
      }
      final client = _httpClient ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..idleTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 30));
      merged.forEach((key, value) {
        if (value.isEmpty) return;
        try {
          req.headers.set(key, value);
        } catch (_) {}
      });
      final resp = await req.close().timeout(const Duration(seconds: 30));
      final setCookies = resp.headers['set-cookie'];
      if (setCookies != null && setCookies.isNotEmpty) {
        _cookieJar.store(uri.host, setCookies);
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        response.statusCode = HttpStatus.notFound;
        await resp.drain<void>();
        await response.close();
        return;
      }
      final contentType = resp.headers.contentType;
      if (contentType != null) response.headers.contentType = contentType;
      await response.addStream(resp);
      await response.close();
    } catch (_) {
      try {
        response.statusCode = HttpStatus.notFound;
        await response.close();
      } catch (_) {}
    }
  }

  /// E38：saveFile 统一落点——先写内存 `_savedFiles`（同步生效，
  /// 同页后续读取立即见），再写穿落盘（`imgdec_*` 图片解密缓存
  /// 不落盘，那是会话级缓存）。落盘失败静默（内存语义不受影响）。
  Future<void> _storeSavedFile(String name, Uint8List bytes) async {
    _savedFiles[name] = bytes;
    if (name.startsWith('imgdec_')) return;
    try {
      final root = await _store.root;
      await HaikuoSavedFiles.writeSavedFile(root, name, bytes);
    } catch (_) {
      // 落盘失败不拦规则
    }
  }

  /// E38：deleteFile 统一落点——内存与落盘同删（含 basename 变体）。
  Future<void> _deleteSavedFile(String name) async {
    _savedFiles.remove(name);
    _savedFiles.remove(name.split('/').last);
    try {
      final root = await _store.root;
      await HaikuoSavedFiles.deleteSavedFile(root, name);
      await HaikuoSavedFiles.deleteSavedFile(root, name.split('/').last);
    } catch (_) {
      // 删不掉也不拦规则
    }
  }

  /// E38：读落盘的 saveFile 文件。命中后填回内存（本页后续读走内存，
  /// 不再反复读盘）；没命中回 null（调用方继续走规则文件/预置回退）。
  Future<Uint8List?> _persistedFileBytes(String name) async {
    try {
      final root = await _store.root;
      final bytes = await HaikuoSavedFiles.readSavedFile(root, name);
      if (bytes != null) _savedFiles[name] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// E33：`/__vars` 会话变量端点。GET 回整表快照 `{vars:{...}}`；
  /// POST `{op, key?, value?}` 写表（set/clear/clearAll），回 `{ok}`。
  Future<void> _handleVars(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      if (request.method == 'POST') {
        final bytes = await request.fold<BytesBuilder>(
          BytesBuilder(copy: false),
          (builder, chunk) => builder..add(chunk),
        );
        final payload = jsonDecode(utf8.decode(bytes.takeBytes()));
        if (payload is Map<String, dynamic>) {
          _sessionVars.apply(payload);
        } else if (payload is Map) {
          _sessionVars.apply({
            for (final e in payload.entries) '${e.key}': e.value,
          });
        }
        response.write(jsonEncode({'ok': true}));
      } else {
        response.write(jsonEncode({'vars': _sessionVars.snapshot()}));
      }
    } catch (_) {
      response.write(
        request.method == 'POST'
            ? jsonEncode({'ok': false})
            : jsonEncode({'vars': <String, String>{}}),
      );
    }
    await response.close();
  }

  /// /__savefile：同步存文件。POST 正文是 base64 文本，n=文件名。
  /// 存进 _savedFiles 供 /__files/ 与播放器取用。
  Future<void> _handleSaveFile(HttpRequest request) async {
    final name = request.uri.queryParameters['n'] ?? '';
    final response = request.response;
    response.headers.contentType = ContentType.json;
    if (name.isEmpty) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'ok': false}));
      await response.close();
      return;
    }
    try {
      final bytes = await request.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
      final text = utf8.decode(bytes.takeBytes()).trim();
      await _storeSavedFile(name, Uint8List.fromList(base64Decode(text)));
      response.write(jsonEncode({'ok': true}));
    } catch (_) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'ok': false}));
    }
    await response.close();
  }

  /// /__rulepage/：跨规则取子页。rule=规则标题（归一匹配），
  /// path=子页名/路径。回 {rule, page:{name,path,rule}}，找不到 404。
  Future<void> _handleRulePage(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final title = params['rule'] ?? '';
    final path = params['path'] ?? '';
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      final programs = await _store.list();
      final matched = matchRuleTitle(title, [
        for (final program in programs) program.name,
      ]);
      HaikuoProgram? found;
      if (matched != null) {
        for (final program in programs) {
          if (program.name == matched) {
            found = program;
            break;
          }
        }
      }
      if (found == null) {
        response.statusCode = HttpStatus.notFound;
        response.write(jsonEncode({}));
        await response.close();
        return;
      }
      Map<String, dynamic> rule = const {};
      if (found.rawJson.trim().startsWith('{')) {
        final decoded = jsonDecode(found.rawJson);
        if (decoded is Map) {
          rule = {
            for (final entry in decoded.entries) '${entry.key}': entry.value,
          };
        }
      }
      final pages = rule['pages'];
      Map<String, dynamic>? page;
      if (pages is List) {
        final wanted = Uri.decodeComponent(path);
        for (final item in pages) {
          if (item is! Map) continue;
          final name = '${item['name'] ?? ''}';
          final itemPath = '${item['path'] ?? ''}';
          if (name == wanted ||
              itemPath == wanted ||
              Uri.decodeComponent(name) == wanted ||
              Uri.decodeComponent(itemPath) == wanted) {
            page = {
              for (final entry in item.entries) '${entry.key}': entry.value,
            };
            break;
          }
        }
      }
      if (page == null) {
        response.statusCode = HttpStatus.notFound;
        response.write(jsonEncode({}));
        await response.close();
        return;
      }
      response.write(
        jsonEncode({
          'rule': rule,
          'page': {
            'name': '${page['name'] ?? ''}',
            'path': '${page['path'] ?? path}',
            'rule': page['rule'] ?? '',
          },
        }),
      );
    } catch (_) {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({}));
    }
    await response.close();
  }

  /// /__findrule：规则是否存在。title=标题（归一匹配），
  /// 回 {name: 匹配到的标题}，找不到 404。
  Future<void> _handleFindRule(HttpRequest request) async {
    final title = request.uri.queryParameters['title'] ?? '';
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      final programs = await _store.list();
      final matched = matchRuleTitle(title, [
        for (final program in programs) program.name,
      ]);
      if (matched != null) {
        response.write(jsonEncode({'name': matched}));
        await response.close();
        return;
      }
    } catch (_) {}
    response.statusCode = HttpStatus.notFound;
    response.write(jsonEncode({}));
    await response.close();
  }

  /// /__ip：本机首个非 loopback IPv4，纯文本；取不到回空串。
  Future<void> _handleIp(HttpRequest request) async {
    var ip = '';
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) {
            ip = address.address;
            break;
          }
        }
        if (ip.isNotEmpty) break;
      }
    } catch (_) {
      ip = '';
    }
    request.response.headers.contentType = ContentType.text;
    request.response.write(ip);
    await request.response.close();
  }

  /// /__appinfo：{version, ruleCount}。version 取 appBuild 固定整数
  /// （无 package_info_plus 依赖，按规格用固定常量并注明）。
  Future<void> _handleAppInfo(HttpRequest request) async {
    var count = 0;
    try {
      count = (await _store.list()).length;
    } catch (_) {}
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({'version': appBuild, 'ruleCount': count}),
    );
    await request.response.close();
  }

  /// /__lastrules：最近的规则标题数组（JSON 数组串）。n=条数。
  Future<void> _handleLastRules(HttpRequest request) async {
    final n = (int.tryParse(request.uri.queryParameters['n'] ?? '') ?? 10)
        .clamp(1, 100)
        .toInt();
    List<String> titles = const [];
    try {
      final programs = await _store.list();
      titles = [for (final p in programs.take(n)) p.name];
    } catch (_) {}
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(titles));
    await request.response.close();
  }

  /// /__clipboard：剪贴板纯文本（input 对话框的初始值用）。
  Future<void> _handleClipboard(HttpRequest request) async {
    var text = '';
    try {
      final data = await Clipboard.getData('text/plain');
      text = data?.text ?? '';
    } catch (_) {}
    request.response.headers.contentType = ContentType.text;
    request.response.write(text);
    await request.response.close();
  }

  /// /__paste：云剪贴板 JS 桥（仅云 6）。POST JSON
  /// `{op: 'list'|'share'|'parse', ...}`，回 `{ok, result/error}`；
  /// 规则侧同步 XHR 等着，Dart 侧 30 秒超时内回。逻辑见
  /// haikuo_paste_bridge.dart（可注入假传输做单元测试）。
  Future<void> _handlePaste(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      final bytes = await request.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      final payload = decoded is Map<String, dynamic>
          ? decoded
          : decoded is Map
          ? <String, dynamic>{
              for (final entry in decoded.entries) '${entry.key}': entry.value,
            }
          : <String, dynamic>{};
      final result = await handlePasteBridgeRequest(
        payload,
        upload: uploadCloud6ShareCode,
        fetchText: fetchPasteText,
      );
      response.write(jsonEncode(result));
    } catch (_) {
      response.write(jsonEncode({'ok': false, 'error': '云剪贴板请求无法解析'}));
    }
    await response.close();
  }

  /// `__proxyserver` 路径：本地代理服务。把查询串交运行时里的
  /// 代理代码求值；结果是 {statusCode, body, headers} 信封就按信封
  /// 响应，否则当正文回（m3u8 类型）。30 秒超时回 502。
  /// 注：运行时正卡在同步对话框 XHR 里时，求值会等对话框先处理完。
  Future<void> _handleProxyServer(HttpRequest request) async {
    final id = parseProxyServerId(request.uri.path) ?? '';
    final response = request.response;
    if (id.isEmpty || _controller == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    try {
      final queryObj = <String, dynamic>{};
      request.uri.queryParameters.forEach((key, value) {
        queryObj[key] = value;
      });
      final raw = await _controller!
          .runJavaScriptReturningResult(
            'window.__haikuoProxyServe(${jsonEncode(id)}, '
            '${jsonEncode(jsonEncode(queryObj))});',
          )
          .timeout(const Duration(seconds: 30));
      final text = _sniffResultText(raw);
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map && decoded.containsKey('statusCode')) {
          response.statusCode = (decoded['statusCode'] as num?)?.toInt() ?? 200;
          final headers = decoded['headers'];
          if (headers is Map) {
            headers.forEach((key, value) {
              try {
                response.headers.set('$key', '$value');
              } catch (_) {}
            });
          }
          response.write('${decoded['body'] ?? ''}');
          await response.close();
          return;
        }
      } catch (_) {
        // 不是信封，当正文回
      }
      response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
        charset: 'utf-8',
      );
      response.write(text);
      await response.close();
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {}
    }
  }

  /// /__webview：fetchCodeByWebView。POST JSON {url, headers,
  /// timeout, checkJs, blockRules}，回 {html}。
  Future<void> _handleWebviewFetch(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    String html = '';
    try {
      final bytes = await request.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, chunk) => builder..add(chunk),
      );
      final payload = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (payload is Map) {
        html = await _fetchHtmlByWebView(payload);
      }
    } catch (_) {
      html = '';
    }
    response.write(jsonEncode({'html': html}));
    await response.close();
  }

  /// 隐藏 WebView 取码：加载页面，checkJs 轮询通过（或无 checkJs
  /// 时加载完成 + 宽限）后取 outerHTML；超时回空。
  Future<String> _fetchHtmlByWebView(Map payload) async {
    final url = '${payload['url'] ?? ''}';
    if (!url.startsWith('http://') && !url.startsWith('https://')) return '';
    if (!mounted) return '';
    final timeoutMs = (payload['timeout'] as num?)?.toInt() ?? 30000;
    final timeout = Duration(milliseconds: timeoutMs.clamp(1000, 120000));
    final checkJs = '${payload['checkJs'] ?? ''}';
    final blockRules = switch (payload['blockRules']) {
      final List list => <String>[for (final e in list) '$e'],
      _ => <String>[],
    };
    final headers = <String, String>{};
    final rawHeaders = payload['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        headers['$key'] = '$value';
      });
    }
    // E111-F1：headers 里的 User-Agent 须走 setUserAgent（loadRequest
    // 的头改不了 WebView UA），拆出后不再进 loadRequest。
    final splitUa = haikuoSplitUserAgent(headers);
    final pageUa = splitUa.userAgent;
    final loadHeaders = splitUa.headers;
    final loaded = Completer<void>();
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF120B20))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (navRequest) {
            final blocked = blockRules.any(
              (rule) => wildcardContains(navRequest.url, rule),
            );
            return blocked
                ? NavigationDecision.prevent
                : NavigationDecision.navigate;
          },
          onPageFinished: (_) {
            if (!loaded.isCompleted) loaded.complete();
          },
        ),
      );
    if (!mounted) return '';
    setState(() => _webviewFetchController = controller);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      if (pageUa.isNotEmpty) {
        await controller.setUserAgent(pageUa);
      }
      await controller.loadRequest(Uri.parse(url), headers: loadHeaders);
      final deadline = DateTime.now().add(timeout);
      var passed = checkJs.isEmpty;
      while (DateTime.now().isBefore(deadline)) {
        if (checkJs.isNotEmpty) {
          try {
            // 垫片与嗅探共用同一构造；判定改哨兵（F3）：null/undefined/
            // false/"" 回空，其余一律回哨兵。无 checkJs 分支不动。
            final pad = haikuoBridgePadScript(await _pageCookiesFor(url));
            final script =
                '(function(){try{$pad}catch(e){}'
                'try{var __r=(0,eval)(${jsonEncode(checkJs)});'
                'return (__r===null||__r===undefined||__r===false||__r==="")'
                '?"":${jsonEncode(haikuoCheckJsPassSentinel)};}catch(e){return "";}})()';
            final raw = await controller.runJavaScriptReturningResult(script);
            await _drainBridgeWriteFiles(controller);
            if (_sniffResultText(raw) == haikuoCheckJsPassSentinel) {
              passed = true;
              break;
            }
          } catch (_) {
            // 页面还没好，这一拍跳过
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
        } else {
          await loaded.future.timeout(
            deadline.difference(DateTime.now()),
            onTimeout: () {},
          );
          // 加载完成后再宽限一会，让动态内容渲染出来。
          await Future<void>.delayed(const Duration(milliseconds: 800));
          passed = true;
          break;
        }
      }
      if (!passed) return '';
      final raw = await controller.runJavaScriptReturningResult(
        'document.documentElement.outerHTML',
      );
      return _sniffResultText(raw);
    } catch (_) {
      return '';
    } finally {
      if (mounted) {
        setState(() {
          if (identical(_webviewFetchController, controller)) {
            _webviewFetchController = null;
          }
        });
      }
    }
  }

  /// 收藏/历史/书签端点：GET 取列表（?rule=&group=），
  /// POST 写（action=add/toggle）。
  Future<void> _handleCollections(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      if (request.method == 'POST') {
        final bytes = await request.fold<BytesBuilder>(
          BytesBuilder(copy: false),
          (builder, chunk) => builder..add(chunk),
        );
        final payload = jsonDecode(utf8.decode(bytes.takeBytes()));
        if (payload is Map) {
          final entry = <String, dynamic>{
            'rule': '${payload['rule'] ?? ''}',
            'url': '${payload['url'] ?? ''}',
            'title': '${payload['title'] ?? ''}',
            'pic': '${payload['pic'] ?? ''}',
          };
          if (path == '/__history') {
            await _store.recordHistory(
              rule: entry['rule'] as String,
              url: entry['url'] as String,
              title: entry['title'] as String,
              pic: entry['pic'] as String,
            );
            response.write(jsonEncode({'ok': true}));
          } else if (path == '/__favorite') {
            final favorite = await _store.toggleFavorite(entry);
            response.write(jsonEncode({'favorite': favorite}));
          } else {
            response.write(jsonEncode({'ok': true}));
          }
        } else {
          response.write(jsonEncode({'ok': false}));
        }
        await response.close();
        return;
      }
      final params = request.uri.queryParameters;
      final rule = params['rule'];
      List<Map<String, dynamic>> entries;
      if (path == '/__history') {
        entries = await _store.listHistory(
          rule: rule == null || rule.isEmpty ? null : rule,
        );
      } else if (path == '/__bookmark') {
        entries = await _store.listBookmarks(
          rule: rule == null || rule.isEmpty ? null : rule,
        );
      } else {
        final group = params['group'];
        entries = await _store.listFavorites(
          rule: rule == null || rule.isEmpty ? null : rule,
          group: group == null || group.isEmpty ? null : group,
        );
      }
      response.write(jsonEncode({'entries': entries}));
    } catch (_) {
      response.write(jsonEncode({'entries': []}));
    }
    await response.close();
  }

  /// H04 `GET /__downloads`：列 haikuo_downloads/ 目录，
  /// 回 {entries:[{name, size, mtime, path}]}（mtime 新的在前）；
  /// `POST /__downloads {action:'delete', name}`：删文件，
  /// name 只取 basename，禁路径穿越。读不到目录时回空列表。
  Future<void> _handleDownloads(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/haikuo_downloads');
      if (request.method == 'POST') {
        final bytes = await request.fold<BytesBuilder>(
          BytesBuilder(copy: false),
          (builder, chunk) => builder..add(chunk),
        );
        final payload = jsonDecode(utf8.decode(bytes.takeBytes()));
        var ok = false;
        if (payload is Map && payload['action'] == 'delete') {
          final base = haikuoSafeFileName('${payload['name'] ?? ''}');
          if (base != null) {
            final file = File('${dir.path}/$base');
            if (await file.exists()) {
              await file.delete();
              ok = true;
            }
          }
        }
        response.write(jsonEncode({'ok': ok}));
        await response.close();
        return;
      }
      final entries = <Map<String, dynamic>>[];
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          try {
            final stat = await entity.stat();
            entries.add({
              'name': entity.path.split('/').last,
              'size': stat.size,
              'mtime': stat.modified.millisecondsSinceEpoch,
              'path': entity.path,
            });
          } catch (_) {
            // 单个文件读不到就跳过，不拦整个列表
          }
        }
      }
      response.write(
        jsonEncode({'entries': sortHaikuoDownloadEntries(entries)}),
      );
    } catch (_) {
      response.write(jsonEncode({'entries': []}));
    }
    await response.close();
  }

  /// /__files/ 的预置模块回退：_savedFiles 里没有时，按清单
  /// （当前规则映射 → __ 后缀 → 精确文件名 → 归一化）找 assets
  /// 里的预置模块文件。找不到回 null（调用方回 404）。
  Future<Uint8List?> _presetModuleBytes(String name, String? ruleTitle) async {
    try {
      final cached = _presetModuleCache[name];
      if (cached != null) return cached;
      _presetManifest ??= await _loadPresetManifest();
      final manifest = _presetManifest!;
      final resolved = resolvePresetModule(
        requestBasename: name,
        ruleTitle: ruleTitle ?? '',
        manifest: manifest,
      );
      if (resolved == null) return null;
      final data = await rootBundle.load('assets/haikuo_modules/$resolved');
      final bytes = data.buffer.asUint8List();
      _presetModuleCache[name] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// /__files/ 的规则私有文件回退：备份导入时落盘的模块文件
  ///（`files/<规则>/` 与共享区），供 $.require/readFile 按名取用。
  /// 查不到回 null（调用方继续走预置模块回退）。
  Future<Uint8List?> _ruleFileBytes(String name, String? ruleTitle) async {
    try {
      final key = '${ruleTitle ?? ''}\u0000$name';
      final cached = _ruleFileCache[key];
      if (cached != null) return cached;
      final root = await _store.root;
      final bytes = await HaikuoRuleFiles.readRuleFile(
        root,
        ruleTitle ?? '',
        name,
      );
      if (bytes != null) _ruleFileCache[key] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, List<String>>> _loadPresetManifest() async {
    try {
      final text = await rootBundle.loadString(
        'assets/haikuo_modules_manifest.json',
      );
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final rules = decoded['rules'];
        if (rules is Map) {
          return {
            for (final entry in rules.entries)
              '${entry.key}': <String>[
                if (entry.value is List)
                  for (final file in entry.value as List) '$file',
              ],
          };
        }
      }
    } catch (_) {
      // 清单读不到（widget 测试下无 assets），回空清单
    }
    return const {};
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
      if (request.uri.path == '/__crypto') {
        await _handleCrypto(request);
        return;
      }
      if (request.uri.path == '/__vars') {
        await _handleVars(request);
        return;
      }
      if (request.uri.path == '/__cookie') {
        await _handleCookie(request);
        return;
      }
      if (request.uri.path == '/__dialog') {
        await _handleDialog(request);
        return;
      }
      if (request.uri.path == '/__img') {
        await _handleImage(request);
        return;
      }
      if (request.uri.path == '/__savefile') {
        await _handleSaveFile(request);
        return;
      }
      if (request.uri.path == '/__rulepage/' ||
          request.uri.path == '/__rulepage') {
        await _handleRulePage(request);
        return;
      }
      if (request.uri.path == '/__findrule') {
        await _handleFindRule(request);
        return;
      }
      if (request.uri.path == '/__ip') {
        await _handleIp(request);
        return;
      }
      if (request.uri.path == '/__appinfo') {
        await _handleAppInfo(request);
        return;
      }
      if (request.uri.path == '/__lastrules') {
        await _handleLastRules(request);
        return;
      }
      if (request.uri.path == '/__clipboard') {
        await _handleClipboard(request);
        return;
      }
      if (request.uri.path == '/__paste') {
        await _handlePaste(request);
        return;
      }
      if (request.uri.path.startsWith('/__proxyserver/')) {
        await _handleProxyServer(request);
        return;
      }
      if (request.uri.path == '/__webview') {
        await _handleWebviewFetch(request);
        return;
      }
      if (request.uri.path == '/__history' ||
          request.uri.path == '/__collection' ||
          request.uri.path == '/__bookmark' ||
          request.uri.path == '/__favorite') {
        await _handleCollections(request);
        return;
      }
      if (request.uri.path == '/__downloads') {
        await _handleDownloads(request);
        return;
      }
      if (request.uri.path.startsWith('/__files/')) {
        final name = Uri.decodeComponent(
          request.uri.path.substring('/__files/'.length),
        );
        // ?rule= 标题供预置模块回退按当前规则映射。
        final ruleTitle = request.uri.queryParameters['rule'];
        final content =
            _savedFiles[name] ??
            await _persistedFileBytes(name) ??
            await _ruleFileBytes(name, ruleTitle) ??
            await _presetModuleBytes(name, ruleTitle);
        if (content == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.headers.contentType = _savedFileContentType(name);
          request.response.add(content);
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

  /// saveFile 存下的文件按扩展名给内容类型：m3u8 给播放器、
  /// 字幕给文本、图片给图片，其余按字节流。
  ContentType _savedFileContentType(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.m3u8')) {
      return ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
    }
    if (lower.endsWith('.json')) {
      return ContentType.json;
    }
    if (lower.endsWith('.srt') ||
        lower.endsWith('.vtt') ||
        lower.endsWith('.txt') ||
        lower.endsWith('.lrc')) {
      return ContentType('text', 'plain', charset: 'utf-8');
    }
    if (lower.endsWith('.png')) return ContentType('image', 'png');
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return ContentType('image', 'jpeg');
    }
    if (lower.endsWith('.gif')) return ContentType('image', 'gif');
    if (lower.endsWith('.webp')) return ContentType('image', 'webp');
    if (lower.endsWith('.mp4')) return ContentType('video', 'mp4');
    if (lower.endsWith('.html') || lower.endsWith('.htm')) {
      return ContentType.html;
    }
    return ContentType.binary;
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
    // 规则 fetch() 的选项：t=超时毫秒，r=0 不跟重定向，
    // o=1 只要响应头，hex=1 正文按 base64 回（规则再转十六进制）。
    final timeoutMs = int.tryParse(params['t'] ?? '') ?? 30000;
    final timeout = Duration(milliseconds: timeoutMs.clamp(5000, 120000));
    final followRedirects = params['r'] != '0';
    final onlyHeaders = params['o'] == '1';
    final hexBody = params['hex'] == '1';
    // cs= 显式字符集（规则请求头 Content-Type 的 charset 或 opt.charset）：
    // 按它解码正文，否则走自动探测。
    final charset = (params['cs'] ?? '').trim().toLowerCase();
    final response = request.response;
    response.headers.contentType = ContentType.json;
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      response.write(
        jsonEncode({'code': 0, 'body': '', 'headers': {}, 'url': target}),
      );
      await response.close();
      return;
    }
    final uri = Uri.parse(target);
    final merged = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
      ...headers,
    };
    // 脚本没带 Cookie 时，带上罐子里同主机的 Cookie。
    final hasCookieHeader = merged.keys.any(
      (key) => key.toLowerCase() == 'cookie',
    );
    if (!hasCookieHeader) {
      final jarCookie = _cookieJar.headerFor(uri.host);
      if (jarCookie.isNotEmpty) merged['Cookie'] = jarCookie;
    }
    try {
      // 共用客户端：同一主机的连接复用，不再每次取数都重建 TCP+TLS。
      // UA 走下面逐请求的头设置，不再写客户端默认值（多请求会互相串）。
      final client = _httpClient ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..idleTimeout = const Duration(seconds: 15);
      // 规则 proxy 字段（规则作者配置）优先于默认直连：本页一个规则，
      // 代理固定写在共用客户端上。规则没有 proxy 字段时不写 findProxy，
      // 客户端走默认直连。
      final proxy = _ruleProxy;
      if (proxy != null) {
        client.findProxy = (_) => 'PROXY $proxy';
      }
      // 只要响应头且是 GET：发 HEAD，省得拉正文。
      final effectiveMethod = onlyHeaders && method == 'GET' ? 'HEAD' : method;
      final req = await client.openUrl(effectiveMethod, uri).timeout(timeout);
      req.followRedirects = followRedirects;
      merged.forEach((key, value) {
        if (value.isEmpty) return;
        if (key.toLowerCase() == 'content-length') return;
        try {
          req.headers.set(key, value);
        } catch (_) {
          // 个别头设置不进去，跳过
        }
      });
      if (method != 'GET' && method != 'HEAD' && body.isNotEmpty) {
        req.add(utf8.encode(body));
      }
      final resp = await req.close().timeout(timeout);
      // 响应头按官方形态回：每个头名对应一个值数组。
      final headerMap = <String, List<String>>{};
      resp.headers.forEach((name, values) {
        headerMap[name] = values;
      });
      // Set-Cookie 存进罐子，下次同主机请求自动带上。
      final setCookies = resp.headers['set-cookie'];
      if (setCookies != null && setCookies.isNotEmpty) {
        _cookieJar.store(uri.host, setCookies);
      }
      String bodyText;
      if (onlyHeaders) {
        await resp.drain<void>();
        bodyText = '';
      } else {
        final bytes = await resp.fold<BytesBuilder>(
          BytesBuilder(copy: false),
          (builder, chunk) => builder..add(chunk),
        );
        final raw = bytes.takeBytes();
        bodyText = hexBody
            ? base64Encode(raw)
            : _decodeWithCharset(raw, charset);
      }
      // 最终地址：跟随重定向后的实际地址，onlyHeaders 形态回给规则。
      final finalUri = haikuoResolveFinalUri(
        uri,
        resp.redirects.map((redirect) => redirect.location),
      );
      response.write(
        jsonEncode({
          'code': resp.statusCode,
          'body': bodyText,
          'headers': headerMap,
          'url': finalUri.toString(),
        }),
      );
      await response.close();
    } catch (error) {
      response.write(
        jsonEncode({
          'code': 0,
          'body': '',
          'headers': {},
          'url': target,
          'error': '$error',
        }),
      );
      await response.close();
    }
  }

  /// 按显式字符集解码响应正文：gbk 系走 GbkCodec，utf-8 走宽容
  /// 解码，其余/空走自动探测（decodeText）。
  String _decodeWithCharset(List<int> bytes, String charset) {
    switch (charset) {
      case 'gbk':
      case 'gb2312':
      case 'gb18030':
      case 'gb_2312':
        try {
          return const GbkCodec(allowInvalid: true).decode(bytes);
        } catch (_) {
          return HaikuoCodec.decodeText(bytes);
        }
      case 'utf-8':
      case 'utf8':
        return utf8.decode(bytes, allowMalformed: true);
      case 'iso-8859-1':
      case 'latin1':
        return latin1.decode(bytes, allowInvalid: true);
      default:
        return HaikuoCodec.decodeText(bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _inline == null && !_x5CanGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_inlineFullscreen) {
          setState(() => _inlineFullscreen = false);
          _reapplyRunnerSystemUiSoon();
          return;
        }
        // G11 canBack：内嵌播放器未开、x5 行有历史时，系统返回键
        // 先退行内历史，不退规则页（与 onBackBtn 分流一致）。
        if (_inline == null && _x5CanGoBack) {
          unawaited(_x5RowBack());
          return;
        }
        _closeInlinePlayer();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF120B20),
        // 壳子顶栏已拿掉：规则自带顶栏即顶栏（对标官方海阔视界），
        // 收藏/搜索/刷新钮在运行时 header 里，经 shellFavorite /
        // shellSearch / shellReload 桥接消息进来。内容贴着状态栏下方，
        // 内嵌全屏时连安全区一起让出，播放器真正占满屏幕。
        body: Stack(
          children: [
            SafeArea(
              top: !haikuoImmersiveUi(
                pageImmersive: _pageImmersive,
                inlineFullscreen: _inlineFullscreen,
              ),
              bottom: false,
              child: _error != null
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
                                      subtitleUrl: inline.subtitleUrl,
                                      headers: inline.headers,
                                      lines: inline.lines,
                                      danmuUrl: inline.danmuUrl,
                                      fullscreen: _inlineFullscreen,
                                      onFullscreenChanged: (value) {
                                        setState(
                                          () => _inlineFullscreen = value,
                                        );
                                        _reapplyRunnerSystemUiSoon();
                                      },
                                      onClose: _closeInlinePlayer,
                                      onAspectRatioChanged: (ratio) => setState(
                                        () => _inlineAspectRatio = ratio,
                                      ),
                                    ),
                            ),
                            Expanded(
                              child: WebViewWidget(controller: _controller!),
                            ),
                            // 嗅探用的隐藏 WebView：1 像素占位，进树才能加载页面。
                            if (_sniffController != null)
                              SizedBox(
                                width: 1,
                                height: 1,
                                child: WebViewWidget(
                                  controller: _sniffController!,
                                ),
                              ),
                            // fetchCodeByWebView 用的隐藏 WebView：同上，请求结束卸载。
                            if (_webviewFetchController != null)
                              SizedBox(
                                width: 1,
                                height: 1,
                                child: WebViewWidget(
                                  controller: _webviewFetchController!,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
            ),
            // G11 原生 x5 行：叠在规则 WebView 内容区上方；内嵌
            // 全屏时不显示（播放器占满屏幕，行不能盖住它）。
            if (_x5RowController != null &&
                _x5RowSession != null &&
                _x5RowSession!.visible &&
                !_inlineFullscreen &&
                _error == null)
              _buildX5RowOverlay(context),
            // W6 floatVideo：悬浮嗅探播放层（只在门开且已检出时出现），
            // 盖在原生行之上；内嵌全屏时不显示。
            if (_floatVideoUrl.isNotEmpty &&
                _x5RowSession != null &&
                identical(_floatVideoSession, _x5RowSession) &&
                _x5RowSession!.visible &&
                !_inlineFullscreen &&
                _error == null)
              _buildFloatVideoOverlay(),
            // 搜索栏改浮在内容上方（原先挂在 AppBar bottom）：平时不占位，
            // 内嵌全屏时不显示。
            if (_showSearch && !_inlineFullscreen)
              Positioned(
                top: MediaQuery.paddingOf(context).top,
                left: 0,
                right: 0,
                child: HaikuoSearchBar(
                  key: ValueKey<int>(_searchNonce),
                  initialKeyword: _searchKeyword,
                  onSubmitted: _runSearch,
                  onClosed: () => setState(() => _showSearch = false),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 海阔搜索栏：顶栏下的一行输入框，输完按搜索或回车提交，
/// 关键词交给运行时的 searchFind/search_url 执行。
class HaikuoSearchBar extends StatefulWidget {
  const HaikuoSearchBar({
    super.key,
    this.initialKeyword = '',
    required this.onSubmitted,
    required this.onClosed,
  });

  final String initialKeyword;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClosed;

  @override
  State<HaikuoSearchBar> createState() => _HaikuoSearchBarState();
}

class _HaikuoSearchBarState extends State<HaikuoSearchBar> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialKeyword,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final word = _controller.text.trim();
    if (word.isEmpty) return;
    widget.onSubmitted(word);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                hintText: '搜索…',
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search_rounded),
            onPressed: _submit,
          ),
          IconButton(
            tooltip: '清除',
            icon: const Icon(Icons.clear_rounded),
            onPressed: () => _controller.clear(),
          ),
          IconButton(
            tooltip: '关闭搜索栏',
            icon: const Icon(Icons.close_rounded),
            onPressed: widget.onClosed,
          ),
        ],
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
class HaikuoWebPage extends StatefulWidget {
  const HaikuoWebPage({super.key, required this.url, required this.title});

  final String url;
  final String title;

  @override
  State<HaikuoWebPage> createState() => _HaikuoWebPageState();
}

class _HaikuoWebPageState extends State<HaikuoWebPage> {
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
    this.subtitleUrl = '',
    this.lines = const [],
    this.danmuUrl = '',
    this.danmuFetcher,
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

  /// 条目自带的字幕地址：非空时打开媒体后加载为外挂字幕；
  /// 字幕加载失败不影响播放本身。
  final String subtitleUrl;

  /// 多线路表（播放 JSON 的 urls/names）：多于 1 条时画质按钮
  /// 显示当前线路名、点开可切换；空表示只有单条地址。
  final List<HaikuoPlayLine> lines;

  /// 弹幕地址（播放 JSON 的 danmu）：空串表示无弹幕；`web://`
  /// 形态不取数、不渲染。
  final String danmuUrl;

  /// 测试注入弹幕取数：默认走 HTTP 取 danmuUrl。
  final HaikuoDanmuFetcher? danmuFetcher;

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
    this.subtitleUrl = '',
    this.lines = const [],
    this.danmuUrl = '',
    this.danmuFetcher,
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

  /// 条目自带的字幕地址：透传给播放器视图加载为外挂字幕。
  final String subtitleUrl;

  /// 多线路表：透传给播放器视图（多于 1 条时可切换线路）。
  final List<HaikuoPlayLine> lines;

  /// 弹幕地址：透传给播放器视图（空串表示无弹幕）。
  final String danmuUrl;

  /// 测试注入弹幕取数：透传给播放器视图。
  final HaikuoDanmuFetcher? danmuFetcher;

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
  late String _subtitleUrl = widget.subtitleUrl;
  // 切集递送的请求头：初始取 widget.headers，切集后取递送值。
  late Map<String, String> _headers = widget.headers;
  // 多线路：初始取 widget.lines（空则以单条地址拼一条），切集后取递送值。
  late List<HaikuoPlayLine> _lines = widget.lines.isNotEmpty
      ? widget.lines
      : [HaikuoPlayLine(name: '', url: widget.url, headers: widget.headers)];
  int _lineIndex = 0;
  bool _switchingLine = false;
  // 弹幕地址与轻量控制器（方案乙）：切集/切线路时重置重取。
  late String _danmuUrl = widget.danmuUrl;
  late final HaikuoDanmuController _danmuController = HaikuoDanmuController();
  // 弹幕开关状态键：只有开关/加载状态变化时才重建控件层，
  // 位置同步的通知只驱动弹幕层本身（AnimatedBuilder）。
  (bool, bool, bool, bool, int)? _danmuStatusKey;
  // 视频宽高比：videoParams 到达前默认 16:9（与旧槽位一致），
  // 到达后按真实尺寸算，竖屏视频全屏进竖屏、槽位按比例加高。
  double _aspectRatio = 16 / 9;
  double _speed = 1.0;
  String? _error;
  bool _resolving = false;
  bool _panel = false;
  // 断线自动重试：流错误/打开失败时退避重开、断点续播，耗尽后才亮错卡。
  // 最多 3 次，退避 1s/2s/4s；进度超过断点 3 秒即认为本链恢复，清零计数。
  static const int _maxAutoRetries = 3;
  static const List<Duration> _retryBackoff = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];
  static const Duration _recoveryProgress = Duration(seconds: 3);
  int _autoRetryCount = 0;
  Timer? _retryTimer;
  Duration _lastPosition = Duration.zero;
  Duration _retryAnchor = Duration.zero;
  bool _retrying = false;
  // 打开代次：换集/换线路时加一，旧打开的滞后失败不再触发新内容的重试。
  int _openGeneration = 0;
  bool _mpvResilienceApplied = false;

  bool get _hasEpisodes => widget.episodes.isNotEmpty;
  bool get _hasPrev => _hasEpisodes && _index > 0;
  bool get _hasNext => _hasEpisodes && _index < widget.episodes.length - 1;

  /// 当前线路名：单线路时固定 '默认'（与旧行为一字不差）。
  String get _currentLineName {
    if (_lines.length <= 1) return '默认';
    final name = _lines[_lineIndex].name;
    return name.isEmpty ? '线路${_lineIndex + 1}' : name;
  }

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
    _errorSubscription = _player.stream.error.listen(_handlePlaybackError);
    _positionSubscription = _player.stream.position.listen((position) {
      // 最后已知位置是断点续播的锚：0 位置事件（刚打开时）不抹掉旧锚。
      if (position > Duration.zero) _lastPosition = position;
      // 本链恢复：进度超过断点 3 秒，清零重试计数。
      if (_autoRetryCount > 0 && position > _retryAnchor + _recoveryProgress) {
        _autoRetryCount = 0;
        _retryAnchor = Duration.zero;
      }
      unawaited(_speedTracker.tick());
      _reportState();
      _syncDanmu();
    });
    _completedSubscription = _player.stream.completed.listen((completed) {
      if (!completed) return;
      // 正常播完：挂起的重试不再有意义，取消并清零。
      _cancelRetryTimer();
      if (_hasNext) _switchEpisode(_index + 1);
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
    _danmuController.addListener(_onDanmuChanged);
    _open();
    _loadDanmu();
  }

  /// 弹幕控制器变化：只有开关/加载状态翻转时重建控件层。
  void _onDanmuChanged() {
    if (!mounted) return;
    final key = (
      _danmuController.enabled,
      _danmuController.loading,
      _danmuController.failed,
      _danmuController.loaded,
      _danmuController.items.length,
    );
    if (key == _danmuStatusKey) return;
    _danmuStatusKey = key;
    setState(() {});
  }

  /// 播放位置同步给弹幕层（位置驱动弹幕飞行，暂停即停、seek 即正）。
  void _syncDanmu() {
    final state = _player.state;
    _danmuController.update(
      position: state.position,
      duration: state.duration,
      playing: state.playing,
      rate: _speed,
    );
  }

  /// 取当前集的弹幕：地址不可取（空串/`web://`）时重置、不取数。
  void _loadDanmu() {
    if (!haikuoDanmuUrlIsFetchable(_danmuUrl)) {
      _danmuController.reset();
      return;
    }
    unawaited(
      _danmuController.load(_danmuUrl, _headers, fetcher: widget.danmuFetcher),
    );
  }

  /// 给 onStateChange 上报当前状态：播/停切换必报，进度只在整秒
  /// 变化时报，避免每帧刷回调。
  void _reportState() {
    final report = widget.onStateChange;
    if (report == null || !mounted) return;
    final state = _player.state;
    final second = state.position.inSeconds;
    if (second == _lastReportedSecond &&
        state.playing == _lastReportedPlaying) {
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
    // 挂起的重试随视图一起死：关闭/退出时绝不再重开。
    _retryTimer?.cancel();
    _retryTimer = null;
    widget.controller?.onDeliver = null;
    widget.controller?.onRequestEpisode = null;
    _danmuController.removeListener(_onDanmuChanged);
    _danmuController.dispose();
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

  Future<void> _open({Duration? resumeFrom}) async {
    final ticket = _openGeneration;
    try {
      await _applyMpvResilience();
      // 断点续播：Media.start 由原生层在加载时经 mpv start 属性生效，
      // 比打开后再 seek 更稳；2 秒内从头播即可，不必带 start。
      final start =
          resumeFrom != null && resumeFrom > const Duration(seconds: 2)
          ? resumeFrom
          : null;
      await _player.open(Media(_url, httpHeaders: _headers, start: start));
      await _player.setRate(_speed);
      // 条目自带字幕：加载为外挂字幕，失败不影响播放。
      if (_subtitleUrl.isNotEmpty) {
        try {
          await _player.setSubtitleTrack(SubtitleTrack.uri(_subtitleUrl));
        } catch (_) {
          // 字幕加载失败，忽略
        }
      }
      _reportState();
    } catch (error) {
      // 滞后失败（已换集/换线路）不触发新内容的重试。
      if (!mounted || ticket != _openGeneration) return;
      _handlePlaybackError('$error');
    }
  }

  /// MPV 断线容错参数：只对原生 mpv 生效（假播放器/非原生平台跳过），
  /// 每个播放器只设一次，任一属性失败都不影响播放。
  /// 依据：media_kit 1.2.6 的 NativePlayer.setProperty（mpv_set_property_string），
  /// 选项语义见 mpv/FFmpeg 文档；手机实测前只认接口真实、效果待验。
  Future<void> _applyMpvResilience() async {
    if (_mpvResilienceApplied) return;
    _mpvResilienceApplied = true;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    for (final entry in const {
      // FFmpeg http 层断线重连：读超时/断流时由 FFmpeg 自己重建连接续读，
      // mpv 不再直接报 ffurl_read 超时错。
      'stream-lavf-o':
          'reconnect=1,reconnect_at_eof=1,reconnect_streamed=1,reconnect_delay_max=5',
      // HLS 分片拉取失败时 demuxer 层多试几次。
      'demuxer-lavf-o': 'seg_max_retry=3',
      // 慢网多等一会再判超时。
      'network-timeout': '30',
    }.entries) {
      try {
        await platform.setProperty(entry.key, entry.value);
      } catch (_) {
        // 单个属性失败忽略，继续设下一个。
      }
    }
  }

  /// 流错误处理：先退避重试续播，耗尽后才亮错卡。
  void _handlePlaybackError(String message) {
    if (!mounted || _error != null) return;
    // 同一次故障可能连发多条错误：已有重试在等时，后到的不再重复排队。
    if (_retryTimer != null) return;
    if (_autoRetryCount >= _maxAutoRetries) {
      setState(() => _error = message);
      return;
    }
    final ticket = _openGeneration;
    _autoRetryCount++;
    _retryAnchor = _lastPosition;
    final resumeFrom = _lastPosition;
    setState(() => _retrying = true);
    _retryTimer = Timer(_retryBackoff[_autoRetryCount - 1], () {
      _retryTimer = null;
      if (!mounted || ticket != _openGeneration) return;
      setState(() => _retrying = false);
      unawaited(_open(resumeFrom: resumeFrom));
    });
  }

  /// 取消挂起的重试并清零计数（换集/换线路/播完/手动重试时调用）。
  void _cancelRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _autoRetryCount = 0;
    _retryAnchor = Duration.zero;
  }

  void _onDelivered({
    required String url,
    required String title,
    required int index,
    String subtitleUrl = '',
    Map<String, String> headers = const {},
    List<HaikuoPlayLine> lines = const [],
    String danmuUrl = '',
  }) {
    if (!mounted) return;
    // 新内容：旧内容的重试链作废，代次加一防滞后失败串扰。
    _openGeneration++;
    _cancelRetryTimer();
    setState(() {
      _url = url;
      _title = title;
      _index = index;
      _subtitleUrl = subtitleUrl;
      _headers = headers;
      _lines = lines.isNotEmpty
          ? lines
          : [HaikuoPlayLine(name: '', url: url, headers: headers)];
      _lineIndex = 0;
      _danmuUrl = danmuUrl;
      _resolving = false;
      _error = null;
      _retrying = false;
    });
    widget.onCurrentChanged?.call(index, title);
    _danmuController.reset();
    unawaited(_open());
    _loadDanmu();
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
                      widget.seriesTitle.isEmpty ? '选集' : widget.seriesTitle,
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

  /// 线路选择表：与选集表同形（深色 bottom sheet + 行列表 + 当前勾选）。
  Future<void> _showLines() async {
    if (_lines.length <= 1) {
      _toast('该站点只提供一种清晰度');
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
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '选择线路',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _lines.length,
                itemBuilder: (context, i) {
                  final current = i == _lineIndex;
                  final label = _lines[i].name.isEmpty
                      ? '线路${i + 1}'
                      : _lines[i].name;
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      current ? Icons.play_arrow : Icons.play_circle_outline,
                      color: current ? Colors.orangeAccent : Colors.white70,
                    ),
                    title: Text(
                      label,
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
    if (selected != null) unawaited(_switchLine(selected));
  }

  /// 换线路：换 url+headers 重开，best-effort 回原位；弹幕随新线路的
  /// 头重取（同一 dm 地址、头变了也可能影响取数成败）。
  Future<void> _switchLine(int index) async {
    if (_switchingLine || index == _lineIndex) return;
    if (index < 0 || index >= _lines.length) return;
    final line = _lines[index];
    if (line.url.isEmpty) return;
    _switchingLine = true;
    // 换线路是新打开：旧重试链作废，代次加一防滞后失败串扰。
    _openGeneration++;
    _cancelRetryTimer();
    final resume = _player.state.position;
    try {
      setState(() {
        _lineIndex = index;
        _url = line.url;
        _headers = line.headers;
        _error = null;
        _retrying = false;
      });
      _danmuController.reset();
      await _open();
      if (!mounted) return;
      _loadDanmu();
      try {
        if (resume > Duration.zero) await _player.seek(resume);
      } catch (_) {
        // 回原位失败忽略，继续从头播
      }
    } finally {
      _switchingLine = false;
    }
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
                          ? const Icon(Icons.check, color: Colors.orangeAccent)
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
        if (haikuoDanmuUrlIsFetchable(_danmuUrl))
          HaikuoDanmuOverlay(
            controller: _danmuController,
            aspectRatio: _aspectRatio,
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
                      // 手动重试也从断点续播，并给一次新的自动重试额度。
                      final resumeFrom = _lastPosition;
                      _cancelRetryTimer();
                      setState(() {
                        _error = null;
                        _retrying = false;
                      });
                      unawaited(_open(resumeFrom: resumeFrom));
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
          )
        else if (_retrying)
          const ColoredBox(
            color: Colors.black45,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('网络波动，正在重连…', style: TextStyle(color: Colors.white70)),
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
              qualityLabel: _currentLineName,
              onEpisodes: _showEpisodes,
              onSpeed: _showSpeed,
              onQuality: _lines.length > 1
                  ? _showLines
                  : () async => _toast('该站点只提供一种清晰度'),
              showDanmaku: haikuoDanmuUrlIsFetchable(_danmuUrl),
              danmakuEnabled: _danmuController.enabled,
              danmakuStatus: _danmuController.status,
              onDanmaku: () async =>
                  _danmuController.setEnabled(!_danmuController.enabled),
              onRetryDanmaku: _danmuController.failed
                  ? () async {
                      _danmuController.reset();
                      _loadDanmu();
                    }
                  : null,
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
      subtitleUrl: widget.subtitleUrl,
      lines: widget.lines,
      danmuUrl: widget.danmuUrl,
      danmuFetcher: widget.danmuFetcher,
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
