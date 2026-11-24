import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core_bridge.dart' show AppFailure;
import 'models.dart';

/// iDuanJu `.idjplugin` 安装器 + 动态注册表（Dart 侧）。
///
/// 一个文件装三样：[IdjPluginManifest]（校验）+ [IdjPluginStore]
///（解析 / 下载 / 校验 / 完整性 / probe / 写盘 / 索引 / 订阅 / 更新检查）
///+ [IdjPluginRegistry]（动态注册 / 注销 / 启用 / 停用 / 启动恢复）。
///
/// 全部按 `docs/idjplugin-system-design.md` §1 的接口表自己写，
/// 不抄 iDuanJu 源码（GPL-3.0）。4 个插件不预装、不预注册、不打进
/// 安装包，只通过市场（本地导入）装进来。

/// 宿主实现的 idj1 规格水平（设计 §2.4）：4 个插件的 minAppVersion
/// 都是 1.5，用 Go 核版本号比会对不上；比对只认这个规格版本。
const String idjHostSpecVersion = '1.5.2';

/// 插件索引的 SharedPreferences 键：值是一个 JSON 对象字符串，
/// `{pluginId: {name, version, type, adult, enabled, origin, fileHash,
/// siteKey, installedAt, failures}}`。manifest 本体不进 prefs，
/// 用时读包文件；包文件是唯一事实来源。
const String idjPluginsPrefsKey = 'moyi_idj_plugins';

/// 订阅地址列表的 SharedPreferences 键：只存地址，订阅内容不持久化。
const String idjSubscriptionsPrefsKey = 'moyi_idj_subscriptions';

/// 安装器下载的 UA：`Moyi/<App 真实版本> plugin-installer`。
/// 版本号与 `pubspec.yaml` 的 `version` 保持一致，改版时同步改这里。
const String idjInstallerAppVersion = '1.0.9+34';

/// probe 试加载的回调：Dart 侧把包里的脚本与 manifest 随请求传给 Go 核，
/// Go 核新建 runtime 跑 prelude、加载入口脚本、调一次 `init({})`（若导出）、
/// 检查 `export default` 是否齐 manifest.capabilities 声明的能力函数。
/// 生产环境由 `main.dart` 接到 `NativeRepository.idjProbe`；
/// 未接线时安装会明确报错，不静默跳过 probe。
typedef IdjProbeFn =
    Future<Map<String, dynamic>> Function({
      required String pluginId,
      required String script,
      required Map<String, dynamic> manifest,
    });

/// manifest 校验失败时逐条列出的错误（不要只报“manifest 不合法”）。
class IdjPluginManifest {
  IdjPluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.entry,
    required this.type,
    required this.adult,
    required this.author,
    required this.description,
    required this.capabilities,
    required this.httpDomains,
    required this.mediaDomains,
    required this.cloudflare,
    required this.storagePermission,
    required this.loginPermission,
    required this.minAppVersion,
    required this.updateUrl,
    required this.raw,
  });

  factory IdjPluginManifest.fromJson(Map<String, dynamic> json) {
    final permissions = json['permissions'] is Map
        ? Map<String, dynamic>.from(json['permissions'] as Map)
        : const <String, dynamic>{};
    final update = json['update'] is Map
        ? Map<String, dynamic>.from(json['update'] as Map)
        : const <String, dynamic>{};
    return IdjPluginManifest(
      id: (json['id'] as Object?)?.toString() ?? '',
      name: (json['name'] as Object?)?.toString() ?? '',
      version: (json['version'] as Object?)?.toString() ?? '',
      entry: (json['entry'] as Object?)?.toString() ?? '',
      type: (json['type'] as Object?)?.toString() ?? '',
      adult: json['adult'] == true,
      author: (json['author'] as Object?)?.toString() ?? '',
      description: (json['description'] as Object?)?.toString() ?? '',
      capabilities: [
        for (final row in json['capabilities'] as List? ?? const [])
          if (row != null && row.toString().isNotEmpty) row.toString(),
      ],
      httpDomains: [
        for (final row in permissions['http'] as List? ?? const [])
          if (row != null && row.toString().isNotEmpty) row.toString(),
      ],
      mediaDomains: [
        for (final row in permissions['media'] as List? ?? const [])
          if (row != null && row.toString().isNotEmpty) row.toString(),
      ],
      cloudflare: permissions['cloudflare'] == true,
      storagePermission: permissions['storage'] == true,
      loginPermission: permissions['login'] == true,
      minAppVersion: (json['minAppVersion'] as Object?)?.toString() ?? '',
      updateUrl: (update['url'] as Object?)?.toString() ?? '',
      raw: Map<String, dynamic>.from(json),
    );
  }

  final String id;
  final String name;
  final String version;
  final String entry;
  final String type;
  final bool adult;
  final String author;
  final String description;
  final List<String> capabilities;
  final List<String> httpDomains;
  final List<String> mediaDomains;
  final bool cloudflare;
  final bool storagePermission;
  final bool loginPermission;
  final String minAppVersion;
  final String updateUrl;

  /// manifest 原始 JSON（原样传给 Go 核，不做二次加工）。
  final Map<String, dynamic> raw;

  /// manifest.id 的末段（`com.idj.ext.chengguo` → `chengguo`）。
  String get shortName => id.split('.').last;

  /// integrity 取值（Android 宽松口径，设计 §1.3）：
  /// 扁平字符串形态直接取整个字符串；对象形态取
  /// `integrity.files[entry]`；都没有时回 null（不校验）。
  String? integrityValue() {
    final integrity = raw['integrity'];
    if (integrity is String) return integrity;
    if (integrity is Map) {
      final files = Map<String, dynamic>.from(integrity)['files'];
      if (files is Map) {
        final value = files[entry];
        if (value is String) return value;
      }
    }
    return null;
  }

  /// Ed25519 签名块（若有）：`integrity.signature`。
  /// 4 个插件都没有；有签名时走验签路径（见 [IdjPluginStore]）。
  Map<String, dynamic>? signatureBlock() {
    final integrity = raw['integrity'];
    if (integrity is Map) {
      final signature = Map<String, dynamic>.from(integrity)['signature'];
      if (signature is Map) return Map<String, dynamic>.from(signature);
    }
    return null;
  }

  /// `x.y.z` 三段 semver 比对：a < b 回负数，相等回 0，a > b 回正数。
  /// 非三段写法的按 0 补齐再比（如 `1.5` 当 `1.5.0`）。
  static int compareVersions(String a, String b) {
    final pa = _versionParts(a);
    final pb = _versionParts(b);
    for (var i = 0; i < 3; i++) {
      if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
    }
    return 0;
  }

  static List<int> _versionParts(String value) {
    final parts = value.trim().split('.');
    final numbers = <int>[];
    for (var i = 0; i < 3; i++) {
      numbers.add(i < parts.length ? int.tryParse(parts[i].trim()) ?? 0 : 0);
    }
    return numbers;
  }

  static final _idPattern = RegExp(r'^[a-z0-9]+(\.[a-z0-9-]+){2,}$');
  static final _versionPattern = RegExp(r'^\d+\.\d+\.\d+$');
  static final _entryPattern = RegExp(r'^[A-Za-z0-9_-]+\.js$');
  static final _domainPattern = RegExp(r'^(\*\.)?[a-z0-9-]+(\.[a-z0-9-]+)+$');

  /// 按设计 §1.3 的 Android 宽松口径校验，失败逐条指明是哪一条。
  /// 宽松点只有两处：integrity 扁平字符串接受、多文件不拒绝；
  /// 其余照抄 iDuanJu `problems()`。
  List<String> problems() {
    final found = <String>[];
    if (!_idPattern.hasMatch(id)) {
      found.add('插件 id 不是合法的反向域名');
    }
    if (name.trim().isEmpty) {
      found.add('插件缺少名称');
    }
    if (!_versionPattern.hasMatch(version)) {
      found.add('插件版本不是合法的三段版本号');
    }
    if (!_entryPattern.hasMatch(entry)) {
      found.add('插件入口不是合法的 .js 文件名');
    }
    const knownTypes = {'video', 'shortdrama', 'comic', 'live'};
    if (!knownTypes.contains(type)) {
      found.add('插件类型未知（只支持 video / shortdrama / comic / live）');
    } else {
      final required = switch (type) {
        'video' || 'shortdrama' => const ['detail', 'play'],
        'comic' => const ['detail', 'pages'],
        'live' => const ['play'],
        _ => const <String>[],
      };
      for (final capability in required) {
        if (!capabilities.contains(capability)) {
          found.add('缺少 $capability 能力');
        }
      }
    }
    for (final domain in [...httpDomains, ...mediaDomains]) {
      if (!_domainPattern.hasMatch(domain)) {
        found.add('域名不合法：$domain（只支持 example.com 或 *.example.com 形态）');
      }
    }
    if (updateUrl.isNotEmpty) {
      final uri = Uri.tryParse(updateUrl);
      if (uri == null || uri.scheme != 'https') {
        found.add('update.url 必须是 https 地址');
      }
    }
    final signature = signatureBlock();
    final alg = signature?['alg']?.toString() ?? '';
    if (alg.isNotEmpty && alg != 'ed25519') {
      found.add('签名算法只支持 ed25519');
    }
    if (minAppVersion.isNotEmpty &&
        compareVersions(minAppVersion, idjHostSpecVersion) > 0) {
      found.add('minAppVersion $minAppVersion 高于本机支持的 $idjHostSpecVersion');
    }
    return found;
  }
}

