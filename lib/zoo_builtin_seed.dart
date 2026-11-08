import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'core_bridge.dart';
import 'jar_bridge.dart';
import 'models.dart';
import 'tvbox_config.dart';
import 'zoo_builtin_data.dart';

class ZooBuiltinStationLine {
  const ZooBuiltinStationLine({
    required this.configId,
    required this.configName,
    required this.site,
  });

  final String configId;
  final String configName;
  final TvBoxSiteRecord site;
}

class ZooBuiltinStation {
  const ZooBuiltinStation({required this.key, required this.lines});

  final String key;
  final List<ZooBuiltinStationLine> lines;

  String get name => lines.first.site.name;
}

class ZooBuiltinSeeder {
  static const _seededKey = 'zoo_builtin_seeded_v1';
  static const _configPrefixes = {'zoo_', 'luna_'};

  static bool isBuiltinConfig(String configId) =>
      _configPrefixes.any(configId.startsWith);

  static List<Map<String, dynamic>> dataConfigs() {
    final decoded = jsonDecode(zooBuiltinConfigsJson);
    if (decoded is! List) return const [];
    return [
      for (final row in decoded)
        if (row is Map) Map<String, dynamic>.from(row),
    ];
  }

  static String stationKeyForSite(TvBoxSiteRecord site) {
    switch (site.kind) {
      case 'py':
        return 'py:${site.remoteUrl}';
      case 'jar':
        return 'jar:${site.className}@${site.jarUrl}';
      default:
        return 'api:${site.coreId}';
    }
  }

  static String kindLabel(String kind) {
    switch (kind) {
      case 'py':
        return 'py 站';
      case 'jar':
        return 'jar 站';
      default:
        return '接口';
    }
  }

  static List<TvBoxConfigRecord> builtinConfigs() => [
    for (final config in TvBoxConfigStore.configs)
      if (isBuiltinConfig(config.configId)) config,
  ];

  static List<ZooBuiltinStation> builtinStations() {
    final byKey = <String, List<ZooBuiltinStationLine>>{};
    for (final config in TvBoxConfigStore.configs) {
      if (!isBuiltinConfig(config.configId)) continue;
      for (final site in config.sites) {
        (byKey[stationKeyForSite(site)] ??= []).add(
          ZooBuiltinStationLine(
            configId: config.configId,
            configName: config.name,
            site: site,
          ),
        );
      }
    }
    return [
      for (final entry in byKey.entries)
        ZooBuiltinStation(key: entry.key, lines: entry.value),
    ];
  }

  static String _dedupKey({
    required String kind,
    required String coreId,
    required String className,
    required String jarUrl,
    required String remoteUrl,
  }) {
    switch (kind) {
      case 'py':
        return 'py:$remoteUrl';
      case 'jar':
        return 'jar:$className@$jarUrl';
      default:
        return 'api:$coreId';
    }
  }

  static String _recordDedupKey(TvBoxSiteRecord site) => _dedupKey(
    kind: site.kind,
    coreId: site.coreId,
    className: site.className,
    jarUrl: site.jarUrl,
    remoteUrl: site.remoteUrl,
  );

  static String _dataDedupKey(Map<String, dynamic> site) => _dedupKey(
    kind: site['kind'] as String? ?? '',
    coreId: site['coreId'] as String? ?? '',
    className: site['className'] as String? ?? '',
    jarUrl: site['jarUrl'] as String? ?? '',
    remoteUrl: site['remoteUrl'] as String? ?? '',
  );

  static bool hasMissingSites() {
    for (final config in dataConfigs()) {
      final configId = config['configId'] as String? ?? '';
      final existing = TvBoxConfigStore.configFor(configId);
      final present = {
        for (final site in existing?.sites ?? const <TvBoxSiteRecord>[])
          _recordDedupKey(site),
      };
      final sites = config['sites'];
      if (sites is! List) continue;
      for (final row in sites) {
        if (row is! Map) continue;
        if (!present.contains(_dataDedupKey(Map<String, dynamic>.from(row)))) {
          return true;
        }
      }
    }
    return false;
  }

