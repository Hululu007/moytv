import 'dart:convert';

import 'package:crypto/crypto.dart';

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
    this.kind = HaikuoKind.script,
    this.origin = '',
    this.rawJson = '',
    this.entries = 0,
    this.importedAt,
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

  final HaikuoKind kind;

  /// 导入来源描述，例如「文件：xx.json」「口令」「链接」。
  final String origin;

  /// 原始 JSON 文本，便于导出与排错。
  final String rawJson;

  /// 规则类条目里发现的站点/条目数量。
  final int entries;

  final DateTime? importedAt;

  bool get runnable => kind == HaikuoKind.script && script.trim().isNotEmpty;

  String get subtitle {
    final parts = <String>[
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
    'kind': kind.name,
    'origin': origin,
    'raw': rawJson,
    'entries': entries,
    'importedAt': (importedAt ?? DateTime.now()).toIso8601String(),
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
      kind: HaikuoKind.values.firstWhere(
        (kind) => kind.name == kindName,
        orElse: () => HaikuoKind.script,
      ),
      origin: '${json['origin'] ?? ''}',
      rawJson: '${json['raw'] ?? ''}',
      entries: int.tryParse('${json['entries'] ?? 0}') ?? 0,
      importedAt: DateTime.tryParse('${json['importedAt'] ?? ''}'),
    );
  }

  /// 用名称 + 主体算稳定 id：同一个小程序重复导入只会覆盖，不会堆出一串重复项。
  static String makeId(String name, String body) {
    final digest = sha1.convert(utf8.encode('$name\u0000$body'));
    return digest.toString().substring(0, 16);
  }

  HaikuoProgram copyWith({String? origin, HaikuoKind? kind, int? entries}) {
    return HaikuoProgram(
      id: id,
      name: name,
      author: author,
      version: version,
      icon: icon,
      description: description,
      script: script,
      url: url,
      kind: kind ?? this.kind,
      origin: origin ?? this.origin,
      rawJson: rawJson,
      entries: entries ?? this.entries,
      importedAt: importedAt ?? DateTime.now(),
    );
  }
}

/// 一次导入的结果。
class HaikuoImportResult {
  const HaikuoImportResult({
    required this.added,
    required this.updated,
    this.notes = const [],
  });

  final List<HaikuoProgram> added;
  final List<HaikuoProgram> updated;
  final List<String> notes;

  int get total => added.length + updated.length;

  String get summary {
    if (total == 0) return '没有新增条目';
    final parts = <String>[
      if (added.isNotEmpty) '新增 ${added.length} 个',
      if (updated.isNotEmpty) '更新 ${updated.length} 个',
    ];
    return parts.join('，');
  }
}

class HaikuoFormatException implements Exception {
  const HaikuoFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}
