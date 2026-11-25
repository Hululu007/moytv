import 'dart:io';

import 'package:sqflite/sqflite.dart';

/// 给内部工作库补的索引（大库上按 vod_id / 人物名查得动）。
/// 只 CREATE INDEX，不改任何一行数据。
const _videoDbIndexSql = <String>[
  'CREATE INDEX IF NOT EXISTS idx_va_vod ON video_actress(vod_id)',
  'CREATE INDEX IF NOT EXISTS idx_va_cate ON video_actress(cate_id)',
  'CREATE INDEX IF NOT EXISTS idx_vc_category ON video_category(main_category)',
  'CREATE INDEX IF NOT EXISTS idx_vt_tag ON video_tag(tag_name)',
  'CREATE INDEX IF NOT EXISTS idx_actresses_name ON actresses(name)',
  'CREATE INDEX IF NOT EXISTS idx_moyi_v_pubdate ON videos(vod_pubdate)',
  'CREATE INDEX IF NOT EXISTS idx_moyi_vc_vod ON video_category(vod_id)',
  'CREATE INDEX IF NOT EXISTS idx_moyi_v_play_from ON videos(vod_play_from)',
];

/// 给内部工作库补索引（2026-11-23 v58 验机：全球丽影库读
/// videos 太慢——合并库的 videos 表除主键外一个索引都没有，34 万行
/// 全表扫；补索引必须对工作库生效，不能只修主库）。
///
/// 只 CREATE INDEX，不改任何一行数据；表/列不存在、库只读、磁盘满时
/// 单条跳过，整体永不抛错。调用方在只读打开前顺手调一次即可
/// （unawaited，不堵首屏；建过一次后 IF NOT EXISTS 直接跳过）。
/// 返回建成的条数（0 也正常：已经建过、或这个库不是视频库结构）。
Future<int> ensureVideoDbIndexes(String filePath) async {
  Database? db;
  try {
    final file = File(filePath);
    if (!await file.exists()) return 0;
    db = await openDatabase(filePath, singleInstance: false);
    var built = 0;
    for (final sql in _videoDbIndexSql) {
      try {
        await db.execute(sql);
        built++;
      } catch (_) {
        // 表/列不存在（不是视频库结构）或库只读：跳过这条。
      }
    }
    return built;
  } catch (_) {
    return 0;
  } finally {
    try {
      await db?.close();
    } catch (_) {}
  }
}
