import 'dart:io';

import 'package:sqflite/sqflite.dart';

/// 数据库管理页要看的当前库信息（作品/女优/地址数 + 文件大小 +
/// 备份情况）。只管演员库内部工作库这一个文件。
class ActressDbInfo {
  const ActressDbInfo({
    required this.exists,
    this.fileBytes = 0,
    this.videos = 0,
    this.actresses = 0,
    this.playUrls = 0,
    this.bakExists = false,
    this.bakBytes = 0,
    this.bakModified,
  });

  final bool exists;
  final int fileBytes;
  final int videos;
  final int actresses;
  final int playUrls;
  final bool bakExists;
  final int bakBytes;
  final DateTime? bakModified;
}

/// 读当前库信息：文件不存在就是空态（exists=false）。计数走一条
/// 只读连接现查；单表缺失按 0 算，不让管理页因为库结构不全打不开。
Future<ActressDbInfo> loadActressDbInfo(String dbPath) async {
  final file = File(dbPath);
  final bakFile = File('$dbPath.bak');
  final bakExists = await bakFile.exists();
  final bakBytes = bakExists ? await bakFile.length() : 0;
  final bakModified = bakExists ? await bakFile.lastModified() : null;
  if (!await file.exists() || await file.length() == 0) {
    return ActressDbInfo(
      exists: false,
      bakExists: bakExists,
      bakBytes: bakBytes,
      bakModified: bakModified,
    );
  }
  var videos = 0;
  var actresses = 0;
  var playUrls = 0;
  Database? db;
  try {
    db = await openDatabase(dbPath, readOnly: true, singleInstance: false);
    Future<int> countOf(String table) async {
      try {
        final rows = await db!.rawQuery('SELECT COUNT(*) AS c FROM "$table"');
        return (rows.first['c'] as num?)?.toInt() ?? 0;
      } catch (_) {
        return 0;
      }
    }

    videos = await countOf('videos');
    actresses = await countOf('actresses');
    playUrls = await countOf('video_play_urls');
  } catch (_) {
    // 库打不开（损坏等）：按文件存在处理，计数为 0，页面照常给出
    // 删除入口让用户能清掉坏库重导。
  } finally {
    try {
      await db?.close();
    } catch (_) {}
  }
  return ActressDbInfo(
    exists: true,
    fileBytes: await file.length(),
    videos: videos,
    actresses: actresses,
    playUrls: playUrls,
    bakExists: bakExists,
    bakBytes: bakBytes,
    bakModified: bakModified,
  );
}

/// 删工作库文件及其 sqlite 边文件（-wal/-shm/-journal）。
/// .bak 不在这里删——备份由管理页单独管。删不掉的文件忽略
/// （调用方关库后调，正常都能删掉）。
Future<void> deleteActressDbFiles(String dbPath) async {
  for (final suffix in const ['', '-wal', '-shm', '-journal']) {
    try {
      final file = File('$dbPath$suffix');
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// 恢复备份：把 .bak 拷回成当前库（备份文件保留不删）。
Future<void> restoreActressDbBackup(String dbPath) async {
  final bak = File('$dbPath.bak');
  if (!await bak.exists()) {
    throw StateError('备份文件不存在');
  }
  // 先删边文件，避免旧 -wal 把恢复的内容盖回去。
  for (final suffix in const ['-wal', '-shm', '-journal']) {
    try {
      final file = File('$dbPath$suffix');
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
  await bak.copy(dbPath);
}

/// 删备份文件。
Future<void> deleteActressDbBackup(String dbPath) async {
  final bak = File('$dbPath.bak');
  if (await bak.exists()) await bak.delete();
}

/// 人类可读文件大小。
String formatDbBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