/// 索引里的一条插件记录（轻量登记；manifest 本体不进 prefs）。
class IdjPluginIndexEntry {
  IdjPluginIndexEntry({
    required this.pluginId,
    required this.name,
    required this.version,
    required this.type,
    required this.adult,
    required this.enabled,
    required this.origin,
    required this.fileHash,
    required this.siteKey,
    required this.installedAt,
    this.failures = 0,
    this.publicKey = '',
  });

  factory IdjPluginIndexEntry.fromJson(
    String pluginId,
    Map<String, dynamic> json,
  ) => IdjPluginIndexEntry(
    pluginId: pluginId,
    name: (json['name'] as Object?)?.toString() ?? '',
    version: (json['version'] as Object?)?.toString() ?? '',
    type: (json['type'] as Object?)?.toString() ?? '',
    adult: json['adult'] == true,
    enabled: json['enabled'] != false,
    origin: (json['origin'] as Object?)?.toString() ?? 'import',
    fileHash: (json['fileHash'] as Object?)?.toString() ?? '',
    siteKey: (json['siteKey'] as Object?)?.toString() ?? '',
    installedAt: json['installedAt'] is num
        ? (json['installedAt'] as num).toInt()
        : 0,
    failures: json['failures'] is num ? (json['failures'] as num).toInt() : 0,
    publicKey: (json['publicKey'] as Object?)?.toString() ?? '',
  );

  final String pluginId;
  final String name;
  final String version;
  final String type;
  final bool adult;
  final bool enabled;
  final String origin;
  final String fileHash;
  final String siteKey;
  final int installedAt;
  final int failures;
  final String publicKey;

  Map<String, dynamic> toJson() => {
    'name': name,
    'version': version,
    'type': type,
    'adult': adult,
    'enabled': enabled,
    'origin': origin,
    'fileHash': fileHash,
    'siteKey': siteKey,
    'installedAt': installedAt,
    'failures': failures,
    if (publicKey.isNotEmpty) 'publicKey': publicKey,
  };

  IdjPluginIndexEntry copyWith({bool? enabled, int? failures}) =>
      IdjPluginIndexEntry(
        pluginId: pluginId,
        name: name,
        version: version,
        type: type,
        adult: adult,
        enabled: enabled ?? this.enabled,
        origin: origin,
        fileHash: fileHash,
        siteKey: siteKey,
        installedAt: installedAt,
        failures: failures ?? this.failures,
        publicKey: publicKey,
      );
}

/// 解析好的一个 `.idjplugin` 包（内存形态，写盘用原文）。
class IdjPluginBundle {
  IdjPluginBundle({
    required this.manifest,
    required this.script,
    required this.fileHash,
    required this.rawText,
  });

  final IdjPluginManifest manifest;
  final String script;
  final String fileHash;
  final String rawText;

  /// 入口脚本按 UTF-8 算 SHA-256 再 base64（pack 脚本同款算法）。
  static String hashScript(String script) =>
      base64Encode(sha256.convert(utf8.encode(script)).bytes);
}

/// 已安装插件的列表视图（含包文件校验结果）。
class IdjInstalledPlugin {
  IdjInstalledPlugin({
    required this.entry,
    required this.manifest,
    required this.damaged,
    this.damageReason = '',
  });

  final IdjPluginIndexEntry entry;
  final IdjPluginManifest? manifest;
  final bool damaged;
  final String damageReason;
}

/// 更新时的权限差异（设计 §1.8）：有扩大项就要用户再确认。
class IdjPermissionDiff {
  IdjPermissionDiff({
    required this.addedDomains,
    required this.addedCapabilities,
    required this.cloudflareEnabled,
    required this.loginEnabled,
    required this.storageEnabled,
    required this.adultBecameTrue,
    required this.minAppVersionRaised,
    required this.newMinAppVersion,
  });

  final List<String> addedDomains;
  final List<String> addedCapabilities;
  final bool cloudflareEnabled;
  final bool loginEnabled;
  final bool storageEnabled;
  final bool adultBecameTrue;
  final bool minAppVersionRaised;
  final String newMinAppVersion;

  bool get needsConfirmation =>
      addedDomains.isNotEmpty ||
      cloudflareEnabled ||
      loginEnabled ||
      storageEnabled ||
      adultBecameTrue;

  bool get isEmpty =>
      !needsConfirmation && addedCapabilities.isEmpty && !minAppVersionRaised;

  /// 差异项中文列表（给确认框展示）。
  List<String> describe() => [
    if (addedDomains.isNotEmpty)
      '新版本多申请了 ${addedDomains.length} 个域名：${addedDomains.join('、')}',
    if (cloudflareEnabled) '新版本开启了 Cloudflare 验证',
    if (loginEnabled) '新版本开启了登录',
    if (storageEnabled) '新版本开启了存储',
    if (adultBecameTrue) '成人标记由否变是',
    if (addedCapabilities.isNotEmpty) '新增能力：${addedCapabilities.join('、')}',
    if (minAppVersionRaised) '最低宿主版本提高到 $newMinAppVersion',
  ];
}

