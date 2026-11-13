// 移植自 NexHub（https://github.com/nexhub-app/NexHub，提交 37ddbdd，Apache-2.0）。
// 原始路径：lib/core/network/source_network_override_store.dart。
// 移植状态：改编——魔蚁无 Hive 依赖，持久化层由 Hive box 改为 SharedPreferences
// （键 `source_network_override_<sourceId>`，值=覆盖 JSON 字符串）；对外 API 与
// 合并语义与原文一致。
/// 源级网络覆盖存储：用户对某个源的网络配置覆盖，持久化到 SharedPreferences。
///
/// key=sourceId，值=覆盖 JSON 字符串。使内置源无需改 asset 也能被用户覆盖。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'model/source_network_config.dart';

/// 源级网络覆盖存储（进程内单例）。
class SourceNetworkOverrideStore {
  SourceNetworkOverrideStore._();
  static final SourceNetworkOverrideStore instance =
      SourceNetworkOverrideStore._();

  /// 持久化键前缀（后接 sourceId）。
  static const String keyPrefix = 'source_network_override_';

  final Map<String, SourceNetworkConfig> _cache =
      <String, SourceNetworkConfig>{};
  bool _loaded = false;

  /// 从 SharedPreferences 加载持久化覆盖。
  Future<void> init() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(keyPrefix)) continue;
        final val = prefs.getString(key);
        if (val == null || val.isEmpty) continue;
        final sourceId = key.substring(keyPrefix.length);
        try {
          _cache[sourceId] = SourceNetworkConfig.fromJson(
            jsonDecode(val) as Map<String, dynamic>,
          );
        } on Object catch (e) {
          debugPrint('SourceNetworkOverrideStore load($sourceId) failed: $e');
        }
      }
    } on Object catch (e) {
      debugPrint('SourceNetworkOverrideStore init failed: $e');
    }
    _loaded = true;
  }

  /// 取某源的用户覆盖（无则返回 null）。
  SourceNetworkConfig? get(String sourceId) => _cache[sourceId];

  /// 设置某源的覆盖并持久化。空覆盖等价于删除。
  Future<void> set(String sourceId, SourceNetworkConfig? config) async {
    if (config == null || config.isEmpty) {
      return remove(sourceId);
    }
    _cache[sourceId] = config;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$keyPrefix$sourceId',
      jsonEncode(config.toJson()),
    );
  }

  /// 删除某源的覆盖。
  Future<void> remove(String sourceId) async {
    _cache.remove(sourceId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$keyPrefix$sourceId');
  }
}
