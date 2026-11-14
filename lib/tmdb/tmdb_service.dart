import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'tmdb_config.dart';
import 'tmdb_metadata.dart';

class TmdbConnectionException implements Exception {
  const TmdbConnectionException(this.message, {this.invalidKey = false});

  final String message;

  /// 是否 TMDB key 无效（401/403）：是则不回落到无 key 源，直接抛给
  /// 调用方（配置错误要让用户知道、去设置里修，不能静默掩盖）。
  final bool invalidKey;

  @override
  String toString() => message;
}

class _CacheEntry {
  const _CacheEntry({required this.expiresAtMs, this.payload});

  final int expiresAtMs;
  final Map<String, dynamic>? payload;

  bool get expired => DateTime.now().millisecondsSinceEpoch >= expiresAtMs;

  Map<String, dynamic> toJson() => {
    'expiresAtMs': expiresAtMs,
    'payload': payload,
  };

  factory _CacheEntry.fromJson(Map<String, dynamic> json) => _CacheEntry(
    expiresAtMs: parseTmdbNumber(json['expiresAtMs']) ?? 0,
    payload: json['payload'] as Map<String, dynamic>?,
  );
}

class TmdbService {
  TmdbService({
    http.Client? client,
    Future<SharedPreferences> Function()? prefsProvider,
  }) : _client = client ?? http.Client(),
       _prefsProvider = prefsProvider ?? SharedPreferences.getInstance;

  static final TmdbService instance = TmdbService();

  static const String cacheKey = 'moyi_tmdb_cache_v1';
  static const Duration positiveTtl = Duration(hours: 24);
  static const Duration negativeTtl = Duration(hours: 1);
  static const int maxCacheEntries = 100;
  static const Duration requestTimeout = Duration(seconds: 15);

  final http.Client _client;
  final Future<SharedPreferences> Function() _prefsProvider;
  final Map<String, Future<TmdbMetadata?>> _inFlight = {};

  String cacheId({required String title, String? year, String? typeHint}) {
    final season = seasonFromTitle(title);
    final base = baseTitleForSearch(title).toLowerCase();
    return '$base|${year ?? ''}|${typeHint ?? ''}|${season ?? ''}';
  }

  Future<TmdbMetadata?> fetchMetadata({
    required String title,
    String? year,
    String? typeHint,
    TmdbConfig? config,
    SharedPreferences? prefs,
  }) {
    final id = cacheId(title: title, year: year, typeHint: typeHint);
    final pending = _inFlight[id];
    if (pending != null) return pending;
    final task = _fetchMetadata(
      title: title,
      year: year,
      typeHint: typeHint,
      config: config,
      prefs: prefs,
      cacheId: id,
    );
    _inFlight[id] = task;
    return task.whenComplete(() => _inFlight.remove(id));
  }

  Future<TmdbMetadata?> _fetchMetadata({
    required String title,
    String? year,
    String? typeHint,
    TmdbConfig? config,
    SharedPreferences? prefs,
    required String cacheId,
  }) async {
    final effectiveConfig = config ?? await TmdbConfig.load(prefs);
    final store = prefs ?? await _prefsProvider();
    final cached = await _readCache(store, cacheId);
    if (cached != null) {
      if (cached.payload == null) return null;
      return TmdbMetadata.fromJson(cached.payload!);
    }
    final query = baseTitleForSearch(title);
    if (query.isEmpty) return null;
    // 刮削链（两档同走 TmdbMetadata 结构，共用同一份缓存）：
    // 填了 TMDB key 先走 TMDB（资料最全，含季/集/演员）；TMDB 无果
    // 或出错时回落到不要 key 的公开源；没填 key 时直接走不要 key
    // 的源，绝不静默跳过。只有 key 无效时不回落、直接抛错。
    TmdbMetadata? meta;
    if (effectiveConfig.configured) {
      try {
        meta = await _fetchTmdb(
          effectiveConfig,
          query,
          title: title,
          year: year,
          typeHint: typeHint,
        );
      } catch (e) {
        // key 无效直接抛（配置错误要让用户知道）；其它 TMDB 故障
        // （超时/断网/限流/脏数据）一律回落到无 key 源。
        if (e is TmdbConnectionException && e.invalidKey) rethrow;
        meta = null;
      }
    }
    meta ??= await _fetchKeyless(query, year: year, typeHint: typeHint);
    if (meta == null) {
      await _writeCache(store, cacheId, null, negativeTtl);
      return null;
    }
    await _writeCache(store, cacheId, meta.toJson(), positiveTtl);
    return meta;
  }