/// 订阅里的一个插件条目：`manifest` 是相对订阅地址的路径或内联 manifest。
class IdjSubscriptionPlugin {
  IdjSubscriptionPlugin({
    required this.id,
    required this.name,
    required this.version,
    required this.type,
    required this.adult,
    required this.description,
    required this.manifestUrl,
    this.manifest,
  });

  final String id;
  final String name;
  final String version;
  final String type;
  final bool adult;
  final String description;
  final String manifestUrl;
  final Map<String, dynamic>? manifest;
}

/// 订阅里的一个 CMS 采集站条目：v1 只展示（名 + api + adult 标记），
/// 不接线（见 [IdjPluginStore] 的 cms 核实结论）。
class IdjSubscriptionCms {
  IdjSubscriptionCms({
    required this.name,
    required this.api,
    required this.adult,
  });

  final String name;
  final String api;
  final bool adult;
}

class IdjSubscription {
  IdjSubscription({
    required this.url,
    required this.name,
    required this.plugins,
    required this.cms,
    this.error = '',
  });

  final String url;
  final String name;
  final List<IdjSubscriptionPlugin> plugins;
  final List<IdjSubscriptionCms> cms;
  final String error;

  IdjSubscription withError(String value) => IdjSubscription(
    url: url,
    name: name,
    plugins: plugins,
    cms: cms,
    error: value,
  );
}

/// 有 update.url 且拉到新版的插件。
class IdjUpdateCandidate {
  IdjUpdateCandidate({
    required this.pluginId,
    required this.currentVersion,
    required this.latestVersion,
    required this.manifest,
  });

  final String pluginId;
  final String currentVersion;
  final String latestVersion;
  final IdjPluginManifest manifest;
}

enum IdjInterpretKind { bundle, subscription, m3u, tvbox, unsupported }

/// `interpret` 的分流结果：粘贴文本或链接统一分流后的安装动作。
class IdjInterpretResult {
  IdjInterpretResult({
    required this.kind,
    required this.message,
    this.bundleText,
    this.subscription,
  });

  final IdjInterpretKind kind;
  final String message;
  final String? bundleText;
  final IdjSubscription? subscription;
}

class IdjPluginStore {
  IdjPluginStore({
    SharedPreferences? preferences,
    Directory? rootOverride,
    Directory? supportOverride,
    IdjProbeFn? probe,
    HttpClient Function()? httpClientFactory,
  }) : _preferencesOverride = preferences,
       _rootOverride = rootOverride,
       _supportOverride = supportOverride,
       _probeOverride = probe,
       _httpClientFactory = httpClientFactory;

  /// 生产环境的 probe 接线（`main.dart` 里接到 `NativeRepository.idjProbe`）。
  /// 单元测试直接传构造参数的 `probe`，不走这个静态回调。
  static IdjProbeFn? probeHandler;

  final SharedPreferences? _preferencesOverride;
  final Directory? _rootOverride;
  final Directory? _supportOverride;
  final IdjProbeFn? _probeOverride;
  final HttpClient Function()? _httpClientFactory;

  /// 订阅内容只缓存在内存里：重拉失败留旧列表、只记 error。
  final Map<String, IdjSubscription> _subscriptionCache = {};

  Future<SharedPreferences> _preferences() async =>
      _preferencesOverride ?? await SharedPreferences.getInstance();

