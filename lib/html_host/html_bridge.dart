import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core_bridge.dart';
import '../global_search_page.dart';
import '../local_store.dart';
import '../settings_screen.dart';
import 'html_gateway.dart';
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

  Map<String, dynamic> _lastPlayState = {};
  final List<String> _extLog = [];

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
    final params = decoded['params'] is Map
        ? Map<String, dynamic>.from(decoded['params'] as Map)
        : <String, dynamic>{};
    try {
      final result = await dispatch(method, params);
      _respond(id, ok: true, result: result);
    } on HtmlBridgeError catch (error) {
      _respond(id, ok: false, error: error.code);
    } catch (error) {
      _respond(id, ok: false, error: error.toString());
    }
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
        throw const HtmlBridgeError('unsupported', 'pan check is v2');
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
      case 'fm.ui.restoreChrome':
        throw const HtmlBridgeError('unsupported', 'no chrome concept in shell');
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
      if (headers is Map) {
        headers.forEach((key, value) {
          final name = key.toString().toLowerCase();
          if (_skipReqHeaders.contains(name)) return;
          request.headers.set(name, value.toString());
        });
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
      if (credentials != 'omit') {
        try {
          await _storeCookies(uri, response.headers['set-cookie'] ?? const []);
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
        'status': response.statusCode,
        'headers': responseHeaders,
        'body': decodedBody,
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
    if (value is num) {
      return value.toInt().clamp(1000, 120000);
    }
    return 30000;
  }

  Future<List<WebViewCookie>> _readCookies(Uri uri) async {
    if (cookieReader != null) return cookieReader!(uri);
    return WebViewCookieManager().getCookies(domain: uri);
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

  Map<String, dynamic> _vod(Map<String, dynamic> params) {
    try {
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
    } on FormatException catch (error) {
      throw HtmlBridgeError('bad_payload', error.message);
    }
  }

  Map<String, dynamic> _search(Map<String, dynamic> params) {
    final query = params['query']?.toString() ?? '';
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
    return {'opened': await open(params)};
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
