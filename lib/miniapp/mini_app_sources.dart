import 'dart:convert';
import 'dart:io';

import '../import_file_store.dart';
import '../jar_bridge.dart';
import '../models.dart';
import '../py_bridge.dart';
import '../py_lazy_fetch.dart';
import '../zakatv_builtin.dart';

/// 采集源桥的失败，code 沿用 window.ant 契约的错误码，桥层会原样
/// 转成 MiniAppApiException 交给 JS 侧 reject。
class MiniAppSourceFailure implements Exception {
  const MiniAppSourceFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// 小程序 source.* 接口的宿主实现契约。
///
/// 返回形状按 window.ant 契约：list 是 [{key, name, type, searchable,
/// available}]；home/category/detail/search 原样返回蜘蛛的 vod_* 数据；
/// play 返回 {url, header, parse?, jx?}。
abstract class MiniAppSourceProvider {
  Future<List<Map<String, dynamic>>> listSites();

  Future<Map<String, dynamic>> home(String siteKey);

  Future<Map<String, dynamic>> category({
    required String siteKey,
    required String tid,
    required int page,
    Map<String, dynamic> ext = const {},
  });

  Future<Map<String, dynamic>> detail({
    required String siteKey,
    required String id,
  });

  Future<Map<String, dynamic>> play({
    required String siteKey,
    required String flag,
    required String id,
  });

  Future<Map<String, dynamic>> search({
    required String siteKey,
    required String wd,
    required int page,
  });
}

enum _SiteKind { jar, py }

class _ResolvedSite {
  const _ResolvedSite(this.kind, this.siteId, this.spec);

  final _SiteKind kind;
  final String siteId;
  final JarSiteSpec? spec;
}

/// 默认实现：只读复用站点区同一套内置注册表，不另起一份。
///
/// jar 站读静态表 zakatvBuiltinSites（跳过纯音频站，与站点区注册口径
/// 一致）；py 站读运行时注册表 SourceSite.importedSites，按
/// importType == 'py' 且 origin == 'builtin' 过滤，只含内置的 44 个。
/// 取数走宿主现有链路：jar 经 JarBridge.callJson，py 经 PyBridge.call，
/// 不另写爬虫。Go 核站（红果等）不是 TVBox 蜘蛛形态，不在此列。
class HostMiniAppSourceProvider implements MiniAppSourceProvider {
  HostMiniAppSourceProvider({
    Future<Map<String, dynamic>> Function(
      JarSiteSpec spec,
      String method,
      Map<String, dynamic> args,
    )?
    jarCall,
    Future<Map<String, dynamic>> Function(
      String source,
      Map<String, dynamic> request,
    )?
    pyCall,
    Duration callTimeout = const Duration(seconds: 60),
  }) : _jarCall = jarCall ?? JarBridge.callJson,
       _pyCall = pyCall,
       _callTimeout = callTimeout;

  /// 契约上限：单次调用 60 秒超时，最多 3 个并发。
  static const int maxConcurrent = 3;

  final Future<Map<String, dynamic>> Function(
    JarSiteSpec spec,
    String method,
    Map<String, dynamic> args,
  )
  _jarCall;
  final Future<Map<String, dynamic>> Function(
    String source,
    Map<String, dynamic> request,
  )?
  _pyCall;
  final Duration _callTimeout;

  int _active = 0;

  @override
  Future<List<Map<String, dynamic>>> listSites() async {
    final sites = <Map<String, dynamic>>[];
    for (final builtin in zakatvBuiltinSites) {
      if (builtin.audioOnly) continue;
      final siteId = JarSiteSpec.siteIdFor(zakatvJarId, builtin.key);
      sites.add(<String, dynamic>{
        'key': siteId,
        'name': builtin.name,
        'type': 'jar',
        'searchable': true,
        'available': JarBridge.isJarSource(siteId),
      });
    }
    for (final entry in SourceSite.importedSites.entries) {
      final site = entry.value;
      if (site.importType != 'py' || site.origin != SourceSite.originBuiltin) {
        continue;
      }
      sites.add(<String, dynamic>{
        'key': site.id,
        'name': site.name,
        'type': 'py',
        'searchable': true,
        'available': SourceSite.importedPyFiles.containsKey(site.id),
      });
    }
    return sites;
  }

  @override
  Future<Map<String, dynamic>> home(String siteKey) async {
    final site = _resolveSite(siteKey);
    return _guarded(() async {
      if (site.kind == _SiteKind.jar) {
        final raw = await _jarCall(site.spec!, 'homeContent', {
          'filter': true,
        });
        return withClassesAlias(raw);
      }
      final raw = await _callPy(site.siteId, {'action': 'home'});
      return withClassesAlias(raw);
    });
  }