  /// 插件包根目录：`documents/idj_plugins`。
  Future<Directory> get root async {
    final override = _rootOverride;
    if (override != null) return override;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'idj_plugins'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Go 侧运行态根目录：`support/idj/<pluginId>/storage.json` +
  /// `cookies.json`（Go 核写，Dart 侧只在卸载清除 / 清数据时碰）。
  Future<Directory> get _supportRoot async {
    final override = _supportOverride;
    if (override != null) return override;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'idj'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _safeDirName(String pluginId) =>
      pluginId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  // ---------- 索引 ----------

  Future<Map<String, IdjPluginIndexEntry>> readIndex() async {
    final prefs = await _preferences();
    final raw = prefs.getString(idjPluginsPrefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final entries = <String, IdjPluginIndexEntry>{};
      for (final item in decoded.entries) {
        if (item.value is! Map) continue;
        entries[item.key] = IdjPluginIndexEntry.fromJson(
          item.key,
          Map<String, dynamic>.from(item.value as Map),
        );
      }
      return entries;
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeIndex(Map<String, IdjPluginIndexEntry> entries) async {
    final prefs = await _preferences();
    final encoded = jsonEncode({
      for (final entry in entries.entries) entry.key: entry.value.toJson(),
    });
    await prefs.setString(idjPluginsPrefsKey, encoded);
  }

  // ---------- 解析与校验 ----------

  /// 解析 `.idjplugin` 包文本：JSON 结构 → manifest 校验 →
  /// 入口脚本存在 → integrity 核对 → 签名检查。
  /// 失败时抛中文 [AppFailure]，逐条指明是哪一步、哪一条。
  static IdjPluginBundle parseBundleText(
    String text, {
    String sourceLabel = '文件',
  }) {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw AppFailure('不是合法的 .idjplugin（缺少 manifest 或入口脚本）');
    }
    if (decoded is! Map) {
      throw AppFailure('不是合法的 .idjplugin（缺少 manifest 或入口脚本）');
    }
    final bundleJson = Map<String, dynamic>.from(decoded);
    final manifestJson = bundleJson['manifest'];
    final filesJson = bundleJson['files'];
    if (manifestJson is! Map || filesJson is! Map) {
      throw AppFailure('不是合法的 .idjplugin（缺少 manifest 或入口脚本）');
    }
    final manifest = IdjPluginManifest.fromJson(
      Map<String, dynamic>.from(manifestJson),
    );
    final problems = manifest.problems();
    if (problems.isNotEmpty) {
      throw AppFailure('manifest 校验失败：${problems.join('；')}');
    }
    final files = Map<String, dynamic>.from(filesJson);
    final script = files[manifest.entry];
    if (script is! String || script.isEmpty) {
      throw AppFailure('不是合法的 .idjplugin（缺少 manifest 或入口脚本）');
    }
    final fileHash = IdjPluginBundle.hashScript(script);
    _verifyIntegrity(manifest, fileHash);
    _checkSignature(manifest);
    return IdjPluginBundle(
      manifest: manifest,
      script: script,
      fileHash: fileHash,
      rawText: text,
    );
  }

  /// integrity 核对（设计 §1.4）：两种形态都接受，去掉 `sha256-`
  /// 前缀后与算出的值逐字节比对；不符拒装。不写 integrity 时不校验
  ///（Android 宿主直接忽略，与 4 个插件的扁平串形态兼容）。
  static void _verifyIntegrity(IdjPluginManifest manifest, String fileHash) {
    final expected = manifest.integrityValue();
    if (expected == null || expected.isEmpty) return;
    final stripped = expected.startsWith('sha256-')
        ? expected.substring('sha256-'.length)
        : expected;
    if (stripped != fileHash) {
      throw AppFailure('完整性校验失败：文件哈希与 manifest 不一致，已拒绝安装（插件 ${manifest.id}）');
    }
  }

  /// Ed25519 签名：4 个插件都没有。v1 只做哈希钉死；有签名时按 iOS
  /// 行为验签——但本机没有可用的 Ed25519 验签实现（`crypto` 包不含
  /// Ed25519），无法验签就**拒装**，不静默放过（Android 不验签是
  /// 安全缺口，魔蚁不照抄这点）。以后补上验签实现再放行签名插件。
  static void _checkSignature(IdjPluginManifest manifest) {
    final signature = manifest.signatureBlock();
    if (signature == null || signature.isEmpty) return;
    throw AppFailure('签名验证失败：本机暂不支持 Ed25519 验签，已拒绝安装（插件 ${manifest.id}）');
  }

  // ---------- probe ----------

  /// probe 试加载（设计 §1.5）：新建 runtime → 跑 prelude → 加载入口
  /// 脚本 → 若导出 `init` 则调一次 `init({})` → 检查 `export default`
  /// 是否齐 manifest.capabilities 声明的能力函数（缺失由 Go 侧报错，
  /// 写明缺哪个函数）。超时 20 秒（Go 侧初始化预算 15 秒 + 余量），
  /// 在 Dart 70 秒总预算内。probe 失败不装。
  Future<void> probeBundle(IdjPluginBundle bundle, {IdjProbeFn? probe}) async {
    final probeFn = probe ?? _probeOverride ?? probeHandler;
    if (probeFn == null) {
      throw AppFailure('试加载失败：插件宿主未就绪，请重启应用后再试');
    }
    try {
      await probeFn(
        pluginId: bundle.manifest.id,
        script: bundle.script,
        manifest: bundle.manifest.raw,
      ).timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw AppFailure('试加载失败：插件初始化超时（15 秒）'),
      );
    } on AppFailure {
      rethrow;
    } catch (error) {
      throw AppFailure('试加载失败：插件报错 $error');
    }
  }

  // ---------- 写盘与安装 ----------

  /// 安装链：解析 → 校验 → integrity → 签名 → probe → 写盘 + 索引 + 注册。
  /// 更新时 [permissionConfirmed] 为 false 且权限有扩大项时不装，
  /// 抛错请用户先确认（差异项见 [permissionDiff]）。
  /// 安装失败不留半成品：staging 删除、索引不写、站点不注册。
  Future<IdjInstalledPlugin> installBundleText(
    String text, {
    String sourceLabel = '文件',
    bool permissionConfirmed = false,
    IdjProbeFn? probe,
  }) async {
    final bundle = parseBundleText(text, sourceLabel: sourceLabel);
    final manifest = bundle.manifest;
    final index = await readIndex();
    final existing = index[manifest.id];
    String siteKey;
    if (existing != null) {
      siteKey = existing.siteKey;
      final oldManifest = await readInstalledManifest(manifest.id);
      if (oldManifest != null) {
        final diff = permissionDiff(oldManifest, manifest);
        if (diff.needsConfirmation && !permissionConfirmed) {
          throw AppFailure('新版本申请了更多权限，请确认后再更新：${diff.describe().join('；')}');
        }
      }
    } else {
      siteKey = IdjPluginRegistry.siteKeyForPluginId(manifest.id);
    }
    final probeFn = probe ?? _probeOverride ?? probeHandler;
    if (probeFn == null) {
      throw AppFailure('试加载失败：插件宿主未就绪，请重启应用后再试');
    }
    await probeBundle(bundle, probe: probeFn);
    await _writeBundle(manifest.id, text);
    final entry = IdjPluginIndexEntry(
      pluginId: manifest.id,
      name: manifest.name,
      version: manifest.version,
      type: manifest.type,
      adult: manifest.adult,
      // 同 id 覆盖安装保留原 enabled 状态，新装默认启用。
      enabled: existing?.enabled ?? true,
      origin: 'import',
      fileHash: bundle.fileHash,
      siteKey: siteKey,
      installedAt:
          existing?.installedAt ?? DateTime.now().millisecondsSinceEpoch,
      failures: 0,
      publicKey: existing?.publicKey ?? '',
    );
    index[manifest.id] = entry;
    await _writeIndex(index);
    // 停用态重装不重新注册：站只在启用时进片库，停用后重装仍停用。
    if (entry.enabled) {
      IdjPluginRegistry.registerPlugin(manifest: manifest, siteKey: siteKey);
    }
    return IdjInstalledPlugin(entry: entry, manifest: manifest, damaged: false);
  }

  Future<IdjInstalledPlugin> installBundleBytes(
    List<int> bytes, {
    String sourceLabel = '文件',
    bool permissionConfirmed = false,
    IdjProbeFn? probe,
  }) async {
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      throw AppFailure('不是合法的 .idjplugin（缺少 manifest 或入口脚本）');
    }
    return installBundleText(
      text,
      sourceLabel: sourceLabel,
      permissionConfirmed: permissionConfirmed,
      probe: probe,
    );
  }

  /// 写盘照抄 MiniAppStore 的 staging + 原子改名：先写
  /// `.staging-<pluginId>/bundle.idjplugin`，写完重算哈希通过后再
  /// 原子改名成目标目录；失败清掉 staging，不留半成品。
  Future<void> _writeBundle(String pluginId, String rawText) async {
    final base = await root;
    final safeId = _safeDirName(pluginId);
    final staging = Directory(p.join(base.path, '.staging-$safeId'));
    final target = Directory(p.join(base.path, safeId));
    try {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
      await staging.create(recursive: true);
      final file = File(p.join(staging.path, 'bundle.idjplugin'));
      await file.writeAsString(rawText, flush: true);
      final written = await file.readAsString();
      final bundle = parseBundleText(written);
      if (bundle.fileHash.isEmpty) {
        throw AppFailure('安装失败：写入失败（存储空间不足？）');
      }
      if (await target.exists()) {
        await target.delete(recursive: true);
      }
      await staging.rename(target.path);
    } catch (error) {
      if (await staging.exists()) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {}
      }
      if (error is AppFailure) rethrow;
      throw AppFailure('安装失败：写入失败（存储空间不足？）：$error');
    }
  }

  /// 读已安装插件的包文件（唯一事实来源）。缺失 / 损坏回 null。
  Future<IdjPluginBundle?> readBundle(String pluginId) async {
    final base = await root;
    final file = File(
      p.join(base.path, _safeDirName(pluginId), 'bundle.idjplugin'),
    );
    if (!await file.exists()) return null;
    try {
      final text = await file.readAsString();
      return parseBundleText(text);
    } catch (_) {
      return null;
    }
  }

  Future<IdjPluginManifest?> readInstalledManifest(String pluginId) async {
    final bundle = await readBundle(pluginId);
    return bundle?.manifest;
  }

