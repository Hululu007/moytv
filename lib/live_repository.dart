import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'core_bridge.dart';
import 'live_api.dart';
import 'live_http.dart';
import 'live_models.dart';
import 'live_parser.dart';
import 'live_sources.dart';
import 'socks5_proxy.dart';

class _Stamped<T> {
  const _Stamped(this.value, this.storedAt);
  final T value;
  final DateTime storedAt;
}

class LiveRepository {
  LiveRepository({
    LiveHttp? http,
    DateTime Function()? now,
    Duration? platformTtl,
    Duration? channelTtl,
    Duration? routeOrderTtl,
  }) : _http = http ?? LiveHttp(),
       _now = now ?? DateTime.now,
       _platformTtl = platformTtl ?? const Duration(minutes: 10),
       _channelTtl = channelTtl ?? const Duration(minutes: 5),
       _routeOrderTtl = routeOrderTtl ?? const Duration(minutes: 15);

  /// 已失效的分类：源站仍返回，但频道统一跳转到版权拦截页。
  static const retiredCategories = ['weishizhibo'];

  /// 频道缓存最多保留条目：键含源 + 分类 + 页码，用户翻页浏览会
  /// 无限增长；超限时丢弃存入最早的一批。分类与线路缓存以源为键，
  /// 天然有界，不设上限。
  static const maxChannelCacheEntries = 64;

  static final _cctv = RegExp(r'^(cctv|央视|中央电视台)', caseSensitive: false);

  final LiveHttp _http;
  final DateTime Function() _now;
  final Duration _platformTtl;
  final Duration _channelTtl;
  final Duration _routeOrderTtl;
  final Map<String, _Stamped<List<LivePlatform>>> _platforms = {};
  final Map<String, _Stamped<List<LiveChannel>>> _channels = {};
  final Map<String, _Stamped<List<int>>> _routeOrders = {};
  final Map<String, Future<List<LivePlatform>>> _platformInflight = {};
  final Map<String, Future<List<LiveChannel>>> _channelInflight = {};
  final Map<String, Future<List<int>?>> _routeOrderInflight = {};

  /// 分组/换台位置记忆（随仓库实例走，首页持有同一个仓库故切区不丢）。
  final LiveGroupMemory groupMemory = LiveGroupMemory();
  int _generation = 0;

  void cancel() {
    _generation++;
    // 在途请求继续跑完，但不再被新调用复用、其结果也不再写缓存
    // （写缓存时凭代次拦截），与界面层“取消后旧结果不写回”同口径。
    _platformInflight.clear();
    _channelInflight.clear();
    _routeOrderInflight.clear();
  }

  void dispose() {
    _generation++;
    _platformInflight.clear();
    _channelInflight.clear();
    _routeOrderInflight.clear();
    _http.close();
  }

  void clear() {
    _platforms.clear();
    _channels.clear();
    _routeOrders.clear();
    _platformInflight.clear();
    _channelInflight.clear();
    _routeOrderInflight.clear();
  }

  T? _fresh<T>(Map<String, _Stamped<T>> cache, String key, Duration ttl) {
    final entry = cache[key];
    if (entry == null) return null;
    if (_now().difference(entry.storedAt) >= ttl) {
      cache.remove(key);
      return null;
    }
    return entry.value;
  }

  void _storeChannels(String key, List<LiveChannel> value) {
    _channels[key] = _Stamped(value, _now());
    if (_channels.length <= maxChannelCacheEntries) return;
    final keys = _channels.keys.toList()
      ..sort(
        (a, b) => _channels[a]!.storedAt.compareTo(_channels[b]!.storedAt),
      );
    for (final old in keys.take(_channels.length - maxChannelCacheEntries)) {
      _channels.remove(old);
    }
  }

  Future<List<LivePlatform>> platforms(
    LiveSource source, {
    bool force = false,
  }) async {
    if (!force) {
      final cached = _fresh(_platforms, source.id, _platformTtl);
      if (cached != null) return cached;
      final inflight = _platformInflight[source.id];
      if (inflight != null) return inflight;
    }
    final token = _generation;
    final future = _fetchPlatforms(source, token);
    _platformInflight[source.id] = future;
    try {
      return await future;
    } finally {
      if (identical(_platformInflight[source.id], future)) {
        _platformInflight.remove(source.id);
      }
    }
  }

  Future<List<LivePlatform>> _fetchPlatforms(
    LiveSource source,
    int token,
  ) async {
    final result = switch (source.protocol) {
      LiveProtocol.pingtai => await _pingtaiPlatforms(source),
      LiveProtocol.list => const [LivePlatform(id: 'all', name: '全部频道')],
      LiveProtocol.api => await _apiPlatforms(source),
    };
    if (result.isEmpty) throw AppFailure('该直播源没有可用分类');
    if (token == _generation) {
      _platforms[source.id] = _Stamped(result, _now());
    }
    return result;
  }

