import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ParseInterface {
  const ParseInterface({
    required this.id,
    required this.name,
    required this.url,
    this.source = '',
    this.enabled = true,
  });

  final String id;
  final String name;

  /// 解析接口前缀模板：可含 `{url}` 占位符；不含时按 TVBox 惯例把原始
  /// 播放页地址直接拼在模板之后。
  final String url;

  final String source;

  final bool enabled;

  factory ParseInterface.fromJson(Map<String, dynamic> json) => ParseInterface(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    url: json['url'] as String? ?? '',
    source: json['source'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    if (source.isNotEmpty) 'source': source,
    'enabled': enabled,
  };

  String apply(String rawUrl) {
    if (url.contains('{url}')) {
      return url.replaceAll('{url}', Uri.encodeComponent(rawUrl));
    }
    return '$url$rawUrl';
  }
}

class ParseInterfaceStore {
  static const _listKey = 'parse_interfaces';
  static const _selectedKey = 'parse_interface_selected';

  static Future<List<ParseInterface>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_listKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final rows = jsonDecode(raw) as List;
      return [
        for (final row in rows)
          if (row is Map)
            ParseInterface.fromJson(Map<String, dynamic>.from(row)),
      ].where((item) => item.url.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(List<ParseInterface> items) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _listKey,
      jsonEncode([for (final item in items) item.toJson()]),
    );
  }

  static Future<List<ParseInterface>> loadEnabled() async {
    final items = await load();
    return [
      for (final item in items)
        if (item.enabled) item,
    ];
  }

  static Future<String> loadSelectedId() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_selectedKey) ?? '';
  }

  static Future<void> saveSelectedId(String id) async {
    final preferences = await SharedPreferences.getInstance();
    if (id.isEmpty) {
      await preferences.remove(_selectedKey);
    } else {
      await preferences.setString(_selectedKey, id);
    }
  }

  static Future<ParseInterface?> loadSelected() async {
    final selectedId = await loadSelectedId();
    if (selectedId.isEmpty) return null;
    for (final item in await load()) {
      if (item.id == selectedId) return item;
    }
    return null;
  }
}

final _mediaExtensionPattern = RegExp(
  r'\.(m3u8|mpd|mp4|m4v|mov|flv|mkv|webm|avi|rmvb|m4s|ts|mp3|m4a|aac|flac|wav|ogg)(\?|#|$)',
  caseSensitive: false,
);

bool looksLikeDirectMedia(String url) {
  final uri = Uri.tryParse(url);
  if (uri != null &&
      (uri.host == '127.0.0.1' ||
          uri.host == 'localhost' ||
          uri.host == '::1')) {
    return true;
  }
  return _mediaExtensionPattern.hasMatch(url.split('#').first);
}

bool looksLikeWebPage(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  return !looksLikeDirectMedia(url);
}

String? applySelectedParse({
  required String url,
  required bool needsParse,
  required ParseInterface? selected,
}) {
  if (selected == null || url.isEmpty) return null;
  if (!needsParse && !looksLikeWebPage(url)) return null;
  return selected.apply(url);
}