  /// 已安装列表：读索引 + 逐个校验包文件存在且哈希未变；
  /// 包文件缺失 / 损坏的条目标记损坏，不拦启动、不拦列表。
  Future<List<IdjInstalledPlugin>> listInstalled() async {
    final index = await readIndex();
    final items = <IdjInstalledPlugin>[];
    for (final entry in index.values) {
      final base = await root;
      final file = File(
        p.join(base.path, _safeDirName(entry.pluginId), 'bundle.idjplugin'),
      );
      if (!await file.exists()) {
        items.add(
          IdjInstalledPlugin(
            entry: entry,
            manifest: null,
            damaged: true,
            damageReason: '包文件缺失',
          ),
        );
        continue;
      }
      try {
        final text = await file.readAsString();
        final bundle = parseBundleText(text);
        if (bundle.fileHash != entry.fileHash) {
          items.add(
            IdjInstalledPlugin(
              entry: entry,
              manifest: bundle.manifest,
              damaged: true,
              damageReason: '包文件已被改动（哈希不一致）',
            ),
          );
          continue;
        }
        items.add(
          IdjInstalledPlugin(
            entry: entry,
            manifest: bundle.manifest,
            damaged: false,
          ),
        );
      } catch (_) {
        items.add(
          IdjInstalledPlugin(
            entry: entry,
            manifest: null,
            damaged: true,
            damageReason: '包文件损坏',
          ),
        );
      }
    }
    items.sort((a, b) => a.entry.name.compareTo(b.entry.name));
    return items;
  }

  // ---------- 卸载 / 启用 / 停用 / 清数据 ----------

  /// 卸载：删包目录、清索引条目、注销站点登记。
  /// Go 侧 `storage.json` / `cookies.json` 默认保留（重装回来状态还在），
  /// 用户在卸载确认框选“同时清除插件数据”才删运行态目录。
  Future<void> uninstall(String pluginId, {bool clearData = false}) async {
    final index = await readIndex();
    final entry = index[pluginId];
    if (entry == null) {
      throw AppFailure('未安装该插件');
    }
    index.remove(pluginId);
    await _writeIndex(index);
    IdjPluginRegistry.unregisterSiteKey(entry.siteKey);
    final base = await root;
    final dir = Directory(p.join(base.path, _safeDirName(pluginId)));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    if (clearData) {
      await _deleteRuntimeDir(pluginId);
    }
  }

  /// 启用 / 停用：只改索引 `enabled` + 登记 / 注销，不动包文件与运行态。
  /// 启用时计数清零；停用后该站从片库消失，重启用立即回来，不用重装。
  Future<IdjPluginIndexEntry> setEnabled(String pluginId, bool enabled) async {
    final index = await readIndex();
    final entry = index[pluginId];
    if (entry == null) {
      throw AppFailure('未安装该插件');
    }
    if (enabled) {
      final bundle = await readBundle(pluginId);
      if (bundle == null) {
        throw AppFailure('插件包文件已损坏，请重新安装');
      }
      final updated = entry.copyWith(enabled: true, failures: 0);
      index[pluginId] = updated;
      await _writeIndex(index);
      IdjPluginRegistry.registerPlugin(
        manifest: bundle.manifest,
        siteKey: entry.siteKey,
      );
      return updated;
    }
    final updated = entry.copyWith(enabled: false);
    index[pluginId] = updated;
    await _writeIndex(index);
    IdjPluginRegistry.unregisterSiteKey(entry.siteKey);
    return updated;
  }

