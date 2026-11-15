import 'dart:convert';

import 'package:archive/archive.dart';

import 'jar_site_config.dart';

/// jar 内插件清单的文件名：放在 jar 根目录或任意子目录下（按 basename 匹配）。
///
/// 清单格式（JSON）：
/// ```json
/// {
///   "name": "插件显示名",
///   "version": "1.0.0",
///   "sites": [
///     {"key": "mykey", "name": "我的站", "api": "csp_MySpider", "ext": "{}"}
///   ]
/// }
/// ```
/// 有清单的 jar 按清单注册站点（key/name/ext 取清单值）；没有清单或
/// 清单无效的 jar 走既有匹配（学习配置 → 内置配置 → 文件名推导）。
const String pluginManifestFileName = 'moyi-plugin.json';

class PluginManifest {
  const PluginManifest({
    this.name = '',
    this.version = '',
    required this.sites,
  });

  final String name;
  final String version;
  final List<JarSiteConfig> sites;
}

/// 解析清单 JSON：顶层须为 Map，`sites` 须为非空 List，每条须 key/api 非空。
/// 不合格返回 null（调用方走既有匹配）。
PluginManifest? parsePluginManifest(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final sitesRaw = decoded['sites'];
    if (sitesRaw is! List) return null;
    final sites = <JarSiteConfig>[];
    for (final entry in sitesRaw) {
      if (entry is Map<String, dynamic>) {
        final config = JarSiteConfig.fromJson(entry);
        if (config.key.isNotEmpty && config.api.isNotEmpty) {
          sites.add(config);
        }
      }
    }
    if (sites.isEmpty) return null;
    return PluginManifest(
      name: (decoded['name'] ?? '').toString(),
      version: (decoded['version'] ?? '').toString(),
      sites: sites,
    );
  } catch (_) {
    return null;
  }
}

/// 从 jar 字节里找清单，返回其站点配置；没有清单或清单无效返回空。
List<JarSiteConfig> extractJarManifestConfigs(List<int> jarBytes) {
  try {
    final archive = ZipDecoder().decodeBytes(jarBytes);
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (file.name.split('/').last != pluginManifestFileName) continue;
      final manifest = parsePluginManifest(
        utf8.decode(file.content as List<int>, allowMalformed: true),
      );
      return manifest?.sites ?? const [];
    }
  } catch (_) {}
  return const [];
}
