import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'tg_list_postprocess.dart';

class JarBridgeFailure implements Exception {
  JarBridgeFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class JarSiteSpec {
  const JarSiteSpec({
    required this.siteId,
    required this.configId,
    required this.name,
    required this.className,
    required this.jarUrl,
    required this.jarMd5,
    required this.ext,
  });

  final String siteId;
  final String configId;
  final String name;
  final String className;
  final String jarUrl;
  final String jarMd5;
  final String ext;

  Map<String, dynamic> toJson() => {
    'siteId': siteId,
    'configId': configId,
    'name': name,
    'className': className,
    'jarUrl': jarUrl,
    'jarMd5': jarMd5,
    'ext': ext,
  };

  factory JarSiteSpec.fromJson(Map<String, dynamic> json) => JarSiteSpec(
    siteId: json['siteId'] as String? ?? '',
    configId: json['configId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    className: json['className'] as String? ?? '',
    jarUrl: json['jarUrl'] as String? ?? '',
    jarMd5: json['jarMd5'] as String? ?? '',
    ext: json['ext'] as String? ?? '',
  );

  static String classNameForApi(String api) {
    final simple = api.startsWith('csp_') ? api.substring(4) : api;
    return 'com.github.catvod.spider.$simple';
  }

  static String siteIdFor(String configId, String key) => 'jar:$configId:$key';

  JarSiteSpec copyWith({String? ext, String? name}) => JarSiteSpec(
    siteId: siteId,
    configId: configId,
    name: name ?? this.name,
    className: className,
    jarUrl: jarUrl,
    jarMd5: jarMd5,
    ext: ext ?? this.ext,
  );
}

class JarClassInfo {
  const JarClassInfo({
    required this.className,
    required this.instantiable,
    this.reason = '',
  });

  final String className;
  final bool instantiable;
  final String reason;

  String get simpleName => className.split('.').last;

  factory JarClassInfo.fromJson(Map<String, dynamic> json) => JarClassInfo(
    className: json['className'] as String? ?? '',
    instantiable: json['instantiable'] == true,
    reason: json['reason'] as String? ?? '',
  );
}

class JarBridge {
  static const _channel = MethodChannel('moyi/jarbridge');
  static final Map<String, JarSiteSpec> _specs = {};
  static final Map<String, String> _jarPaths = {};
  static final Map<String, Map<String, dynamic>> _homeCache = {};

  static bool get supported => Platform.isAndroid;

  static List<JarSiteSpec> get specs => List.unmodifiable(_specs.values);

  static void register(JarSiteSpec spec) {
    final previous = _specs[spec.siteId];
    _specs[spec.siteId] = spec;
    if (previous != null && previous.ext != spec.ext) {
      _homeCache.remove(spec.siteId);
      if (supported) {
        _channel
            .invokeMethod<void>('release', {'siteId': spec.siteId})
            .catchError((Object _) {});
      }
    }
  }

  static Future<void> updateExt(String siteId, String ext) async {
    final previous = _specs[siteId];
    if (previous == null || previous.ext == ext) return;
    _specs[siteId] = previous.copyWith(ext: ext);
    _homeCache.remove(siteId);
    if (supported) {
      try {
        await _channel.invokeMethod<void>('release', {'siteId': siteId});
      } catch (_) {}
    }
  }

  static void unregister(String siteId) {
    _specs.remove(siteId);
    _homeCache.remove(siteId);
    if (supported) {
      _channel
          .invokeMethod<void>('release', {'siteId': siteId})
          .catchError((Object _) {});
    }
  }

  /// 测试缝：非 Android 环境下 jar 桥本会直接抛错；预置 jar 路径后
  /// callJson 只走平台通道，测试可 mock 通道返回合成数据。
  @visibleForTesting
  static void setTestJarPath(String configId, String path) {
    _jarPaths[configId] = path;
  }

  @visibleForTesting
  static void clearTestJarPaths() => _jarPaths.clear();

  static Future<void> setJarFingerprint(bool enabled) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('setJarFingerprint', {
        'enabled': enabled,
      });
    } catch (_) {}
  }

