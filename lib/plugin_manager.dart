import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'builtin_py_sites.dart';
import 'build_variant.dart';
import 'jar_bridge.dart';
import 'jar_import.dart';
import 'jar_zip.dart';
import 'models.dart';
import 'plugin_icons.dart';
import 'zakatv_builtin.dart';

/// 内置插件清单与安装状态。清单是代码内 const 表，不新增 asset 文件。
///
/// 插件粒度（用户 2026-11-14 纠正：不拆 jar）：
/// - jar 插件 1 个：整个 zakatv.jar，安装即注册全部 148 个站点配置
///   （147 个可见站点 + 1 个纯音频配置），卸载即整个一起撤掉；
/// - py 插件 44 个：一个 py 文件一个插件（jinguo.py 一文件两站，同装同卸）。
///
/// 安装状态只记“用户卸载的内置插件 id 列表”：缺省全部已安装，
/// 首次启动行为与插件化之前一致。
class PluginManager {
  PluginManager._();

  /// 内置 jar 插件 id。
  static const String jarPluginId = 'jar:zakatv';

  /// 卸载列表的 SharedPreferences 键。
  static const String uninstalledPrefsKey = 'moyi_plugin_uninstalled';

  /// 远程插件索引地址的 SharedPreferences 键，默认空。
  static const String marketUrlPrefsKey = 'moyi_plugin_market_url';

  /// py 文件的插件 id：`py:<文件名去后缀>`。
  static String pyPluginIdForAsset(String assetPath) {
    final base = assetPath.split('/').last;
    final name = base.endsWith('.py')
        ? base.substring(0, base.length - 3)
        : base;
    return 'py:$name';
  }

  static Set<String> _uninstalledFrom(SharedPreferences preferences) {
    return preferences.getStringList(uninstalledPrefsKey)?.toSet() ?? {};
  }

  static Future<Set<String>> _loadUninstalled() async {
    final preferences = await SharedPreferences.getInstance();
    return _uninstalledFrom(preferences);
  }

  static Future<void> _storeUninstalled(
    SharedPreferences preferences,
    Set<String> uninstalled,
  ) async {
    await preferences.setStringList(
      uninstalledPrefsKey,
      uninstalled.toList()..sort(),
    );
  }

  /// 全部内置插件清单：jar 插件在首位，其后是 py 插件（今天的注册顺序）。
  /// 空壳版无内置插件（构建时已去掉捆绑 asset），返回空清单。
  static List<BuiltinPluginInfo> builtinPlugins() {
    if (emptyShellBuild) return const [];
    final plugins = <BuiltinPluginInfo>[
      BuiltinPluginInfo(
        id: jarPluginId,
        name: 'ZakaTV 内置 jar',
        kind: PluginIconKind.jar,
        siteIds: [
          for (final config in zakatvBuiltinSites)
            if (!config.audioOnly)
              JarSiteSpec.siteIdFor(zakatvJarId, config.key),
        ],
        detail: '内置 jar · ${zakatvBuiltinSites.length} 个站点配置',
        md5: zakatvJarMd5,
      ),
    ];
    final grouped = <String, List<BuiltinPyEntry>>{};
    for (final entry in BuiltinPySites.entries) {
      (grouped[pyPluginIdForAsset(entry.assetPath)] ??= []).add(entry);
    }
    for (final group in grouped.values) {
      final first = group.first;
      final fileName = first.assetPath.split('/').last;
      plugins.add(
        BuiltinPluginInfo(
          id: pyPluginIdForAsset(first.assetPath),
          name: group.length > 1
              ? '${first.site.name} 等 ${group.length} 站'
              : first.site.name,
          kind: PluginIconKind.py,
          siteIds: [for (final entry in group) entry.siteId],
          detail: '内置 py · $fileName',
        ),
      );
    }
    return plugins;
  }

