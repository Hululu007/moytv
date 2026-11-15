import 'dart:convert';

import 'package:archive/archive.dart';

import 'jar_zip.dart';
import 'legado_gbk.dart';
import 'live_parser.dart';
import 'miniapp/mini_app_manifest.dart';
import 'py_spider_validator.dart';

/// ZIP 内容检查：打开一个 zip 后先看里面有什么，按 影视源 / 直播列表 /
/// 组件 / 无法识别 分类，供选择器列出勾选。只做“识别”，不安装。
///
/// 识别规则全部复用树内已有的判定，不发明新格式：
/// - 影视源：.py（validatePySource 通过）与 .jar（zip 文件头），与
///   ImportEngine / expandPluginZip 同款；内嵌的 jar 包 zip 也算。
/// - 直播列表：.m3u/.m3u8/.txt 且 LiveParser 能解析出频道。
/// - 组件：.js（identifyJsSource 通过）、.json（XBPQ / TVBox 配置 /
///   自定义源，与 ImportEngine._importJson 同款判定）、小程序形态
///   （manifest.json 清单、内嵌小程序 zip、带 manifest 的文件夹）。
/// - 无法识别：其余一切，列出置灰，绝不硬装。
///
/// 目录、__MACOSX__ 与隐藏文件（expandPluginZip 同款）直接跳过，不列出。

enum ZipItemKind { videoSource, liveList, component, unknown }

/// 条目的安装通道：决定安装器把该条目交给哪套已有 machinery。
enum ZipInstallKind {
  /// 走 ImportEngine（py/jar/js/json/内嵌 jar 包 zip/整包 zip）。
  importEngine,

  /// 走 M3uSubscriptionService（m3u/txt 直播列表）。
  liveList,

  /// 走 MiniAppStore.installFromZipBytes（内嵌小程序 zip / 文件夹重打包）。
  miniappZip,

  /// 走 MiniAppStore.installFromManifestJson（单份 manifest.json）。
  miniappManifest,
}

class ZipPickItem {
  const ZipPickItem({
    required this.key,
    required this.name,
    required this.archivePath,
    required this.kind,
    required this.detail,
    required this.installKind,
    required this.installName,
    required this.bytes,
    this.unrecognizedReason = '',
  });

  /// 勾选状态的键：单文件取包内路径，分组/整包取合成键，全包内唯一。
  final String key;

  /// 显示名：平时取文件名，同名文件取包内完整路径（expandPluginZip 同款）。
  final String name;

  /// 包内路径（分组条目取 manifest 路径，整包条目取 zip 文件名）。
  final String archivePath;
  final ZipItemKind kind;

  /// 副标题：识别说明（频道数、形态名）或无法识别的原因。
  final String detail;
  final ZipInstallKind installKind;

  /// 安装时传给安装通道的文件名（带后缀，安装通道靠后缀分流）。
  final String installName;

  /// 安装用的字节：单文件取包内原字节，分组取重打包的 zip，整包取原 zip。
  final List<int> bytes;

  /// 无法识别的原因（kind 为 unknown 时非空）。
  final String unrecognizedReason;

  bool get installable => kind != ZipItemKind.unknown;
}

class ZipInspection {
  const ZipInspection({required this.zipName, required this.items});

  final String zipName;
  final List<ZipPickItem> items;

  List<ZipPickItem> itemsOf(ZipItemKind kind) =>
      [for (final item in items) if (item.kind == kind) item];

  int get installableCount =>
      items.where((item) => item.installable).length;

  bool get hasInstallable => installableCount > 0;
}

/// 勾选状态：默认全选可安装项；无法识别的条目永远选不中。
/// 安装器只收到 [selectedItems]，不勾选的绝不安装。
class ZipPickSelection {
  ZipPickSelection({Set<String>? selectedKeys})
    : _selected = {...?selectedKeys};

  factory ZipPickSelection.allInstallable(Iterable<ZipPickItem> items) =>
      ZipPickSelection(
        selectedKeys: {
          for (final item in items)
            if (item.installable) item.key,
        },
      );

