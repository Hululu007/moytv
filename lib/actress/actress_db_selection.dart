import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'actress_db_mirror.dart';
import 'actress_film_library.dart';
import 'actress_generic_db.dart';
import 'actress_mytv_bind.dart';
import 'actress_site_db.dart';

/// 女优库多库勾选：一个库选项（设置齿轮弹窗“数据库”区里一行）。
typedef ActressDbChoice = ({
  String name,
  String path,
  bool isMain,
  bool isSiteDb,
});

/// 勾选的数据库集合：存在 SharedPreferences，默认只勾主库
/// （MYTV/db/女优库.db）。存的是完整路径；主库路径变了（换绑）
/// 以后旧路径对不上就按默认只勾主库处理。
class ActressDbSelection {
  static const String keySelectedDbs = 'moyi_actress_selected_dbs';

  /// 已勾的库路径（默认只勾主库）。调用方传当前主库路径。
  static Future<Set<String>> loadSelectedPaths(String mainPath) async {
    final store = await SharedPreferences.getInstance();
    final saved = store.getStringList(keySelectedDbs);
    if (saved == null || saved.isEmpty) {
      return mainPath.isEmpty ? <String>{} : {mainPath};
    }
    final paths = saved.where((p) => p.isNotEmpty).toSet();
    if (mainPath.isNotEmpty) paths.add(mainPath);
    return paths;
  }

  static Future<void> saveSelectedPaths(Set<String> paths) async {
    final store = await SharedPreferences.getInstance();
    await store.setStringList(keySelectedDbs, paths.toList());
  }

  /// 可勾的库：主库 + MYTV/db 与补充目录里其它 .db（与镜像收集
  /// 同一套扫描，站点库.db 已在排除名单里所以扫不到，这里单独补
  /// 回来——默认不勾）。主库永远在第一位。
  static List<ActressDbChoice> availableChoices({
    required MytvBindResult bind,
  }) {
    final choices = <ActressDbChoice>[];
    final seen = <String>{};
    void addChoice(String filePath, {required bool isMain}) {
      final normalized = path.normalize(filePath);
      if (!seen.add(normalized)) return;
      final baseName = path.basename(filePath);
      choices.add((
        name: path.basenameWithoutExtension(filePath),
        path: filePath,
        isMain: isMain,
        isSiteDb: baseName == siteDbFileName,
      ));
    }

    if (bind.dbPath.isNotEmpty) {
      addChoice(bind.dbPath, isMain: true);
    }
    final extraDirs = bind.externalRoot == null
        ? const <Directory>[]
        : [
            for (final rel in sikuDbScanDirs)
              Directory(path.join(bind.externalRoot!.path, rel)),
          ];
    List<File> targets;
    try {
      targets = collectDbMirrorTargets(
        dbDir: bind.dbDir,
        libraryPath: bind.dbPath,
        extraDirs: extraDirs,
      );
    } catch (_) {
      targets = const [];
    }
    for (final file in targets) {
      addChoice(file.path, isMain: false);
    }
    // 站点库.db 不在镜像扫描里（已排除），单独补回来，默认不勾。
    final siteDbPath = path.join(bind.dbDir.path, siteDbFileName);
    if (File(siteDbPath).existsSync()) {
      addChoice(siteDbPath, isMain: false);
    }
    return choices;
  }

  /// 这个文件是不是女优库严格结构（videos/video_actress/
  /// video_category 三张表）：只读探一下，不写、不建索引。
  /// 不是的库不进列表合并（仍可当播放兜底，那是另一条路）。
  static Future<bool> isStrictVideoLibraryDbFile(String filePath) async {
    Database? db;
    try {
      final file = File(filePath);
      if (!file.existsSync() || file.lengthSync() == 0) return false;
      db = await openDatabase(filePath, readOnly: true);
      final schema = await probeGenericDbSchema(db);
      return filmIsStrictVideosSchema(schema);
    } catch (_) {
      return false;
    } finally {
      await db?.close();
    }
  }

  /// 该库的视频数（严格结构才数，失败/不是严格结构返回 -1，
  /// 界面不显示数字，只显示名字）。
  static Future<int> countVideos(String filePath) async {
    Database? db;
    try {
      final file = File(filePath);
      if (!file.existsSync() || file.lengthSync() == 0) return -1;
      db = await openDatabase(filePath, readOnly: true);
      final schema = await probeGenericDbSchema(db);
      if (!filmIsStrictVideosSchema(schema)) return -1;
      final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM videos');
      return (rows.first['c'] as num?)?.toInt() ?? -1;
    } catch (_) {
      return -1;
    } finally {
      await db?.close();
    }
  }
}