  /// 首次启动（及每次启动）：装好全部未被用户卸载的内置插件。
  /// 空壳版不自动装（无捆绑插件可装），直接返回。
  static Future<void> ensureBuiltinPlugins(
    SharedPreferences preferences,
  ) async {
    if (emptyShellBuild) return;
    final uninstalled = _uninstalledFrom(preferences);
    if (!uninstalled.contains(jarPluginId)) {
      await JarImport.registerBuiltinZakatv();
    }
    final skipSiteIds = <String>{};
    for (final entry in BuiltinPySites.entries) {
      if (uninstalled.contains(pyPluginIdForAsset(entry.assetPath))) {
        skipSiteIds.add(entry.siteId);
      }
    }
    await BuiltinPySites.registerSkipping(skipSiteIds);
  }

  /// 安装一个内置插件（重装被卸载的插件）。失败时不改卸载状态。
  /// 空壳版无内置插件可装，直接失败。
  static Future<bool> installBuiltinPlugin(String pluginId) async {
    if (emptyShellBuild) return false;
    final preferences = await SharedPreferences.getInstance();
    if (pluginId == jarPluginId) {
      final ok = await JarImport.registerBuiltinZakatv();
      if (!ok) return false;
    } else {
      final entries = BuiltinPySites.entries
          .where((e) => pyPluginIdForAsset(e.assetPath) == pluginId)
          .toList();
      if (entries.isEmpty) return false;
      var ok = true;
      for (final entry in entries) {
        ok = await BuiltinPySites.installEntry(entry.siteId) && ok;
      }
      if (!ok) return false;
    }
    final uninstalled = _uninstalledFrom(preferences);
    if (uninstalled.remove(pluginId)) {
      await _storeUninstalled(preferences, uninstalled);
    }
    return true;
  }

  /// 卸载一个内置插件：撤登记 + 记入卸载列表，下次启动不再自动装。
  static Future<void> uninstallBuiltinPlugin(String pluginId) async {
    final preferences = await SharedPreferences.getInstance();
    if (pluginId == jarPluginId) {
      JarImport.unregisterBuiltinZakatv();
    } else {
      for (final entry in BuiltinPySites.entries) {
        if (pyPluginIdForAsset(entry.assetPath) == pluginId) {
          await BuiltinPySites.uninstallEntry(entry.siteId);
        }
      }
    }
    final uninstalled = _uninstalledFrom(preferences);
    if (uninstalled.add(pluginId)) {
      await _storeUninstalled(preferences, uninstalled);
    }
  }

  static Future<bool> isBuiltinPluginUninstalled(String pluginId) async {
    return (await _loadUninstalled()).contains(pluginId);
  }

  /// 站点行图标：jar 桥注册的站用咖啡杯，py 文件站用爬虫，
  /// 其余（Go 核/配置/自定义）返回 null，调用方用默认图标。
  /// 站点模型今天没有自有图标字段；将来有了，优先用自有图标。
  static Widget? pluginIconForSource(SourceSite site, {double size = 20}) {
    if (JarBridge.isJarSource(site.id)) {
      return PluginTypeIcon(kind: PluginIconKind.jar, size: size);
    }
    if (SourceSite.importedPyFiles.containsKey(site.id)) {
      return PluginTypeIcon(kind: PluginIconKind.py, size: size);
    }
    return null;
  }

  static Future<String> loadMarketUrl() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(marketUrlPrefsKey) ?? '';
  }

  static Future<void> saveMarketUrl(String url) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(marketUrlPrefsKey, url.trim());
  }
}

class BuiltinPluginInfo {
  const BuiltinPluginInfo({
    required this.id,
    required this.name,
    required this.kind,
    required this.siteIds,
    this.detail = '',
    this.md5,
  });

  final String id;
  final String name;
  final PluginIconKind kind;

  /// 该插件注册的站点 id（jar 插件不含 audioOnly 的纯音频配置）。
  final List<String> siteIds;
  final String detail;

  /// jar 插件的指纹：安装时以此 md5 校验（JarBridge.ensureJar 的 md5 门）。
  final String? md5;

  int get siteCount => siteIds.length;
}

