import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 演员库最近一次 .sql 导入的元信息（来源文件名 + 时间 + 计数）。
///
/// 数据库管理页展示用。只记导入事件本身：没有记录就返回 null，
/// 页面显示「未知」，绝不编造。删除数据库时一并清掉（库没了，
/// 上次导入记录也不再算数）；恢复备份不清（导入事件仍是事实）。
class ActressDbImportMeta {
  const ActressDbImportMeta({
    required this.sourceName,
    required this.importedAtMillis,
    required this.videos,
    required this.actresses,
    required this.playUrls,
  });

  /// 来源文件名（只存文件名，不存完整路径）。
  final String sourceName;

  /// 导入完成时间（毫秒时间戳）。
  final int importedAtMillis;

  final int videos;
  final int actresses;
  final int playUrls;

  DateTime get importedAt =>
      DateTime.fromMillisecondsSinceEpoch(importedAtMillis);

  Map<String, Object?> toJson() => {
    'sourceName': sourceName,
    'importedAtMillis': importedAtMillis,
    'videos': videos,
    'actresses': actresses,
    'playUrls': playUrls,
  };

  static ActressDbImportMeta? fromJson(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, Object?>;
      return ActressDbImportMeta(
        sourceName: '${map['sourceName'] ?? ''}',
        importedAtMillis: (map['importedAtMillis'] as num?)?.toInt() ?? 0,
        videos: (map['videos'] as num?)?.toInt() ?? 0,
        actresses: (map['actresses'] as num?)?.toInt() ?? 0,
        playUrls: (map['playUrls'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

const _kMetaKey = 'actress_db_import_meta_v1';

/// 记一次成功导入（顶替生效后调）。
Future<void> saveActressDbImportMeta(ActressDbImportMeta meta) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMetaKey, jsonEncode(meta.toJson()));
  } catch (_) {
    // 记不下不拦任何功能：管理页显示「未知」即可。
  }
}

/// 读最近一次导入元信息；没记过返回 null。
Future<ActressDbImportMeta?> loadActressDbImportMeta() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return ActressDbImportMeta.fromJson(prefs.getString(_kMetaKey));
  } catch (_) {
    return null;
  }
}

/// 清元信息（删除数据库时调）。
Future<void> clearActressDbImportMeta() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kMetaKey);
  } catch (_) {}
}
