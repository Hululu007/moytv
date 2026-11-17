import 'dart:convert';
import 'dart:io';

import '../import_file_store.dart';
import '../imported_site_record.dart';
import '../local_store.dart';

/// HTML 站点的两条路线：单文件首页（Route A）与原站注入增强（Route B）。
/// 两条路线都经同一宿主页面、同一 fm 桥、同一播放链路。
enum HtmlSiteRoute { singleFile, injected }

/// 一条注入扩展（设计 §3.3 扩展模型 v1 子集：内联 code 与远程 js、
/// 三档 runAt；依赖排序、三级来源与管理界面是 v2）。
class HtmlExtension {
  const HtmlExtension({
    required this.id,
    required this.name,
    this.version = '',
    this.runAt = 'end',
    this.code = '',
    this.js = '',
    this.enabled = true,
  });

  final String id;
  final String name;
  final String version;
  final String runAt;
  final String code;
  final String js;
  final bool enabled;

  bool get hasCode => code.isNotEmpty || js.isNotEmpty;

  factory HtmlExtension.fromJson(Map<String, dynamic> json, {int index = 0}) {
    final rawRunAt = (json['runAt'] as String? ?? 'end').toLowerCase();
    return HtmlExtension(
      id: (json['id'] as String? ?? '').trim().isEmpty
          ? 'ext-$index'
          : (json['id'] as String).trim(),
      name: (json['name'] as String? ?? '').trim().isEmpty
          ? ((json['id'] as String? ?? '').trim().isEmpty
                ? 'ext-$index'
                : (json['id'] as String).trim())
          : (json['name'] as String).trim(),
      version: json['version']?.toString() ?? '',
      runAt: const {'start', 'end', 'idle'}.contains(rawRunAt) ? rawRunAt : 'end',
      code: json['code']?.toString() ?? '',
      js: json['js']?.toString() ?? '',
      enabled: json['enabled'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (version.isNotEmpty) 'version': version,
    'runAt': runAt,
    if (code.isNotEmpty) 'code': code,
    if (js.isNotEmpty) 'js': js,
    'enabled': enabled,
  };
}

/// Route B 站点清单：原站地址 + 扩展列表。
class HtmlSiteManifest {
  const HtmlSiteManifest({
    required this.name,
    required this.siteUrl,
    required this.extensions,
  });

  final String name;
  final String siteUrl;
  final List<HtmlExtension> extensions;

  /// 解析清单；字段缺失或非法时抛 FormatException（中文可读原因）。
  factory HtmlSiteManifest.parse(
    Map<String, dynamic> json, {
    String fallbackName = '',
  }) {
    final siteUrl = ((json['siteUrl'] ?? json['url'])?.toString() ?? '').trim();
    if (siteUrl.isEmpty ||
        !(siteUrl.startsWith('http://') || siteUrl.startsWith('https://'))) {
      throw const FormatException('清单缺少可用的 siteUrl（须为 http/https 地址）');
    }
    final name = (json['name']?.toString() ?? '').trim().isEmpty
        ? fallbackName
        : (json['name'] as String).trim();
    final extensions = <HtmlExtension>[];
    final rawList = json['extensions'];
    if (rawList is List) {
      var index = 0;
      for (final item in rawList) {
        if (item is Map<String, dynamic>) {
          final ext = HtmlExtension.fromJson(item, index: index);
          if (ext.hasCode) extensions.add(ext);
          index++;
        }
      }
    } else if (json['code'] != null || json['js'] != null) {
      // 单扩展简写：清单本身就是一条扩展。
      final ext = HtmlExtension.fromJson(json, index: 0);
      if (ext.hasCode) extensions.add(ext);
    }
    if (extensions.isEmpty) {
      throw const FormatException('清单里没有带 code/js 的扩展');
    }
    return HtmlSiteManifest(
      name: name,
      siteUrl: siteUrl,
      extensions: extensions,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'siteUrl': siteUrl,
    'extensions': [for (final ext in extensions) ext.toJson()],
  };
}

/// 一个 HTML 站点条目：宿主页面只认它，不直接读文件。
class HtmlSiteEntry {
  const HtmlSiteEntry({
    required this.siteKey,
    required this.siteName,
    required this.route,
    this.entryHtml = '',
    this.siteUrl = '',
    this.extensions = const [],
  });

  final String siteKey;
  final String siteName;
  final HtmlSiteRoute route;
  final String entryHtml;
  final String siteUrl;
  final List<HtmlExtension> extensions;

  bool get isSingleFile => route == HtmlSiteRoute.singleFile;

  HtmlSiteEntry copyWith({String? siteName}) => HtmlSiteEntry(
    siteKey: siteKey,
    siteName: siteName ?? this.siteName,
    route: route,
    entryHtml: entryHtml,
    siteUrl: siteUrl,
    extensions: extensions,
  );

  /// 按文件名分流：.json 走清单（Route B），其余走单文件 HTML（Route A）。
  /// 内容非法时抛 FormatException（中文可读原因）。
  /// [siteName] 非空时直接作站名（登记名优先）；为空时从内容推导
  /// （清单 name / HTML title / fallbackName / 文件名主干）。
  factory HtmlSiteEntry.fromFileContent({
    required String siteKey,
    required String fileName,
    required List<int> bytes,
    String siteName = '',
    String fallbackName = '',
  }) {
    if (bytes.isEmpty) throw const FormatException('文件为空');
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      throw const FormatException('文件不是有效的 UTF-8 文本');
    }
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    final stem = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.json')) {
      dynamic parsed;
      try {
        parsed = jsonDecode(text);
      } catch (error) {
        throw FormatException('JSON 解析失败：$error');
      }
      if (parsed is! Map<String, dynamic>) {
        throw const FormatException('清单须为 JSON 对象');
      }
      final manifest = HtmlSiteManifest.parse(
        parsed,
        fallbackName: fallbackName.isEmpty ? stem : fallbackName,
      );
      return HtmlSiteEntry(
        siteKey: siteKey,
        siteName: siteName.isEmpty ? manifest.name : siteName,
        route: HtmlSiteRoute.injected,
        siteUrl: manifest.siteUrl,
        extensions: manifest.extensions,
      );
    }
    if (text.trim().isEmpty) throw const FormatException('文件为空');
    final derived = siteName.isNotEmpty
        ? siteName
        : (() {
            final title = htmlTitleName(text);
            if (title.isNotEmpty) return title;
            return fallbackName.isEmpty ? stem : fallbackName;
          })();
    return HtmlSiteEntry(
      siteKey: siteKey,
      siteName: derived,
      route: HtmlSiteRoute.singleFile,
      entryHtml: text,
    );
  }
}

/// 从 HTML 文本头部取 <title> 作站名；取不到返回 ''。
String htmlTitleName(String text) {
  final head = text.length > 8192 ? text.substring(0, 8192) : text;
  final match = RegExp(
    r'<title[^>]*>(.*?)</title>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(head);
  if (match == null) return '';
  final title = match
      .group(1)!
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return title.length > 40 ? title.substring(0, 40) : title;
}

/// 从导入登记里按站 id 取回 HTML 站条目；不是 HTML 站、文件缺失、
/// 内容非法都返回 null（调用方报“站源打不开”，不抛异常）。
Future<HtmlSiteEntry?> loadHtmlSiteEntry(LocalStore store, String siteId) async {
  ImportedSiteRecord? record;
  for (final item in store.importedSiteRecords) {
    if (item.id == siteId) {
      record = item;
      break;
    }
  }
  if (record == null || record.type != ImportedSiteRecord.typeHtml) return null;
  try {
    final path = await ImportFileStore.pathOf(record.fileName);
    final bytes = await File(path).readAsBytes();
    return HtmlSiteEntry.fromFileContent(
      siteKey: record.id,
      fileName: record.fileName,
      bytes: bytes,
      siteName: record.name,
    );
  } catch (_) {
    return null;
  }
}