  final Set<String> _selected;

  bool isSelected(ZipPickItem item) =>
      item.installable && _selected.contains(item.key);

  void toggle(ZipPickItem item) {
    if (!item.installable) return;
    if (!_selected.remove(item.key)) _selected.add(item.key);
  }

  void setSelected(ZipPickItem item, bool value) {
    if (!item.installable) return;
    if (value) {
      _selected.add(item.key);
    } else {
      _selected.remove(item.key);
    }
  }

  /// 整类全选/全不选（只影响该类里可安装的条目）。
  void selectKind(Iterable<ZipPickItem> items, ZipItemKind kind, bool value) {
    for (final item in items) {
      if (item.kind == kind) setSelected(item, value);
    }
  }

  bool allSelected(Iterable<ZipPickItem> items) {
    var any = false;
    for (final item in items) {
      if (!item.installable) continue;
      any = true;
      if (!_selected.contains(item.key)) return false;
    }
    return any;
  }

  int selectedCount(Iterable<ZipPickItem> items) =>
      items.where(isSelected).length;

  List<ZipPickItem> selectedItems(Iterable<ZipPickItem> items) =>
      [for (final item in items) if (isSelected(item)) item];
}

class _RawEntry {
  _RawEntry(this.path, this.bytes);

  final String path;
  final List<int> bytes;

  String get baseName => path.split('/').last;

  String get extension {
    final dot = baseName.lastIndexOf('.');
    return dot < 0 ? '' : baseName.substring(dot + 1).toLowerCase();
  }

  String get directory {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? '' : path.substring(0, slash + 1);
  }
}

class _Classified {
  _Classified(this.entry, this.item);

  final _RawEntry entry;
  final ZipPickItem item;
}

String _decodeText(List<int> bytes) {
  try {
    final text = utf8.decode(bytes);
    return text.startsWith('\uFEFF') ? text.substring(1) : text;
  } catch (_) {
    final text = decodeGbkBytes(bytes);
    return text.startsWith('\uFEFF') ? text.substring(1) : text;
  }
}

bool _isXbpqRule(Map<String, dynamic> parsed) =>
    parsed.containsKey('主页url') ||
    (parsed.containsKey('分类url') && parsed.containsKey('数组')) ||
    (parsed.containsKey('分类') && parsed.containsKey('数组'));

bool _isTvBoxConfig(Map<String, dynamic> parsed) =>
    parsed.containsKey('sites') || parsed.containsKey('spider');

bool _isCustomSources(dynamic parsed) =>
    parsed is List ||
    (parsed is Map<String, dynamic> &&
        (parsed['sources'] is List || parsed['items'] is List));

MiniAppManifest? _validManifest(List<int> bytes) {
  try {
    final decoded = jsonDecode(_decodeText(bytes));
    if (decoded is! Map<String, dynamic>) return null;
    final manifest = MiniAppManifest.fromJson(decoded);
    return manifest.isValid ? manifest : null;
  } catch (_) {
    return null;
  }
}

ZipPickItem _unknown(_RawEntry entry, String reason) => ZipPickItem(
  key: entry.path,
  name: entry.baseName,
  archivePath: entry.path,
  kind: ZipItemKind.unknown,
  detail: reason,
  installKind: ZipInstallKind.importEngine,
  installName: entry.baseName,
  bytes: const [],
  unrecognizedReason: reason,
);