  /// 清数据：只删 Go 侧 `cookies.json` + `storage.json`，不卸载插件。
  Future<void> clearData(String pluginId) async {
    final support = await _supportRoot;
    final dir = Directory(p.join(support.path, _safeDirName(pluginId)));
    for (final name in const ['cookies.json', 'storage.json']) {
      final file = File(p.join(dir.path, name));
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<void> _deleteRuntimeDir(String pluginId) async {
    final support = await _supportRoot;
    final dir = Directory(p.join(support.path, _safeDirName(pluginId)));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  // ---------- 看门狗 ----------

  /// 看门狗（设计 §2.3）：连续 3 次失败自动停用并记日志，
  /// 用户在插件 tab 里可手动再启用（计数随启用清零）。
  Future<void> recordFailure(String pluginId) async {
    final index = await readIndex();
    final entry = index[pluginId];
    if (entry == null) return;
    final failures = entry.failures + 1;
    if (failures >= 3 && entry.enabled) {
      final updated = entry.copyWith(enabled: false, failures: failures);
      index[pluginId] = updated;
      await _writeIndex(index);
      IdjPluginRegistry.unregisterSiteKey(entry.siteKey);
      debugPrint('idj 看门狗：插件 $pluginId 连续失败 $failures 次，已自动停用');
      return;
    }
    index[pluginId] = entry.copyWith(failures: failures);
    await _writeIndex(index);
  }

  Future<void> recordSuccess(String pluginId) async {
    final index = await readIndex();
    final entry = index[pluginId];
    if (entry == null || entry.failures == 0) return;
    index[pluginId] = entry.copyWith(failures: 0);
    await _writeIndex(index);
  }

  // ---------- 安装确认摘要与 PermissionDiff ----------

  /// 新装确认 sheet 的 manifest 摘要：名、版本、作者、类型、adult 标记、
  /// 域名数、存储需求（包字节数）、update.url 有无、简介。
  static Map<String, Object?> manifestSummary(
    IdjPluginManifest manifest, {
    required int bundleBytes,
  }) => {
    'name': manifest.name,
    'version': manifest.version,
    'author': manifest.author,
    'description': manifest.description,
    'type': manifest.type,
    'adult': manifest.adult,
    'domainCount': {...manifest.httpDomains, ...manifest.mediaDomains}.length,
    'httpDomains': manifest.httpDomains,
    'mediaDomains': manifest.mediaDomains,
    'bundleBytes': bundleBytes,
    'hasUpdateUrl': manifest.updateUrl.isNotEmpty,
    'updateUrl': manifest.updateUrl,
  };

  /// 更新时算 PermissionDiff：多了域名、开了 CF / 登录 / 存储、
  /// adult 由 false 变 true 都要用户再确认，列出差异项。
  static IdjPermissionDiff permissionDiff(
    IdjPluginManifest oldManifest,
    IdjPluginManifest newManifest,
  ) {
    final oldDomains = {
      ...oldManifest.httpDomains,
      ...oldManifest.mediaDomains,
    };
    final newDomains = {
      ...newManifest.httpDomains,
      ...newManifest.mediaDomains,
    };
    final addedDomains = newDomains.difference(oldDomains).toList()..sort();
    final addedCapabilities = newManifest.capabilities
        .where((capability) => !oldManifest.capabilities.contains(capability))
        .toList();
    return IdjPermissionDiff(
      addedDomains: addedDomains,
      addedCapabilities: addedCapabilities,
      cloudflareEnabled: !oldManifest.cloudflare && newManifest.cloudflare,
      loginEnabled: !oldManifest.loginPermission && newManifest.loginPermission,
      storageEnabled:
          !oldManifest.storagePermission && newManifest.storagePermission,
      adultBecameTrue: !oldManifest.adult && newManifest.adult,
      minAppVersionRaised:
          IdjPluginManifest.compareVersions(
            newManifest.minAppVersion,
            oldManifest.minAppVersion,
          ) >
          0,
      newMinAppVersion: newManifest.minAppVersion,
    );
  }

  // ---------- 输入解释器 interpret ----------

  /// 输入解释器（设计 §1.6）：粘贴文本或链接统一分流。
  /// M3U 报“请走直播导入”不走安装器；TVBox JSON 拒绝；
  /// 含 `plugins` / `cms` 的走订阅流程；含 `manifest` + `files` 的
  /// 走安装链；含 `schema` 的单个 manifest 按 entry 从同目录下载
  /// 脚本拼成包再走安装链；http(s) 链接先下载正文再按内容分流。
  Future<IdjInterpretResult> interpret(String input, {Uri? baseUri}) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return IdjInterpretResult(
        kind: IdjInterpretKind.unsupported,
        message: '这个链接不是插件 manifest / .idjplugin / 订阅列表 / M3U',
      );
    }
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri == null) {
        return IdjInterpretResult(
          kind: IdjInterpretKind.unsupported,
          message: '这个链接不是插件 manifest / .idjplugin / 订阅列表 / M3U',
        );
      }
      late final String text;
      try {
        text = await downloadText(uri, maxBytes: 2 * 1024 * 1024);
      } on AppFailure catch (error) {
        return IdjInterpretResult(
          kind: IdjInterpretKind.unsupported,
          message: error.message,
        );
      }
      return interpretText(text, baseUri: uri);
    }
    return interpretText(trimmed, baseUri: baseUri);
  }

  /// 文本分流（`interpret` 的内容分支，可单独测，不联网）。
  Future<IdjInterpretResult> interpretText(String text, {Uri? baseUri}) async {
    final trimmed = text.trim();
    if (trimmed.startsWith('#EXTM3U')) {
      return IdjInterpretResult(
        kind: IdjInterpretKind.m3u,
        message: '这是 M3U 频道列表，请走直播导入',
      );
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return IdjInterpretResult(
        kind: IdjInterpretKind.unsupported,
        message: '这个链接不是插件 manifest / .idjplugin / 订阅列表 / M3U',
      );
    }
    if (decoded is! Map) {
      return IdjInterpretResult(
        kind: IdjInterpretKind.unsupported,
        message: '这个链接不是插件 manifest / .idjplugin / 订阅列表 / M3U',
      );
    }
    final json = Map<String, dynamic>.from(decoded);
    if (json.containsKey('sites') ||
        json.containsKey('spider') ||
        json.containsKey('lives')) {
      return IdjInterpretResult(
        kind: IdjInterpretKind.tvbox,
        message: '这是 TVBox 配置，不是 idj1 插件；不支持直接运行 JAR / CatVod / Python 源',
      );
    }
    if (json.containsKey('plugins') || json.containsKey('cms')) {
      final subscription = parseSubscriptionJson(
        json,
        baseUri ?? Uri.parse('https://localhost/'),
      );
      return IdjInterpretResult(
        kind: IdjInterpretKind.subscription,
        message: '订阅：${subscription.name}',
        subscription: subscription,
      );
    }
    if (json.containsKey('manifest') && json.containsKey('files')) {
      return IdjInterpretResult(
        kind: IdjInterpretKind.bundle,
        message: '插件包',
        bundleText: trimmed,
      );
    }
    if (json.containsKey('schema')) {
      // 裸 manifest：按 entry 从同目录下载脚本，拼成包再走安装链。
      if (baseUri == null) {
        return IdjInterpretResult(
          kind: IdjInterpretKind.unsupported,
          message: '这是单个 manifest，缺少入口脚本地址，请用链接安装或直接粘贴 .idjplugin 包',
        );
      }
      final manifest = IdjPluginManifest.fromJson(json);
      if (manifest.entry.isEmpty) {
        return IdjInterpretResult(
          kind: IdjInterpretKind.unsupported,
          message: '不是合法的 .idjplugin（缺少 manifest 或入口脚本）',
        );
      }
      final scriptUri = baseUri.resolve(manifest.entry);
      late final String script;
      try {
        script = await downloadText(scriptUri, maxBytes: 2 * 1024 * 1024);
      } on AppFailure catch (error) {
        return IdjInterpretResult(
          kind: IdjInterpretKind.unsupported,
          message: error.message,
        );
      }
      final bundleText = jsonEncode({
        'manifest': json,
        'files': {manifest.entry: script},
      });
      return IdjInterpretResult(
        kind: IdjInterpretKind.bundle,
        message: '插件包',
        bundleText: bundleText,
      );
    }
    return IdjInterpretResult(
      kind: IdjInterpretKind.unsupported,
      message: '这个链接不是插件 manifest / .idjplugin / 订阅列表 / M3U',
    );
  }

  // ---------- 下载器 ----------

  /// 下载器（设计 §1.7）：只接受无凭证 HTTPS 公网域名、443 端口、
  /// 非 IP 字面量；不自动跟随跳转（手动最多 6 跳，每跳重验规则）；
  /// 请求 20 秒、资源 30 秒超时；解析到本机 / 内网直接拒绝；
  /// UA 是 `Moyi/<App 真实版本> plugin-installer`；
  /// 单文件上限由 [maxBytes] 定（订阅 1MB、链接识别 2MB、插件包 2MB）。
  /// 用 `dart:io` 的 HttpClient（`followRedirects = false`）手动循环，
  /// 不用 `package:http` 的 get（它默认自动跟随跳转）。
  Future<String> downloadText(Uri uri, {required int maxBytes}) async {
    final bytes = await _downloadBytes(uri, maxBytes: maxBytes);
    try {
      return utf8.decode(bytes);
    } catch (_) {
      throw AppFailure('下载失败：内容不是合法文本');
    }
  }

  Future<List<int>> _downloadBytes(Uri uri, {required int maxBytes}) async {
    var current = uri;
    final client = (_httpClientFactory ?? HttpClient.new)();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      for (var hop = 0; hop <= 6; hop++) {
        await _validateDownloadUri(current);
        final request = await client.getUrl(current);
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'Moyi/$idjInstallerAppVersion plugin-installer',
        );
        final response = await request.close().timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw AppFailure('下载超时（20 秒）'),
        );
        final location = response.headers.value(HttpHeaders.locationHeader);
        if ((response.statusCode == 301 ||
                response.statusCode == 302 ||
                response.statusCode == 303 ||
                response.statusCode == 307 ||
                response.statusCode == 308) &&
            location != null &&
            location.isNotEmpty) {
          if (hop == 6) {
            throw AppFailure('下载失败：跳转次数过多');
          }
          current = current.resolve(location);
          await response.drain<void>();
          continue;
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
          throw AppFailure('下载失败：HTTP ${response.statusCode}');
        }
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
          onTimeout: (_) => throw AppFailure('下载超时（30 秒）'),
        )) {
          bytes.addAll(chunk);
          if (bytes.length > maxBytes) {
            throw AppFailure('下载失败：文件超过上限');
          }
        }
        return bytes;
      }
      throw AppFailure('下载失败：跳转次数过多');
    } on AppFailure {
      rethrow;
    } catch (error) {
      throw AppFailure('下载失败：$error');
    } finally {
      client.close(force: true);
    }
  }

  /// 每跳重验：https、无凭证、443 端口、非 IP 字面量、非本机 / 内网。
  static Future<void> _validateDownloadUri(Uri uri) async {
    if (uri.scheme != 'https') {
      throw AppFailure('这个地址不是合法的插件下载地址（只支持 HTTPS 公网地址）');
    }
    if (uri.userInfo.isNotEmpty) {
      throw AppFailure('这个地址不是合法的插件下载地址（只支持 HTTPS 公网地址）');
    }
    if (uri.hasPort && uri.port != 443) {
      throw AppFailure('这个地址不是合法的插件下载地址（只支持 HTTPS 公网地址）');
    }
    final host = uri.host.toLowerCase();
    if (host.isEmpty ||
        host == 'localhost' ||
        host.endsWith('.local') ||
        RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host) ||
        host.contains(':')) {
      throw AppFailure('这个地址不是合法的插件下载地址（只支持 HTTPS 公网地址）');
    }
    List<InternetAddress> addresses;
    try {
      addresses = await InternetAddress.lookup(host);
    } catch (_) {
      throw AppFailure('下载失败：域名无法解析');
    }
    for (final address in addresses) {
      if (_isPrivateOrLoopback(address)) {
        throw AppFailure('这个地址不是合法的插件下载地址（只支持 HTTPS 公网地址）');
      }
    }
  }

  static bool _isPrivateOrLoopback(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal) return true;
    if (address.type == InternetAddressType.IPv4) {
      final raw = address.rawAddress;
      if (raw.length == 4) {
        if (raw[0] == 10) return true;
        if (raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31) return true;
        if (raw[0] == 192 && raw[1] == 168) return true;
      }
      return false;
    }
    // IPv6：fc00::/7（唯一本地）与 fe80::/10（链路本地）拒绝。
    final raw = address.rawAddress;
    if (raw.isNotEmpty && (raw[0] & 0xfe) == 0xfc) return true;
    if (raw.length >= 2 && raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) {
      return true;
    }
    return false;
  }

  // ---------- 订阅 ----------

  /// 解析订阅 JSON：`{"name", "plugins": [...], "cms": [...]}`。
  /// `manifest` 可以是相对订阅地址的路径（Uri.resolve 解析，
  /// 失败的条目跳过记日志）；订阅里的插件不自动安装，只展示、逐个点安装。
  static IdjSubscription parseSubscriptionJson(
    Map<String, dynamic> json,
    Uri baseUri,
  ) {
    final plugins = <IdjSubscriptionPlugin>[];
    for (final row in json['plugins'] as List? ?? const []) {
      if (row is! Map) continue;
      final parsed = Map<String, dynamic>.from(row);
      final manifestRaw = parsed['manifest'];
      String manifestUrl = '';
      Map<String, dynamic>? manifest;
      if (manifestRaw is String && manifestRaw.isNotEmpty) {
        try {
          manifestUrl = baseUri.resolve(manifestRaw).toString();
        } catch (error) {
          debugPrint('idj 订阅：插件 manifest 地址解析失败，已跳过：$error');
          continue;
        }
      } else if (manifestRaw is Map) {
        manifest = Map<String, dynamic>.from(manifestRaw);
      }
      plugins.add(
        IdjSubscriptionPlugin(
          id: (parsed['id'] as Object?)?.toString() ?? '',
          name: (parsed['name'] as Object?)?.toString() ?? '',
          version: (parsed['version'] as Object?)?.toString() ?? '',
          type: (parsed['type'] as Object?)?.toString() ?? '',
          adult: parsed['adult'] == true,
          description: (parsed['description'] as Object?)?.toString() ?? '',
          manifestUrl: manifestUrl,
          manifest: manifest,
        ),
      );
    }
    final cms = <IdjSubscriptionCms>[
      for (final row in json['cms'] as List? ?? const [])
        if (row is Map)
          IdjSubscriptionCms(
            name:
                (Map<String, dynamic>.from(row)['name'] as Object?)
                    ?.toString() ??
                '',
            api:
                (Map<String, dynamic>.from(row)['api'] as Object?)
                    ?.toString() ??
                '',
            adult: Map<String, dynamic>.from(row)['adult'] == true,
          ),
    ];
    return IdjSubscription(
      url: baseUri.toString(),
      name: (json['name'] as Object?)?.toString() ?? '',
      plugins: plugins,
      cms: cms,
    );
  }

  Future<List<String>> _subscriptionUrls() async {
    final prefs = await _preferences();
    return prefs.getStringList(idjSubscriptionsPrefsKey) ?? const [];
  }

  Future<void> _saveSubscriptionUrls(List<String> urls) async {
    final prefs = await _preferences();
    await prefs.setStringList(idjSubscriptionsPrefsKey, urls);
  }

  /// 订阅内容不持久化：每次打开 tab 时重拉；失败只记 error 不丢旧列表。
  Future<List<IdjSubscription>> loadSubscriptions() async {
    final urls = await _subscriptionUrls();
    final result = <IdjSubscription>[];
    for (final url in urls) {
      final uri = Uri.tryParse(url);
      if (uri == null) continue;
      try {
        final text = await downloadText(uri, maxBytes: 1024 * 1024);
        final decoded = jsonDecode(text);
        if (decoded is! Map) {
          throw AppFailure('订阅内容不是合法 JSON');
        }
        final subscription = parseSubscriptionJson(
          Map<String, dynamic>.from(decoded),
          uri,
        );
        _subscriptionCache[url] = subscription;
        result.add(subscription);
      } catch (error) {
        final cached = _subscriptionCache[url];
        if (cached != null) {
          final failed = cached.withError(error.toString());
          _subscriptionCache[url] = failed;
          result.add(failed);
        } else {
          final failed = IdjSubscription(
            url: url,
            name: '',
            plugins: const [],
            cms: const [],
            error: error.toString(),
          );
          _subscriptionCache[url] = failed;
          result.add(failed);
        }
      }
    }
    return result;
  }

  /// 逐个重拉（与 [loadSubscriptions] 同款：失败留旧列表记 error）。
  Future<List<IdjSubscription>> refreshSubscriptions() => loadSubscriptions();

  /// 添加订阅先拉取一次成功才保存（失败不保存地址）。
  Future<IdjSubscription> addSubscription(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) {
      throw AppFailure('这个地址不是合法的插件下载地址（只支持 HTTPS 公网地址）');
    }
    final text = await downloadText(uri, maxBytes: 1024 * 1024);
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw AppFailure('订阅内容不是合法 JSON');
    }
    if (decoded is! Map) {
      throw AppFailure('订阅内容不是合法 JSON');
    }
    final subscription = parseSubscriptionJson(
      Map<String, dynamic>.from(decoded),
      uri,
    );
    final urls = await _subscriptionUrls();
    if (!urls.contains(url.trim())) {
      await _saveSubscriptionUrls([...urls, url.trim()]);
    }
    _subscriptionCache[url.trim()] = subscription;
    return subscription;
  }

  /// 删除订阅只删地址，不卸载已装插件（已装插件独立存在）。
  Future<void> removeSubscription(String url) async {
    final urls = await _subscriptionUrls();
    await _saveSubscriptionUrls(urls.where((item) => item != url).toList());
    _subscriptionCache.remove(url);
  }

  /// 从订阅安装一个插件：按 `manifestUrl` 下载正文再分流
  ///（包 JSON 直接装；裸 manifest 从同目录下载脚本拼包再装）。
  Future<IdjInstalledPlugin> installFromSubscriptionPlugin(
    IdjSubscriptionPlugin plugin, {
    bool permissionConfirmed = false,
    IdjProbeFn? probe,
  }) async {
    if (plugin.manifest != null) {
      // 内联 manifest：没有脚本地址，无法拼包，明确报错。
      throw AppFailure('该订阅条目只有 manifest、没有插件包地址，无法安装');
    }
    if (plugin.manifestUrl.isEmpty) {
      throw AppFailure('该订阅条目没有插件地址，无法安装');
    }
    final uri = Uri.tryParse(plugin.manifestUrl);
    if (uri == null) {
      throw AppFailure('该订阅条目没有合法的插件地址，无法安装');
    }
    final text = await downloadText(uri, maxBytes: 2 * 1024 * 1024);
    final interpreted = await interpretText(text, baseUri: uri);
    if (interpreted.kind != IdjInterpretKind.bundle ||
        interpreted.bundleText == null) {
      throw AppFailure(interpreted.message);
    }
    return installBundleText(
      interpreted.bundleText!,
      sourceLabel: '订阅',
      permissionConfirmed: permissionConfirmed,
      probe: probe,
    );
  }

  // ---------- 更新检查 ----------

  /// 更新检查（设计 §4.5）：只对 manifest 写了 `update.url` 的插件
  /// 拉新 manifest 比 semver；手动触发，无定时自动刷新。
  /// 本案 4 个插件都没有 update.url，所以它们不会自动检查更新，
  /// 更新靠订阅里的版本号比对 + 作者发新版。
  Future<List<IdjUpdateCandidate>> checkUpdates() async {
    final index = await readIndex();
    final candidates = <IdjUpdateCandidate>[];
    for (final entry in index.values) {
      final manifest = await readInstalledManifest(entry.pluginId);
      if (manifest == null || manifest.updateUrl.isEmpty) continue;
      final uri = Uri.tryParse(manifest.updateUrl);
      if (uri == null) continue;
      try {
        final text = await downloadText(uri, maxBytes: 1024 * 1024);
        final decoded = jsonDecode(text);
        if (decoded is! Map) continue;
        final latest = IdjPluginManifest.fromJson(
          Map<String, dynamic>.from(decoded),
        );
        if (IdjPluginManifest.compareVersions(latest.version, entry.version) >
            0) {
          candidates.add(
            IdjUpdateCandidate(
              pluginId: entry.pluginId,
              currentVersion: entry.version,
              latestVersion: latest.version,
              manifest: latest,
            ),
          );
        }
      } catch (error) {
        debugPrint('idj 更新检查：${entry.pluginId} 拉取失败：$error');
        continue;
      }
    }
    return candidates;
  }
}

