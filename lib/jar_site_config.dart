import 'dart:convert';

import 'package:flutter/services.dart';

import 'jar_bridge.dart';

const String builtinJarConfigsAsset = 'assets/jar_site_configs.json';

List<JarSiteConfig>? _builtinJarConfigsCache;

Future<List<JarSiteConfig>> loadBuiltinJarConfigs() async {
  final cached = _builtinJarConfigsCache;
  if (cached != null) return cached;
  try {
    final text = await rootBundle.loadString(builtinJarConfigsAsset);
    final configs = parseJarSiteConfigs(text);
    _builtinJarConfigsCache = configs;
    return configs;
  } catch (_) {
    _builtinJarConfigsCache = const [];
    return const [];
  }
}

class JarSiteConfig {
  const JarSiteConfig({
    required this.key,
    required this.name,
    required this.api,
    required this.ext,
  });

  final String key;
  final String name;
  final String api;
  final String ext;

  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'api': api,
    'ext': ext,
  };

  factory JarSiteConfig.fromJson(Map<String, dynamic> json) =>
      JarSiteConfig(
        key: json['key']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        api: json['api']?.toString() ?? '',
        ext: json['ext']?.toString() ?? '',
      );
}

List<JarSiteConfig> parseLearnedJarConfigs(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is! List) return const [];
    final configs = <JarSiteConfig>[];
    for (final entry in decoded) {
      if (entry is Map) {
        final config = JarSiteConfig.fromJson(
          Map<String, dynamic>.from(entry),
        );
        if (config.api.isNotEmpty || config.key.isNotEmpty) {
          configs.add(config);
        }
      }
    }
    return configs;
  } catch (_) {
    return const [];
  }
}

String _learnedKey(JarSiteConfig config) {
  if (config.api.isNotEmpty) return config.api;
  return config.key;
}

List<JarSiteConfig> upsertLearnedJarConfigs(
  List<JarSiteConfig> learned,
  List<JarSiteConfig> fresh,
) {
  final merged = [...learned];
  var changed = false;
  for (final config in fresh) {
    if (_learnedKey(config).isEmpty) continue;
    final index = merged.indexWhere(
      (item) => _learnedKey(item) == _learnedKey(config),
    );
    if (index < 0) {
      merged.add(config);
      changed = true;
    } else if (merged[index].key != config.key ||
        merged[index].name != config.name ||
        merged[index].ext != config.ext) {
      merged[index] = config;
      changed = true;
    }
  }
  if (!changed) return learned;
  return merged;
}

String _encodeExt(Object? ext) {
  if (ext == null) return '';
  if (ext is Map || ext is List) return jsonEncode(ext);
  return ext.toString().trim();
}

JarSiteConfig? _configOf(Map<String, dynamic> entry) {
  final key = entry['key']?.toString().trim() ?? '';
  final name = entry['name']?.toString().trim() ?? '';
  final api = entry['api']?.toString().trim() ?? '';
  if (key.isEmpty && name.isEmpty && api.isEmpty) return null;
  return JarSiteConfig(
    key: key,
    name: name,
    api: api,
    ext: _encodeExt(entry['ext']),
  );
}

List<JarSiteConfig> parseJarSiteConfigs(String text) {
  final dynamic decoded = jsonDecode(text);
  final configs = <JarSiteConfig>[];
  if (decoded is Map<String, dynamic>) {
    final sites = decoded['sites'];
    if (sites is List) {
      for (final entry in sites) {
        if (entry is Map) {
          final config = _configOf(Map<String, dynamic>.from(entry));
          if (config != null) configs.add(config);
        }
      }
      return configs;
    }
    final single = _configOf(decoded);
    if (single != null && single.api.isNotEmpty) configs.add(single);
    return configs;
  }
  if (decoded is List) {
    for (final entry in decoded) {
      if (entry is Map) {
        final config = _configOf(Map<String, dynamic>.from(entry));
        if (config != null) configs.add(config);
      }
    }
  }
  return configs;
}

bool looksLikeJarSiteConfig(String text) {
  try {
    return parseJarSiteConfigs(text).isNotEmpty;
  } catch (_) {
    return false;
  }
}

String _classNameOfApi(String api) {
  if (!api.startsWith('csp_') && api.contains('.')) return api;
  return JarSiteSpec.classNameForApi(api);
}

JarSiteConfig? matchJarSiteConfig(
  String className,
  List<JarSiteConfig> configs,
) {
  for (final config in configs) {
    if (config.api.isEmpty) continue;
    if (_classNameOfApi(config.api) == className) return config;
  }
  final simple = className.split('.').last;
  for (final config in configs) {
    if (config.key.isNotEmpty &&
        config.key.toLowerCase() == simple.toLowerCase()) {
      return config;
    }
  }
  return null;
}