ZipPickItem _classifySingle(_RawEntry entry) {
  final bytes = entry.bytes;
  switch (entry.extension) {
    case 'jar':
      if (bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
        return ZipPickItem(
          key: entry.path,
          name: entry.baseName,
          archivePath: entry.path,
          kind: ZipItemKind.videoSource,
          detail: 'jar 插件',
          installKind: ZipInstallKind.importEngine,
          installName: entry.baseName,
          bytes: bytes,
        );
      }
      return _unknown(entry, '不是有效的 jar 文件（缺少 zip 文件头）');
    case 'py':
      final validation = validatePySource(_decodeText(bytes));
      if (validation.ok) {
        return ZipPickItem(
          key: entry.path,
          name: entry.baseName,
          archivePath: entry.path,
          kind: ZipItemKind.videoSource,
          detail: validation.playOnly ? 'py 蜘蛛 · 仅播放模式' : 'py 蜘蛛',
          installKind: ZipInstallKind.importEngine,
          installName: entry.baseName,
          bytes: bytes,
        );
      }
      return _unknown(entry, validation.message);
    case 'js':
      final problem = identifyJsSource(_decodeText(bytes));
      if (problem == null) {
        return ZipPickItem(
          key: entry.path,
          name: entry.baseName,
          archivePath: entry.path,
          kind: ZipItemKind.component,
          detail: 'JS 蜘蛛',
          installKind: ZipInstallKind.importEngine,
          installName: entry.baseName,
          bytes: bytes,
        );
      }
      return _unknown(entry, problem);
    case 'json':
      return _classifyJson(entry);
    case 'm3u':
    case 'm3u8':
    case 'txt':
      final parsed = LiveParser.parse(
        _decodeText(bytes),
        source: 'zip:${entry.path}',
      );
      if (parsed.channelCount > 0) {
        return ZipPickItem(
          key: entry.path,
          name: entry.baseName,
          archivePath: entry.path,
          kind: ZipItemKind.liveList,
          detail: '${parsed.channelCount} 个频道 · ${parsed.groups.length} 个分类',
          installKind: ZipInstallKind.liveList,
          installName: entry.baseName,
          bytes: bytes,
        );
      }
      return _unknown(entry, '未解析到任何频道');
    case 'zip':
      return _classifyNestedZip(entry);
    default:
      return _unknown(entry, '不支持的文件类型');
  }
}

ZipPickItem _classifyJson(_RawEntry entry) {
  final manifest = _validManifest(entry.bytes);
  if (manifest != null) {
    return ZipPickItem(
      key: entry.path,
      name: entry.baseName,
      archivePath: entry.path,
      kind: ZipItemKind.component,
      detail: '小程序清单「${manifest.name}」',
      installKind: ZipInstallKind.miniappManifest,
      installName: entry.baseName,
      bytes: entry.bytes,
    );
  }
  dynamic parsed;
  try {
    parsed = jsonDecode(_decodeText(entry.bytes));
  } catch (error) {
    return _unknown(entry, 'JSON 解析失败：$error');
  }
  if (parsed is Map<String, dynamic>) {
    if (_isXbpqRule(parsed)) {
      return ZipPickItem(
        key: entry.path,
        name: entry.baseName,
        archivePath: entry.path,
        kind: ZipItemKind.component,
        detail: 'XBPQ 规则',
        installKind: ZipInstallKind.importEngine,
        installName: entry.baseName,
        bytes: entry.bytes,
      );
    }
    if (_isTvBoxConfig(parsed)) {
      return ZipPickItem(
        key: entry.path,
        name: entry.baseName,
        archivePath: entry.path,
        kind: ZipItemKind.component,
        detail: 'TVBox 配置',
        installKind: ZipInstallKind.importEngine,
        installName: entry.baseName,
        bytes: entry.bytes,
      );
    }
  }
  if (_isCustomSources(parsed)) {
    return ZipPickItem(
      key: entry.path,
      name: entry.baseName,
      archivePath: entry.path,
      kind: ZipItemKind.component,
      detail: '自定义源',
      installKind: ZipInstallKind.importEngine,
      installName: entry.baseName,
      bytes: entry.bytes,
    );
  }
  // 只符合 jar 站点配置形态的 JSON 不能单独装：ImportEngine 不认，
  // 它只在 jar 整包里才有意义，单列时如实标无法识别。
  return _unknown(entry, '无法识别的 JSON（不是 XBPQ / TVBox / 自定义源 / 小程序清单）');
}

