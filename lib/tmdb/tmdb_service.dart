import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'tmdb_config.dart';
import 'tmdb_metadata.dart';

class TmdbConnectionException implements Exception {
  const TmdbConnectionException(this.message);

  final String message;

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
    if (!effectiveConfig.configured) return null;
    final store = prefs ?? await _prefsProvider();
    final cached = await _readCache(store, cacheId);
    if (cached != null) {
      if (cached.payload == null) return null;
      return TmdbMetadata.fromJson(cached.payload!);
    }
    final query = baseTitleForSearch(title);
    if (query.isEmpty) return null;
    final search = await _getJson(effectiveConfig.searchMultiUri(query));
    final results = search['results'] as List<dynamic>? ?? const <dynamic>[];
    final best = _pickBest(
      results,
      title: query,
      year: year,
      typeHint: typeHint,
    );
    if (best == null) {
      await _writeCache(store, cacheId, null, negativeTtl);
      return null;
    }
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
    await _writeCache(store, cacheId, meta.toJson(), positiveTtl);
    return meta;
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
      throw const TmdbConnectionException('API Key 无效，请检查后重试');
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