  Future<List<LiveChannel>> channels(
    LiveSource source,
    LivePlatform platform, {
    int page = 1,
    bool force = false,
  }) async {
    final imported = importedLiveChannels[source.id];
    if (imported != null) {
      if (imported.isEmpty) throw AppFailure('该订阅暂时没有频道');
      return imported;
    }
    final cacheKey = '${source.id}\u0000${platform.id}\u0000$page';
    if (!force) {
      final cached = _fresh(_channels, cacheKey, _channelTtl);
      if (cached != null) return cached;
      final inflight = _channelInflight[cacheKey];
      if (inflight != null) return inflight;
    }
    final token = _generation;
    final future = _fetchChannels(source, platform, page, cacheKey, token);
    _channelInflight[cacheKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_channelInflight[cacheKey], future)) {
        _channelInflight.remove(cacheKey);
      }
    }
  }

  Future<List<LiveChannel>> _fetchChannels(
    LiveSource source,
    LivePlatform platform,
    int page,
    String cacheKey,
    int token,
  ) async {
    final result = switch (source.protocol) {
      LiveProtocol.pingtai => await _pingtaiChannels(source, platform),
      LiveProtocol.list => await _listChannels(source),
      LiveProtocol.api => await _apiChannels(source, platform, page: page),
    };
    if (result.isEmpty) throw AppFailure('该分类暂时没有频道');
    // 原先频道结果无条件写缓存：cancel() 后回来的慢响应会覆盖新
    // 抓的数据。现与 platforms() 同口径，凭代次拦截过期写入。
    if (token == _generation) _storeChannels(cacheKey, result);
    return result;
  }

  Future<LivePlayback> playback(LiveSource source, LiveChannel channel) async {
    switch (source.protocol) {
      case LiveProtocol.pingtai:
      case LiveProtocol.list:
        if (channel.urls.isEmpty) throw AppFailure('该频道没有可用线路');
        return LivePlayback(url: channel.urls.first, headers: channel.headers);
      case LiveProtocol.api:
        return _apiPlayback(source, channel);
    }
  }

  Future<List<LivePlatform>> _apiPlatforms(LiveSource source) async {
    final spec = liveApiSpecById(source.id);
    if (spec == null) throw AppFailure('该直播源暂未接入');
    if (spec.platformsUrl.isEmpty) {
      if (!spec.derivePlatformName) {
        return [
          LivePlatform(
            id: spec.singlePlatformId,
            name: spec.singlePlatformName,
          ),
        ];
      }
      final platform = LivePlatform(
        id: spec.singlePlatformId,
        name: spec.singlePlatformName,
      );
      final text = await _http.get(
        spec.listUrlFor(platform, page: 1),
        headers: spec.headers,
        proxyResourceKey: socks5LiveResourceKey(source.id),
      );
      return [
        LivePlatform(
          id: spec.singlePlatformId,
          name: deriveApiPlatformName(spec, text),
          count: deriveApiPlatformCount(spec, text),
        ),
      ];
    }
    final text = await _http.get(
      spec.platformsUrl,
      headers: spec.headers,
      proxyResourceKey: socks5LiveResourceKey(source.id),
    );
    final result = parseApiPlatforms(spec, text);
    if (result.isEmpty) throw AppFailure('该直播源没有可用分类');
    return result;
  }

  Future<List<LiveChannel>> _apiChannels(
    LiveSource source,
    LivePlatform platform, {
    int page = 1,
  }) async {
    final spec = liveApiSpecById(source.id);
    if (spec == null) throw AppFailure('该直播源暂未接入');
    final text = await _http.get(
      spec.listUrlFor(platform, page: page),
      headers: spec.headers,
      proxyResourceKey: socks5LiveResourceKey(source.id),
    );
    final result = parseApiChannels(spec, platform, text, source.id);
    if (result.isEmpty) throw AppFailure('该分类暂时没有频道');
    return result;
  }

  Future<LivePlayback> _apiPlayback(
    LiveSource source,
    LiveChannel channel,
  ) async {
    final spec = liveApiSpecById(source.id);
    if (spec == null) throw AppFailure('该直播源暂未接入');
    if (channel.urls.isNotEmpty) {
      return LivePlayback(url: channel.urls.first, headers: channel.headers);
    }
    if (spec.playUrl.isEmpty || channel.token.isEmpty) {
      throw AppFailure('该频道没有可用线路');
    }
    final text = await _http.get(
      spec.playUrlFor(channel.token),
      headers: spec.headers,
      proxyResourceKey: socks5LiveResourceKey(source.id),
    );
    final url = parseApiPlayUrl(spec, text);
    if (url == null || url.isEmpty) throw AppFailure('该频道暂时无法播放');
    return LivePlayback(
      url: url,
      headers: {...channel.headers, ...spec.headers},
    );
  }

  /// 合并同一面板的所有镜像：各镜像共享内容但分类子集不同，取并集后去重，
  /// 并让每个分类记住提供它的镜像。
  ///
  /// 各镜像并行拉取：原先串行等，一个慢镜像（最长一个请求超时）会拖住
  /// 后面所有镜像；合并仍按镜像声明顺序处理，失败也按声明顺序记录，
  /// 结果与串行版一致。
  Future<List<LivePlatform>> _pingtaiPlatforms(LiveSource source) async {
    final outcomes = await Future.wait([
      for (final endpoint in source.endpoints)
        _fetchPingtaiRows(source, endpoint),
    ]);
    final byId = <String, LivePlatform>{};
    final failures = <String>[];
    for (var i = 0; i < outcomes.length; i++) {
      final endpoint = source.endpoints[i];
      final outcome = outcomes[i];
      if (outcome.failure != null) {
        failures.add(outcome.failure!);
        continue;
      }
      final rows = outcome.rows;
      if (rows == null) continue;
      for (final row in rows.whereType<Map>()) {
        final id = '${row['address'] ?? ''}'.trim();
        final name = '${row['title'] ?? ''}'.trim();
        if (id.isEmpty || name.isEmpty) continue;
        if (retiredCategories.any(id.contains)) continue;
        final count = int.tryParse('${row['Number'] ?? ''}') ?? 0;
        final item = LivePlatform(
          id: id,
          name: name,
          logo: '${row['xinimg'] ?? ''}'.trim(),
          count: count,
          endpoint: endpoint,
        );
        // 各镜像的分类计数并不同步（实测同一分类一边记 0、另一边记 77），
        // 只要任一镜像报告有内容就保留，并跟随该镜像取频道。
        final previous = byId[id];
        if (previous == null || count > previous.count) byId[id] = item;
      }
    }
    if (byId.isEmpty) {
      throw AppFailure(
        failures.isEmpty ? '该直播源没有可用分类' : '该直播源暂时不可用：${failures.first}',
      );
    }
    final all = byId.values.toList();
    final result = [
      for (final item in all)
        if (item.count > 0) item,
    ];
    // 上游整体不带频道数字段时不做过滤，避免把整个源误判成没有分类。
    return result.isEmpty ? all : result;
  }

  /// 拉一个镜像的分类行：失败或结构不对时不抛错，由调用方按声明顺序
  /// 合并失败信息；rows 为 null 且 failure 为 null 表示结构不对被跳过。
  Future<({List<dynamic>? rows, String? failure})> _fetchPingtaiRows(
    LiveSource source,
    String endpoint,
  ) async {
    try {
      final text = await _http.get(
        '$endpoint/json.txt',
        proxyResourceKey: socks5LiveResourceKey(source.id),
      );
      final dynamic decoded = jsonDecode(text);
      final raw = decoded is Map ? decoded['pingtai'] : decoded;
      if (raw is! List) return (rows: null, failure: null);
      return (rows: raw, failure: null);
    } catch (error) {
      return (rows: null, failure: '$error');
    }
  }

  Future<List<LiveChannel>> _pingtaiChannels(
    LiveSource source,
    LivePlatform platform,
  ) async {
    // 优先用提供该分类的镜像，全部失败再依次试其他镜像。
    final candidates = <String>{
      if (platform.endpoint.isNotEmpty) platform.endpoint,
      ...source.endpoints,
    };
    String? text;
    Object? lastError;
    for (final endpoint in candidates) {
      try {
        text = await _http.get(
          '$endpoint/${platform.id}',
          proxyResourceKey: socks5LiveResourceKey(source.id),
        );
        break;
      } catch (error) {
        lastError = error;
      }
    }
    if (text == null) throw AppFailure('$lastError');
    final dynamic decoded = jsonDecode(text);
    final rows = decoded is Map
        ? decoded['zhubo'] ?? decoded['list'] ?? decoded['data']
        : decoded;
    if (rows is! List) throw AppFailure('该分类暂时没有频道');
    final reliable = <LiveChannel>[];
    final fallback = <LiveChannel>[];
    final seen = <String>{};
    var number = 0;
    for (final row in rows.whereType<Map>()) {
      final name = '${row['title'] ?? ''}'.trim();
      final url = '${row['address'] ?? ''}'.trim();
      if (name.isEmpty || !isPlayableLiveUrl(url) || !seen.add(name)) continue;
      if (_cctv.hasMatch(name)) continue;
      number++;
      final channel = LiveChannel(
        key: LiveChannel.makeKey(source.id, platform.name, name),
        name: name,
        urls: [url],
        number: number.toString().padLeft(3, '0'),
        headers: source.headers,
        logo: '${row['img'] ?? ''}'.trim(),
        group: platform.name,
        source: source.id,
      );
      (url.startsWith('rtmp') ? fallback : reliable).add(channel);
    }
    return [...reliable, ...fallback];
  }

  Future<List<LiveChannel>> _listChannels(LiveSource source) async {
    final endpoint = source.endpoint;
    final text = endpoint.startsWith('asset://')
        ? await rootBundle.loadString(endpoint.substring('asset://'.length))
        : await _http.get(
            endpoint,
            headers: source.headers,
            proxyResourceKey: socks5LiveResourceKey(source.id),
          );
    final parsed = LiveParser.parse(
      text,
      source: source.id,
      defaultGroup: source.group.isEmpty ? liveUnsortedGroup : source.group,
    );
    final channels = [for (final group in parsed.groups) ...group.channels];
    // 空列表直接返回，由 channels() 统一报“该分类暂时没有频道”：
    // 原先带代理的源会在此对空列表取 channels.first，漏出 StateError。
    if (channels.isEmpty) return channels;
    if (source.proxies.isEmpty) return channels;
    final expanded = [
      for (final channel in channels)
        channel.withUrls([
          for (final proxy in source.proxies)
            if (channel.url.isNotEmpty) '$proxy${channel.url}',
          ...channel.urls,
        ]),
    ];
    final order = await _routeOrder(
      source,
      channels.first.url,
      channels.first.headers,
    );
    if (order == null) return expanded;
    return [
      for (final channel in expanded)
        channel.withUrls([
          for (final index in order)
            if (index < channel.urls.length) channel.urls[index],
        ]),
    ];
  }

  /// 线路可用性取决于用户所处网络，写死的顺序对一部分用户必然是最差顺序：
  /// 列表型源的首条代理实测要 11 秒才响应，而同一条直连在另一些网络直接 403。
  /// 因此按「能取到清单 + 响应快」实测排序，取不到清单的线路沉到最后兜底。
  Future<List<int>?> _routeOrder(
    LiveSource source,
    String sample,
    Map<String, String> headers,
  ) async {
    if (source.proxies.isEmpty || sample.isEmpty) return null;
    final cached = _fresh(_routeOrders, source.id, _routeOrderTtl);
    if (cached != null) return cached;
    final inflight = _routeOrderInflight[source.id];
    if (inflight != null) return inflight;
    final future = _probeRouteOrder(source, sample, headers);
    _routeOrderInflight[source.id] = future;
    try {
      return await future;
    } finally {
      if (identical(_routeOrderInflight[source.id], future)) {
        _routeOrderInflight.remove(source.id);
      }
    }
  }

  Future<List<int>?> _probeRouteOrder(
    LiveSource source,
    String sample,
    Map<String, String> headers,
  ) async {
    final total = source.proxies.length + 1;
    final probes = await Future.wait<Duration?>([
      for (var index = 0; index < total; index++)
        _probeRoute(
          index == total - 1 ? sample : '${source.proxies[index]}$sample',
          headers,
          proxyResourceKey: socks5LiveResourceKey(source.id),
        ),
    ]);
    final order = List<int>.generate(total, (index) => index)
      ..sort((left, right) {
        final a = probes[left];
        final b = probes[right];
        if (a == null || b == null) {
          if (a == null && b == null) return left.compareTo(right);
          return a == null ? 1 : -1;
        }
        final compared = a.compareTo(b);
        return compared == 0 ? left.compareTo(right) : compared;
      });
    _routeOrders[source.id] = _Stamped(order, _now());
    return order;
  }

  /// 返回该线路取回播放清单的耗时，取不到返回 null。
  Future<Duration?> _probeRoute(
    String url,
    Map<String, String> headers, {
    String? proxyResourceKey,
  }) async {
    final watch = Stopwatch()..start();
    try {
      await _http
          .get(url, headers: headers, proxyResourceKey: proxyResourceKey)
          .timeout(liveRouteProbeTimeout);
      return watch.elapsed;
    } catch (_) {
      // 预检失败只影响排序，不应该让整个分类加载失败。
      return null;
    }
  }
}