  /// TMDB 一档：搜索 → 选最优 → 详情 → 电视剧再取一季的集列表。
  /// 无果返回 null（由调用方决定是否回落、是否写负缓存）。
  Future<TmdbMetadata?> _fetchTmdb(
    TmdbConfig effectiveConfig,
    String query, {
    required String title,
    String? year,
    String? typeHint,
  }) async {
    final search = await _getJson(effectiveConfig.searchMultiUri(query));
    final results = search['results'] as List<dynamic>? ?? const <dynamic>[];
    final best = _pickBest(
      results,
      title: query,
      year: year,
      typeHint: typeHint,
    );
    if (best == null) return null;
    var meta = best;
    final detail = await _getJson(
      effectiveConfig.detailUri(meta.mediaType, meta.tmdbId),
    );
    meta = meta.withDetail(detail);
    if (meta.isTv) {
      final season = seasonFromTitle(title) ?? 1;
      if (meta.seasonCount == 0 || season <= meta.seasonCount) {
        try {
          final seasonJson = await _getJson(
            effectiveConfig.seasonUri(meta.tmdbId, season),
          );
          final episodes =
              seasonJson['episodes'] as List<dynamic>? ?? const <dynamic>[];
          meta = meta.withEpisodes([
            for (final row in episodes)
              if (row is Map<String, dynamic>) TmdbEpisode.fromJson(row),
          ]);
        } catch (_) {
          // 季详情拉不到不影响主资料，只是不出剧集预览。
        }
      }
    }
    return meta;
  }

  /// 不要 key 的一档：TVMaze（剧集）→ Bangumi（动画/三次元），
  /// 两家都是公开接口、实测通了才接进来（2026-11-14 实测记录见
  /// 回报；豆瓣从本机出口探不通、iTunes 返回 0 结果，均未接入）。
  /// 任何一家出错/无果都继续下一家，全无果返回 null。
  /// 电影类标题（typeHint == 'movie'）跳过 TVMaze——它只有剧集，
  /// 同名剧集的海报贴到电影上是张冠李戴；Bangumi 仍试（三次元
  /// 条目含电影，标题对上才认）。
  Future<TmdbMetadata?> _fetchKeyless(
    String query, {
    String? year,
    String? typeHint,
  }) async {
    if (typeHint != 'movie') {
      try {
        final fromTvMaze = await _fetchTvMaze(query, year: year);
        if (fromTvMaze != null) return fromTvMaze;
      } catch (_) {}
    }
    try {
      return await _fetchBangumi(query, year: year);
    } catch (_) {
      return null;
    }
  }