  static bool isJarSource(String source) => _specs.containsKey(source);

  static JarSiteSpec? specFor(String source) => _specs[source];

  static void requireSupported(JarSiteSpec spec) {
    if (!supported) {
      throw JarBridgeFailure(
        '「${spec.name}」是 jar 站点：jar 桥仅支持 Android，当前平台无法加载远程 jar',
      );
    }
  }

  static Future<String> ensureJarPath({
    required String configId,
    required String url,
    String md5 = '',
  }) async {
    final cached = _jarPaths[configId];
    if (cached != null) return cached;
    if (!supported) {
      throw JarBridgeFailure('jar 桥仅支持 Android，当前平台无法下载与加载远程 jar');
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'ensureJar',
        {'configId': configId, 'url': url, 'md5': md5},
      );
      final jarPath = result?['path'] as String? ?? '';
      if (jarPath.isEmpty) {
        throw JarBridgeFailure('jar 下载失败：桥未返回本地路径');
      }
      _jarPaths[configId] = jarPath;
      return jarPath;
    } on PlatformException catch (error) {
      throw JarBridgeFailure(error.message ?? 'jar 桥调用失败');
    } on MissingPluginException {
      throw JarBridgeFailure('jar 桥未就绪：当前安装包未包含 jar 桥通道');
    }
  }

  static Future<String> _ensureJar(JarSiteSpec spec) => ensureJarPath(
    configId: spec.configId,
    url: spec.jarUrl,
    md5: spec.jarMd5,
  );

  static Future<List<JarClassInfo>> enumerate(String jarPath) async {
    if (!supported) {
      throw JarBridgeFailure('jar 桥仅支持 Android，当前平台无法枚举 jar 内的 Spider 类');
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'enumerate',
        {'jarPath': jarPath},
      );
      return [
        for (final row in result?['classes'] as List? ?? const [])
          if (row is Map) JarClassInfo.fromJson(Map<String, dynamic>.from(row)),
      ];
    } on PlatformException catch (error) {
      throw JarBridgeFailure(error.message ?? 'jar 枚举失败');
    } on MissingPluginException {
      throw JarBridgeFailure('jar 桥未就绪：当前安装包未包含 jar 桥通道');
    }
  }

  static void invalidateJar(String configId) {
    _jarPaths.remove(configId);
    _homeCache.removeWhere((siteId, _) => siteId.startsWith('jar:$configId:'));
  }

  static Future<Map<String, dynamic>> callJson(
    JarSiteSpec spec,
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    final jarPath = await _ensureJar(spec);
    try {
      return await _invokeCall(spec, jarPath, method, args);
    } on JarBridgeFailure catch (failure) {
      if (!failure.message.contains('未找到站点类')) rethrow;
      final recovered = await _retryWithFreshJar(spec, method, args);
      if (recovered != null) return recovered;
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> _invokeCall(
    JarSiteSpec spec,
    String jarPath,
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('call', {
        'siteId': spec.siteId,
        'configId': spec.configId,
        'jarPath': jarPath,
        'className': spec.className,
        'ext': spec.ext,
        'method': method,
        'args': args,
      });
      final text = result?['text'] as String? ?? '';
      if (text.trim().isEmpty) return const {};
      try {
        final decoded = jsonDecode(text);
        return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
      } catch (_) {
        throw JarBridgeFailure('jar 站点「${spec.name}」的 $method 返回了无法解析的内容');
      }
    } on PlatformException catch (error) {
      throw JarBridgeFailure(error.message ?? 'jar 桥调用失败');
    } on MissingPluginException {
      throw JarBridgeFailure('jar 桥未就绪：当前安装包未包含 jar 桥通道');
    }
  }

  static Future<Map<String, dynamic>?> _retryWithFreshJar(
    JarSiteSpec spec,
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      _jarPaths.remove(spec.configId);
      String? fallbackPath;
      if (spec.jarMd5.isNotEmpty) {
        final directory = await getApplicationSupportDirectory();
        final imported = File(
          path.join(directory.path, 'imported_jars', '${spec.jarMd5}.jar'),
        );
        if (await imported.exists()) fallbackPath = imported.path;
      }
      fallbackPath ??= await _ensureJar(spec);
      final recovered = await _invokeCall(spec, fallbackPath, method, args);
      if (spec.jarMd5.isNotEmpty && fallbackPath.isNotEmpty) {
        try {
          await ensureJarPath(
            configId: spec.configId,
            url: fallbackPath,
            md5: spec.jarMd5,
          );
        } catch (_) {}
      }
      return recovered;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> home(
    JarSiteSpec spec, {
    bool force = false,
  }) async {
    // 实时口径：force 时不读会话内 home 缓存，现抓并覆盖缓存。
    if (!force) {
      final cached = _homeCache[spec.siteId];
      if (cached != null) return cached;
    }
    final result = await callJson(spec, 'homeContent', {'filter': true});
    if (result.isNotEmpty) _homeCache[spec.siteId] = result;
    return result;
  }

  static Future<List<CatalogCategory>> categories(
    JarSiteSpec spec, {
    bool force = false,
  }) async {
    final result = await home(spec, force: force);
    return [
      for (final row in result['class'] as List? ?? const [])
        if (row is Map)
          CatalogCategory(
            row['type_id']?.toString() ?? '',
            row['type_name']?.toString() ?? '',
          ),
    ].where((category) => category.id.isNotEmpty).toList();
  }

  static Drama _vodToDrama(JarSiteSpec spec, Map row) {
    final map = Map<String, dynamic>.from(row);
    return Drama(
      id: map['vod_id']?.toString() ?? '',
      source: spec.siteId,
      title: map['vod_name']?.toString() ?? '',
      description: map['vod_blurb']?.toString() ?? '',
      cover: map['vod_pic']?.toString() ?? '',
      category: map['type_name']?.toString() ?? '',
      heat: map['vod_remarks']?.toString() ?? '',
      onlineDate: map['vod_year']?.toString() ?? '',
      tags: [
        for (final tag in (map['vod_tag']?.toString() ?? '').split(','))
          if (tag.trim().isNotEmpty) tag.trim(),
      ],
    );
  }

  static CatalogPage _listToPage(
    JarSiteSpec spec,
    Map<String, dynamic> result, {
    required int page,
  }) {
    final items = [
      for (final row in result['list'] as List? ?? const [])
        if (row is Map) _vodToDrama(spec, row),
    ].where((drama) => drama.id.isNotEmpty && drama.title.isNotEmpty).toList();
    final pageCount = intValue(result['pagecount']);
    final total = intValue(result['total']);
    final hasMore = pageCount > 0
        ? page < pageCount
        : total > 0
        ? items.length * page < total
        : items.isNotEmpty;
    return CatalogPage(items, hasMore: hasMore, page: page, fresh: true);
  }

  /// jar 目录统一入口：TG 两站的列表在壳侧做广告过滤/去重/归拢
  /// （tgPostProcessPage，类名 gate）；其它站原样返回同一页对象。
  static Future<CatalogPage> catalog(
    JarSiteSpec spec, {
    int page = 1,
    String query = '',
    String category = '',
    Map<String, String> filters = const {},
  }) async {
    final pageResult = await _catalogRaw(
      spec,
      page: page,
      query: query,
      category: category,
      filters: filters,
    );
    return tgPostProcessPage(
      pageResult,
      className: spec.className,
      category: category,
    );
  }

  static Future<CatalogPage> _catalogRaw(
    JarSiteSpec spec, {
    int page = 1,
    String query = '',
    String category = '',
    Map<String, String> filters = const {},
  }) async {
    if (query.isNotEmpty) {
      final result = await callJson(spec, 'searchContent', {
        'key': query,
        'quick': false,
        'pg': '$page',
      });
      return _listToPage(spec, result, page: page);
    }
    if (category.isEmpty) {
      final videos = await callJson(spec, 'homeVideoContent');
      if ((videos['list'] as List? ?? const []).isNotEmpty) {
        return _listToPage(spec, videos, page: page);
      }
      final homeResult = await home(spec, force: true);
      return _listToPage(spec, homeResult, page: page);
    }
    final result = await callJson(spec, 'categoryContent', {
      'tid': category,
      'pg': '$page',
      'filter': true,
      'extend': filters,
    });
    if ((result['list'] as List? ?? const []).isNotEmpty || page > 1) {
      return _listToPage(spec, result, page: page);
    }
    final videos = await callJson(spec, 'homeVideoContent');
    if ((videos['list'] as List? ?? const []).isNotEmpty) {
      return _listToPage(spec, videos, page: page);
    }
    return _listToPage(spec, result, page: page);
  }

  static Future<DramaDetail> detail(JarSiteSpec spec, Drama drama) async {
    final result = await callJson(spec, 'detailContent', {
      'ids': [drama.id],
    });
    final rows = result['list'] as List? ?? const [];
    if (rows.isEmpty || rows.first is! Map) {
      throw JarBridgeFailure('jar 站点「${spec.name}」未返回「${drama.title}」的详情');
    }
    final vod = Map<String, dynamic>.from(rows.first as Map);
    final enriched = _vodToDrama(spec, vod).merge(drama);
    final detailDrama = Drama(
      id: enriched.id,
      source: spec.siteId,
      title: enriched.title,
      description: (vod['vod_content']?.toString() ?? '').isNotEmpty
          ? vod['vod_content'].toString()
          : enriched.description,
      cover: enriched.cover,
      episodes: 0,
      category: enriched.category,
      heat: enriched.heat,
      onlineDate: enriched.onlineDate,
      tags: [
        for (final tag in [
          ...(vod['vod_actor']?.toString() ?? '').split(','),
          ...(vod['vod_tag']?.toString() ?? '').split(','),
        ])
          if (tag.trim().isNotEmpty) tag.trim(),
      ],
    );
    final flags = (vod['vod_play_from']?.toString() ?? '').split(r'$$$');
    final groups = (vod['vod_play_url']?.toString() ?? '').split(r'$$$');
    final episodes = <Episode>[];
    var number = 0;
    for (var group = 0; group < groups.length; group++) {
      final flag = group < flags.length && flags[group].trim().isNotEmpty
          ? flags[group].trim()
          : '正片';
      for (final entry in groups[group].split('#')) {
        if (entry.trim().isEmpty) continue;
        final split = entry.indexOf('\$');
        final name = split >= 0 ? entry.substring(0, split) : entry;
        final playId = split >= 0 ? entry.substring(split + 1) : entry;
        number++;
        episodes.add(
          Episode({
            'id': playId,
            'title': groups.length > 1 ? '$flag · $name' : name,
            'flag': flag,
            'playId': playId,
            'currentEpisode': number,
          }, number),
        );
      }
    }
    if (episodes.isEmpty) {
      throw JarBridgeFailure('jar 站点「${spec.name}」的「${drama.title}」没有可播放的集数');
    }
    return DramaDetail(detailDrama, episodes);
  }

  static bool _parseFlag(Object? value) =>
      value == true || intValue(value) == 1;

  static Future<PlaybackPlan> resolve(
    JarSiteSpec spec,
    Drama drama,
    Episode episode,
  ) async {
    final flag = episode.raw['flag'] as String? ?? '';
    final playId = episode.raw['playId'] as String? ?? episode.id;
    final result = await callJson(spec, 'playerContent', {
      'flag': flag,
      'id': playId,
      'vipFlags': <String>[],
    });
    final url = result['url']?.toString() ?? '';
    if (url.isEmpty) {
      throw JarBridgeFailure('jar 站点「${spec.name}」未返回播放地址');
    }
    final headers = <String, String>{};
    final rawHeaders = result['header'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        if (value != null) headers[key.toString()] = value.toString();
      });
    } else if (rawHeaders is String && rawHeaders.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(rawHeaders);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value != null) headers[key.toString()] = value.toString();
          });
        }
      } catch (_) {}
    }
    final needsParse = _parseFlag(result['parse']) || _parseFlag(result['jx']);
    return PlaybackPlan(url: url, headers: headers, needsParse: needsParse);
  }

  static Map<String, String> parseProxyParams(String proxyUrl) {
    var rest = proxyUrl;
    if (rest.startsWith('proxy://')) {
      rest = rest.substring('proxy://'.length);
    } else if (rest.startsWith('proxy:')) {
      rest = rest.substring('proxy:'.length);
    }
    if (!rest.contains('=')) return {'url': rest};
    final map = <String, String>{};
    for (final part in rest.split('&')) {
      final eq = part.indexOf('=');
      if (eq > 0) {
        map[Uri.decodeComponent(part.substring(0, eq))] = Uri.decodeComponent(
          part.substring(eq + 1),
        );
      }
    }
    return map.isNotEmpty ? map : {'url': rest};
  }

  static Map<String, dynamic> jarProxyPayload(
    JarSiteSpec spec,
    Map<String, String> param,
  ) => {
    'siteId': spec.siteId,
    'configId': spec.configId,
    'className': spec.className,
    'param': param,
  };

  static String jarProxyLocalUrl(int port, Map<String, dynamic> payload) {
    final encoded = base64Url.encode(utf8.encode(jsonEncode(payload)));
    return 'http://127.0.0.1:$port/jarproxy?d=$encoded';
  }

  static Future<Map<String, dynamic>> jarProxy(
    JarSiteSpec spec,
    Map<String, String> param,
  ) async {
    final jarPath = await _ensureJar(spec);
    try {
      final result = await _channel
          .invokeMapMethod<String, dynamic>('jarProxy', {
            'configId': spec.configId,
            'jarPath': jarPath,
            'className': spec.className,
            'param': param,
          });
      final mime = result?['mime'] as String? ?? 'application/octet-stream';
      final body = result?['bodyBase64'] as String? ?? '';
      if (body.isEmpty) {
        throw JarBridgeFailure('jar 站点「${spec.name}」的本地代理未返回内容');
      }
      final status = result?['status'];
      return {
        'status': status is int ? status : 200,
        'mime': mime,
        'bodyBase64': body,
      };
    } on PlatformException catch (error) {
      throw JarBridgeFailure(error.message ?? 'jar 本地代理调用失败');
    } on MissingPluginException {
      throw JarBridgeFailure('jar 桥未就绪：当前安装包未包含 jar 桥通道');
    }
  }

  static Future<String> coverFile(Drama drama) async {
    final url = drama.cover.trim();
    if (url.isEmpty) throw JarBridgeFailure('该条目没有封面');
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      throw JarBridgeFailure('封面地址不可用');
    }
    final directory = await getTemporaryDirectory();
    final cacheDir = Directory(path.join(directory.path, 'jar_covers'));
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    final file = File(
      path.join(cacheDir.path, '${_fnv1a(url)}${_extensionOf(url)}'),
    );
    if (await file.exists() && await file.length() > 0) return file.path;
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'okhttp/4.12.0');
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw JarBridgeFailure('封面下载失败：HTTP ${response.statusCode}');
      }
      final sink = file.openWrite();
      await response.pipe(sink);
      await sink.close();
      return file.path;
    } finally {
      client.close();
    }
  }

  static String _extensionOf(String url) {
    final clean = url.split('?').first.split('#').first.toLowerCase();
    for (final ext in ['.jpg', '.jpeg', '.png', '.webp', '.gif']) {
      if (clean.endsWith(ext)) return ext;
    }
    return '.jpg';
  }

  static String _fnv1a(String text) {
    var hash = 0x811c9dc5;
    for (final unit in text.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
