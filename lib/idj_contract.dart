import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart' show AppFailure;
import 'models.dart';

/// iDuanJu 插件返回形状 → 魔蚁站点形状的翻译（与 [PyContract] 并列）。
///
/// 插件返回的是 idj1 形状：`home()` 给 `{categories, items, hasMore}`，
/// `category` / `search` 给 `{items, hasMore}`，`detail` 给
/// `{id, title, cover, desc, duration, tags, lines}`，`play` 给
/// `{streams: [{url, format, headers, name}], expiresAt}`，可选带
/// `drm: {key, type, header}`（结果级或流级，流级优先）——带上时
/// 解析进 [PlaybackPlan.drm]，播放器路由据此强制走 EXO 核。
/// 本文件只做形状翻译，不跑 JS、不联网、不改 [PyContract]。
class IdjContract {
  IdjContract._();

  static const int maxTitleLength = 200;
  static const int maxDescriptionLength = 4000;
  static const int maxItems = 500;
  static const int maxChapters = 5000;
  static const int maxStreams = 12;

  static String _text(Object? value) => value?.toString() ?? '';

  static String _truncate(String value, int max) {
    if (value.length <= max) return value;
    debugPrint('idj contract: 文本超长已截断（$max 字）');
    return value.substring(0, max);
  }

  static int _int(Object? value) =>
      value is num ? value.toInt() : int.tryParse('${value ?? ''}') ?? 0;

  static List<String> _stringList(Object? value) => [
    for (final row in value as List? ?? const [])
      if (row != null && row.toString().isNotEmpty) row.toString(),
  ];

  /// `home()` → 分类列表：读 `home['categories']`（`[{id, name}]`），
  /// 前置「全部」（id `''`）。`home` 里没有 `categories` 时只回「全部」，
  /// 不编默认分类。
  static List<CatalogCategory> categoriesFromHome(Map<String, dynamic> home) {
    final categories = <CatalogCategory>[CatalogCategory.all];
    for (final row in home['categories'] as List? ?? const []) {
      if (row is! Map) continue;
      final parsed = Map<String, dynamic>.from(row);
      final id = _text(parsed['id']);
      if (id.isEmpty) continue;
      final name = _text(parsed['name']);
      categories.add(
        CatalogCategory(
          id,
          name.isEmpty ? id : _truncate(name, maxTitleLength),
        ),
      );
    }
    return categories;
  }

  static Drama _itemToDrama(String source, Map<String, dynamic> item) {
    final vodId = _text(item['id']);
    final title = _text(item['title']);
    final remarks = _text(item['remarks']);
    final duration = _text(item['duration']);
    // 备注本身就是展示文案（橙果的备注就是“N集”，2048 的备注是
    // “分类名 · 时长”）；备注为空时才用 duration 顶上，不拼两份。
    final description = remarks.isNotEmpty ? remarks : duration;
    return Drama(
      id: '$source:$vodId',
      source: source,
      sourceId: vodId,
      title: _truncate(title.isEmpty ? '未命名' : title, maxTitleLength),
      description: _truncate(description, maxDescriptionLength),
      cover: _text(item['cover']),
      tags: _stringList(item['tags']),
    );
  }

  /// `{items, hasMore}` → [CatalogPage]：`hasMore` 为真表示还有下一页
  ///（调用方以 `page + 1` 续拉）；插件不回 `page` 字段，不补编页码。
  /// 列表超过 500 条时截断并记日志，不抛错。
  static CatalogPage pageFromResult(
    String source,
    Map<String, dynamic> result, {
    int page = 1,
  }) {
    final rows = result['items'] as List? ?? const [];
    if (rows.length > maxItems) {
      debugPrint('idj contract: 列表 ${rows.length} 条超上限，已截断到 $maxItems 条');
    }
    final items = <Drama>[];
    for (final row in rows.take(maxItems)) {
      if (row is! Map) continue;
      items.add(_itemToDrama(source, Map<String, dynamic>.from(row)));
    }
    return CatalogPage(
      items,
      hasMore: result['hasMore'] == true,
      page: page > 0 ? page : 1,
    );
  }

  /// 插件详情 → [DramaDetail]：`lines[i].name` 是线路显示名，只进
  /// [Episode.raw] 的 `flag` 供展示；`episodes[j].id` 是分集键，
  /// `episodes[j].name` 是集标题。`line` 字段是显示名，不可当键用。
  /// 分集超过 5000 集时截断并记日志，不抛错。
  static DramaDetail detailFromResult(
    String source,
    Drama base,
    Map<String, dynamic> result,
  ) {
    final lines = result['lines'] as List? ?? const [];
    final episodes = <Episode>[];
    var truncated = false;
    for (final lineRow in lines) {
      if (lineRow is! Map) continue;
      final line = Map<String, dynamic>.from(lineRow);
      final flag = _text(line['name']);
      for (final episodeRow in line['episodes'] as List? ?? const []) {
        if (episodes.length >= maxChapters) {
          truncated = true;
          break;
        }
        if (episodeRow is! Map) continue;
        final episode = Map<String, dynamic>.from(episodeRow);
        final playId = _text(episode['id']);
        if (playId.isEmpty) continue;
        episodes.add(
          Episode({
            'id': playId,
            'title': _text(episode['name']).isEmpty
                ? '第${episodes.length + 1}集'
                : _text(episode['name']),
            'flag': flag,
          }, episodes.length + 1),
        );
      }
      if (truncated) break;
    }
    if (truncated) {
      debugPrint('idj contract: 分集超上限，已截断到 $maxChapters 集');
    }
    final title = _text(result['title']);
    final desc = _text(result['desc']);
    final cover = _text(result['cover']);
    final drama = Drama(
      id: base.id,
      source: source,
      sourceId: _text(result['id']).isEmpty
          ? base.sourceId
          : _text(result['id']),
      title: _truncate(title.isEmpty ? base.title : title, maxTitleLength),
      description: _truncate(
        desc.isEmpty ? base.description : desc,
        maxDescriptionLength,
      ),
      cover: cover.isEmpty ? base.cover : cover,
      episodes: episodes.length,
    );
    return DramaDetail(
      drama,
      episodes,
      warning: episodes.isEmpty ? '该站详情未提供播放地址' : '',
      tags: [
        for (final tag in _stringList(result['tags']))
          DetailTag(id: tag, name: tag),
      ],
    );
  }