/// 远程插件索引里的一条。格式见 ~/workspace/moyi_jar_plugins/INVENTORY.md 第 6 节。
class RemotePluginItem {
  const RemotePluginItem({
    required this.key,
    required this.name,
    required this.type,
    this.version = '',
    required this.url,
    this.md5,
    this.icon = '',
    this.description = '',
    this.author = '',
  });

  factory RemotePluginItem.fromJson(Map<String, dynamic> json) {
    return RemotePluginItem(
      key: (json['key'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      type: (json['type'] ?? '').toString(),
      version: (json['version'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      md5: (json['md5'] as String?)?.toLowerCase(),
      icon: (json['icon'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      author: (json['author'] ?? '').toString(),
    );
  }

  final String key;
  final String name;

  /// `jar` 或 `py`。
  final String type;
  final String version;
  final String url;
  final String? md5;
  final String icon;
  final String description;
  final String author;

  bool get isValid =>
      key.isNotEmpty &&
      name.isNotEmpty &&
      url.isNotEmpty &&
      (type == 'jar' || type == 'py');

  PluginIconKind get kind =>
      type == 'jar' ? PluginIconKind.jar : PluginIconKind.py;
}

/// 解析远程插件索引 JSON：顶层须为 Map，`plugins` 须为 List，
/// 不合格的条目跳过（照小程序市场的 parseMiniAppMarketJson）。
List<RemotePluginItem> parsePluginMarketJson(String raw) {
  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const [];
  }
  if (decoded is! Map<String, dynamic>) return const [];
  final plugins = decoded['plugins'];
  if (plugins is! List) return const [];
  final items = <RemotePluginItem>[];
  for (final entry in plugins) {
    if (entry is Map<String, dynamic>) {
      final item = RemotePluginItem.fromJson(entry);
      if (item.isValid) items.add(item);
    }
  }
  return items;
}

/// 拉取远程插件索引（照小程序市场的 _loadMarket：GET + 30 秒超时）。
Future<List<RemotePluginItem>> fetchPluginMarket(String url) async {
  final response = await http
      .get(Uri.parse(url))
      .timeout(const Duration(seconds: 30));
  if (response.statusCode != 200) {
    throw HttpException('HTTP ${response.statusCode}');
  }
  return parsePluginMarketJson(utf8.decode(response.bodyBytes));
}

/// zip 批量安装包里的一个插件文件。
class PluginZipEntry {
  const PluginZipEntry({required this.name, required this.bytes});

  /// 显示名：同名文件重名时用包内完整路径区分，平时用文件名。
  final String name;
  final List<int> bytes;

  bool get isJar => name.toLowerCase().endsWith('.jar');
  bool get isPy => name.toLowerCase().endsWith('.py');
}

/// 展开 zip 批量安装包：只取 .jar/.py 文件，跳过目录、隐藏文件与
/// __MACOSX__；非 zip 字节抛错（调用方报安装失败）。
/// 批量安装不产生“成组绑定”：展开后每个文件独立安装、独立卸载。
List<PluginZipEntry> expandPluginZip(List<int> bytes) {
  if (!isZipBytes(bytes)) {
    throw const FormatException('不是有效的 zip 包（缺少 zip 文件头）');
  }
  final archive = ZipDecoder().decodeBytes(bytes);
  final byBase = <String, List<ArchiveFile>>{};
  for (final file in archive.files) {
    if (!file.isFile) continue;
    if (file.name.contains('__MACOSX__')) continue;
    final lower = file.name.toLowerCase();
    if (!lower.endsWith('.jar') && !lower.endsWith('.py')) continue;
    final base = file.name.split('/').last;
    if (base.isEmpty || base.startsWith('.')) continue;
    (byBase[base] ??= []).add(file);
  }
  final entries = <PluginZipEntry>[];
  for (final group in byBase.values) {
    for (final file in group) {
      entries.add(
        PluginZipEntry(
          name: group.length > 1 ? file.name : file.name.split('/').last,
          bytes: List<int>.from(file.content as List<int>),
        ),
      );
    }
  }
  entries.sort((a, b) => a.name.compareTo(b.name));
  return entries;
}
