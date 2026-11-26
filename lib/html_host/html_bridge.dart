import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core_bridge.dart';
import '../detail_screen.dart';
import '../global_search_page.dart';
import '../local_store.dart';
import '../models.dart';
import '../settings_screen.dart';
import 'html_gateway.dart';
import 'html_nvku.dart';
import 'html_play.dart';

/// 桥方法失败：code 发回页面作 reject 原因，message 仅记日志。
class HtmlBridgeError implements Exception {
  const HtmlBridgeError(this.code, [this.message = '']);

  final String code;
  final String message;

  @override
  String toString() => message.isEmpty ? code : '$code: $message';
}

/// fm.cache 的存取口：默认 SharedPreferences 实现，测试注假。
abstract class HtmlCacheStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

class SharedPreferencesHtmlCacheStore implements HtmlCacheStore {
  SharedPreferencesHtmlCacheStore(this.prefix);

  final String prefix;

  @override
  Future<String?> read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$prefix$key');
  }

  @override
  Future<void> write(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$prefix$key', value);
  }

  @override
  Future<void> remove(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$prefix$key');
  }
}

/// 宿主页面向桥注入的宿主能力（导航/提示/WebView 动作/外部入口）。
/// 测试注假，页面接真实现。
class HtmlBridgeHost {
  const HtmlBridgeHost({
    required this.pushPage,
    required this.showToast,
    required this.popPage,
    required this.canGoBack,
    required this.goBack,
    required this.reloadPage,
    required this.viewport,
    required this.precacheArtwork,
    this.onOpenLive,
    this.onOpenKeep,
    this.setChrome,
    this.restoreChrome,
    this.exitPage,
  });

  final void Function(Widget page) pushPage;
  final void Function(String message) showToast;
  final void Function() popPage;
  final Future<bool> Function() canGoBack;
  final Future<void> Function() goBack;
  final Future<void> Function() reloadPage;
  final Map<String, dynamic> Function() viewport;
  final Future<void> Function(List<String> urls) precacheArtwork;
  final Future<bool> Function(Map<String, dynamic> params)? onOpenLive;
  final Future<bool> Function(Map<String, dynamic> params)? onOpenKeep;

  /// chrome 控制：宿主页面接真实现（顶栏显隐 + 系统栏模式），
  /// 返回实际生效的模式；未接线时桥报 unsupported。
  /// [setChrome] 入参为归一后的模式与页面原选项（restoreAffordance /
  /// statusBarStyle / navigationBarStyle / startup 由宿主页面处理）。
  final Future<String> Function(String mode, Map<String, dynamic> options)?
  setChrome;
  final Future<String> Function()? restoreChrome;

  /// 强制退出宿主页面：fm.openLive 切到下层直播区后，宿主页面
  /// 须退掉直播才可见；宿主页面接“放行 PopScope 后退栈”的真实现
  /// （直接 pop 会被 PopScope 拦去走 WebView 历史）。未接线时
  /// 不退（调用方自行处理），fm.openKeep 不用它（收藏页压在
  /// 宿主页面之上，返回即回 HTML 页）。
  final void Function()? exitPage;
}

/// chrome 模式归一（手机端）：指南的 TV 模式按语义就近映射——
/// tv-normal 顶栏在位 → normal；tv-full / tv-toolbar-hidden 顶栏
/// 隐藏、页面接管首屏 → edge（保留系统栏，页面要沉浸须显式要
/// immersive）；tv-overlay 顶栏在位、页面避让 → normal。
/// 不认识的模式返回 null，调用方报 bad_payload。
String? normalizeHtmlChromeMode(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'normal':
    case 'tv-normal':
    case 'tv-overlay':
      return 'normal';
    case 'edge':
    case 'tv-full':
    case 'tv-toolbar-hidden':
      return 'edge';
    case 'immersive':
      return 'immersive';
    default:
      return null;
  }
}