ZipPickItem _classifyNestedZip(_RawEntry entry) {
  if (!isZipBytes(entry.bytes)) {
    return _unknown(entry, '不是有效的 zip 包');
  }
  Archive nested;
  try {
    nested = ZipDecoder().decodeBytes(entry.bytes);
  } catch (error) {
    return _unknown(entry, 'zip 解包失败：$error');
  }
  for (final file in nested.files) {
    if (!file.isFile) continue;
    final name = file.name.replaceAll('\\', '/');
    if (name == 'manifest.json' || name.endsWith('/manifest.json')) {
      final manifest = _validManifest(List<int>.from(file.content as List<int>));
      if (manifest != null) {
        return ZipPickItem(
          key: entry.path,
          name: entry.baseName,
          archivePath: entry.path,
          kind: ZipItemKind.component,
          detail: '小程序安装包「${manifest.name}」',
          installKind: ZipInstallKind.miniappZip,
          installName: entry.baseName,
          bytes: entry.bytes,
        );
      }
    }
  }
  try {
    decodeJarZipPackage(entry.bytes);
  } catch (_) {
    return _unknown(entry, 'zip 里没有可识别的内容（没有小程序清单，也没有 jar）');
  }
  return ZipPickItem(
    key: entry.path,
    name: entry.baseName,
    archivePath: entry.path,
    kind: ZipItemKind.videoSource,
    detail: 'jar 包（zip）',
    installKind: ZipInstallKind.importEngine,
    installName: entry.baseName,
    bytes: entry.bytes,
  );
}

/// 把带 manifest 的文件夹折成一个小程序条目：manifest 所在目录下
/// 未被单独识别的文件（html/css/图片等）随 manifest 一起重打包安装，
/// 已被单独识别的影视源/直播/组件条目不卷入，仍各装各的。
/// 最深的目录先折，避免根目录的 manifest 把子目录的包卷走。
List<_Classified> _foldMiniAppFolders(List<_Classified> classified) {
  final remaining = List<_Classified>.of(classified);
  final groups = <ZipPickItem>[];
  final manifests = [
    for (final item in classified)
      if (item.item.installKind == ZipInstallKind.miniappManifest) item,
  ]..sort((a, b) => b.entry.directory.length.compareTo(a.entry.directory.length));
  for (final manifest in manifests) {
    if (!remaining.contains(manifest)) continue;
    final prefix = manifest.entry.directory;
    final siblings = [
      for (final item in remaining)
        if (item != manifest &&
            item.entry.path.startsWith(prefix) &&
            item.item.kind == ZipItemKind.unknown)
          item,
    ];
    if (siblings.isEmpty) continue;
    final manifestData = _validManifest(manifest.entry.bytes);
    final members = [manifest, ...siblings];
    final archive = Archive();
    for (final member in members) {
      final relative = prefix.isEmpty
          ? member.entry.path
          : member.entry.path.substring(prefix.length);
      if (relative.isEmpty) continue;
      archive.addFile(
        ArchiveFile(relative, member.entry.bytes.length, member.entry.bytes),
      );
    }
    final appName = manifestData?.name ?? manifest.entry.baseName;
    groups.add(
      ZipPickItem(
        key: 'group:${manifest.entry.path}',
        name: appName,
        archivePath: manifest.entry.path,
        kind: ZipItemKind.component,
        detail: '小程序 · ${members.length} 个文件',
        installKind: ZipInstallKind.miniappZip,
        installName: '$appName.zip',
        bytes: ZipEncoder().encode(archive),
      ),
    );
    remaining.removeWhere(members.contains);
  }
  return [...remaining, for (final group in groups) _Classified(_RawEntry(group.archivePath, group.bytes), group)];
}

