import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// 站点列表缩图：站 id → 站内随机视频封面地址。
///
/// 只存封面地址（取到后按站 id 缓存，下次打开弹窗直接用，不用
/// 每次都重新拉首页）；图片本体不另存，走 [SiteIconCache] 的
/// 磁盘缓存（py_covers/、sha1(url).img）显示。
///
/// 失败不记：拉不到、超时、首页为空、没封面的，一律回 null，
/// 调用方回落站标；失败只留在当次内存里，下次打开再拉（站
/// 恢复了就有图）。成功才落盘。
///
/// 并发上限 4 个在途首页请求；同站同时只拉一次（在途去重）。
typedef SiteThumbFetcher = Future<String?> Function(String siteId);

class SiteThumbCache {
  SiteThumbCache({
    Future<Directory> Function()? directoryProvider,
    this.maxConcurrent = 4,
  }) : _directoryProvider =
           directoryProvider ?? SiteThumbCache._defaultDirectory;

  static final SiteThumbCache instance = SiteThumbCache();

  /// 缩图映射文件名：应用支持目录下的 site_thumbs.json。
  static const String fileName = 'site_thumbs.json';

  final Future<Directory> Function() _directoryProvider;

  /// 同时在途的首页请求上限（与 SiteIconCache 同值）。
  final int maxConcurrent;

  Map<String, String>? _map;
  final Map<String, Future<String?>> _pending = {};
  Future<void> _writes = Future<void>.value();
  int _inFlight = 0;
  final List<Completer<void>> _waiters = [];

  static Future<Directory> _defaultDirectory() async {
    return getApplicationSupportDirectory();
  }

  /// 同步读内存缓存：有则回地址，无则 null（不触发加载、不联网）。
  /// 注意：首次调用前内存还是空的，调用方应走 [thumbUrlFor]。
  String? cachedUrl(String siteId) => _map?[siteId];

  /// 取某站的缩图地址：内存/磁盘命中直接回，否则调 [fetcher]
  /// 拉首页随机取一张封面；取到就缓存落盘，取不到回 null。
  /// 任何失败都不抛错、不记失败，下次打开再拉。
  Future<String?> thumbUrlFor(
    String siteId, {
    required SiteThumbFetcher fetcher,
  }) async {
    final map = await _load();
    final hit = map[siteId];
    if (hit != null && hit.isNotEmpty) return hit;
    final pending = _pending[siteId];
    if (pending != null) return pending;
    final future = _fetch(siteId, fetcher);
    _pending[siteId] = future;
    try {
      return await future;
    } finally {
      _pending.remove(siteId);
    }
  }

  Future<String?> _fetch(String siteId, SiteThumbFetcher fetcher) async {
    await _acquire();
    try {
      final url = await fetcher(siteId);
      if (url == null || url.isEmpty) return null;
      final map = await _load();
      map[siteId] = url;
      _save(map);
      return url;
    } catch (_) {
      return null;
    } finally {
      _release();
    }
  }

  Future<Map<String, String>> _load() async {
    final cached = _map;
    if (cached != null) return cached;
    final loaded = <String, String>{};
    try {
      final file = File(path.join((await _directoryProvider()).path, fileName));
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final key = entry.key.toString();
            final value = entry.value;
            if (key.isNotEmpty && value is String && value.isNotEmpty) {
              loaded[key] = value;
            }
          }
        }
      }
    } catch (_) {
      // 磁盘映射损坏/读不到时当空缓存，不阻塞、不抛错。
    }
    _map = loaded;
    return loaded;
  }

  void _save(Map<String, String> map) {
    _writes = _writes.then((_) async {
      try {
        final file = File(
          path.join((await _directoryProvider()).path, fileName),
        );
        await file.writeAsString(jsonEncode(map), flush: true);
      } catch (_) {
        // 落盘失败只丢本次写入，内存缓存照常可用。
      }
    });
  }

  /// 测试用：直接写一条缓存（内存 + 落盘排队）。
  Future<void> put(String siteId, String url) async {
    if (siteId.isEmpty || url.isEmpty) return;
    final map = await _load();
    map[siteId] = url;
    _save(map);
  }

  Future<void> _acquire() async {
    while (_inFlight >= maxConcurrent) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _inFlight++;
  }

  void _release() {
    _inFlight--;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }
}
