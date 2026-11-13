import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../playback_sniffer.dart';
import 'mini_app_manifest.dart';
import 'mini_app_sources.dart';

class MiniAppApiException implements Exception {
  MiniAppApiException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class MiniAppBridgeCallbacks {
  const MiniAppBridgeCallbacks({
    required this.evaluateJavascript,
    required this.showToast,
    required this.showLoading,
    required this.hideLoading,
    required this.confirm,
    required this.actionSheet,
    required this.navigateTo,
    required this.navigateBack,
    required this.exit,
    required this.openMiniApp,
    required this.resolveMiniAppUrl,
    required this.log,
    this.openPlayer,
    this.playerState,
  });

  final Future<void> Function(String js) evaluateJavascript;
  final void Function(String message) showToast;
  final void Function(String? message) showLoading;
  final void Function() hideLoading;
  final Future<bool> Function({
    required String title,
    required String content,
  })
  confirm;
  final Future<int> Function(List<String> items) actionSheet;
  final Future<void> Function(String path) navigateTo;
  final Future<void> Function() navigateBack;
  final void Function() exit;
  final Future<void> Function(String appId) openMiniApp;
  final Future<String?> Function(String appId) resolveMiniAppUrl;
  final void Function(String message) log;

  /// 播放器桥：宿主收到解析好的播放目标后调起宿主播放器（或先嗅探
  /// 再播），返回 true 表示确实打开了播放器。未提供时 player.open
  /// 报 NOT_IMPLEMENTED。
  final Future<bool> Function(MiniAppPlayTarget target)? openPlayer;

  /// 播放器当前状态快照（opened/url/title/playing/positionMs/
  /// durationMs）；未提供时 player.getState 回 opened:false。
  final Map<String, dynamic> Function()? playerState;
}

/// 小程序 player.open 的入参（影视库 lib.js 的 playEpisode 形态）。
class MiniAppPlayRequest {
  const MiniAppPlayRequest({
    required this.url,
    this.title = '',
    this.headers = const {},
    this.parse = '',
    this.jx = '',
    this.playUrl = '',
    this.flag = '',
    this.jxFrom = '',
    this.key = '',
  });

  factory MiniAppPlayRequest.fromParams(Map<String, dynamic> params) {
    final headers = <String, String>{};
    final rawHeaders = params['headers'] ?? params['header'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        if (value != null) headers[key.toString()] = value.toString();
      });
    }
    String text(Object? value) => value?.toString() ?? '';
    return MiniAppPlayRequest(
      url: text(params['url']),
      title: text(params['title']),
      headers: headers,
      parse: text(params['parse']),
      jx: text(params['jx']),
      playUrl: text(params['playUrl']),
      flag: text(params['flag']),
      jxFrom: text(params['jxFrom']),
      key: text(params['key']),
    );
  }

  final String url;
  final String title;
  final Map<String, String> headers;
  final String parse;
  final String jx;
  final String playUrl;
  final String flag;
  final String jxFrom;
  final String key;

  bool get needsParse => parse == '1' || jx == '1';
}

/// 解析好的播放目标：宿主按 kind 分流。
/// direct：直链地址，直接进播放器；sniff：网页/解析线路地址，
/// 先过嗅探页找流再播。
class MiniAppPlayTarget {
  const MiniAppPlayTarget({
    required this.kind,
    required this.url,
    this.title = '',
    this.headers = const {},
  });

  final String kind;
  final String url;
  final String title;
  final Map<String, String> headers;

  bool get isDirect => kind == 'direct';
  bool get isSniff => kind == 'sniff';
}

class MiniAppBridge {
  MiniAppBridge({
    required this.manifest,
    required this.appDir,
    required this.prefs,
    required this.callbacks,
    this.launchOptions = const <String, dynamic>{},
    http.Client? httpClient,
    MiniAppSourceProvider? sourceProvider,
  }) : sourceProvider = sourceProvider ?? HostMiniAppSourceProvider() {
    _httpClient = httpClient;
  }

  final MiniAppManifest manifest;
  final Directory appDir;
  final SharedPreferences prefs;
  final MiniAppBridgeCallbacks callbacks;
  final Map<String, dynamic> launchOptions;
  final MiniAppSourceProvider sourceProvider;
  http.Client? _httpClient;

  String _storageKey(String key) => 'moyi_miniapp_${manifest.appId}_$key';

