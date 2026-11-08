import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core_bridge.dart';
import 'import_file_store.dart';
import 'jar_bridge.dart';
import 'live_sources.dart';
import 'models.dart';
import 'playback_parse.dart';

class TvBoxSiteRecord {
  const TvBoxSiteRecord({
    required this.siteId,
    required this.key,
    required this.name,
    required this.kind,
    this.coreId = '',
    this.className = '',
    this.jarUrl = '',
    this.jarMd5 = '',
    this.ext = '',
    this.fileName = '',
    this.remoteUrl = '',
  });

  final String siteId;
  final String key;
  final String name;
  final String kind;
  final String coreId;
  final String className;
  final String jarUrl;
  final String jarMd5;
  final String ext;
  final String fileName;
  final String remoteUrl;

  Map<String, dynamic> toJson() => {
    'siteId': siteId,
    'key': key,
    'name': name,
    'kind': kind,
    if (coreId.isNotEmpty) 'coreId': coreId,
    if (className.isNotEmpty) 'className': className,
    if (jarUrl.isNotEmpty) 'jarUrl': jarUrl,
    if (jarMd5.isNotEmpty) 'jarMd5': jarMd5,
    if (ext.isNotEmpty) 'ext': ext,
    if (fileName.isNotEmpty) 'fileName': fileName,
    if (remoteUrl.isNotEmpty) 'remoteUrl': remoteUrl,
  };

  factory TvBoxSiteRecord.fromJson(Map<String, dynamic> json) =>
      TvBoxSiteRecord(
        siteId: json['siteId'] as String? ?? '',
        key: json['key'] as String? ?? '',
        name: json['name'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
        coreId: json['coreId'] as String? ?? '',
        className: json['className'] as String? ?? '',
        jarUrl: json['jarUrl'] as String? ?? '',
        jarMd5: json['jarMd5'] as String? ?? '',
        ext: json['ext'] as String? ?? '',
        fileName: json['fileName'] as String? ?? '',
        remoteUrl: json['remoteUrl'] as String? ?? '',
      );
}

class TvBoxLiveRecord {
  const TvBoxLiveRecord({
    required this.id,
    required this.name,
    required this.url,
  });

  final String id;
  final String name;
  final String url;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url};

  factory TvBoxLiveRecord.fromJson(Map<String, dynamic> json) =>
      TvBoxLiveRecord(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
      );
}

class TvBoxConfigRecord {
  const TvBoxConfigRecord({
    required this.configId,
    required this.name,
    required this.url,
    required this.sites,
    required this.lives,
    required this.parseIds,
    required this.updatedAt,
  });

  final String configId;
  final String name;
  final String url;
  final List<TvBoxSiteRecord> sites;
  final List<TvBoxLiveRecord> lives;
  final List<String> parseIds;
  final String updatedAt;

  int get jarSiteCount => sites.where((site) => site.kind == 'jar').length;
  int get apiSiteCount => sites.where((site) => site.kind == 'api').length;
  int get pySiteCount => sites.where((site) => site.kind == 'py').length;
  String get summaryLine =>
      '站点 ${sites.length}（接口 $apiSiteCount · jar $jarSiteCount · py $pySiteCount）· 直播 ${lives.length} · 解析 ${parseIds.length}';

  Map<String, dynamic> toJson() => {
    'configId': configId,
    'name': name,
    'url': url,
    'sites': [for (final site in sites) site.toJson()],
    'lives': [for (final live in lives) live.toJson()],
    'parseIds': parseIds,
    'updatedAt': updatedAt,
  };

  factory TvBoxConfigRecord.fromJson(Map<String, dynamic> json) =>
      TvBoxConfigRecord(
        configId: json['configId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        sites: [
          for (final row in json['sites'] as List? ?? const [])
            if (row is Map)
              TvBoxSiteRecord.fromJson(Map<String, dynamic>.from(row)),
        ],
        lives: [
          for (final row in json['lives'] as List? ?? const [])
            if (row is Map)
              TvBoxLiveRecord.fromJson(Map<String, dynamic>.from(row)),
        ],
        parseIds: [
          for (final id in json['parseIds'] as List? ?? const []) id.toString(),
        ],
        updatedAt: json['updatedAt'] as String? ?? '',
      );
}

