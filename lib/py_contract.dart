import 'dart:convert';

import 'models.dart';

class PyContract {
  PyContract._();

  static String _text(Object? value) => value?.toString() ?? '';

  static int _int(Object? value) =>
      value is num ? value.toInt() : int.tryParse('${value ?? ''}') ?? 0;

  static bool _parseFlag(Object? value) => value == true || _int(value) == 1;

  static Drama itemToDrama(String source, Map<String, dynamic> item) {
    final vodId = _text(item['vod_id']);
    final folder =
        _text(item['vod_tag']) == 'folder' ||
        _text(item['vod_tag']) == 'folder卡';
    return Drama(
      id: '$source:$vodId',
      source: source,
      sourceId: vodId,
      title: _text(item['vod_name']).isEmpty ? '未命名' : _text(item['vod_name']),
      description: _text(item['vod_remarks']),
      cover: _text(item['vod_pic']),
      kind: folder ? 'folder' : 'video',
      folderId: folder ? vodId : '',
    );
  }

  static List<Drama> itemsToDramas(String source, Object? raw) => [
    for (final row in raw as List? ?? const [])
      if (row is Map) itemToDrama(source, Map<String, dynamic>.from(row)),
  ];

  static List<CatalogCategory> categoriesFromHome(Map<String, dynamic> home) {
    return [
          CatalogCategory.all,
          for (final row in home['class'] as List? ?? const [])
            if (row is Map)
              CatalogCategory(
                _text(Map<String, dynamic>.from(row)['type_id']),
                _text(Map<String, dynamic>.from(row)['type_name']).isEmpty
                    ? _text(Map<String, dynamic>.from(row)['type_id'])
                    : _text(Map<String, dynamic>.from(row)['type_name']),
              ),
        ]
        .where((category) => category.id.isNotEmpty || category.name == '全部')
        .toList();
  }

  static Map<String, dynamic> filtersFromHome(Map<String, dynamic> home) {
    final raw = home['filters'];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const {};
  }

  static List<CatalogFilterGroup> filterGroupsForCategory(
    Map<String, dynamic> filters,
    String category,
  ) {
    final rows = <Object?>[];
    final direct = filters[category];
    if (direct is List) rows.addAll(direct);
    if (rows.isEmpty) {
      for (final key in const ['all', '']) {
        final fallback = filters[key];
        if (fallback is List) rows.addAll(fallback);
      }
    }
    final groups = <CatalogFilterGroup>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final group = Map<String, dynamic>.from(row);
      final key = _text(group['key']);
      if (key.isEmpty) continue;
      final options = <CatalogFilterOption>[];
      for (final option in group['value'] as List? ?? const []) {
        if (option is Map) {
          final parsed = Map<String, dynamic>.from(option);
          options.add(
            CatalogFilterOption(
              _text(parsed['v']),
              _text(parsed['n']).isEmpty
                  ? _text(parsed['v'])
                  : _text(parsed['n']),
            ),
          );
        }
      }
      groups.add(
        CatalogFilterGroup(
          key,
          _text(group['name']).isEmpty ? key : _text(group['name']),
          options,
        ),
      );
    }
    return groups;
  }

  static CatalogPage pageFromResult(
    String source,
    Map<String, dynamic> result, {
    int page = 1,
  }) {
    final current = _int(result['page']) > 0 ? _int(result['page']) : page;
    final pageCount = _int(result['pagecount']);
    final items = itemsToDramas(source, result['list']);
    return CatalogPage(items, hasMore: pageCount > current, page: current);
  }

  static DramaDetail detailFromResult(
    String source,
    Drama base,
    Map<String, dynamic> result,
  ) {
    final rows = result['list'] as List? ?? const [];
    if (rows.isEmpty || rows.first is! Map) {
      return DramaDetail(base, const [], warning: '该站未返回详情');
    }
    final item = Map<String, dynamic>.from(rows.first as Map);
    final fromRaw = _text(item['vod_play_from']);
    final urlRaw = _text(item['vod_play_url']);
    final froms = fromRaw.isEmpty ? ['默认'] : fromRaw.split('\$\$\$');
    final groups = urlRaw.isEmpty ? <String>[] : urlRaw.split('\$\$\$');
    final episodes = <Episode>[];
    for (var g = 0; g < groups.length; g++) {
      final flag = g < froms.length ? froms[g] : '线路${g + 1}';
      for (final segment in groups[g].split('#')) {
        final trimmed = segment.trim();
        if (trimmed.isEmpty) continue;
        final at = trimmed.indexOf('\$');
        final name = at > 0
            ? trimmed.substring(0, at)
            : '第${episodes.length + 1}集';
        final playId = at > 0 ? trimmed.substring(at + 1) : trimmed;
        if (playId.isEmpty) continue;
        episodes.add(
          Episode({
            'id': playId,
            'title': name,
            'flag': flag,
          }, episodes.length + 1),
        );
      }
    }
    final content = _text(item['vod_content']);
    final actor = _text(item['vod_actor']);
    final drama = Drama(
      id: base.id,
      source: source,
      sourceId: _text(item['vod_id']).isEmpty
          ? base.sourceId
          : _text(item['vod_id']),
      title: _text(item['vod_name']).isEmpty
          ? base.title
          : _text(item['vod_name']),
      description: actor.isEmpty
          ? content
          : [if (content.isNotEmpty) content, '演员：$actor'].join('\n'),
      cover: _text(item['vod_pic']).isEmpty
          ? base.cover
          : _text(item['vod_pic']),
      episodes: episodes.length,
      category: _text(item['vod_class']),
      onlineDate: _text(item['vod_year']),
    );
    return DramaDetail(
      drama,
      episodes,
      warning: episodes.isEmpty ? '该站详情未提供播放地址' : '',
    );
  }

  static PlaybackPlan planFromResult(Map<String, dynamic> result) {
    final headers = <String, String>{};
    final rawHeaders = result['header'];
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
    } else if (rawHeaders is List) {
      for (final row in rawHeaders) {
        if (row is List && row.length >= 2) {
          headers[row[0].toString()] = row[1].toString();
        } else if (row is Map) {
          final parsed = Map<String, dynamic>.from(row);
          final key = parsed['key'] ?? parsed['name'];
          final value = parsed['value'];
          if (key != null && value != null) {
            headers[key.toString()] = value.toString();
          }
        }
      }
    }
    final needsParse = _parseFlag(result['parse']) || _parseFlag(result['jx']);
    var url = _text(result['url']);
    if (url.isEmpty) url = _text(result['playUrl']);
    return PlaybackPlan(url: url, headers: headers, needsParse: needsParse);
  }
}
