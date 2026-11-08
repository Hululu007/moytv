import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'mini_app_manifest.dart';

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
}

class MiniAppBridge {
  MiniAppBridge({
    required this.manifest,
    required this.appDir,
    required this.prefs,
    required this.callbacks,
    this.launchOptions = const <String, dynamic>{},
    http.Client? httpClient,
  }) {
    _httpClient = httpClient;
  }

  final MiniAppManifest manifest;
  final Directory appDir;
  final SharedPreferences prefs;
  final MiniAppBridgeCallbacks callbacks;
  final Map<String, dynamic> launchOptions;
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
          'sdkVersion': 1,
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
      case 'player.open':
      case 'player.getState':
        throw MiniAppApiException(
          'NOT_IMPLEMENTED',
          '播放器桥未接：宿主播放器暂未开放给小程序',
        );
      case 'python.call':
        throw MiniAppApiException(
          'NOT_IMPLEMENTED',
          'Python 服务未接：小程序暂不能调用宿主 Python',
        );
      default:
        if (api.startsWith('source.')) {
          throw MiniAppApiException(
            'NOT_IMPLEMENTED',
            '采集源桥未接：宿主站源暂未开放给小程序',
          );
        }
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