class TvBoxConfigStore {
  static const _prefsKey = 'tvbox_configs';
  static final Map<String, TvBoxConfigRecord> _configs = {};

  static List<TvBoxConfigRecord> get configs =>
      List.unmodifiable(_configs.values);

  static TvBoxConfigRecord? configFor(String configId) => _configs[configId];

  static void restore(SharedPreferences preferences) {
    _configs.clear();
    final raw = preferences.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final rows = jsonDecode(raw) as List;
      for (final row in rows) {
        if (row is! Map) continue;
        final record = TvBoxConfigRecord.fromJson(
          Map<String, dynamic>.from(row),
        );
        if (record.configId.isEmpty) continue;
        _configs[record.configId] = record;
        _registerRecord(record);
      }
    } catch (_) {}
  }

  static void _registerRecord(TvBoxConfigRecord record) {
    for (final site in record.sites) {
      if (site.kind == 'py') {
        SourceSite.importedSites[site.coreId] = SourceSite(
          site.coreId,
          site.name,
          'Python 蜘蛛 · 来自配置「${record.name}」',
          section: SourceSite.sectionVideo,
          origin: SourceSite.originConfig,
          configId: record.configId,
          configName: record.name,
          importType: 'py',
        );
        if (site.fileName.isNotEmpty) {
          SourceSite.importedPyFiles[site.coreId] = site.fileName;
        } else if (site.remoteUrl.isNotEmpty) {
          SourceSite.importedPyRemoteUrls[site.coreId] = site.remoteUrl;
        }
      } else if (site.kind == 'jar') {
        JarBridge.register(
          JarSiteSpec(
            siteId: site.siteId,
            configId: record.configId,
            name: site.name,
            className: site.className,
            jarUrl: site.jarUrl,
            jarMd5: site.jarMd5,
            ext: site.ext,
          ),
        );
        SourceSite.importedSites[site.siteId] = SourceSite(
          site.siteId,
          site.name,
          'jar 站 · 来自配置「${record.name}」',
          section: SourceSite.sectionVideo,
          origin: SourceSite.originConfig,
          configId: record.configId,
          configName: record.name,
        );
      } else if (site.coreId.isNotEmpty) {
        SourceSite.importedSites[site.coreId] = SourceSite(
          site.coreId,
          site.name,
          '来自配置「${record.name}」',
          section: SourceSite.sectionVideo,
          origin: SourceSite.originConfig,
          configId: record.configId,
          configName: record.name,
        );
      }
    }
    for (final live in record.lives) {
      LiveSource.importedValues.removeWhere((source) => source.id == live.id);
      LiveSource.importedValues.add(
        LiveSource(
          id: live.id,
          name: live.name,
          description: '来自配置「${record.name}」',
          protocol: LiveProtocol.list,
          endpoints: [live.url],
          group: live.name,
          builtin: false,
        ),
      );
    }
  }

  static Future<void> save(TvBoxConfigRecord record) async {
    _configs[record.configId] = record;
    _registerRecord(record);
    await _persist();
  }

  static Future<void> delete(String configId) async {
    _configs.remove(configId);
    await _persist();
  }

  static Future<void> _persist() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _prefsKey,
      jsonEncode([for (final record in _configs.values) record.toJson()]),
    );
  }
}

class TvBoxImportReport {
  TvBoxImportReport(this.configId, this.name);

  final String configId;
  final String name;
  int apiSites = 0;
  int jarSites = 0;
  int pySites = 0;
  int t4Sites = 0;
  int lives = 0;
  int parses = 0;
  final List<String> notes = [];

  String get summary =>
      '站点 ${apiSites + jarSites + pySites + t4Sites} 个（接口 $apiSites · jar $jarSites · py $pySites · T4 $t4Sites）、直播 $lives 个、解析 $parses 个';
}

