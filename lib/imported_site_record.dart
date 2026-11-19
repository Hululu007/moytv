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
  });

  final String id;
  final String name;
  final String type;
  final String fileName;
  final String contentHash;
  final bool enabled;
  final int importedAtMs;
  final String ext;

  static const typePy = 'py';
  static const typeJs = 'js';
  static const typeHtml = 'html';

  /// TVBox 视频列表 JSON 导入站：登记类型是 jsonlist，执行走
  /// 生成的 py 蜘蛛（见 [json_list_import.dart]），故本地登记
  /// 与 _pySpiderPath 都按 py 通道处理。
  static const typeJsonList = 'jsonlist';

  ImportedSiteRecord copyWith({bool? enabled, String? name, String? ext}) =>
      ImportedSiteRecord(
        id: id,
        name: name ?? this.name,
        type: type,
        fileName: fileName,
        contentHash: contentHash,
        enabled: enabled ?? this.enabled,
        importedAtMs: importedAtMs,
        ext: ext ?? this.ext,
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