  @override
  Future<Map<String, dynamic>> category({
    required String siteKey,
    required String tid,
    required int page,
    Map<String, dynamic> ext = const {},
  }) async {
    final site = _resolveSite(siteKey);
    final safePage = page < 1 ? 1 : page;
    return _guarded(() async {
      if (site.kind == _SiteKind.jar) {
        if (tid.isEmpty) {
          final raw = await _jarCall(site.spec!, 'homeVideoContent', {
            'pg': '$safePage',
          });
          final list = raw['list'];
          if (list is List && list.isNotEmpty) {
            return withClassesAlias(raw);
          }
          final home = await _jarCall(site.spec!, 'homeContent', {
            'filter': true,
          });
          return withClassesAlias(home);
        }
        final raw = await _jarCall(site.spec!, 'categoryContent', {
          'tid': tid,
          'pg': '$safePage',
          'filter': true,
          'extend': Map<String, dynamic>.from(ext),
        });
        return withClassesAlias(raw);
      }
      final raw = await _callPy(site.siteId, {
        'action': 'catalog',
        'page': safePage,
        'query': '',
        'category': tid,
        'filter': ext.isNotEmpty,
        'extend': Map<String, dynamic>.from(ext),
      });
      return Map<String, dynamic>.from(raw);
    });
  }

  @override
  Future<Map<String, dynamic>> detail({
    required String siteKey,
    required String id,
  }) async {
    if (id.isEmpty) {
      throw const MiniAppSourceFailure(
        'INVALID_PARAMS',
        'source.detail 缺少 id',
      );
    }
    final site = _resolveSite(siteKey);
    return _guarded(() async {
      if (site.kind == _SiteKind.jar) {
        final raw = await _jarCall(site.spec!, 'detailContent', {
          'ids': [id],
        });
        return Map<String, dynamic>.from(raw);
      }
      final raw = await _callPy(site.siteId, {
        'action': 'detail',
        'vodId': id,
      });
      return Map<String, dynamic>.from(raw);
    });
  }

  @override
  Future<Map<String, dynamic>> play({
    required String siteKey,
    required String flag,
    required String id,
  }) async {
    if (id.isEmpty) {
      throw const MiniAppSourceFailure('INVALID_PARAMS', 'source.play 缺少 id');
    }
    final site = _resolveSite(siteKey);
    return _guarded(() async {
      final raw = site.kind == _SiteKind.jar
          ? await _jarCall(site.spec!, 'playerContent', {
              'flag': flag,
              'id': id,
              'vipFlags': <String>[],
            })
          : await _callPy(site.siteId, {
              'action': 'resolve',
              'flag': flag,
              'playId': id,
            });
      return normalizePlayResult(raw);
    });
  }

  @override
  Future<Map<String, dynamic>> search({
    required String siteKey,
    required String wd,
    required int page,
  }) async {
    if (wd.isEmpty) {
      throw const MiniAppSourceFailure(
        'INVALID_PARAMS',
        'source.search 缺少 wd',
      );
    }
    final site = _resolveSite(siteKey);
    final safePage = page < 1 ? 1 : page;
    return _guarded(() async {
      if (site.kind == _SiteKind.jar) {
        final raw = await _jarCall(site.spec!, 'searchContent', {
          'key': wd,
          'quick': false,
          'pg': '$safePage',
        });
        return Map<String, dynamic>.from(raw);
      }
      final raw = await _callPy(site.siteId, {
        'action': 'catalog',
        'page': safePage,
        'query': wd,
        'category': '',
        'filter': false,
        'extend': <String, dynamic>{},
      });
      return Map<String, dynamic>.from(raw);
    });
  }

  /// 只认内置站：jar 看静态表，py 看运行时注册表里的 builtin 条目。
  /// 用户导入/配置的站不在开放范围，一律报 SITE_NOT_FOUND。
  /// jar 既认站点区完整 id（`jar:zakatv:<key>`），也认短 key。
  _ResolvedSite _resolveSite(String siteKey) {
    final key = siteKey.trim();
    if (key.isEmpty) {
      throw const MiniAppSourceFailure(
        'INVALID_PARAMS',
        '缺少 siteKey',
      );
    }
    var shortKey = key;
    const prefix = 'jar:$zakatvJarId:';
    if (key.startsWith(prefix)) {
      shortKey = key.substring(prefix.length);
    }
    for (final builtin in zakatvBuiltinSites) {
      if (builtin.audioOnly || builtin.key != shortKey) continue;
      if (key != shortKey && key != '$prefix$shortKey') continue;
      final siteId = JarSiteSpec.siteIdFor(zakatvJarId, builtin.key);
      final spec = JarBridge.specFor(siteId);
      if (spec == null) {
        throw MiniAppSourceFailure(
          'SITE_UNAVAILABLE',
          '站点「${builtin.name}」尚未注册到 jar 桥',
        );
      }
      return _ResolvedSite(_SiteKind.jar, siteId, spec);
    }
    final site = SourceSite.importedSites[key];
    if (site != null &&
        site.importType == 'py' &&
        site.origin == SourceSite.originBuiltin) {
      return _ResolvedSite(_SiteKind.py, site.id, null);
    }
    throw MiniAppSourceFailure('SITE_NOT_FOUND', '未找到内置站点：$key');
  }