class TvBoxConfigParser {
  static Map<String, dynamic> parse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const FormatException('配置内容为空');
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw const FormatException('配置不是 JSON 对象');
    } on FormatException {
      final repaired = _repair(trimmed);
      final decoded = jsonDecode(repaired);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw const FormatException('配置不是合法的 TVBox JSON');
    }
  }

  static String _repair(String text) {
    final out = StringBuffer();
    var inString = false;
    var escaped = false;
    var pendingComma = false;
    void flushComma() {
      if (pendingComma) {
        out.write(',');
        pendingComma = false;
      }
    }

    var i = 0;
    while (i < text.length) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          out.write(ch);
          escaped = false;
        } else if (ch == r'\') {
          out.write(ch);
          escaped = true;
        } else if (ch == '"') {
          out.write(ch);
          inString = false;
        } else if (ch == '\n') {
          out.write(r'\n');
        } else if (ch == '\r') {
          out.write(r'\r');
        } else if (ch == '\t') {
          out.write(r'\t');
        } else {
          out.write(ch);
        }
        i++;
        continue;
      }
      if (ch == '"') {
        flushComma();
        inString = true;
        out.write(ch);
        i++;
        continue;
      }
      if (ch == '/' && i + 1 < text.length && text[i + 1] == '/') {
        while (i < text.length && text[i] != '\n') {
          i++;
        }
        continue;
      }
      if (ch == '/' && i + 1 < text.length && text[i + 1] == '*') {
        i += 2;
        while (i + 1 < text.length && !(text[i] == '*' && text[i + 1] == '/')) {
          i++;
        }
        i += 2;
        continue;
      }
      if (ch == ',') {
        if (pendingComma) {
          i++;
          continue;
        }
        pendingComma = true;
        i++;
        continue;
      }
      if (ch == '}' || ch == ']') {
        pendingComma = false;
        out.write(ch);
        i++;
        continue;
      }
      if (ch.trim().isEmpty) {
        out.write(ch);
        i++;
        continue;
      }
      flushComma();
      out.write(ch);
      i++;
    }
    return out.toString();
  }
}

class _SpiderRef {
  const _SpiderRef(this.url, this.md5);
  final String url;
  final String md5;
}

_SpiderRef _parseSpiderRef(String raw) {
  final parts = raw.split(';').map((part) => part.trim()).toList();
  var url = '';
  var md5 = '';
  final md5Pattern = RegExp(r'^[0-9a-fA-F]{32}$');
  for (final part in parts) {
    if (part.isEmpty) continue;
    if (md5Pattern.hasMatch(part)) {
      md5 = part.toLowerCase();
    } else if (url.isEmpty) {
      url = part;
    }
  }
  return _SpiderRef(url, md5);
}

class TvBoxImporter {
  TvBoxImporter(this.repository);

  final AppRepository repository;