/// fm 桥：页面消息的唯一分发点。每个宿主页面一个桥实例，
/// 与海阔运行时无任何共享状态。
class HtmlBridge {
  HtmlBridge({
    required this.siteKey,
    required this.siteName,
    required this.repository,
    required this.store,
    required this.host,
    required this.cache,
    required this.sendToPage,
    required this.gatewayPort,
    this.httpClientFactory,
    this.cookieReader,
    this.cookieWriter,
    this.userAgentReader,
  });

  final String siteKey;
  final String siteName;
  final AppRepository repository;
  final LocalStore store;
  final HtmlBridgeHost host;
  final HtmlCacheStore cache;

  /// 向页面执行 JS（宿主页面接 WebViewController.runJavaScript）。
  final void Function(String javaScript) sendToPage;

  /// 回环网关端口（fm.res 拼地址用）。
  final int gatewayPort;

  final HttpClient Function()? httpClientFactory;
  final Future<List<WebViewCookie>> Function(Uri url)? cookieReader;
  final Future<void> Function(WebViewCookie cookie)? cookieWriter;

  /// 宿主 WebView 的 UA 读口：宿主页面接 controller.getUserAgent，
  /// _req 默认 UA 取它（与解题票据绑定的 UA 一致）。测试注假；
  /// 未注入时 _req 沿用 Dart 默认 UA（旧行为）。
  final Future<String?> Function()? userAgentReader;

  Map<String, dynamic> _lastPlayState = {};
  final List<String> _extLog = [];

  /// 宿主 WebView UA 缓存：一页生命周期内 UA 不变，只取一次。
  String? _cachedUserAgent;

  List<String> get extLog => List.unmodifiable(_extLog);

  String currentUrl = '';

  void recordPlayState(Map<String, dynamic> state) {
    _lastPlayState = Map<String, dynamic>.of(state);
  }

  void dispatchPageEvent(String name, Map<String, dynamic> detail) {
    sendToPage(
      'window.dispatchEvent(new CustomEvent(${jsonEncode(name)},'
      '{detail:${jsonEncode(detail)}}));',
    );
  }

  /// 处理一条通道消息（JSON 文本 `{id, method, params}`），
  /// 响应经 sendToPage 回传；超 64KB 的响应自动分块。
  Future<void> handleMessage(String message) async {
    if (message.length > 512 * 1024) {
      final idMatch = RegExp(
        r'"id"\s*:\s*"([^"]+)"',
      ).firstMatch(message.substring(0, math.min(message.length, 4096)));
      if (idMatch != null) {
        _respond(idMatch.group(1)!, ok: false, error: 'message_too_large');
      }
      return;
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(message);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final id = decoded['id']?.toString() ?? '';
    final method = decoded['method']?.toString() ?? '';
    if (id.isEmpty || method.isEmpty) return;
    final params = _normalizeParams(method, decoded['params']);
    try {
      final result = await dispatch(method, params);
      _respond(id, ok: true, result: result);
    } on HtmlBridgeError catch (error) {
      _respond(id, ok: false, error: error.code);
    } catch (error) {
      _respond(id, ok: false, error: error.toString());
    }
  }

  /// params 形态容错（垫片归一的双保险）：对象原样收；字符串按方法
  /// 语义理解为地址/关键词/消息，不再静默丢成空对象（丢了就报
  /// bad_payload，页面看到的就是“网络或站点异常 / bad_payload”）；
  /// 数组只在 fm.pan.check 时理解为待检清单。
  Map<String, dynamic> _normalizeParams(String method, dynamic raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.isNotEmpty) {
      switch (method) {
        case 'fm.req':
        case 'fm.res':
        case 'fm.play':
        case 'fm.vodInline':
        case 'fm.vod':
        case 'fm.pan.play':
          return {'url': raw};
        case 'fm.search':
          return {'query': raw, 'keyword': raw};
        case 'fm.ext.log':
        case 'fm.ext.toast':
          return {'message': raw};
        default:
          return <String, dynamic>{};
      }
    }
    if (raw is List && method == 'fm.pan.check') {
      return {'items': raw};
    }
    return <String, dynamic>{};
  }

