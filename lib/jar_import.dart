import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'jar_bridge.dart';
import 'jar_site_config.dart';
import 'models.dart';
import 'zakatv_builtin.dart';

class StandaloneJarSite {
  const StandaloneJarSite({
    required this.siteId,
    required this.jarId,
    required this.jarUrl,
    required this.jarMd5,
    required this.className,
    required this.name,
    this.ext = '',
    this.missingConfig = false,
    this.baseName = '',
    this.section = SourceSite.sectionVideo,
  });

  final String siteId;
  final String jarId;
  final String jarUrl;
  final String jarMd5;
  final String className;
  final String name;
  final String ext;
  final bool missingConfig;
  final String baseName;
  final String section;

  String get effectiveBase => baseName.isNotEmpty ? baseName : name;

  JarSiteSpec get spec => JarSiteSpec(
    siteId: siteId,
    configId: jarId,
    name: name,
    className: className,
    jarUrl: jarUrl,
    jarMd5: jarMd5,
    ext: ext,
  );

  StandaloneJarSite copyWith({
    String? ext,
    String? name,
    bool? missingConfig,
    String? baseName,
    String? section,
  }) => StandaloneJarSite(
    siteId: siteId,
    jarId: jarId,
    jarUrl: jarUrl,
    jarMd5: jarMd5,
    className: className,
    name: name ?? this.name,
    ext: ext ?? this.ext,
    missingConfig: missingConfig ?? this.missingConfig,
    baseName: baseName ?? this.baseName,
    section: section ?? this.section,
  );

  Map<String, dynamic> toJson() => {
    'siteId': siteId,
    'jarId': jarId,
    'jarUrl': jarUrl,
    'jarMd5': jarMd5,
    'className': className,
    'name': name,
    if (ext.isNotEmpty) 'ext': ext,
    if (missingConfig) 'missingConfig': true,
    if (baseName.isNotEmpty) 'baseName': baseName,
  };

  factory StandaloneJarSite.fromJson(Map<String, dynamic> json) =>
      StandaloneJarSite(
        siteId: json['siteId'] as String? ?? '',
        jarId: json['jarId'] as String? ?? '',
        jarUrl: json['jarUrl'] as String? ?? '',
        jarMd5: json['jarMd5'] as String? ?? '',
        className: json['className'] as String? ?? '',
        name: json['name'] as String? ?? '',
        ext: json['ext'] as String? ?? '',
        missingConfig: json['missingConfig'] == true,
        baseName: json['baseName'] as String? ?? '',
      );
}

/// 一个已导入 jar 插件注册的全部站点（同一 jarId 一组）。
class ImportedJarGroup {
  const ImportedJarGroup({required this.jarId, required this.sites});

  final String jarId;
  final List<StandaloneJarSite> sites;

  String get displayName =>
      sites.isEmpty ? jarId : sites.first.effectiveBase;
  int get siteCount => sites.length;
}

class JarImport {
  static const _prefsKey = 'standalone_jar_sites';
  static const _learnedPrefsKey = 'learned_jar_configs';