/// 插件变站点桥接：动态注册 / 注销 / 启用 / 停用 / 启动恢复。
class IdjPluginRegistry {
  IdjPluginRegistry._();

  /// 注册 / 注销后通知片库刷新（`LocalStore.refreshSiteRegistry()`）。
  /// 由 `main.dart` 在 LocalStore 建好后接线；未接线时只改登记表，
  /// 调用方（插件 tab）自己调刷新。测试可直接置这个回调断言刷新被调到。
  static void Function()? onRegistryChanged;

  /// 显示名加 🔞 前缀的插件 id（用户定的分区：潮流AV、2048AI，
  /// 2026-11-24 新增 PornTube、妻友社、HQPorner 三站）。
  /// 注意不是按 `manifest.adult` 判定——4 个 manifest 的 adult 全是
  /// true，按它推会把短剧站也判成人。
  static const Set<String> adultDisplayPluginIds = {
    'com.idj.ext.chaoliu',
    'com.idj.ext.ai2048',
    'com.idj.ext.porntube',
    'com.idj.ext.qiyoushe',
    'com.idj.ext.hqporner',
  };

  /// 短剧分区的插件 id（用户定的分区：橙果短剧、爱果短剧）。
  /// 注意：4 个真包的 manifest.type 全是 `video`，只按 type 推导会把
  /// 橙果 / 爱果也判进视频区；这两个站的短剧分区以用户定为准。
  /// 以后出现的新插件按 manifest.type 推导（shortdrama → 短剧区）。
  static const Set<String> shortDramaPluginIds = {
    'com.idj.ext.chengguo',
    'com.idj.ext.aiguo',
  };