  void _respond(String id, {required bool ok, Object? result, String error = ''}) {
    final envelope = jsonEncode(
      ok
          ? {'id': id, 'ok': true, 'result': result}
          : {'id': id, 'ok': false, 'error': error},
    );
    const chunkSize = 65536;
    if (envelope.length <= chunkSize) {
      sendToPage(
        'window.__moyiFmResolve(${jsonEncode(id)},${jsonEncode(envelope)});',
      );
      return;
    }
    final total = (envelope.length / chunkSize).ceil();
    for (var i = 0; i < total; i++) {
      final end = math.min((i + 1) * chunkSize, envelope.length);
      final part = envelope.substring(i * chunkSize, end);
      sendToPage(
        'window.__moyiFmChunk(${jsonEncode(id)},$i,$total,${jsonEncode(part)});',
      );
    }
  }

  Future<dynamic> dispatch(String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'fm.req':
        return _req(params);
      case 'fm.res':
        return _res(params);
      case 'fm.play':
        return _play(params);
      case 'fm.vod':
        return _vod(params);
      case 'fm.vodInline':
        return _play(params);
      case 'fm.ctrl':
        // 壳无视频控制句柄：静默成功（指南认可的降级）。
        return {};
      case 'fm.stat':
        return _lastPlayState;
      case 'fm.search':
        return _search(params);
      case 'fm.nvku':
        // 女优库本地兜底查询（合并演员库页专用，只读查工作库）。
        return HtmlNvkuService.shared.handle(params);
      case 'fm.history':
        return _history();
      case 'fm.cache':
        return _cacheOp(params);
      case 'fm.device':
        return {
          'platform': Platform.operatingSystem,
          'isAndroid': Platform.isAndroid,
          'isIOS': Platform.isIOS,
          'version': Platform.operatingSystemVersion,
        };
      case 'fm.site':
        return {'siteKey': siteKey, 'siteName': siteName};
      case 'fm.config':
        // driveCheck：壳无此开关，恒 false（写明，不编假开关）。
        return {'siteKey': siteKey, 'siteName': siteName, 'driveCheck': false};
      case 'fm.openLive':
        return _openLive(params);
      case 'fm.openKeep':
        return _openKeep(params);
      case 'fm.openSetting':
        host.pushPage(
          SettingsScreen(repository: repository, store: store),
        );
        return {};
      case 'fm.back':
        return _back();
      case 'fm.reload':
        await host.reloadPage();
        return {};
      case 'fm.preloadArtwork':
        return _preload(params);
      case 'fm.pan.play':
        return _panPlay(params);
      case 'fm.pan.check':
        // 诚实不支持（v2）：网盘分享检测须逐家接匿名分享接口——
        // 阿里/夸克/UC/百度/天翼/123/迅雷/115/移动共 9 家，含迅雷
        // captcha token 与移动内置加解密；树内网盘引擎只有登录态
        // 浏览（凭据 + 目录 + 直链），无任何一家分享有效性检测，
        // 也无 driveCheck 开关（fm.config 已如实报 false）。拿
        // HTTP 探活冒充检测会把“已失效分享页也回 200”误判为有
        // 效，故不做假实现；页面应先查 fm.config().driveCheck。
        throw const HtmlBridgeError(
          'unsupported',
          'pan check needs per-provider share APIs (v2)',
        );
      case 'fm.ext.info':
        return {
          'siteKey': siteKey,
          'siteName': siteName,
          'version': 1,
          'route': 'html',
        };
      case 'fm.ext.log':
        _log(params['message']?.toString() ?? '');
        return {};
      case 'fm.ext.toast':
        host.showToast(params['message']?.toString() ?? '');
        return {};
      case 'fm.ui.setChrome':
        return _setChrome(params);
      case 'fm.ui.restoreChrome':
        return _restoreChrome();
      case 'fm.ui.getViewport':
        return host.viewport();
      case 'fm._urlchange':
        currentUrl = params['url']?.toString() ?? currentUrl;
        return {};
      case 'fm._exterror':
        _log('ext error ${params['id']}: ${params['message']}');
        dispatchPageEvent('fmexterror', {
          'id': params['id']?.toString() ?? '',
          'message': params['message']?.toString() ?? '',
        });
        return {};
      default:
        throw HtmlBridgeError('unknown_method', method);
    }
  }

  void _log(String message) {
    _extLog.add(message);
    if (_extLog.length > 200) _extLog.removeRange(0, _extLog.length - 200);
    debugPrint('[html:$siteKey] $message');
  }

  static const _skipReqHeaders = {'host', 'content-length', 'connection'};

  Future<Map<String, dynamic>> _req(Map<String, dynamic> params) async {
    final url = (params['url']?.toString() ?? '').trim();
    if (url.isEmpty || !(url.startsWith('http://') || url.startsWith('https://'))) {
      throw const HtmlBridgeError('bad_payload', 'fm.req needs an http/https url');
    }
    final method = (params['method']?.toString() ?? 'GET').toUpperCase();
    const allowedMethods = {'GET', 'POST', 'PUT', 'DELETE', 'HEAD', 'PATCH', 'OPTIONS'};
    if (!allowedMethods.contains(method)) {
      throw HtmlBridgeError('bad_payload', 'unsupported method $method');
    }
    final responseType =
        (params['responseType']?.toString() ?? 'text').toLowerCase();
    if (!{'text', 'json', 'base64'}.contains(responseType)) {
      throw const HtmlBridgeError('bad_payload', 'bad responseType');
    }
    final timeoutMs = _clampTimeout(params['timeout']);
    final credentials = params['credentials']?.toString() ?? 'include';
    final uri = Uri.parse(url);
    final client = httpClientFactory?.call() ?? HttpClient();
    try {
      final request = await client
          .openUrl(method, uri)
          .timeout(Duration(milliseconds: timeoutMs));
      final headers = params['headers'];
      var pageSetUserAgent = false;
      if (headers is Map) {
        headers.forEach((key, value) {
          final name = key.toString().toLowerCase();
          if (name == 'user-agent') pageSetUserAgent = true;
          if (_skipReqHeaders.contains(name)) return;
          request.headers.set(name, value.toString());
        });
      }
      if (!pageSetUserAgent) {
        // 默认 UA 取宿主 WebView 的 UA：CF 的 cf_clearance 绑定解题
        // 时的 UA；_req 若用 Dart 默认 UA 发请求，票据带上也会被
        // 重拦，复用就断了。取不到时沿用旧行为，不让请求失败。
        // UA 不是凭据，与 credentials 取值无关，omit 也照发。
        try {
          final ua = await _readUserAgent();
          if (ua != null && ua.isNotEmpty) {
            request.headers.set('user-agent', ua);
          }
        } catch (_) {}
      }
      if (credentials != 'omit') {
        try {
          final cookies = await _readCookies(uri);
          if (cookies.isNotEmpty) {
            request.headers.set(
              'cookie',
              cookies.map((c) => '${c.name}=${c.value}').join('; '),
            );
          }
        } catch (_) {}
      }
      final body = params['body'];
      if (body != null) {
        final bytes = body is String
            ? utf8.encode(body)
            : utf8.encode(jsonEncode(body));
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(
        Duration(milliseconds: timeoutMs),
      );
      final setCookieHeaders = response.headers['set-cookie'] ?? const [];
      if (credentials != 'omit') {
        try {
          await _storeCookies(uri, setCookieHeaders);
        } catch (_) {}
      }
      const maxBody = 8 * 1024 * 1024;
      final chunks = <List<int>>[];
      var total = 0;
      await for (final chunk in response.timeout(Duration(milliseconds: timeoutMs))) {
        total += chunk.length;
        if (total > maxBody) {
          throw const HtmlBridgeError('response_too_large');
        }
        chunks.add(chunk);
      }
      final bytes = chunks.expand((chunk) => chunk).toList();
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name.toLowerCase()] = values.join(', ');
      });
      final finalUrl = response.redirects.isEmpty
          ? url
          : response.redirects.last.location.toString();
      Object? decodedBody;
      if (responseType == 'base64') {
        decodedBody = base64Encode(bytes);
      } else if (responseType == 'json') {
        final text = utf8.decode(bytes, allowMalformed: true);
        try {
          decodedBody = jsonDecode(text);
        } catch (_) {
          throw const HtmlBridgeError('invalid_json');
        }
      } else {
        decodedBody = utf8.decode(bytes, allowMalformed: true);
      }
      return {
        'ok': true,
        'status': response.statusCode,
        'headers': responseHeaders,
        'cookies': setCookieHeaders,
        'body': decodedBody,
        'data': decodedBody,
        'url': finalUrl,
      };
    } on HtmlBridgeError {
      rethrow;
    } on TimeoutException {
      throw const HtmlBridgeError('timeout');
    } catch (error) {
      throw HtmlBridgeError('network', error.toString());
    } finally {
      client.close();
    }
  }

  int _clampTimeout(dynamic value) {
    num? numeric;
    if (value is num) {
      numeric = value;
    } else if (value is String) {
      numeric = num.tryParse(value.trim());
    }
    if (numeric == null) return 30000;
    var ms = numeric.toDouble();
    // 超时单位双约定：指南写秒、已发页面传毫秒；小于 1000 的值按秒读。
    if (ms < 1000) ms *= 1000;
    return ms.toInt().clamp(1000, 120000);
  }

  Future<List<WebViewCookie>> _readCookies(Uri uri) async {
    if (cookieReader != null) return cookieReader!(uri);
    return WebViewCookieManager().getCookies(domain: uri);
  }

  /// 宿主 WebView 的 UA：未注入读口时返回 null。非空结果缓存，
  /// 取失败（空/抛错）时不缓存，下次再试。
  Future<String?> _readUserAgent() async {
    final cached = _cachedUserAgent;
    if (cached != null && cached.isNotEmpty) return cached;
    final reader = userAgentReader;
    if (reader == null) return null;
    final ua = await reader();
    if (ua != null && ua.isNotEmpty) _cachedUserAgent = ua;
    return ua;
  }

  Future<void> _storeCookies(Uri uri, List<String> setCookie) async {
    for (final raw in setCookie) {
      final first = raw.split(';').first.trim();
      final eq = first.indexOf('=');
      if (eq <= 0) continue;
      var path = '/';
      for (final part in raw.split(';').skip(1)) {
        final trimmed = part.trim();
        if (trimmed.toLowerCase().startsWith('path=')) {
          path = trimmed.substring('path='.length).trim();
        }
      }
      final cookie = WebViewCookie(
        name: first.substring(0, eq).trim(),
        value: first.substring(eq + 1).trim(),
        domain: uri.host,
        path: path.isEmpty ? '/' : path,
      );
      if (cookieWriter != null) {
        await cookieWriter!(cookie);
      } else {
        await WebViewCookieManager().setCookie(cookie);
      }
    }
  }

  String _res(Map<String, dynamic> params) {
    final url = (params['url']?.toString() ?? '').trim();
    if (url.isEmpty || !(url.startsWith('http://') || url.startsWith('https://'))) {
      throw const HtmlBridgeError('bad_payload', 'fm.res needs an http/https url');
    }
    final payload = <String, dynamic>{'url': url};
    if (params['headers'] is Map) payload['headers'] = params['headers'];
    final referer = params['referer']?.toString() ?? '';
    if (referer.isNotEmpty) payload['referer'] = referer;
    final method = params['method']?.toString() ?? '';
    if (method.isNotEmpty) payload['method'] = method;
    return buildHtmlGatewayUrl(port: gatewayPort, payload: payload);
  }

  Map<String, dynamic> _play(Map<String, dynamic> params) {
    try {
      final request = parseHtmlPlayPayload(params);
      host.pushPage(
        buildHtmlPlayPage(request, onStateChange: recordPlayState),
      );
      return {};
    } on HtmlResolverUnsupported {
      throw const HtmlBridgeError('resolver_not_supported');
    } on FormatException catch (error) {
      throw HtmlBridgeError('bad_payload', error.message);
    }
  }

  Future<Map<String, dynamic>> _vod(Map<String, dynamic> params) async {
    try {
      // 自带可播内容优先：载荷自带选集时走 HTML 详情页，与之前一致，
      // 哪怕载荷里同时带了别站的 siteKey 也不改道。
      final detail = parseHtmlVodPayload(params);
      host.pushPage(
        HtmlVodDetailPage(
          detail: detail,
          siteName: siteName,
          onStateChange: recordPlayState,
        ),
      );
      return {};
    } on HtmlResolverUnsupported {
      throw const HtmlBridgeError('resolver_not_supported');
    } on FormatException {
      // 无可播内容：只剩 siteKey + vodId 时试跨站详情，取数走
      // 目标站自己的引擎（DetailScreen 内调 repository.detail，
      // 与全局搜索打开别站详情同一条链）。
    }
    final target = _crossSiteVodTarget(params);
    if (target == null) {
      throw const HtmlBridgeError(
        'bad_payload',
        'vod payload has no playable episodes',
      );
    }
    final (targetSite, vodId) = target;
    if (targetSite == siteKey || !SourceSite.isKnown(targetSite)) {
      // 自身 HTML 站无详情引擎可查；未知站无法取数。两处都报
      // bad_payload：载荷指了一个桥无法解析的详情目标。
      throw HtmlBridgeError('bad_payload', 'unknown vod target $targetSite');
    }
    if (SourceSite.byId(targetSite).isHtmlSite) {
      throw const HtmlBridgeError(
        'unsupported',
        'html sites have no detail engine',
      );
    }
    if (!store.allowsSource(targetSite)) {
      // 当前用户档案不可见/不可用的站（如未成年保护锁定时），
      // 不许经 HTML 桥绕过门禁打开。
      throw const HtmlBridgeError(
        'unsupported',
        'site not available for the current profile',
      );
    }
    host.pushPage(
      DetailScreen(
        drama: Drama(
          id: '$targetSite:$vodId',
          source: targetSite,
          sourceId: vodId,
          title:
              (params['vod_name'] ?? params['title'] ?? params['name'] ?? '')
                  .toString()
                  .trim(),
          description:
              (params['vod_content'] ??
                      params['description'] ??
                      params['content'] ??
                      '')
                  .toString()
                  .trim(),
          cover:
              (params['vod_pic'] ?? params['pic'] ?? params['cover'] ?? '')
                  .toString()
                  .trim(),
          category:
              (params['vod_class'] ??
                      params['category'] ??
                      params['type_name'] ??
                      '')
                  .toString()
                  .trim(),
        ),
        repository: repository,
        store: store,
      ),
    );
    return {};
  }

  /// 跨站详情目标：(siteKey, vodId)。siteKey 取 siteKey/source，
  /// vodId 取 vod_id/vodId/id；vodId 带 `站:号` 前缀时剥掉站前缀
  /// （与 py 详情取 vodId 的口径一致）。缺任一项返回 null。
  (String, String)? _crossSiteVodTarget(Map<String, dynamic> params) {
    final targetSite =
        (params['siteKey'] ?? params['source'] ?? '').toString().trim();
    var vodId =
        (params['vod_id'] ?? params['vodId'] ?? params['id'] ?? '')
            .toString()
            .trim();
    if (targetSite.isEmpty || vodId.isEmpty) return null;
    final prefix = '$targetSite:';
    if (vodId.startsWith(prefix)) vodId = vodId.substring(prefix.length);
    if (vodId.isEmpty) return null;
    return (targetSite, vodId);
  }

  Future<Map<String, dynamic>> _setChrome(Map<String, dynamic> params) async {
    final apply = host.setChrome;
    if (apply == null) {
      throw const HtmlBridgeError('unsupported', 'chrome control not wired');
    }
    final mode = normalizeHtmlChromeMode(params['mode']?.toString() ?? '');
    if (mode == null) {
      throw HtmlBridgeError(
        'bad_payload',
        'unknown chrome mode ${params['mode']}',
      );
    }
    final applied = await apply(mode, params);
    return {'mode': applied, 'chromeMode': applied};
  }

  Future<Map<String, dynamic>> _restoreChrome() async {
    final restore = host.restoreChrome;
    if (restore == null) {
      throw const HtmlBridgeError('unsupported', 'chrome control not wired');
    }
    final mode = await restore();
    return {'mode': mode, 'chromeMode': mode};
  }

  Map<String, dynamic> _search(Map<String, dynamic> params) {
    final query = (params['query'] ?? params['keyword'] ?? '').toString();
    host.pushPage(
      GlobalSearchPage(
        repository: repository,
        store: store,
        initialQuery: query,
      ),
    );
    return {};
  }

  List<Map<String, dynamic>> _history() {
    final entries = store.history.take(50);
    return [
      for (final entry in entries)
        {
          ...entry.toJson(),
          'finished': entry.finished,
        },
    ];
  }

  Future<dynamic> _cacheOp(Map<String, dynamic> params) async {
    final op = params['op']?.toString() ?? 'get';
    final key = params['key']?.toString() ?? '';
    if (key.isEmpty) throw const HtmlBridgeError('bad_payload', 'cache key empty');
    switch (op) {
      case 'get':
        final stored = await cache.read(key);
        if (stored == null) return null;
        try {
          return jsonDecode(stored);
        } catch (_) {
          return stored;
        }
      case 'set':
        await cache.write(key, jsonEncode(params['value']));
        return {};
      case 'remove':
      case 'del':
        await cache.remove(key);
        return {};
      default:
        throw HtmlBridgeError('bad_payload', 'unknown cache op $op');
    }
  }

  Future<Map<String, dynamic>> _openLive(Map<String, dynamic> params) async {
    final open = host.onOpenLive;
    if (open == null) {
      throw const HtmlBridgeError('unsupported', 'live entry not wired');
    }
    final opened = await open(params);
    // 直播区在宿主页面下层：打开成功就退掉宿主页面，直播立即
    // 可见。桥在其上又推了详情/播放页时只退掉最上一层，再按
    // 一次返回即见直播（与返回键逐层退的规矩一致）。
    if (opened) host.exitPage?.call();
    return {'opened': opened};
  }

  Future<Map<String, dynamic>> _openKeep(Map<String, dynamic> params) async {
    final open = host.onOpenKeep;
    if (open == null) {
      throw const HtmlBridgeError('unsupported', 'keep entry not wired');
    }
    return {'opened': await open(params)};
  }

  Future<Map<String, dynamic>> _back() async {
    if (await host.canGoBack()) {
      await host.goBack();
      return {'navigated': true};
    }
    host.popPage();
    return {'navigated': false};
  }

  Future<Map<String, dynamic>> _preload(Map<String, dynamic> params) async {
    final raw = params['urls'];
    final urls = <String>[];
    if (raw is List) {
      for (final item in raw) {
        final url = item?.toString() ?? '';
        if (url.isNotEmpty) urls.add(url);
        if (urls.length >= 20) break;
      }
    } else if (raw is String && raw.isNotEmpty) {
      urls.add(raw);
    }
    await host.precacheArtwork(urls);
    return {'count': urls.length};
  }

  Map<String, dynamic> _panPlay(Map<String, dynamic> params) {
    final url = (params['url'] ?? params['playUrl'] ?? '').toString().trim();
    final lower = url.toLowerCase();
    if (lower.startsWith('magnet:') ||
        lower.startsWith('ed2k:') ||
        lower.startsWith('thunder://')) {
      host.showToast('磁力/电驴链接暂不支持播放');
      throw const HtmlBridgeError('unsupported', 'magnet links not supported');
    }
    const netdiskHosts = [
      'pan.baidu.com',
      'drive.aliyun.com',
      'aliyundrive.com',
      'quark.cn',
      'pan.quark.cn',
      '115.com',
      'cloud.189.cn',
      'pan.xunlei.com',
      '123pan.com',
      '123pan.cn',
      'lanzou.com',
      'lanzoui.com',
      'lanzoux.com',
    ];
    Uri? uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {}
    final requestHost = uri?.host ?? '';
    if (requestHost.isNotEmpty &&
        netdiskHosts.any(
          (netdisk) =>
              requestHost == netdisk || requestHost.endsWith('.$netdisk'),
        )) {
      throw const HtmlBridgeError('unsupported', 'netdisk share links not supported');
    }
    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      throw const HtmlBridgeError('bad_payload', 'fm.pan.play needs an http url');
    }
    return _play(params);
  }
}