  static Future<int> seed(
    AppRepository repository, {
    bool force = false,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!force && prefs.getBool(_seededKey) == true) return 0;
      var added = 0;
      for (final config in dataConfigs()) {
        try {
          added += await _seedConfig(repository, config);
        } catch (_) {}
      }
      await prefs.setBool(_seededKey, true);
      return added;
    } catch (_) {
      return 0;
    }
  }

  static Future<int> restore(AppRepository repository) =>
      seed(repository, force: true);

  static String _uniquePySiteId(String base, Set<String> used) {
    if (!used.contains(base)) return base;
    var index = 2;
    while (used.contains('$base#$index')) {
      index++;
    }
    return '$base#$index';
  }

  static Future<int> _seedConfig(
    AppRepository repository,
    Map<String, dynamic> config,
  ) async {
    final configId = config['configId'] as String? ?? '';
    if (configId.isEmpty) return 0;
    final rawSites = config['sites'];
    if (rawSites is! List) return 0;
    final existing = TvBoxConfigStore.configFor(configId);
    final merged = [
      for (final site in existing?.sites ?? const <TvBoxSiteRecord>[]) site,
    ];
    final seen = <String>{};
    for (final site in merged) {
      seen.add(_recordDedupKey(site));
    }
    final usedPyIds = <String>{};
    for (final site in merged) {
      if (site.kind == 'py') usedPyIds.add(site.siteId);
    }
    var added = 0;
    for (final row in rawSites) {
      if (row is! Map) continue;
      final site = Map<String, dynamic>.from(row);
      final kind = site['kind'] as String? ?? '';
      final name = site['name'] as String? ?? '';
      final ext = site['ext'] as String? ?? '';
      TvBoxSiteRecord? record;
      if (kind == 'api') {
        final coreId = await _resolveApiCoreId(
          repository,
          name: name,
          base: site['base'] as String? ?? '',
          rule: site['rule'] as String? ?? '',
          apikind: site['apikind'] as String? ?? '',
        );
        if (coreId == null) continue;
        if (seen.contains('api:$coreId')) continue;
        record = TvBoxSiteRecord(
          siteId: coreId,
          key: site['key'] as String? ?? '',
          name: name,
          kind: 'api',
          coreId: coreId,
          ext: ext,
        );
      } else if (kind == 'jar') {
        if (seen.contains(_dataDedupKey(site))) continue;
        record = TvBoxSiteRecord(
          siteId: site['siteId'] as String? ?? '',
          key: site['key'] as String? ?? '',
          name: name,
          kind: 'jar',
          className: site['className'] as String? ?? '',
          jarUrl: site['jarUrl'] as String? ?? '',
          jarMd5: site['jarMd5'] as String? ?? '',
          ext: ext,
        );
      } else if (kind == 'py') {
        if (seen.contains(_dataDedupKey(site))) continue;
        final baseId = site['siteId'] as String? ?? '';
        if (baseId.isEmpty) continue;
        final siteId = _uniquePySiteId(baseId, usedPyIds);
        record = TvBoxSiteRecord(
          siteId: siteId,
          key: site['key'] as String? ?? '',
          name: name,
          kind: 'py',
          coreId: siteId,
          remoteUrl: site['remoteUrl'] as String? ?? '',
          ext: ext,
        );
      } else {
        continue;
      }
      if (record.siteId.isEmpty) continue;
      merged.add(record);
      seen.add(_recordDedupKey(record));
      if (record.kind == 'py') usedPyIds.add(record.siteId);
      added++;
    }
    if (added == 0) return 0;
    await TvBoxConfigStore.save(
      TvBoxConfigRecord(
        configId: configId,
        name: existing?.name ?? (config['name'] as String? ?? ''),
        url: existing?.url ?? (config['url'] as String? ?? ''),
        sites: merged,
        lives: existing?.lives ?? const [],
        parseIds: existing?.parseIds ?? const [],
        updatedAt: DateTime.now().toIso8601String(),
      ),
    );
    return added;
  }

  static Future<String?> _resolveApiCoreId(
    AppRepository repository, {
    required String name,
    required String base,
    required String rule,
    required String apikind,
  }) async {
    if (base.isEmpty) return null;
    try {
      final created = await repository.addCustomSource(
        name: name,
        base: base,
        rule: rule,
        kind: apikind,
      );
      if (created.id.isNotEmpty) return created.id;
    } catch (_) {}
    try {
      final sources = await repository.customSources();
      final wanted = base.toLowerCase().replaceAll(RegExp(r'/+$'), '');
      for (final source in sources) {
        if (source.base.toLowerCase().replaceAll(RegExp(r'/+$'), '') ==
            wanted) {
          return source.id;
        }
      }
    } catch (_) {}
    return null;
  }

  static bool _apiCoreStillUsed(
    String coreId, {
    required String excludeConfigId,
    required String excludeSiteId,
  }) {
    for (final config in TvBoxConfigStore.configs) {
      for (final site in config.sites) {
        if (site.kind != 'api' || site.coreId != coreId) continue;
        if (config.configId == excludeConfigId &&
            site.siteId == excludeSiteId) {
          continue;
        }
        return true;
      }
    }
    return false;
  }

  static Future<bool> deleteSite(
    AppRepository repository,
    String configId,
    TvBoxSiteRecord site,
  ) async {
    final record = TvBoxConfigStore.configFor(configId);
    if (record == null) return false;
    final remaining = [
      for (final item in record.sites)
        if (item.siteId != site.siteId) item,
    ];
    if (remaining.length == record.sites.length) return false;
    if (site.kind == 'api' && site.coreId.isNotEmpty) {
      if (!_apiCoreStillUsed(
        site.coreId,
        excludeConfigId: configId,
        excludeSiteId: site.siteId,
      )) {
        try {
          await repository.removeCustomSource(site.coreId);
        } catch (_) {}
      }
    } else if (site.kind == 'jar') {
      JarBridge.unregister(site.siteId);
    } else if (site.kind == 'py') {
      SourceSite.importedSites.remove(site.siteId);
      SourceSite.importedPyFiles.remove(site.siteId);
      SourceSite.importedPyRemoteUrls.remove(site.siteId);
    }
    SourceSite.importedSites.remove(site.siteId);
    await TvBoxConfigStore.save(
      TvBoxConfigRecord(
        configId: record.configId,
        name: record.name,
        url: record.url,
        sites: remaining,
        lives: record.lives,
        parseIds: record.parseIds,
        updatedAt: DateTime.now().toIso8601String(),
      ),
    );
    return true;
  }

  static Future<int> deleteStation(
    AppRepository repository,
    String stationKey,
  ) async {
    var removed = 0;
    for (final config in TvBoxConfigStore.configs) {
      if (!isBuiltinConfig(config.configId)) continue;
      for (final site in List.of(config.sites)) {
        if (stationKeyForSite(site) == stationKey) {
          if (await deleteSite(repository, config.configId, site)) {
            removed++;
          }
        }
      }
    }
    return removed;
  }

  static Future<int> deleteConfig(
    AppRepository repository,
    String configId,
  ) async {
    final record = TvBoxConfigStore.configFor(configId);
    if (record == null) return 0;
    var removed = 0;
    for (final site in List.of(record.sites)) {
      if (await deleteSite(repository, configId, site)) removed++;
    }
    await TvBoxConfigStore.delete(configId);
    return removed;
  }
}
