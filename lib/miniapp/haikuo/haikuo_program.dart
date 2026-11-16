import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 规则自带 icon 是 data: URI 时解出图片字节；不是 data: 图片或
/// base64 解不出时返回 null（调用方回落 favicon/首字色块）。
Uint8List? haikuoDataIconBytes(String iconValue) {
  final text = iconValue.trim();
  if (!text.startsWith('data:image/')) return null;
  final comma = text.indexOf(',');
  if (comma < 0) return null;
  if (!text.substring(0, comma).contains(';base64')) return null;
  try {
    final bytes = base64Decode(text.substring(comma + 1).trim());
    return bytes.isEmpty ? null : bytes;
  } catch (_) {
    return null;
  }
}

/// 由规则的 host/入口链接推导站点 favicon 地址；推导不出返回 null。
///
/// 只认规则里真实出现的地址：host 字段优先，入口链接次之；
/// hiker://empty##https://站/... 这种嵌着真实地址的也认（取里面
/// 的第一个 http(s) 地址的 origin）；裸域名默认按 https 取 origin。
/// 推导不出或地址不是 http(s) 时返回 null，绝不编一个假地址。
String? haikuoFaviconUrl(HaikuoProgram program) {
  for (final candidate in [program.host, program.url]) {
    final origin = _haikuoOriginOf(candidate);
    if (origin != null) return '$origin/favicon.ico';
  }
  return null;
}

String? _haikuoOriginOf(String value) {
  final text = value.trim();
  if (text.isEmpty) return null;
  final embedded = RegExp(r'https?://[^\s#]+').firstMatch(text);
  final raw = embedded?.group(0) ?? text;
  var uri = Uri.tryParse(raw);
  if (uri == null) return null;
  if (uri.scheme.isEmpty && !raw.contains('://')) {
    uri = Uri.tryParse('https://$raw');
  }
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri.origin;
}

/// 海阔小程序条目类型。
///
/// - [script]：带 JS 主体（script/code/js 字段）的海阔小程序，可直接在运行时里执行。
/// - [rule]：只带规则/清单的结构（sites、data、rules…），按条目展示与打开。
/// - [link]：只带入口链接的条目（url/link），点击后按网页打开。
enum HaikuoKind { script, rule, link }

String haikuoKindLabel(HaikuoKind kind) => switch (kind) {
  HaikuoKind.script => '脚本',
  HaikuoKind.rule => '规则',
  HaikuoKind.link => '链接',
};

/// 一个海阔小程序。
class HaikuoProgram {
  const HaikuoProgram({
    required this.id,
    required this.name,
    this.author = '',
    this.version = '',
    this.icon = '',
    this.description = '',
    this.script = '',
    this.url = '',
    this.host = '',
    this.kind = HaikuoKind.script,
    this.origin = '',
    this.rawJson = '',
    this.entries = 0,
    this.importedAt,
    this.group = '',
    this.ruleType = '',
  });

  final String id;
  final String name;
  final String author;
  final String version;
  final String icon;
  final String description;

  /// 海阔小程序的 JS 主体（只有 [HaikuoKind.script] 才有）。
  final String script;

  /// 入口链接（[HaikuoKind.link] / [HaikuoKind.rule] 常用）。
  final String url;

  /// 规则自带的站点地址（host/homeUrl/baseUrl 字段），用于推导
  /// 站点 favicon；没有该字段的规则为空，瓦片回落首字色块。
  final String host;

  final HaikuoKind kind;

  /// 导入来源描述，例如「文件：xx.json」「口令」「链接」。
  final String origin;

  /// 原始 JSON 文本，便于导出与排错。
  final String rawJson;

  /// 规则类条目里发现的站点/条目数量。
  final int entries;

  final DateTime? importedAt;

  /// 规则自带的分组（数据库列 `group_lpcolumn` / JSON 键 `group`）。
  final String group;

  /// 规则自带的类型（`type` 键，如 video/live/read）。
  final String ruleType;

  bool get runnable => kind == HaikuoKind.script && script.trim().isNotEmpty;