  /// 站 key = `idj_` + manifest.id 末段（`idj_chengguo`、`idj_chaoliu`、
  /// `idj_aiguo`、`idj_ai2048`）；末段冲突加 `_2` / `_3`。
  /// `chaoliu` 已被 py 潮流站占用，绝不能用裸名。
  static String siteKeyForPluginId(String pluginId) {
    final short = pluginId.split('.').last;
    final base = 'idj_$short';
    var candidate = base;
    var suffix = 2;
    while (SourceSite.importedSites.containsKey(candidate) ||
        SourceSite.values.any((site) => site.id == candidate)) {
      candidate = '${base}_$suffix';
      suffix++;
    }
    return candidate;
  }

  static SourceSite siteForPlugin({
    required IdjPluginManifest manifest,
    required String siteKey,
  }) {
    final name = adultDisplayPluginIds.contains(manifest.id)
        ? '🔞${manifest.name}'
        : manifest.name;
    final section =
        shortDramaPluginIds.contains(manifest.id) ||
            manifest.type == 'shortdrama'
        ? SourceSite.sectionDrama
        : SourceSite.sectionVideo;
    return SourceSite(
      siteKey,
      name,
      manifest.description,
      section: section,
      origin: SourceSite.originImport,
      importType: 'js',
      importExt: manifest.id,
    );
  }

  /// 注册进 `SourceSite.importedSites[siteKey]`，绝不写
  /// `importedJsFiles`（idj 脚本不走 `_jsSpiderScript`，写了反而会被
  /// 当成普通 JS 蜘蛛文件误读）。注册后调刷新回调。
  static SourceSite registerPlugin({
    required IdjPluginManifest manifest,
    required String siteKey,
  }) {
    final site = siteForPlugin(manifest: manifest, siteKey: siteKey);
    SourceSite.importedSites[siteKey] = site;
    onRegistryChanged?.call();
    return site;
  }

  /// 注销：从 `importedSites` 移除 + 调刷新回调。
  static void unregisterSiteKey(String siteKey) {
    SourceSite.importedSites.remove(siteKey);
    onRegistryChanged?.call();
  }

  /// 启动恢复：读索引 → 逐个校验包文件存在且哈希未变 →
  /// 重登记 `enabled == true` 的插件；包文件缺失 / 损坏的跳过并记日志，
  /// 不拦启动。损坏的条目保留在索引里（列表里显示“已损坏”，可卸载 /
  /// 重装），不在这里删。
  static Future<List<IdjInstalledPlugin>> restoreAll({
    IdjPluginStore? store,
  }) async {
    final pluginStore = store ?? IdjPluginStore();
    final installed = await pluginStore.listInstalled();
    for (final item in installed) {
      if (!item.entry.enabled || item.damaged || item.manifest == null) {
        if (item.damaged) {
          debugPrint(
            'idj 启动恢复：跳过已损坏插件 ${item.entry.pluginId}（${item.damageReason}）',
          );
        }
        continue;
      }
      registerPlugin(manifest: item.manifest!, siteKey: item.entry.siteKey);
    }
    return installed;
  }
}