  static Future<List<JarSiteConfig>> _loadLearnedConfigs() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_learnedPrefsKey);
      if (raw == null || raw.isEmpty) return const [];
      return parseLearnedJarConfigs(raw);
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _saveLearnedConfigs(
    List<JarSiteConfig> configs,
  ) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _learnedPrefsKey,
        jsonEncode([for (final config in configs) config.toJson()]),
      );
    } catch (_) {}
  }
  static final Map<String, StandaloneJarSite> _sites = {};
  static final Map<String, StandaloneJarSite> _builtinSites = {};
  static bool _builtinRegistered = false;
  static final Map<String, StandaloneJarSite> _oneSites = {};
  static bool _oneRegistered = false;
  static final Map<String, StandaloneJarSite> _missav30Sites = {};
  static bool _missav30Registered = false;

  static List<StandaloneJarSite> get sites =>
      List.unmodifiable(_sites.values);

  static List<StandaloneJarSite> get builtinSites =>
      List.unmodifiable(_builtinSites.values);

  static List<StandaloneJarSite> get oneSites =>
      List.unmodifiable(_oneSites.values);

  static List<StandaloneJarSite> get missav30Sites =>
      List.unmodifiable(_missav30Sites.values);

  static bool isBuiltinSite(String siteId) =>
      _builtinSites.containsKey(siteId);

  static StandaloneJarSite? siteFor(String siteId) => _sites[siteId];

  static String fileBaseName(String fileName) {
    var base = fileName.replaceAll('\\', '/');
    final slash = base.lastIndexOf('/');
    if (slash >= 0) base = base.substring(slash + 1);
    base = base.trim();
    final lower = base.toLowerCase();
    if (lower.endsWith('.jar') || lower.endsWith('.zip')) {
      base = base.substring(0, base.length - 4);
    }
    return base.trim();
  }

  static List<String> numberedNames(String base, int count) {
    if (count <= 1) return [base];
    return [for (var i = 1; i <= count; i++) '$base$i'];
  }

  static String uniqueSiteKey(String key, Set<String> taken) {
    if (!taken.contains(key)) return key;
    var index = 2;
    while (taken.contains('${key}_$index')) {
      index++;
    }
    return '${key}_$index';
  }

  static void _renumberBase(String base) {
    final group = [
      for (final site in _sites.values)
        if (site.effectiveBase == base) site,
    ];
    final builtinCount = _builtinSites.values
        .where((site) => site.effectiveBase == base)
        .length;
    final numbered = group.length + builtinCount > 1;
    for (var i = 0; i < group.length; i++) {
      final site = group[i];
      final target = numbered ? '$base${i + 1}' : base;
      if (site.name == target && site.baseName == base) continue;
      final renamed = site.copyWith(name: target, baseName: base);
      _sites[renamed.siteId] = renamed;
      _register(renamed);
    }
  }

  static void restore(SharedPreferences preferences) {
    _sites.clear();
    final raw = preferences.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final rows = jsonDecode(raw) as List;
      for (final row in rows) {
        if (row is! Map) continue;
        final site = StandaloneJarSite.fromJson(Map<String, dynamic>.from(row));
        if (site.siteId.isEmpty || site.className.isEmpty) continue;
        _sites[site.siteId] = site;
        _register(site);
      }
    } catch (_) {}
  }

  static void _register(StandaloneJarSite site) {
    JarBridge.register(site.spec);
    SourceSite.importedSites[site.siteId] = SourceSite(
      site.siteId,
      site.name,
      'jar 导入 · ${site.className}',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originImport,
      importType: 'jar',
    );
  }

  static void _registerBuiltin(StandaloneJarSite site, {bool audioOnly = false}) {
    JarBridge.register(site.spec);
    if (audioOnly) return;
    SourceSite.importedSites[site.siteId] = SourceSite(
      site.siteId,
      site.name,
      'ZakaTV jar 内置 · ${site.className}',
      section: site.section,
      origin: SourceSite.originImport,
      importType: 'jar',
    );
  }

  static Future<bool> registerBuiltinZakatv() async {
    if (_builtinRegistered || !JarBridge.supported) return _builtinRegistered;
    try {
      final bytes = await rootBundle.load(zakatvJarAsset);
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/zakatv.jar');
      await tempFile.writeAsBytes(bytes.buffer.asUint8List());
      final jarPath = await JarBridge.ensureJarPath(
        configId: zakatvJarId,
        url: tempFile.path,
        md5: zakatvJarMd5,
      );
      var youtubeConfig = '';
      try {
        youtubeConfig = await rootBundle.loadString(youtubeConfigAsset);
      } catch (_) {
        youtubeConfig = '';
      }
      for (final builtin in zakatvBuiltinSites) {
        final site = StandaloneJarSite(
          siteId: JarSiteSpec.siteIdFor(zakatvJarId, builtin.key),
          jarId: zakatvJarId,
          jarUrl: jarPath,
          jarMd5: zakatvJarMd5,
          className: builtin.className,
          name: builtin.name,
          ext: builtin.className == youtubeSpiderClass &&
                  youtubeConfig.isNotEmpty
              ? youtubeConfig
              : builtin.ext,
          section: builtin.section,
        );
        _builtinSites[site.siteId] = site;
        _registerBuiltin(site, audioOnly: builtin.audioOnly);
      }
      _builtinRegistered = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 卸载内置 jar 插件：撤掉全部内置站点的登记（含 audioOnly 的纯音频
  /// 配置），下次 registerBuiltinZakatv 可重新注册。jar 文件本身是
  /// APK 内 asset，不删除；JarBridge 侧的缓存拷贝由 ensureJar 复用。
  static void unregisterBuiltinZakatv() {
    for (final siteId in _builtinSites.keys.toList()) {
      JarBridge.unregister(siteId);
      SourceSite.importedSites.remove(siteId);
    }
    _builtinSites.clear();
    _builtinRegistered = false;
  }

  /// 一点播独立 jar 内置：与 zakatv.jar 分开的配置 id 与加载器，jar
  /// 文件原样落盘（SelfCheck 要读磁盘上的 .jar 与 META-INF/SIG）。
  /// 生命周期与 ZakaTV 插件分开，可独立安装/卸载。
  static Future<bool> registerBuiltinOne() async {
    if (_oneRegistered || !JarBridge.supported) return _oneRegistered;
    try {
      final bytes = await rootBundle.load(oneJarAsset);
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/one.jar');
      await tempFile.writeAsBytes(bytes.buffer.asUint8List());
      final jarPath = await JarBridge.ensureJarPath(
        configId: oneJarId,
        url: tempFile.path,
        md5: oneJarMd5,
      );
      for (final builtin in oneBuiltinSites) {
        final site = StandaloneJarSite(
          siteId: JarSiteSpec.siteIdFor(oneJarId, builtin.key),
          jarId: oneJarId,
          jarUrl: jarPath,
          jarMd5: oneJarMd5,
          className: builtin.className,
          name: builtin.name,
          ext: builtin.ext,
          section: builtin.section,
        );
        _oneSites[site.siteId] = site;
        JarBridge.register(site.spec);
        SourceSite.importedSites[site.siteId] = SourceSite(
          site.siteId,
          site.name,
          '一点播 jar 内置 · ${site.className}',
          section: site.section,
          origin: SourceSite.originImport,
          importType: 'jar',
        );
      }
      _oneRegistered = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 卸载一点播内置 jar：撤掉登记，下次 registerBuiltinOne 可重新
  /// 注册。jar 文件本身是 APK 内 asset，不删除。
  static void unregisterBuiltinOne() {
    for (final siteId in _oneSites.keys.toList()) {
      JarBridge.unregister(siteId);
      SourceSite.importedSites.remove(siteId);
    }
    _oneSites.clear();
    _oneRegistered = false;
  }

  /// MissAV v30 独立 jar 内置：与 zakatv.jar、一点播 jar 分开的配置
  /// id 与加载器，jar 文件原样落盘（用户原话“内置不要改里面的代码”，
  /// 只做字节复制，不解包、不改 smali）。3 个蜘蛛原样从
  /// zakatvBuiltinSites 挪到 missav30BuiltinSites，key/显示名/类名/
  /// ext 一字不动，只换 jar 归属。生命周期与 ZakaTV/一点播插件分开，
  /// 可独立安装/卸载。
  static Future<bool> registerBuiltinMissav30() async {
    if (_missav30Registered || !JarBridge.supported) {
      return _missav30Registered;
    }
    try {
      final bytes = await rootBundle.load(missav30JarAsset);
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/missav30.jar');
      await tempFile.writeAsBytes(bytes.buffer.asUint8List());
      final jarPath = await JarBridge.ensureJarPath(
        configId: missav30JarId,
        url: tempFile.path,
        md5: missav30JarMd5,
      );
      for (final builtin in missav30BuiltinSites) {
        final site = StandaloneJarSite(
          siteId: JarSiteSpec.siteIdFor(missav30JarId, builtin.key),
          jarId: missav30JarId,
          jarUrl: jarPath,
          jarMd5: missav30JarMd5,
          className: builtin.className,
          name: builtin.name,
          ext: builtin.ext,
          section: builtin.section,
        );
        _missav30Sites[site.siteId] = site;
        JarBridge.register(site.spec);
        SourceSite.importedSites[site.siteId] = SourceSite(
          site.siteId,
          site.name,
          'MissAV jar 内置 · ${site.className}',
          section: site.section,
          origin: SourceSite.originImport,
          importType: 'jar',
        );
      }
      _missav30Registered = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 卸载 MissAV v30 内置 jar：撤掉登记，下次 registerBuiltinMissav30
  /// 可重新注册。jar 文件本身是 APK 内 asset，不删除。
  static void unregisterBuiltinMissav30() {
    for (final siteId in _missav30Sites.keys.toList()) {
      JarBridge.unregister(siteId);
      SourceSite.importedSites.remove(siteId);
    }
    _missav30Sites.clear();
    _missav30Registered = false;
  }

  /// 已导入 jar 按 jarId 分组（插件管理界面用）。
  static List<ImportedJarGroup> importedJarGroups() {
    final groups = <String, List<StandaloneJarSite>>{};
    for (final site in _sites.values) {
      (groups[site.jarId] ??= []).add(site);
    }
    return [
      for (final entry in groups.entries)
        ImportedJarGroup(jarId: entry.key, sites: entry.value),
    ];
  }

  /// 按 jar 文件 md5 找已安装的导入组（批量安装跳过同款用）。
  /// 同一 jar 文件的全部站点共享同一 md5，取组内首条即可。
  static ImportedJarGroup? groupForJarMd5(String md5) {
    for (final group in importedJarGroups()) {
      if (group.sites.isNotEmpty && group.sites.first.jarMd5 == md5) {
        return group;
      }
    }
    return null;
  }

  /// 卸载一个已导入的 jar 插件：撤掉它注册的全部站点、删持久记录、
  /// 删 imported_jars 下的 jar 文件副本。
  static Future<void> removeImportedJar(String jarId) async {
    final victims = [
      for (final site in _sites.values)
        if (site.jarId == jarId) site,
    ];
    if (victims.isEmpty) return;
    final bases = <String>{};
    String? jarPath;
    for (final site in victims) {
      _sites.remove(site.siteId);
      JarBridge.unregister(site.siteId);
      SourceSite.importedSites.remove(site.siteId);
      bases.add(site.effectiveBase);
      jarPath ??= site.jarUrl;
    }
    for (final base in bases) {
      _renumberBase(base);
    }
    await _persist();
    // 只删 imported_jars 目录下的副本，绝不碰其它路径。
    final path = jarPath;
    if (path != null && path.contains('imported_jars')) {
      final file = File(path);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }

  static Future<
      ({
        List<JarClassInfo> all,
        List<JarClassInfo> newly,
        List<String> updated,
        List<String> configured,
        List<String> missing,
        List<String> newSiteIds,
      })>
      scanAndRegister({
    required String jarId,
    required String jarUrl,
    String jarMd5 = '',
    List<JarSiteConfig> configs = const [],
    String displayName = '',
  }) async {
    final jarPath = await JarBridge.ensureJarPath(
      configId: jarId,
      url: jarUrl,
      md5: jarMd5,
    );
    final storedUrl = jarUrl.startsWith('http') ? jarUrl : jarPath;
    final classes = await JarBridge.enumerate(jarPath);
    final builtinConfigs = await loadBuiltinJarConfigs();
    final learnedConfigs = await _loadLearnedConfigs();
    final newly = <JarClassInfo>[];
    final newSiteIds = <String>[];
    final created = <({String siteId, bool hasConfig})>[];
    final bases = <String>[];
    final usedCallerConfigs = <JarSiteConfig>[];
    for (final info in classes) {
      if (!info.instantiable) continue;
      final callerConfig = matchJarSiteConfig(info.className, configs);
      if (callerConfig != null) usedCallerConfigs.add(callerConfig);
      final config = callerConfig ??
          matchJarSiteConfig(info.className, learnedConfigs) ??
          matchJarSiteConfig(info.className, builtinConfigs);
      final fileBase = fileBaseName(displayName);
      final base = config != null && config.name.isNotEmpty
          ? config.name
          : fileBase.isNotEmpty
          ? fileBase
          : info.simpleName;
      final key = config != null && config.key.isNotEmpty
          ? config.key
          : info.simpleName;
      final prefix = 'jar:$jarId:';
      final takenKeys = <String>{
        for (final id in [..._sites.keys, ..._builtinSites.keys])
          if (id.startsWith(prefix)) id.substring(prefix.length),
      };
      final siteId = JarSiteSpec.siteIdFor(
        jarId,
        uniqueSiteKey(key, takenKeys),
      );
      final site = StandaloneJarSite(
        siteId: siteId,
        jarId: jarId,
        jarUrl: storedUrl,
        jarMd5: jarMd5,
        className: info.className,
        name: base,
        ext: config?.ext ?? '',
        missingConfig: config == null,
        baseName: base,
      );
      _sites[siteId] = site;
      _register(site);
      newly.add(info);
      newSiteIds.add(siteId);
      created.add((siteId: siteId, hasConfig: config != null));
      if (!bases.contains(base)) bases.add(base);
    }
    for (final base in bases) {
      _renumberBase(base);
    }
    final configured = <String>[];
    final missing = <String>[];
    for (final item in created) {
      final site = _sites[item.siteId];
      if (site == null) continue;
      if (item.hasConfig) {
        configured.add(site.name);
      } else {
        missing.add(site.name);
      }
    }
    if (created.isNotEmpty) await _persist();
    if (usedCallerConfigs.isNotEmpty) {
      final merged = upsertLearnedJarConfigs(
        learnedConfigs,
        usedCallerConfigs,
      );
      if (!identical(merged, learnedConfigs)) {
        await _saveLearnedConfigs(merged);
      }
    }
    JarBridge.invalidateJar(jarId);
    return (
      all: classes,
      newly: newly,
      updated: const <String>[],
      configured: configured,
      missing: missing,
      newSiteIds: newSiteIds,
    );
  }

  static List<String> siteIdsForJar(String jarId) {
    final prefix = 'jar:$jarId:';
    return [
      for (final entry in _sites.entries)
        if (entry.key.startsWith(prefix)) entry.key,
    ];
  }

  static Future<void> registerClass({
    required String jarId,
    required String jarUrl,
    String jarMd5 = '',
    required String className,
    String name = '',
    String ext = '',
    String displayName = '',
  }) async {
    final simple = className.split('.').last;
    final fileBase = fileBaseName(displayName);
    final base = fileBase.isNotEmpty
        ? fileBase
        : name.isNotEmpty
        ? name
        : simple;
    final prefix = 'jar:$jarId:';
    final takenKeys = <String>{
      for (final id in [..._sites.keys, ..._builtinSites.keys])
        if (id.startsWith(prefix)) id.substring(prefix.length),
    };
    final siteId = JarSiteSpec.siteIdFor(
      jarId,
      uniqueSiteKey(simple, takenKeys),
    );
    final site = StandaloneJarSite(
      siteId: siteId,
      jarId: jarId,
      jarUrl: jarUrl,
      jarMd5: jarMd5,
      className: className,
      name: base,
      ext: ext,
      missingConfig: ext.isEmpty,
      baseName: base,
    );
    _sites[siteId] = site;
    _register(site);
    _renumberBase(base);
    await _persist();
  }

  static Future<void> remove(String siteId) async {
    if (_builtinSites.containsKey(siteId)) return;
    final removed = _sites.remove(siteId);
    if (removed == null) return;
    JarBridge.unregister(siteId);
    SourceSite.importedSites.remove(siteId);
    _renumberBase(removed.effectiveBase);
    await _persist();
  }

  static Future<void> updateExt(String siteId, String ext) async {
    final builtin = _builtinSites[siteId];
    if (builtin != null) {
      if (builtin.ext == ext) return;
      _builtinSites[siteId] = builtin.copyWith(ext: ext);
      await JarBridge.updateExt(siteId, ext);
      return;
    }
    final site = _sites[siteId];
    if (site == null || (site.ext == ext && !site.missingConfig)) return;
    _sites[siteId] = site.copyWith(
      ext: ext,
      missingConfig: ext.isEmpty ? site.missingConfig : false,
    );
    await JarBridge.updateExt(siteId, ext);
    await _persist();
    if (ext.isNotEmpty) {
      final learned = await _loadLearnedConfigs();
      final key = siteId.split(':').last;
      final merged = upsertLearnedJarConfigs(learned, [
        JarSiteConfig(
          key: key,
          name: site.name,
          api: site.className,
          ext: ext,
        ),
      ]);
      if (!identical(merged, learned)) {
        await _saveLearnedConfigs(merged);
      }
    }
  }

  static Future<void> _persist() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _prefsKey,
      jsonEncode([for (final site in _sites.values) site.toJson()]),
    );
  }
}