List<ZipPickItem> _resolveDisplayNames(List<ZipPickItem> items) {
  final baseCounts = <String, int>{};
  for (final item in items) {
    if (item.key.startsWith('group:')) continue;
    baseCounts[item.name] = (baseCounts[item.name] ?? 0) + 1;
  }
  final groupNameCounts = <String, int>{};
  for (final item in items) {
    if (!item.key.startsWith('group:')) continue;
    groupNameCounts[item.name] = (groupNameCounts[item.name] ?? 0) + 1;
  }
  return [
    for (final item in items)
      if (item.key.startsWith('group:') &&
          (groupNameCounts[item.name] ?? 0) > 1)
        ZipPickItem(
          key: item.key,
          name: '${item.name}（${item.archivePath}）',
          archivePath: item.archivePath,
          kind: item.kind,
          detail: item.detail,
          installKind: item.installKind,
          installName: item.installName,
          bytes: item.bytes,
        )
      else if (!item.key.startsWith('group:') &&
          (baseCounts[item.name] ?? 0) > 1)
        ZipPickItem(
          key: item.key,
          name: item.archivePath,
          archivePath: item.archivePath,
          kind: item.kind,
          detail: item.detail,
          installKind: item.installKind,
          installName: item.installName,
          bytes: item.bytes,
          unrecognizedReason: item.unrecognizedReason,
        )
      else
        item,
  ];
}

int _kindOrder(ZipItemKind kind) {
  switch (kind) {
    case ZipItemKind.videoSource:
      return 0;
    case ZipItemKind.liveList:
      return 1;
    case ZipItemKind.component:
      return 2;
    case ZipItemKind.unknown:
      return 3;
  }
}

/// 检查 zip 内容并分类。不是 zip 或解包失败时抛 FormatException，
/// 调用方报“解包失败”，与 expandPluginZip 同款。
ZipInspection inspectZipBytes(List<int> bytes, {required String zipName}) {
  if (!isZipBytes(bytes)) {
    throw const FormatException('不是有效的 zip 包（缺少 zip 文件头）');
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (error) {
    throw FormatException('zip 包解包失败：$error');
  }
  final entries = <_RawEntry>[];
  for (final file in archive.files) {
    if (!file.isFile) continue;
    if (file.name.contains('__MACOSX__')) continue;
    final base = file.name.split('/').last;
    if (base.isEmpty || base.startsWith('.')) continue;
    entries.add(_RawEntry(file.name, List<int>.from(file.content as List<int>)));
  }
  var classified = [
    for (final entry in entries) _Classified(entry, _classifySingle(entry)),
  ];
  classified = _foldMiniAppFolders(classified);
  var items = _resolveDisplayNames([
    for (final entry in classified) entry.item,
  ]);
  items.sort((a, b) {
    final order = _kindOrder(a.kind).compareTo(_kindOrder(b.kind));
    return order != 0
        ? order
        : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });

  // 单 jar 整包：与上一批同款语义——包里只有一个 jar、没有 py /
  // 直播 / JS / 小程序内容时，整包走既有 zip 包路径（包内配置 JSON
  // 与附加文件一并带上），选择器只列一条“整包”，不把 jar 与配置
  // 拆开装。JSON 组件（jar 配置常是 sites 形态）与未知文件都折进包里；
  // 一旦包里还有别的可装内容，就拆开列，让用户逐个勾选。
  bool foldsIntoPackage(ZipPickItem item) {
    if (!item.installable) return true;
    return item.kind == ZipItemKind.component &&
        item.installKind == ZipInstallKind.importEngine &&
        item.installName.toLowerCase().endsWith('.json');
  }

  final core = [
    for (final item in items) if (!foldsIntoPackage(item)) item,
  ];
  if (core.length == 1 &&
      core.first.kind == ZipItemKind.videoSource &&
      core.first.installName.toLowerCase().endsWith('.jar')) {
    final extras = items.length - 1;
    return ZipInspection(
      zipName: zipName,
      items: [
        ZipPickItem(
          key: 'package:$zipName',
          name: zipName,
          archivePath: zipName,
          kind: ZipItemKind.videoSource,
          detail: extras > 0 ? 'jar 包整体安装 · 含 $extras 个附加文件' : 'jar 包整体安装',
          installKind: ZipInstallKind.importEngine,
          installName: zipName,
          bytes: List<int>.from(bytes),
        ),
      ],
    );
  }
  return ZipInspection(zipName: zipName, items: items);
}
