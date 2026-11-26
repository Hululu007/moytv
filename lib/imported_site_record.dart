import 'models.dart';

class ImportedSiteRecord {
  const ImportedSiteRecord({
    required this.id,
    required this.name,
    required this.type,
    required this.fileName,
    required this.contentHash,
    this.enabled = true,
    this.importedAtMs = 0,
    this.ext = '',
    this.baseName = '',
  });

  final String id;
  final String name;
  final String type;
  final String fileName;
  final String contentHash;
  final bool enabled;
  final int importedAtMs;
  final String ext;

  /// 命名基准名：py/js 导入站是文件名（去路径、去后缀），与 jar 直导入
  /// 的 baseName 同义。同名组在站点列表按序号区分（单个不带号、多个
  /// 改 1/2/3、删后重排）靠它分组，[name] 是可能带序号的显示名。
  /// 旧登记没有这个字段时回落 [name] 本身（见 [effectiveBaseName]）。
  final String baseName;

  String get effectiveBaseName => baseName.isNotEmpty ? baseName : name;

  static const typePy = 'py';
  static const typeJs = 'js';
  static const typeHtml = 'html';

  /// TVBox 视频列表 JSON 导入站：登记类型是 jsonlist，执行走
  /// 生成的 py 蜘蛛（见 [json_list_import.dart]），故本地登记
  /// 与 _pySpiderPath 都按 py 通道处理。
  static const typeJsonList = 'jsonlist';

  ImportedSiteRecord copyWith({
    bool? enabled,
    String? name,
    String? ext,
    String? baseName,
  }) => ImportedSiteRecord(
    id: id,
    name: name ?? this.name,
    type: type,
    fileName: fileName,
    contentHash: contentHash,
    enabled: enabled ?? this.enabled,
    importedAtMs: importedAtMs,
    ext: ext ?? this.ext,
    baseName: baseName ?? this.baseName,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'fileName': fileName,
    'contentHash': contentHash,
    'enabled': enabled,
    'importedAtMs': importedAtMs,
    'ext': ext,
    'baseName': baseName,
  };

  factory ImportedSiteRecord.fromJson(Map<String, dynamic> json) =>
      ImportedSiteRecord(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        type: json['type'] as String? ?? '',
        fileName: json['fileName'] as String? ?? '',
        contentHash: json['contentHash'] as String? ?? '',
        enabled: json['enabled'] != false,
        importedAtMs: json['importedAtMs'] as int? ?? 0,
        ext: json['ext'] as String? ?? '',
        baseName: json['baseName'] as String? ?? '',
      );

  SourceSite get asSite => SourceSite(
    id,
    name,
    type == typePy
        ? 'Python 蜘蛛导入站'
        : type == typeHtml
        ? 'HTML 站源导入站'
        : type == typeJsonList
        ? 'JSON 列表导入站'
        : 'JS 蜘蛛导入站',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originImport,
    importType: type,
    importExt: ext,
  );
}

/// 同名导入站序号重排（与 jar 直导入 _renumberBase 同款口径）：
/// 按 [ImportedSiteRecord.effectiveBaseName] 分组，组内只有一条时
/// 显示名就是基准名本身（不带号）；多条时按列表顺序改成
/// 「基准名1、基准名2、…」。增删都经这里重算，所以删掉一条后
/// 其余自动重排、剩一条时自动回不带号的原名。无变化时原样返回
/// 入参列表（元素与列表都不新建），供单测与调用方判等。
List<ImportedSiteRecord> renumberImportedSiteRecords(
  List<ImportedSiteRecord> records,
) {
  final groups = <String, List<int>>{};
  for (var i = 0; i < records.length; i++) {
    groups.putIfAbsent(records[i].effectiveBaseName, () => []).add(i);
  }
  List<ImportedSiteRecord>? out;
  for (final entry in groups.entries) {
    final indexes = entry.value;
    final numbered = indexes.length > 1;
    for (var k = 0; k < indexes.length; k++) {
      final target = numbered ? '${entry.key}${k + 1}' : entry.key;
      final record = (out ?? records)[indexes[k]];
      if (record.name == target) continue;
      out ??= List<ImportedSiteRecord>.of(records);
      out[indexes[k]] = record.copyWith(name: target);
    }
  }
  return out ?? records;
}