  Future<TmdbMetadata?> _fetchTvMaze(String query, {String? year}) async {
    final uri = Uri.parse(
      'https://api.tvmaze.com/search/shows',
    ).replace(queryParameters: {'q': query});
    final decoded = await _fetchJson(uri, 'TVMaze');
    if (decoded is! List) return null;
    TmdbMetadata? best;
    var bestScore = 0;
    for (final row in decoded) {
      if (row is! Map<String, dynamic>) continue;
      final show = row['show'];
      if (show is! Map<String, dynamic>) continue;
      final candidate = _tvMazeToMetadata(show);
      if (candidate.title.isEmpty) continue;
      if (year != null &&
          year.isNotEmpty &&
          candidate.year.isNotEmpty &&
          candidate.year != year) {
        continue;
      }
      final score = _matchScore(
        candidate.title,
        candidate.originalTitle,
        query,
      );
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return best;
  }

  TmdbMetadata _tvMazeToMetadata(Map<String, dynamic> show) {
    final image = show['image'];
    final imageMap = image is Map<String, dynamic>
        ? image
        : const <String, dynamic>{};
    final poster = _text(imageMap['original']).isNotEmpty
        ? _text(imageMap['original'])
        : _text(imageMap['medium']);
    final rating = show['rating'];
    final ratingMap = rating is Map<String, dynamic>
        ? rating
        : const <String, dynamic>{};
    return TmdbMetadata(
      tmdbId: 0,
      mediaType: 'tv',
      title: _text(show['name']),
      originalTitle: _text(show['name']),
      year: yearFromText(_text(show['premiered'])) ?? '',
      overview: _stripHtml(_text(show['summary'])),
      posterPath: poster,
      voteAverage: parseTmdbDouble(ratingMap['average']),
      runtime:
          parseTmdbNumber(show['runtime']) ??
          parseTmdbNumber(show['averageRuntime']) ??
          0,
    );
  }

  Future<TmdbMetadata?> _fetchBangumi(String query, {String? year}) async {
    final uri = Uri.parse(
      'https://api.bgm.tv/search/subject/${Uri.encodeComponent(query)}',
    ).replace(queryParameters: {'responseGroup': 'small', 'max_results': '5'});
    final decoded = await _fetchJson(uri, 'Bangumi');
    if (decoded is! Map<String, dynamic>) return null;
    final list = decoded['list'];
    if (list is! List) return null;
    TmdbMetadata? best;
    var bestScore = 0;
    for (final row in list) {
      if (row is! Map<String, dynamic>) continue;
      // 只认动画（2）与三次元（6）；书籍/音乐/游戏条目不认，
      // 避免把书/游戏的封面贴到视频上。type 缺失时放行（未知形态
      // 按标题匹配兜底）。
      final type = parseTmdbNumber(row['type']);
      if (type != null && type != 2 && type != 6) continue;
      final candidate = _bangumiToMetadata(row);
      if (candidate.title.isEmpty) continue;
      if (year != null &&
          year.isNotEmpty &&
          candidate.year.isNotEmpty &&
          candidate.year != year) {
        continue;
      }
      final score = _matchScore(
        candidate.title,
        candidate.originalTitle,
        query,
      );
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return best;
  }

  TmdbMetadata _bangumiToMetadata(Map<String, dynamic> row) {
    final images = row['images'];
    final imageMap = images is Map<String, dynamic>
        ? images
        : const <String, dynamic>{};
    final poster = _text(imageMap['large']).isNotEmpty
        ? _text(imageMap['large'])
        : _text(imageMap['common']).isNotEmpty
        ? _text(imageMap['common'])
        : _text(imageMap['medium']);
    final nameCn = _text(row['name_cn']);
    final name = _text(row['name']);
    return TmdbMetadata(
      tmdbId: 0,
      mediaType: 'tv',
      title: nameCn.isNotEmpty ? nameCn : name,
      originalTitle: name,
      year: yearFromText(_text(row['air_date'])) ?? '',
      overview: _text(row['summary']),
      posterPath: poster,
    );
  }

  /// 标题匹配分（与 TMDB 选最优同一口径）：全等 100、前缀 60、
  /// 包含 30、不相关 0；空标题不给分（空串是任何串的前缀/子串，
  /// 不设防会把无名条目误认成命中）。
  int _matchScore(String name, String original, String wantedRaw) {
    final wanted = _normalizeForMatch(wantedRaw);
    if (wanted.isEmpty) return 0;
    final variants = [
      _normalizeForMatch(name),
      _normalizeForMatch(original),
    ].where((value) => value.isNotEmpty).toList();
    if (variants.isEmpty) return 0;
    if (variants.any((value) => value == wanted)) return 100;
    if (variants.any(
      (value) => value.startsWith(wanted) || wanted.startsWith(value),
    )) {
      return 60;
    }
    if (variants.any(
      (value) => value.contains(wanted) || wanted.contains(value),
    )) {
      return 30;
    }
    return 0;
  }

  /// 去掉简介里的 HTML 标签与常见实体（TVMaze 的 summary 带 <p> 标签）。
  String _stripHtml(String value) {
    if (value.isEmpty) return '';
    var out = value.replaceAll(RegExp(r'<[^>]*>'), '');
    out = out
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
    return out.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _text(dynamic value) => value?.toString() ?? '';

  /// 通用 JSON 拉取（返回动态类型：TVMaze 返回数组、Bangumi 返回
  /// 对象，TMDB 专用的 [_getJson] 只认对象，两者不混用）。
  Future<dynamic> _fetchJson(Uri uri, String sourceLabel) async {
    http.Response response;
    try {
      response = await _client
          .get(uri, headers: const {'User-Agent': 'Moyi/1.0'})
          .timeout(requestTimeout);
    } on TimeoutException {
      throw TmdbConnectionException('$sourceLabel 连接超时，请检查网络');
    } on SocketException {
      throw TmdbConnectionException('$sourceLabel 连接失败，请检查网络');
    } on http.ClientException {
      throw TmdbConnectionException('$sourceLabel 连接失败，请检查网络');
    }
    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    }
    throw TmdbConnectionException(
      '$sourceLabel 请求失败（HTTP ${response.statusCode}）',
    );
  }

  Future<bool> testConnection(TmdbConfig config) async {
    if (!config.configured) {
      throw const TmdbConnectionException('请先填写 API Key');
    }
    await _getJson(config.configurationUri());
    return true;
  }

  TmdbMetadata? _pickBest(
    List<dynamic> results, {
    required String title,
    String? year,
    String? typeHint,
  }) {
    final wanted = _normalizeForMatch(title);
    if (wanted.isEmpty) return null;
    TmdbMetadata? best;
    var bestScore = 0;
    for (final row in results) {
      if (row is! Map<String, dynamic>) continue;
      final candidate = TmdbMetadata.fromSearchResult(row);
      if (candidate.tmdbId == 0) continue;
      if (candidate.mediaType != 'movie' && candidate.mediaType != 'tv') {
        continue;
      }
      if (year != null &&
          year.isNotEmpty &&
          candidate.year.isNotEmpty &&
          candidate.year != year) {
        continue;
      }
      final name = _normalizeForMatch(candidate.title);
      final original = _normalizeForMatch(candidate.originalTitle);
      var score = 0;
      if (name == wanted || original == wanted) {
        score = 100;
      } else if (name.startsWith(wanted) || wanted.startsWith(name)) {
        score = 60;
      } else if (name.contains(wanted) || wanted.contains(name)) {
        score = 30;
      } else {
        continue;
      }
      if (candidate.year.isNotEmpty && candidate.year == year) score += 20;
      if (typeHint != null && candidate.mediaType == typeHint) score += 10;
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return best;
  }

  String _normalizeForMatch(String value) {
    var cleaned = value.toLowerCase();
    cleaned = cleaned.replaceAll(
      RegExp('[\\s·:：,，。.!！？\\?\\-—_（）()\\[\\]【】]'),
      '',
    );
    return cleaned;
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    http.Response response;
    try {
      response = await _client.get(uri).timeout(requestTimeout);
    } on TimeoutException {
      throw const TmdbConnectionException('TMDB 连接超时，请检查网络');
    } on SocketException {
      throw const TmdbConnectionException('TMDB 连接失败，请检查网络');
    } on http.ClientException {
      throw const TmdbConnectionException('TMDB 连接失败，请检查网络');
    }
    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
      throw const TmdbConnectionException('TMDB 返回了无法识别的数据');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const TmdbConnectionException(
        'API Key 无效，请检查后重试',
        invalidKey: true,
      );
    }
    if (response.statusCode == 429) {
      throw const TmdbConnectionException('TMDB 请求太频繁，请稍后再试');
    }
    throw TmdbConnectionException('TMDB 请求失败（HTTP ${response.statusCode}）');
  }

  Future<_CacheEntry?> _readCache(SharedPreferences store, String id) async {
    try {
      final raw = store.getString(cacheKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final row = decoded[id];
      if (row is! Map<String, dynamic>) return null;
      final entry = _CacheEntry.fromJson(row);
      if (entry.expired) return null;
      return entry;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(
    SharedPreferences store,
    String id,
    Map<String, dynamic>? payload,
    Duration ttl,
  ) async {
    try {
      final raw = store.getString(cacheKey);
      final map = <String, dynamic>{};
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) map.addAll(decoded);
      }
      map[id] = _CacheEntry(
        expiresAtMs: DateTime.now().millisecondsSinceEpoch + ttl.inMilliseconds,
        payload: payload,
      ).toJson();
      while (map.length > maxCacheEntries) {
        map.remove(map.keys.first);
      }
      await store.setString(cacheKey, jsonEncode(map));
    } catch (_) {}
  }
}