  /// `play()` 返回 → [PlaybackPlan]：只取 `streams[0]` 的 `url` +
  /// `headers`（`{User-Agent, Referer}` 透传），`expiresAt` 透传，
  /// `format: hls/mp4` → `needsParse: false`。
  /// DRM：结果级 `drm` 或命中流自带的 `drm`（流级优先）按 FongMi
  /// 形态 `{key, type, header}` 经 [PlaybackDrm.fromJson] 解析进
  /// 计划（header 认 Map 或 JSON 字符串；key/type 缺一即视为无 DRM，
  /// 不硬造、不抛错）。带有效 drm 的计划 `hasDrm` 为真，播放器
  /// 路由强制走 EXO（点播侧现成链，见 player_screen）；不带 drm
  /// 时计划与旧行为完全一致。
  /// 空 `streams`（或全部流都不合法）时抛
  /// [AppFailure]（'插件没有返回可播放地址'）。
  /// URL 形态校验：https、443 端口（不写端口或写 443 都行）、无 userinfo、
  /// 非 IP 字面量；不符的流丢弃并记日志。`media` 白名单不符只记日志、
  /// 不丢弃（播放器侧白名单是后续项）。
  static PlaybackPlan planFromResult(
    Map<String, dynamic> result, {
    List<String> mediaAllowlist = const [],
  }) {
    final streams = result['streams'] as List? ?? const [];
    if (streams.length > maxStreams) {
      debugPrint('idj contract: 播放流 ${streams.length} 条超上限，只取前 $maxStreams 条');
    }
    for (final streamRow in streams.take(maxStreams)) {
      if (streamRow is! Map) continue;
      final stream = Map<String, dynamic>.from(streamRow);
      final url = _text(stream['url']);
      if (url.isEmpty) continue;
      if (!_isPlayableUrl(url)) {
        debugPrint('idj contract: 丢弃不合法播放地址（形态校验未过）');
        continue;
      }
      if (mediaAllowlist.isNotEmpty &&
          !_matchesAllowlist(url, mediaAllowlist)) {
        debugPrint('idj contract: 播放地址不在 media 白名单内（只记日志、不丢弃）');
      }
      final headers = <String, String>{};
      final rawHeaders = stream['headers'];
      if (rawHeaders is Map) {
        for (final entry in rawHeaders.entries) {
          headers[entry.key.toString()] = entry.value.toString();
        }
      } else if (rawHeaders is String) {
        final trimmed = rawHeaders.trim();
        if (trimmed.startsWith('{')) {
          try {
            final decoded = jsonDecode(trimmed);
            if (decoded is Map) {
              for (final entry in decoded.entries) {
                headers[entry.key.toString()] = entry.value.toString();
              }
            }
          } catch (_) {}
        }
      }
      final drm =
          PlaybackDrm.fromJson(stream['drm']) ??
          PlaybackDrm.fromJson(result['drm']);
      return PlaybackPlan(
        url: url,
        headers: headers,
        needsParse: false,
        expiresAt: _int(result['expiresAt']),
        drm: drm,
      );
    }
    throw AppFailure('插件没有返回可播放地址');
  }

  static bool _isPlayableUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme != 'https') return false;
    if (uri.userInfo.isNotEmpty) return false;
    if (uri.hasPort && uri.port != 443) return false;
    final host = uri.host;
    if (host.isEmpty) return false;
    // 非 IP 字面量：IPv4 四段数字或冒号（IPv6）都算 IP 字面量。
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) return false;
    if (host.contains(':')) return false;
    return true;
  }

  /// media 白名单匹配：精确域名或 `*.example.com`（只匹配一层子域）。
  static bool _matchesAllowlist(String url, List<String> allowlist) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return false;
    for (final entry in allowlist) {
      final pattern = entry.trim().toLowerCase();
      if (pattern.isEmpty) continue;
      if (pattern.startsWith('*.')) {
        final suffix = pattern.substring(1); // '.example.com'
        if (host.toLowerCase().endsWith(suffix)) {
          final head = host.substring(0, host.length - suffix.length);
          if (head.isNotEmpty && !head.contains('.')) return true;
        }
      } else if (host.toLowerCase() == pattern) {
        return true;
      }
    }
    return false;
  }
}