  static String? requiredPermission(String api) {
    if (api.startsWith('request') ||
        api == 'resolveService' ||
        api.startsWith('requestStream') ||
        api.startsWith('requestSSE')) {
      return 'network';
    }
    if (api.startsWith('storage.') || api.startsWith('file.')) {
      return 'storage';
    }
    if (api.startsWith('ui.')) return 'ui';
    if (api.startsWith('navigate') ||
        api == 'exitMiniApp' ||
        api.startsWith('miniApp.')) {
      return 'navigate';
    }
    if (api.startsWith('player.')) return 'player';
    if (api.startsWith('source.')) return 'source';
    if (api.startsWith('python.')) return 'python';
    return null;
  }

  Future<void> handleChannelMessage(String raw) async {
    Map<String, dynamic>? message;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) message = decoded;
    } catch (_) {}
    if (message == null) return;
    final callId = message['callId'];
    final api = (message['api'] ?? '').toString();
    final params = message['params'];
    final args = params is Map<String, dynamic>
        ? params
        : <String, dynamic>{};
    try {
      final data = await invoke(api, args);
      await _reply(<String, dynamic>{
        'callId': callId,
        'ok': true,
        'data': data,
      });
    } on MiniAppApiException catch (error) {
      await _reply(<String, dynamic>{
        'callId': callId,
        'ok': false,
        'code': error.code,
        'message': error.message,
        'api': api,
      });
    } catch (error) {
      await _reply(<String, dynamic>{
        'callId': callId,
        'ok': false,
        'code': 'UNKNOWN',
        'message': error.toString(),
        'api': api,
      });
    }
  }

  Future<void> _reply(Map<String, dynamic> payload) async {
    try {
      await callbacks.evaluateJavascript(
        'window.__moyiResolve && window.__moyiResolve(${jsonEncode(payload)})',
      );
    } catch (_) {}
  }

  Future<void> emit(String event, [dynamic data]) async {
    try {
      await callbacks.evaluateJavascript(
        'window.__moyiEmit && window.__moyiEmit(${jsonEncode(event)}, ${jsonEncode(data)})',
      );
    } catch (_) {}
  }

  Future<dynamic> invoke(String api, Map<String, dynamic> params) async {
    final permission = requiredPermission(api);
    if (permission != null && !manifest.hasPermission(permission)) {
      throw MiniAppApiException(
        'PERMISSION_DENIED',
        '未在 manifest 里声明 $permission 权限',
      );
    }
    switch (api) {
      case 'env.getSystemInfo':
        return <String, dynamic>{
          'platform': defaultTargetPlatform.name,
          'sdkVersion': 4,
          'isTV': false,
          'devMode': kDebugMode,
        };
      case 'log':
        final text = (params['message'] ?? '').toString();
        callbacks.log('[${manifest.appId}] $text');
        return null;
      case 'request':
        return _request(params);
      case 'resolveService':
        return _resolveService((params['url'] ?? '').toString());
      case 'storage.get':
        return prefs.getString(_storageKey((params['key'] ?? '').toString()));
      case 'storage.set':
        await prefs.setString(
          _storageKey((params['key'] ?? '').toString()),
          (params['value'] ?? '').toString(),
        );
        return null;
      case 'storage.remove':
        await prefs.remove(_storageKey((params['key'] ?? '').toString()));
        return null;
      case 'storage.clear':
        await _clearStorage();
        return null;
      case 'storage.keys':
        return _storageKeys();
      case 'file.write':
        return _fileWrite(params);
      case 'file.read':
        return _fileRead(params);
      case 'file.stat':
        return _fileStat(params);
      case 'file.list':
        return _fileList(params);
      case 'file.mkdir':
        return _fileMkdir(params);
      case 'file.rename':
        return _fileRename(params);
      case 'file.delete':
        return _fileDelete(params);
      case 'clipboard.get':
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        return data?.text;
      case 'clipboard.set':
        await Clipboard.setData(
          ClipboardData(text: (params['text'] ?? '').toString()),
        );
        return null;
      case 'ui.toast':
        callbacks.showToast((params['message'] ?? '').toString());
        return null;
      case 'ui.loading':
        callbacks.showLoading((params['message'] ?? '').toString());
        return null;
      case 'ui.hideLoading':
        callbacks.hideLoading();
        return null;
      case 'ui.confirm':
        return callbacks.confirm(
          title: (params['title'] ?? '确认').toString(),
          content: (params['content'] ?? '').toString(),
        );
      case 'ui.actionSheet':
        final items = <String>[];
        final raw = params['items'];
        if (raw is List) {
          for (final item in raw) {
            items.add(item.toString());
          }
        }
        return callbacks.actionSheet(items);
      case 'navigateTo':
      case 'redirectTo':
        await callbacks.navigateTo((params['path'] ?? '').toString());
        return null;
      case 'navigateBack':
        await callbacks.navigateBack();
        return null;
      case 'exitMiniApp':
        callbacks.exit();
        return null;
      case 'miniApp.open':
        await callbacks.openMiniApp((params['appId'] ?? '').toString());
        return null;
      case 'miniApp.getLaunchOptions':
        return launchOptions;
      case 'source.list':
        return _source(() => sourceProvider.listSites());
      case 'source.home':
        return _source(
          () => sourceProvider.home(
            _sourceArg(params, const ['siteKey']),
          ),
        );
      case 'source.category':
        return _source(
          () => sourceProvider.category(
            siteKey: _sourceArg(params, const ['siteKey']),
            tid: _sourceArg(params, const ['tid', 'typeId', 'category']),
            page: _sourcePage(params),
            ext: _sourceExt(params),
          ),
        );
      case 'source.detail':
        return _source(
          () => sourceProvider.detail(
            siteKey: _sourceArg(params, const ['siteKey']),
            id: _sourceArg(params, const ['id', 'vodId']),
          ),
        );
      case 'source.play':
        return _source(
          () => sourceProvider.play(
            siteKey: _sourceArg(params, const ['siteKey']),
            flag: _sourceArg(params, const ['flag', 'from']),
            id: _sourceArg(params, const ['id', 'playId', 'vodId']),
          ),
        );
      case 'source.search':
        return _source(
          () => sourceProvider.search(
            siteKey: _sourceArg(params, const ['siteKey']),
            wd: _sourceArg(params, const ['wd', 'query', 'keyword']),
            page: _sourcePage(params),
          ),
        );
      case 'player.open':
        return _playerOpen(params);
      case 'player.getState':
        return callbacks.playerState?.call() ??
            const <String, dynamic>{'opened': false};
      case 'python.call':
        throw MiniAppApiException(
          'NOT_IMPLEMENTED',
          'Python 服务未接：小程序暂不能调用宿主 Python',
        );
      default:
        if (api.startsWith('requestStream') ||
            api.startsWith('requestSSE') ||
            api == 'requestBytes' ||
            api == 'readLines') {
          throw MiniAppApiException(
            'NOT_IMPLEMENTED',
            '流式/二进制请求未实现：只支持普通文本请求',
          );
        }
        throw MiniAppApiException('UNKNOWN_API', '未知接口：$api');
    }
  }

  /// source.* 统一出口：宿主失败码原样交给 JS 侧，意外异常收成
  /// SOURCE_FAILED，不把宿主内部细节直接抛给小程序。
  Future<dynamic> _source(Future<dynamic> Function() run) async {
    try {
      return await run();
    } on MiniAppSourceFailure catch (failure) {
      throw MiniAppApiException(failure.code, failure.message);
    } catch (error) {
      throw MiniAppApiException('SOURCE_FAILED', '采集源调用失败：$error');
    }
  }

  /// player.open：解析播放目标后交给宿主播放回调。回调返回 true
  /// 才算打开了播放器（嗅探页被用户取消时返回 false，不报错）。
  Future<Map<String, dynamic>> _playerOpen(
    Map<String, dynamic> params,
  ) async {
    final request = MiniAppPlayRequest.fromParams(params);
    if (request.url.isEmpty) {
      throw MiniAppApiException('INVALID_PARAMS', '播放地址为空');
    }
    final openPlayer = callbacks.openPlayer;
    if (openPlayer == null) {
      throw MiniAppApiException(
        'NOT_IMPLEMENTED',
        '播放器桥未接：宿主未提供播放器回调',
      );
    }
    final target = MiniAppBridge.resolvePlayTarget(request);
    final opened = await openPlayer(target);
    return <String, dynamic>{
      'opened': opened,
      'kind': target.kind,
      'url': target.url,
    };
  }

  /// 播放目标分流（纯函数，可单测）：
  /// 1. parse/jx == '1' 是蜘蛛的权威声明：地址是网页/解析线路，
  ///    走嗅探；有 playUrl（解析服务地址）就嗅探它，否则嗅探 url。
  ///    这一条优先于媒体特征判断——解析地址里常嵌着 .mp4 串，
  ///    不能只看特征就直放。
  /// 2. 无解析声明且地址本身是媒体地址 → 直播。
  /// 3. 其余非媒体地址 → 嗅探页（页面上找流，用户也能在候选里挑）。
  static MiniAppPlayTarget resolvePlayTarget(MiniAppPlayRequest request) {
    if (request.needsParse) {
      final target = request.playUrl.isNotEmpty &&
              request.playUrl.startsWith('http')
          ? request.playUrl
          : request.url;
      return MiniAppPlayTarget(
        kind: 'sniff',
        url: target,
        title: request.title,
        headers: request.headers,
      );
    }
    if (MediaSniffer.isMediaUrl(request.url)) {
      return MiniAppPlayTarget(
        kind: 'direct',
        url: request.url,
        title: request.title,
        headers: request.headers,
      );
    }
    return MiniAppPlayTarget(
      kind: 'sniff',
      url: request.url,
      title: request.title,
      headers: request.headers,
    );
  }

  /// 按契约字段名取参，顺带认几个常见别名；取不到给空串，
  /// 由宿主实现报 INVALID_PARAMS。
  String _sourceArg(Map<String, dynamic> params, List<String> keys) {
    for (final key in keys) {
      final value = params[key];
      if (value != null && value.toString().isNotEmpty) {
        return value.toString();
      }
    }
    return '';
  }

  int _sourcePage(Map<String, dynamic> params) {
    final raw = params['page'];
    if (raw is num) return raw.toInt();
    return int.tryParse('${raw ?? ''}') ?? 1;
  }

  Map<String, dynamic> _sourceExt(Map<String, dynamic> params) {
    final raw = params['ext'];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return const {};
  }

  Future<Map<String, dynamic>> _request(Map<String, dynamic> params) async {
    var url = (params['url'] ?? '').toString();
    if (url.isEmpty) {
      throw MiniAppApiException('INVALID_PARAM', 'request 缺少 url');
    }
    if (url.startsWith('miniapp://')) {
      final resolved = await _resolveService(url);
      final target = resolved['url']?.toString() ?? '';
      if (target.isEmpty) {
        throw MiniAppApiException('NOT_FOUND', 'miniapp:// 目标未安装或未启动');
      }
      url = target;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw MiniAppApiException('INVALID_PARAM', '只支持 http/https 请求');
    }
    if (!_hostAllowed(uri.host)) {
      throw MiniAppApiException(
        'PERMISSION_DENIED',
        '域名不在 manifest 的 network.allowlist 里：${uri.host}',
      );
    }
    final method = (params['method'] ?? 'GET').toString().toUpperCase();
    final headers = <String, String>{};
    final rawHeaders = params['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        headers[key.toString()] = value.toString();
      });
    }
    final timeoutMs =
        (params['timeout'] as num?)?.toInt() ?? 10000;
    final client = _httpClient ?? http.Client();
    try {
      http.Response response;
      final body = params['body']?.toString();
      switch (method) {
        case 'POST':
          response = await client
              .post(uri, headers: headers, body: body)
              .timeout(Duration(milliseconds: timeoutMs));
        case 'PUT':
          response = await client
              .put(uri, headers: headers, body: body)
              .timeout(Duration(milliseconds: timeoutMs));
        case 'DELETE':
          response = await client
              .delete(uri, headers: headers, body: body)
              .timeout(Duration(milliseconds: timeoutMs));
        default:
          response = await client
              .get(uri, headers: headers)
              .timeout(Duration(milliseconds: timeoutMs));
      }
      return <String, dynamic>{
        'statusCode': response.statusCode,
        'data': response.body,
      };
    } on MiniAppApiException {
      rethrow;
    } catch (error) {
      throw MiniAppApiException('NETWORK_ERROR', error.toString());
    } finally {
      if (_httpClient == null) client.close();
    }
  }

  Future<Map<String, dynamic>> _resolveService(String url) async {
    if (!url.startsWith('miniapp://')) {
      return <String, dynamic>{'url': url};
    }
    final rest = url.substring('miniapp://'.length);
    final slash = rest.indexOf('/');
    final appId = slash < 0 ? rest : rest.substring(0, slash);
    final path = slash < 0 ? '' : rest.substring(slash);
    final base = await callbacks.resolveMiniAppUrl(appId);
    if (base == null) return <String, dynamic>{'url': ''};
    return <String, dynamic>{'url': '$base$path'};
  }

  bool _hostAllowed(String host) {
    final allowlist = manifest.networkAllowlist;
    if (allowlist.contains('*')) return true;
    final lower = host.toLowerCase();
    for (final pattern in allowlist) {
      final item = pattern.toLowerCase().trim();
      if (item.isEmpty) continue;
      if (item.startsWith('*.')) {
        final suffix = item.substring(1);
        if (lower.endsWith(suffix)) return true;
      } else if (lower == item || lower.endsWith('.$item')) {
        return true;
      }
    }
    return false;
  }

  Future<void> _clearStorage() async {
    final prefix = 'moyi_miniapp_${manifest.appId}_';
    final keys = prefs.getKeys().where((key) => key.startsWith(prefix));
    for (final key in keys.toList()) {
      await prefs.remove(key);
    }
  }

  List<String> _storageKeys() {
    final prefix = 'moyi_miniapp_${manifest.appId}_';
    return prefs
        .getKeys()
        .where((key) => key.startsWith(prefix))
        .map((key) => key.substring(prefix.length))
        .toList();
  }

  String? _resolveFilePath(String relative) {
    if (relative.isEmpty) return appDir.path;
    return safeJoinPath(appDir.path, relative);
  }

  Future<void> _fileWrite(Map<String, dynamic> params) async {
    final path = _resolveFilePath((params['path'] ?? '').toString());
    if (path == null) {
      throw MiniAppApiException('INVALID_PARAM', '文件路径不合法');
    }
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString((params['content'] ?? '').toString());
  }

  Future<String> _fileRead(Map<String, dynamic> params) async {
    final path = _resolveFilePath((params['path'] ?? '').toString());
    if (path == null) {
      throw MiniAppApiException('INVALID_PARAM', '文件路径不合法');
    }
    final file = File(path);
    if (!await file.exists()) {
      throw MiniAppApiException('NOT_FOUND', '文件不存在');
    }
    return file.readAsString();
  }

  Future<Map<String, dynamic>> _fileStat(
    Map<String, dynamic> params,
  ) async {
    final path = _resolveFilePath((params['path'] ?? '').toString());
    if (path == null) {
      throw MiniAppApiException('INVALID_PARAM', '文件路径不合法');
    }
    final file = File(path);
    if (await file.exists()) {
      return <String, dynamic>{
        'isDirectory': false,
        'size': await file.length(),
      };
    }
    final dir = Directory(path);
    if (await dir.exists()) {
      return <String, dynamic>{'isDirectory': true, 'size': 0};
    }
    throw MiniAppApiException('NOT_FOUND', '文件不存在');
  }

  Future<List<Map<String, dynamic>>> _fileList(
    Map<String, dynamic> params,
  ) async {
    final path = _resolveFilePath((params['path'] ?? '').toString());
    if (path == null) {
      throw MiniAppApiException('INVALID_PARAM', '文件路径不合法');
    }
    final dir = Directory(path);
    if (!await dir.exists()) {
      throw MiniAppApiException('NOT_FOUND', '目录不存在');
    }
    final entries = <Map<String, dynamic>>[];
    await for (final entity in dir.list()) {
      entries.add(<String, dynamic>{
        'name': entity.path.split(Platform.pathSeparator).last,
        'isDirectory': entity is Directory,
      });
    }
    return entries;
  }

  Future<void> _fileMkdir(Map<String, dynamic> params) async {
    final path = _resolveFilePath((params['path'] ?? '').toString());
    if (path == null) {
      throw MiniAppApiException('INVALID_PARAM', '文件路径不合法');
    }
    await Directory(path).create(recursive: true);
  }

  Future<void> _fileRename(Map<String, dynamic> params) async {
    final from = _resolveFilePath((params['from'] ?? '').toString());
    final to = _resolveFilePath((params['to'] ?? '').toString());
    if (from == null || to == null) {
      throw MiniAppApiException('INVALID_PARAM', '文件路径不合法');
    }
    final file = File(from);
    if (await file.exists()) {
      await file.rename(to);
      return;
    }
    final dir = Directory(from);
    if (await dir.exists()) {
      await dir.rename(to);
      return;
    }
    throw MiniAppApiException('NOT_FOUND', '文件不存在');
  }

  Future<void> _fileDelete(Map<String, dynamic> params) async {
    final path = _resolveFilePath((params['path'] ?? '').toString());
    if (path == null || path == appDir.path) {
      throw MiniAppApiException('INVALID_PARAM', '文件路径不合法');
    }
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
      return;
    }
    final dir = Directory(path);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      return;
    }
    throw MiniAppApiException('NOT_FOUND', '文件不存在');
  }
}