  String get subtitle {
    final parts = <String>[
      if (group.isNotEmpty) group,
      if (author.isNotEmpty) author,
      if (version.isNotEmpty) 'v$version',
      if (!runnable && entries > 0) '$entries 条',
      haikuoKindLabel(kind),
    ];
    return parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'author': author,
    'version': version,
    'icon': icon,
    'description': description,
    'script': script,
    'url': url,
    'host': host,
    'kind': kind.name,
    'origin': origin,
    'raw': rawJson,
    'entries': entries,
    'importedAt': (importedAt ?? DateTime.now()).toIso8601String(),
    'group': group,
    'ruleType': ruleType,
  };

  static HaikuoProgram fromJson(Map<String, dynamic> json) {
    final kindName = '${json['kind'] ?? 'script'}';
    return HaikuoProgram(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? '未命名小程序'}',
      author: '${json['author'] ?? ''}',
      version: '${json['version'] ?? ''}',
      icon: '${json['icon'] ?? ''}',
      description: '${json['description'] ?? ''}',
      script: '${json['script'] ?? ''}',
      url: '${json['url'] ?? ''}',
      host: '${json['host'] ?? ''}',
      kind: HaikuoKind.values.firstWhere(
        (kind) => kind.name == kindName,
        orElse: () => HaikuoKind.script,
      ),
      origin: '${json['origin'] ?? ''}',
      rawJson: '${json['raw'] ?? ''}',
      entries: int.tryParse('${json['entries'] ?? 0}') ?? 0,
      importedAt: DateTime.tryParse('${json['importedAt'] ?? ''}'),
      group: '${json['group'] ?? ''}',
      ruleType: '${json['ruleType'] ?? ''}',
    );
  }

  /// 用名称 + 主体算稳定 id：同一个小程序重复导入只会覆盖，不会堆出一串重复项。
  static String makeId(String name, String body) {
    final digest = sha1.convert(utf8.encode('$name\u0000$body'));
    return digest.toString().substring(0, 16);
  }

  HaikuoProgram copyWith({
    String? id,
    String? name,
    String? origin,
    HaikuoKind? kind,
    int? entries,
  }) {
    return HaikuoProgram(
      id: id ?? this.id,
      name: name ?? this.name,
      author: author,
      version: version,
      icon: icon,
      description: description,
      script: script,
      url: url,
      host: host,
      kind: kind ?? this.kind,
      origin: origin ?? this.origin,
      rawJson: rawJson,
      entries: entries ?? this.entries,
      importedAt: importedAt ?? DateTime.now(),
      group: group,
      ruleType: ruleType,
    );
  }
}

/// 一次导入的结果。
class HaikuoImportResult {
  const HaikuoImportResult({
    required this.added,
    required this.updated,
    this.notes = const [],
    this.cancelled = false,
  });

  final List<HaikuoProgram> added;
  final List<HaikuoProgram> updated;
  final List<String> notes;

  /// 用户在重复提示里选了取消：整批导入未写入。
  final bool cancelled;

  int get total => added.length + updated.length;

  String get summary {
    if (cancelled) return '已取消导入';
    if (total == 0) return '没有新增条目';
    final parts = <String>[
      if (added.isNotEmpty) '新增 ${added.length} 个',
      if (updated.isNotEmpty) '更新 ${updated.length} 个',
    ];
    return parts.join('，');
  }
}

/// 导入时发现的同名重复：新条目与库里已有的同名条目内容不同
/// （所以 id 不同），旧逻辑会无提示地堆成两个同名条目。
class HaikuoDuplicate {
  const HaikuoDuplicate({required this.incoming, required this.existing});

  final HaikuoProgram incoming;
  final HaikuoProgram existing;
}

/// 用户对一批重复项的决定：替换旧的 / 保留两者（新条目改名 _2）/
/// 取消整批导入。
enum HaikuoDuplicateDecision { replace, keepBoth, cancel }

class HaikuoFormatException implements Exception {
  const HaikuoFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}
