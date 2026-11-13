// 移植自 NexHub（https://github.com/nexhub-app/NexHub，提交 37ddbdd，Apache-2.0）。
// 原始路径：lib/core/scraper/cookie_store.dart。
// 移植状态：改编——魔蚁无 Hive 依赖，持久化层由 Hive box 改为 SharedPreferences
// （单键 JSON：host -> {cookie, ua, updatedAt}）；对外 API、记录结构、7 天 TTL
// 语义与原文一致。调用方注意：本类目前是独立服务，未接入任何抓取链路。
/// 持久化 Cookie 存储：把各 host 的会话 Cookie（含该 host 当时使用的 UA）落盘，
/// 避免「每次冷启动都重新过验证」导致高频请求 → IP 被封。
///
/// 反爬会话通常绑定 UA+IP+Cookie，故持久化时一并存 UA，回灌时若 UA 漂移会失效，
/// 上层应保证全链路 UA 一致。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 各 host 会话 Cookie 的持久化层（SharedPreferences 单键 JSON）。
///
/// 每条记录结构：cookie 头字符串、当时的 UA、ISO8601 时间戳。
/// 记录超过 [ttl] 视为无效（避免长期陈旧会话）。
class CookieStore {
  static const String _prefsKey = 'nexhub_http_cookies_v1';

  /// Cookie 有效期：超过 7 天未更新的会话视为失效，重新过验证。
  static const Duration ttl = Duration(days: 7);

  static Map<String, Map<String, String>>? _cache;

  /// 初始化（加载落盘记录到内存；幂等）。
  static Future<void> init() async {
    if (_cache != null) return;
    _cache = <String, Map<String, String>>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final value = entry.value;
            if (value is Map) {
              _cache![entry.key.toString()] = Map<String, String>.from(
                value.map(
                  (key, val) => MapEntry(key.toString(), val.toString()),
                ),
              );
            }
          }
        }
      }
    } catch (_) {
      _cache = <String, Map<String, String>>{};
    }
  }

  static Future<void> _ensureOpen() async {
    if (_cache == null) {
      await init();
    }
  }

  static Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_cache ?? {}));
  }

  static bool _isExpired(Map<String, String> rec) {
    final ts = rec['updatedAt'];
    if (ts == null) return true;
    final dt = DateTime.tryParse(ts);
    if (dt == null) return true;
    return DateTime.now().difference(dt) > ttl;
  }

  /// 读取所有未过期的 `host -> cookie 头`，供抓取层回填内存 jar。
  static Future<Map<String, String>> load() async {
    await _ensureOpen();
    final out = <String, String>{};
    for (final entry in (_cache ?? {}).entries) {
      final rec = entry.value;
      if (!_isExpired(rec)) {
        final cookie = rec['cookie'];
        if (cookie != null && cookie.isNotEmpty) {
          out[entry.key] = cookie;
        }
      }
    }
    return out;
  }

  /// 读取所有未过期记录（`host -> {cookie, ua, updatedAt}`）。
  ///
  /// 与 [load] 的区别：保留记录里的 `ua`。反爬会话（cf_clearance / turnstile
  /// 通过态）绑定验证时的 UA，冷启动回灌时若只恢复 Cookie 而把 UA 换成随机指纹
  /// 档案，落盘的会话立即失效 → 又要重新验证。故回灌需同时恢复 UA。
  static Future<Map<String, Map<String, String>>> loadDetailed() async {
    await _ensureOpen();
    final out = <String, Map<String, String>>{};
    for (final entry in (_cache ?? {}).entries) {
      if (!_isExpired(entry.value)) {
        out[entry.key] = Map<String, String>.from(entry.value);
      }
    }
    return out;
  }

  /// 持久化单个 host 的 cookie 与该 host 当时 UA（UA 配套验证回灌，防漂移）。
  static Future<void> save(String host, String cookie, String ua) async {
    await _ensureOpen();
    _cache![host] = <String, String>{
      'cookie': cookie,
      'ua': ua,
      'updatedAt': DateTime.now().toIso8601String(),
    };
    await _persist();
  }

  /// 读取单个 host 记录（含 cookie/ua/updatedAt），过期返回 null。
  static Future<Map<String, String>?> get(String host) async {
    await _ensureOpen();
    final rec = _cache![host];
    if (rec != null && !_isExpired(rec)) {
      return Map<String, String>.from(rec);
    }
    return null;
  }

  /// 删除单个 host 的持久化记录（源登出时仅清该域会话，不影响其他站点）。
  static Future<void> delete(String host) async {
    await _ensureOpen();
    _cache!.remove(host);
    await _persist();
  }

  static Future<void> clear() async {
    await _ensureOpen();
    _cache!.clear();
    await _persist();
  }
}