  Future<T> _guarded<T>(Future<T> Function() run) async {
    if (_active >= maxConcurrent) {
      throw const MiniAppSourceFailure(
        'TOO_MANY_REQUESTS',
        '采集源并发调用已满（最多 3 个），请稍后重试',
      );
    }
    _active++;
    try {
      return await run().timeout(_callTimeout, onTimeout: () {
        throw const MiniAppSourceFailure(
          'TIMEOUT',
          '采集源调用超时（60 秒）',
        );
      });
    } on MiniAppSourceFailure {
      rethrow;
    } catch (error) {
      throw MiniAppSourceFailure('SOURCE_FAILED', '采集源调用失败：$error');
    } finally {
      _active--;
    }
  }

  Future<Map<String, dynamic>> _callPy(
    String source,
    Map<String, dynamic> request,
  ) async {
    final override = _pyCall;
    if (override != null) return override(source, request);
    final path = await _resolvePyPath(source);
    final ext = SourceSite.importedSites[source]?.importExt ?? '';
    final payload = <String, dynamic>{
      ...request,
      if (ext.isNotEmpty) 'extend': ext,
      'cfDisguise': true,
    };
    return PyBridge.call(path, payload);
  }

  /// 与 NativeRepository._pySpiderPath 同一口径：已保存文件优先，
  /// 其次懒加载缓存；内置站注册时已落盘，文件缺失即报不可用。
  Future<String> _resolvePyPath(String source) async {
    final fileName = SourceSite.importedPyFiles[source];
    if (fileName != null && fileName.isNotEmpty) {
      return ImportFileStore.pathOf(fileName);
    }
    final saved = await PyLazyFetch.savedFileName(source);
    if (saved != null && saved.isNotEmpty) {
      final savedPath = await ImportFileStore.pathOf(saved);
      if (await File(savedPath).exists()) {
        SourceSite.importedPyFiles[source] = saved;
        return savedPath;
      }
    }
    throw const MiniAppSourceFailure(
      'SITE_UNAVAILABLE',
      '该站的 py 蜘蛛文件尚未就绪',
    );
  }

  /// 蜘蛛首页用 TVBox 惯例的 `class` 键；契约文字写的是 `classes`，
  /// 两个键都给，读哪边都行，值是同一份真实数据。
  static Map<String, dynamic> withClassesAlias(Map<String, dynamic> raw) {
    final copy = Map<String, dynamic>.from(raw);
    if (!copy.containsKey('classes') && copy['class'] is List) {
      copy['classes'] = copy['class'];
    }
    return copy;
  }

  /// 取流结果归一成契约形状：url（取不到时看 playUrl）、header 一律
  /// Map、parse/jx 有则归一成 '1'/'0' 字符串、无则不编。
  static Map<String, dynamic> normalizePlayResult(Map<String, dynamic> raw) {
    var url = raw['url']?.toString() ?? '';
    if (url.isEmpty) url = raw['playUrl']?.toString() ?? '';
    if (url.isEmpty) {
      throw const MiniAppSourceFailure(
        'SOURCE_FAILED',
        '采集源取流未返回播放地址',
      );
    }
    final result = <String, dynamic>{
      'url': url,
      'header': normalizeHeaders(raw['header']),
    };
    if (raw.containsKey('parse')) {
      result['parse'] = _parseFlagString(raw['parse']);
    }
    if (raw.containsKey('jx')) {
      result['jx'] = _parseFlagString(raw['jx']);
    }
    return result;
  }

  /// header 三种形态（Map / JSON 字符串 / 键值对列表）都收成 Map。
  static Map<String, String> normalizeHeaders(Object? raw) {
    final headers = <String, String>{};
    if (raw is Map) {
      raw.forEach((key, value) {
        if (value != null) headers[key.toString()] = value.toString();
      });
    } else if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.startsWith('{')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map) {
            decoded.forEach((key, value) {
              if (value != null) headers[key.toString()] = value.toString();
            });
          }
        } catch (_) {}
      }
    } else if (raw is List) {
      for (final row in raw) {
        if (row is List && row.length >= 2) {
          headers[row[0].toString()] = row[1].toString();
        } else if (row is Map) {
          final key = row['key'] ?? row['name'];
          final value = row['value'];
          if (key != null && value != null) {
            headers[key.toString()] = value.toString();
          }
        }
      }
    }
    return headers;
  }

  static String _parseFlagString(Object? value) {
    if (value == true) return '1';
    if (value is num) return value.toInt() == 1 ? '1' : '0';
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text == '1' || text == 'true' ? '1' : '0';
  }
}
