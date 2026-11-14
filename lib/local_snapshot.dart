import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class LocalSnapshot {
  LocalSnapshot(this.preferences) {
    reloadValues();
  }
  LocalSnapshot.empty(this.preferences);

  LocalSnapshot.migrated(this.preferences) {
    _values = _migrateLegacy(preferences);
  }

  static Map<String, Object> _migrateLegacy(SharedPreferences preferences) {
    final values = <String, Object>{};
    for (final key in preferences.getKeys().where(owns)) {
      final value = preferences.get(key);
      final boolean = {
        'hideVip',
        'autoExport',
        'exportPosters',
      }.contains(key.split('.').last);
      if (value is String && !boolean) {
        values[key] = value;
      } else if (value is bool && boolean) {
        values[key] = value;
      }
    }
    return values;
  }

  static const storageKey = 'localSnapshot.v1';
  static const libraryKeys = {
    'history',
    'favorites',
    'followStates',
    'seriesCandidates',
    'mediaHistory',
    'source',
    'hideVip',
    'pythonCfDisguise',
    'jarFingerprintEnabled',
    'customHeadersEnabled',
    'customHeaderRules',
    'expandedSourceGroups',
    // 源显示列表的隐藏集合（每用户），必须列入受管字段，
    // 否则开关站源显示会被 commit 判为「无效的本地配置字段」。
    'hiddenSites',
    'playback',
    'downloadPreferences',
    'catalogView',
    'recentSearches',
    // 观看统计（xigua 播放器移植新增，每用户），必须列入受管字段，
    // 否则记录播放进度会被 commit 判为「无效的本地配置字段」。
    'watchStats',
    // 视频区按区记忆的上次站点（每用户），必须列入受管字段，
    // 否则切站记盘会被 commit 判为「无效的本地配置字段」。
    'zoneSources',
    'lanRecords',
    'lanSettings',
    'lanReceipts',
  };
  static const globalKeys = {
    'profiles',
    'activeProfile',
    'displayMode',
    'appThemeMode',
    // 每套主题绑定的显示方案（导航样式 + 内容档），必须列入受管字段，
    // 否则保存导航样式会被 commit 判为「无效的本地配置字段」。
    'themeScheme_purpleNeon',
    'themeScheme_lightClean',
    'themeScheme_goldVip',
    'themeScheme_cyberBlue',
    'themeScheme_kidFamily',
    'themeScheme_minimalCard',
    'themeScheme_retroFilm',
    'themeScheme_tvBigScreen',
    // 旧主题系统的键：不再被读取，只为校验旧快照保留，
    // migrateLegacyThemeSettings 会删掉它们。
    'themeMode',
    'themeModeStyle',
    'themeStyle',
    'themeAccent',
    'themeBackground',
    'themeBackgroundImage',
    'autoExport',
    'exportPosters',
    // 自定义源是设备级配置，所有本地用户共用，必须在受管字段内，
    // 否则保存自定义源会被判为“无效的本地配置字段”。
    'site_check_last_run',
    'customSources',
    'importedSites',
    'm3uSubscriptions',
    // 播放器偏好（guo / xigua，设备级）必须列入受管字段，
    // 否则「播放器选择」点击立即生效会被 commit 判为「无效的本地配置字段」。
    'player',
  };
  final SharedPreferences preferences;
  Map<String, Object> _values = {};

  static bool owns(String key) =>
      globalKeys.contains(key) ||
      libraryKeys.contains(key) ||
      RegExp(
        r'^profile\.[a-zA-Z0-9_-]{1,64}\.(history|favorites|followStates|seriesCandidates|mediaHistory|source|hideVip|hiddenSites|playback|downloadPreferences|catalogView|recentSearches|watchStats|zoneSources|lanRecords|lanSettings|lanReceipts)$',
      ).hasMatch(key);

  Map<String, Object> get values => Map.of(_values);
  String? getString(String key) => _values[key] as String?;
  bool? getBool(String key) => _values[key] as bool?;

  void reloadValues() {
    final raw = preferences.getString(storageKey);
    if (raw == null) {
      _values = _migrateLegacy(preferences);
      return;
    }
    final decoded = jsonDecode(raw) as Map;
    if (decoded['version'] != 1 || decoded['values'] is! Map) {
      throw const FormatException('本地配置快照无效');
    }
    final values = Map<String, Object>.from(decoded['values'] as Map);
    if (!values.containsKey('profiles')) {
      throw const FormatException('本地配置快照无效');
    }
    _validate(values);
    _values = values;
  }

  void _validate(Map<String, Object> values) {
    for (final entry in values.entries) {
      final boolean = {
        'hideVip',
        'autoExport',
        'exportPosters',
      }.contains(entry.key.split('.').last);
      if (!owns(entry.key) ||
          (boolean ? entry.value is! bool : entry.value is! String)) {
        throw const FormatException('本地配置字段无效');
      }
    }
  }

  Future<bool> _restore(Object? value) => switch (value) {
    null => preferences.remove(storageKey),
    String value => preferences.setString(storageKey, value),
    bool value => preferences.setBool(storageKey, value),
    int value => preferences.setInt(storageKey, value),
    double value => preferences.setDouble(storageKey, value),
    List<String> value => preferences.setStringList(storageKey, value),
    _ => Future.value(false),
  };

  Future<void> commit(Map<String, Object> values) async {
    if (values.keys.any((key) => !owns(key))) throw StateError('无效的本地配置字段');
    final content = jsonEncode({'version': 1, 'values': values});
    if (utf8.encode(content).length > 16 * 1024 * 1024) {
      throw StateError('本地记录超过保存上限，请先导出备份并清理记录');
    }
    final previous = preferences.get(storageKey);
    try {
      if (!await preferences.setString(storageKey, content)) {
        throw StateError('本地配置未能保存');
      }
    } catch (_) {
      try {
        await preferences.reload();
        if (preferences.get(storageKey) != previous) {
          final restored = await _restore(previous);
          if (!restored) throw StateError('无法恢复原配置');
          await preferences.reload();
          if (preferences.get(storageKey) != previous) {
            throw StateError('无法恢复原配置');
          }
        }
      } catch (_) {
        throw const SnapshotRecoveryRequired();
      }
      throw StateError('未能保存，原有记录已保留；请检查存储空间和权限后重试');
    }
    _values = Map.of(values);
  }
}

class SnapshotRecoveryRequired implements Exception {
  const SnapshotRecoveryRequired();
  @override
  String toString() => '无法确认本地配置保存结果，已锁定访问；请重新读取配置或恢复备份';
}