  static Future<String> fetchText(String url) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'okhttp/4.12.0');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FormatException('拉取配置失败：HTTP ${response.statusCode}');
      }
      return await utf8.decoder.bind(response).join();
    } finally {
      client.close();
    }
  }

  static Future<List<int>> fetchBytes(String url) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'okhttp/4.12.0');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FormatException('拉取失败：HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      return bytes;
    } finally {
      client.close();
    }
  }

  Future<TvBoxImportReport> importFromUrl(
    String url, {
    String displayName = '',
  }) async {
    final text = await fetchText(url);
    return importFromText(
      text,
      sourceIdentity: url,
      sourceUrl: url,
      displayName: displayName,
    );
  }

  Future<TvBoxImportReport> importFromText(
    String text, {
    required String sourceIdentity,
    String sourceUrl = '',
    String displayName = '',
  }) async {
    final raw = TvBoxConfigParser.parse(text);
    final configId = md5
        .convert(utf8.encode(sourceIdentity))
        .toString()
        .substring(0, 12);
    final existing = TvBoxConfigStore.configFor(configId);
    if (existing != null) {
      await _removeRegistrations(existing);
    }
    final name = displayName.isNotEmpty
        ? displayName
        : _configName(raw, sourceUrl);
    final report = TvBoxImportReport(configId, name);
    final configSpider = _parseSpiderRef(raw['spider']?.toString() ?? '');

    final sites = <TvBoxSiteRecord>[];
    for (final row in raw['sites'] as List? ?? const []) {
      if (row is! Map) continue;
      final entry = Map<String, dynamic>.from(row);
      try {
        final record = await _importSite(
          entry,
          configId: configId,
          configName: name,
          configSpider: configSpider,
          report: report,
        );
        if (record != null) sites.add(record);
      } catch (error) {
        report.notes.add('${entry['name'] ?? entry['key'] ?? '未命名站点'}：$error');
      }
    }

    final lives = <TvBoxLiveRecord>[];
    var liveIndex = 0;
    for (final row in raw['lives'] as List? ?? const []) {
      if (row is! Map) continue;
      final entry = Map<String, dynamic>.from(row);
      liveIndex++;
      final liveName = entry['name']?.toString() ?? '直播 $liveIndex';
      final liveUrl = entry['url']?.toString() ?? '';
      final type = entry['type'];
      if (liveUrl.isEmpty || !liveUrl.startsWith('http')) {
        report.notes.add('直播「$liveName」缺少可用地址，已跳过');
        continue;
      }
      if (type != null && type.toString() != '0') {
        report.notes.add('直播「$liveName」类型 $type 不是 m3u/txt 列表，已跳过');
        continue;
      }
      lives.add(
        TvBoxLiveRecord(
          id: 'live:$configId:$liveIndex',
          name: liveName,
          url: liveUrl,
        ),
      );
      report.lives++;
    }

    if (configSpider.url.isNotEmpty && report.jarSites == 0) {
      try {
        final jarPath = await JarBridge.ensureJarPath(
          configId: configId,
          url: configSpider.url,
          md5: configSpider.md5,
        );
        final classes = await JarBridge.enumerate(jarPath);
        for (final info in classes) {
          if (!info.instantiable) continue;
          sites.add(
            TvBoxSiteRecord(
              siteId: JarSiteSpec.siteIdFor(configId, info.simpleName),
              key: info.simpleName,
              name: info.simpleName,
              kind: 'jar',
              className: info.className,
              jarUrl: configSpider.url,
              jarMd5: configSpider.md5,
            ),
          );
          report.jarSites++;
        }
        if (report.jarSites > 0) {
          report.notes.add('配置未列出 jar 站点，已按 jar 内 Spider 类自动注册');
        }
      } catch (error) {
        report.notes.add('jar 自动枚举失败：$error');
      }
    }

    final parseIds = await _importParses(raw, configId, name, report);

    final record = TvBoxConfigRecord(
      configId: configId,
      name: name,
      url: sourceUrl,
      sites: sites,
      lives: lives,
      parseIds: parseIds,
      updatedAt: DateTime.now().toIso8601String(),
    );
    await TvBoxConfigStore.save(record);
    await _syncCustomSources();
    if (report.pySites > 0) {
      report.notes.add('py 站已懒加载注册：首次打开该站时再下载校验');
    }
    return report;
  }

  Future<void> _syncCustomSources() async {
    final sync = _syncStore;
    if (sync == null) return;
    try {
      sync(await repository.customSources());
    } catch (_) {}
  }

  static void Function(List<CustomSourceSite> sources)? _syncStore;

  static set storeSync(void Function(List<CustomSourceSite>) sync) =>
      _syncStore = sync;

  String _configName(Map<String, dynamic> raw, String sourceUrl) {
    final declared = raw['name']?.toString().trim() ?? '';
    if (declared.isNotEmpty) return declared;
    if (sourceUrl.isNotEmpty) {
      final uri = Uri.tryParse(sourceUrl);
      if (uri != null && uri.host.isNotEmpty) {
        final segment = uri.pathSegments.isNotEmpty
            ? uri.pathSegments.last.replaceAll(
                RegExp(r'\.json$', caseSensitive: false),
                '',
              )
            : '';
        return segment.isNotEmpty ? segment : uri.host;
      }
      return sourceUrl;
    }
    return 'TVBox 配置';
  }

  Future<TvBoxSiteRecord?> _importSite(
    Map<String, dynamic> entry, {
    required String configId,
    required String configName,
    required _SpiderRef configSpider,
    required TvBoxImportReport report,
  }) async {
    final key = entry['key']?.toString() ?? '';
    final name = (entry['name']?.toString() ?? '').isNotEmpty
        ? entry['name'].toString()
        : key;
    final api = entry['api']?.toString().trim() ?? '';
    if (name.isEmpty || api.isEmpty) {
      report.notes.add('一条站点缺少 name/api，已跳过');
      return null;
    }
    final ext = await _resolveExt(entry['ext'], report, name);
    if (api.startsWith('csp_')) {
      final siteSpider = entry['jar'] != null
          ? _parseSpiderRef(entry['jar'].toString())
          : configSpider;
      if (siteSpider.url.isEmpty) {
        report.notes.add('「$name」是 jar 站但配置未提供 spider jar 地址，已跳过');
        return null;
      }
      final siteId = JarSiteSpec.siteIdFor(
        configId,
        key.isNotEmpty ? key : name,
      );
      report.jarSites++;
      return TvBoxSiteRecord(
        siteId: siteId,
        key: key,
        name: name,
        kind: 'jar',
        className: JarSiteSpec.classNameForApi(api),
        jarUrl: siteSpider.url,
        jarMd5: siteSpider.md5,
        ext: ext,
      );
    }
    if (entry['type']?.toString() == '4' &&
        (api.startsWith('http://') || api.startsWith('https://'))) {
      final created = await repository.addCustomSource(
        name: name,
        base: api,
        rule: '',
        kind: 't4',
      );
      report.t4Sites++;
      return TvBoxSiteRecord(
        siteId: created.id,
        key: key,
        name: name,
        kind: 't4',
        coreId: created.id,
        ext: ext,
      );
    }
    final apiPath = api.split('?').first.split('#').first;
    if (apiPath.toLowerCase().endsWith('.py')) {
      return _importRemotePy(
        key: key,
        name: name,
        api: api,
        ext: ext,
        configId: configId,
        report: report,
      );
    }
    if (api.startsWith('http://') || api.startsWith('https://')) {
      final rule = _xbpqRuleOf(ext);
      final created = await repository.addCustomSource(
        name: name,
        base: rule != null ? (_ruleHome(rule) ?? api) : api,
        rule: rule ?? '',
        kind: rule != null
            ? ''
            : (entry['type']?.toString() == '1' ? 'json' : ''),
      );
      if (rule == null && ext.isNotEmpty) {
        report.notes.add('「$name」的 ext 无法透传到核心自定义源通道，已忽略');
      }
      report.apiSites++;
      return TvBoxSiteRecord(
        siteId: created.id,
        key: key,
        name: name,
        kind: 'api',
        coreId: created.id,
        ext: ext,
      );
    }
    report.notes.add('「$name」的 api 类型不支持（$api），已跳过');
    return null;
  }

  Future<TvBoxSiteRecord?> _importRemotePy({
    required String key,
    required String name,
    required String api,
    required String ext,
    required String configId,
    required TvBoxImportReport report,
  }) async {
    var slug = key.isNotEmpty ? key : name;
    slug = slug.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    if (slug.isEmpty) slug = 'py';
    final id = 'py:tvbox:$configId:$slug';
    report.pySites++;
    return TvBoxSiteRecord(
      siteId: id,
      key: key,
      name: name,
      kind: 'py',
      coreId: id,
      remoteUrl: api,
      ext: ext,
    );
  }

  Future<String> _resolveExt(
    Object? ext,
    TvBoxImportReport report,
    String siteName,
  ) async {
    if (ext == null) return '';
    if (ext is Map || ext is List) return jsonEncode(ext);
    final text = ext.toString().trim();
    if (text.isEmpty) return '';
    if (text.startsWith('http://') || text.startsWith('https://')) {
      try {
        return await fetchText(text);
      } catch (_) {
        report.notes.add('「$siteName」的远程 ext 拉取失败，已按地址原文传给站源');
        return text;
      }
    }
    return text;
  }

  String? _xbpqRuleOf(String ext) {
    if (ext.isEmpty) return null;
    try {
      final decoded = jsonDecode(ext);
      if (decoded is Map) {
        final map = Map<String, dynamic>.from(decoded);
        const ruleKeys = ['主页url', '首页url', '分类url', '数组', '搜索url', '线路数组'];
        final hits = ruleKeys.where(map.containsKey).length;
        if (hits >= 2) return jsonEncode(map);
      }
    } catch (_) {}
    return null;
  }

  String? _ruleHome(String rule) {
    try {
      final decoded = jsonDecode(rule);
      if (decoded is Map) {
        final home = decoded['主页url'] ?? decoded['首页url'];
        if (home is String && home.isNotEmpty) return home;
      }
    } catch (_) {}
    return null;
  }

  Future<List<String>> _importParses(
    Map<String, dynamic> raw,
    String configId,
    String configName,
    TvBoxImportReport report,
  ) async {
    final rows = raw['parses'] as List? ?? const [];
    if (rows.isEmpty) return const [];
    final existing = await ParseInterfaceStore.load();
    final kept = existing
        .where((item) => !item.id.startsWith('tvbox:$configId:'))
        .toList();
    final added = <ParseInterface>[];
    var index = 0;
    for (final row in rows) {
      if (row is! Map) continue;
      final entry = Map<String, dynamic>.from(row);
      index++;
      final parseName = entry['name']?.toString() ?? '解析 $index';
      final parseUrl = entry['url']?.toString() ?? '';
      final type = entry['type'];
      if (parseUrl.isEmpty) continue;
      if (type != null && type.toString() != '0') {
        report.notes.add('解析「$parseName」是 JSON 型接口，与现有前缀模板不兼容，已跳过');
        continue;
      }
      added.add(
        ParseInterface(
          id: 'tvbox:$configId:$index',
          name: parseName,
          url: parseUrl,
          source: configName,
        ),
      );
      report.parses++;
    }
    await ParseInterfaceStore.save([...kept, ...added]);
    if (added.isNotEmpty && await ParseInterfaceStore.loadSelected() == null) {
      await ParseInterfaceStore.saveSelectedId(added.first.id);
    }
    return [for (final item in added) item.id];
  }

  Future<void> _removeRegistrations(TvBoxConfigRecord record) async {
    for (final site in record.sites) {
      if (site.kind == 'py') {
        SourceSite.importedSites.remove(site.coreId);
        SourceSite.importedPyFiles.remove(site.coreId);
        if (site.fileName.isNotEmpty) {
          try {
            await ImportFileStore.delete(site.fileName);
          } catch (_) {}
        }
      } else if (site.kind == 'jar') {
        JarBridge.unregister(site.siteId);
        SourceSite.importedSites.remove(site.siteId);
      } else if (site.coreId.isNotEmpty) {
        try {
          await repository.removeCustomSource(site.coreId);
        } catch (_) {}
        SourceSite.importedSites.remove(site.coreId);
      }
    }
    for (final live in record.lives) {
      LiveSource.importedValues.removeWhere((source) => source.id == live.id);
    }
    if (record.parseIds.isNotEmpty) {
      final items = await ParseInterfaceStore.load();
      await ParseInterfaceStore.save(
        items.where((item) => !record.parseIds.contains(item.id)).toList(),
      );
      final selected = await ParseInterfaceStore.loadSelectedId();
      if (record.parseIds.contains(selected)) {
        await ParseInterfaceStore.saveSelectedId('');
      }
    }
    JarBridge.invalidateJar(record.configId);
  }

  Future<void> removeConfig(String configId) async {
    final record = TvBoxConfigStore.configFor(configId);
    if (record == null) return;
    await _removeRegistrations(record);
    await TvBoxConfigStore.delete(configId);
    await _syncCustomSources();
  }

  Future<TvBoxImportReport> refreshConfig(String configId) async {
    final record = TvBoxConfigStore.configFor(configId);
    if (record == null || record.url.isEmpty) {
      throw const FormatException('该配置没有可刷新的来源地址');
    }
    return importFromUrl(record.url);
  }
}
