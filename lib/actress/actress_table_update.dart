import 'package:sqflite/sqflite.dart';

import 'actress_json_fallback.dart' show normalizeActressJsonName;
import 'actress_spreadsheet.dart';
import 'actress_sql_import.dart' show ActressSqlImportCancelled;

/// 表格导入更新的存储层：引擎只认这组行级操作，生产用 sqflite
/// 实现，测试用内存假实现（flutter test 里 sqflite 打不开真库，
/// 与导入器的 SqlImportExecutor 同款分工）。
abstract class ActressTableStore {
  /// 整段更新在一个事务里跑：body 抛任何错都整体回滚。
  Future<T> transaction<T>(
    Future<T> Function(ActressTableStore tx) body,
  );

  /// 按番号查作品行（videos 表子集），没有返回 null。
  Future<Map<String, Object?>?> findWork(String code);

  Future<void> insertWork(Map<String, Object?> values);

  Future<void> updateWork(String code, Map<String, Object?> values);

  /// 整表替换某作品的播放地址（video_play_urls 先删后插）。
  Future<void> replacePlayUrls(
    String code,
    List<String> urls,
    String playFrom,
  );

  /// 某作品现有的来源标记（第一条地址的 play_from），没有回 ''。
  Future<String> playFromOf(String code);

  /// 写分类（video_category upsert）。
  Future<void> setCategory(String code, String category);

  /// 加标签（video_tag，已有不重复）。
  Future<void> addTag(String code, String tag);

  /// 按人名找女优主键：先精确匹配 cate_id、再 name、最后按
  /// [normalizeActressJsonName] 归一化口径扫（与影视库按名匹配
  /// 同一口径）。找不到返回 null。
  Future<String?> findActressCateId(String name);

  Future<void> insertActress(String cateId, String name, String avatar);

  Future<void> updateActressAvatar(String cateId, String avatar);

  /// 关联作品与女优（已有不重复）。
  Future<void> linkActress(String code, String cateId);
}

/// 表格导入更新结果（管理页汇总展示用）。
class ActressTableUpdateResult {
  const ActressTableUpdateResult({
    required this.ok,
    this.error,
    this.totalRows = 0,
    this.added = 0,
    this.updated = 0,
    this.skipped = 0,
    this.skipReasons = const {},
  });

  final bool ok;
  final String? error;
  final int totalRows;
  final int added;
  final int updated;
  final int skipped;

  /// 跳过原因 → 行数（如 缺番号 / 没有可更新的内容）。
  final Map<String, int> skipReasons;

  String get summary {
    if (!ok) return '更新失败：${error ?? '未知原因'}';
    final reasons = skipReasons.entries
        .map((e) => '${e.key} ${e.value} 行')
        .join('、');
    return '新增 $added 部 · 更新 $updated 部 · 跳过 $skipped 行'
        '${reasons.isEmpty ? '' : '（$reasons）'}';
  }
}

/// 表格导入更新引擎（2026-11-25 用户令：「数据库要支持表格
/// 导入更新数据库」）。
///
/// 语义是「更新」不是「替换」：以番号对齐——库里有就按行更新、
/// 没有就新增；表格里没出现的作品一律不动。细则：
/// - 单元格为空的字段不覆盖原值（空不算更新）；
/// - 播放地址列非空 → 整表替换该作品的地址（videos 的
///   m3u8_url/vod_play_url 两列同步第一条，播放链读这两列）；
/// - 分类非空 → video_category 与 videos.type_name 同步写
///   （与 .sql 归一化时分类同写两处的口径一致）；
/// - 女优列的人名自动建人/关联（只加不删）；带女优头像列时
///   更新这些女优的头像；只有头像没有人名时无处落，忽略；
/// - 标签只加不删；
/// - 整个更新一个事务：中途失败/取消整体回滚，旧库完好。
class ActressTableUpdater {
  const ActressTableUpdater();

  Future<ActressTableUpdateResult> apply({
    required ActressTableStore store,
    required List<SpreadsheetWorkRow> rows,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    var added = 0;
    var updated = 0;
    var skipped = 0;
    final skipReasons = <String, int>{};
    void skip(String reason) {
      skipped++;
      skipReasons[reason] = (skipReasons[reason] ?? 0) + 1;
    }

    try {
      await store.transaction((tx) async {
        var done = 0;
        for (final row in rows) {
          if (isCancelled != null && isCancelled()) {
            throw ActressSqlImportCancelled();
          }
          done++;
          if (done % 50 == 0 || done == rows.length) {
            onProgress?.call(done, rows.length);
          }
          if (row.code.isEmpty) {
            skip('缺番号');
            continue;
          }
          final hasContent =
              row.title != null ||
              row.cover != null ||
              row.category != null ||
              row.playUrls.isNotEmpty ||
              row.actresses.isNotEmpty ||
              row.tags.isNotEmpty;
          final existing = await tx.findWork(row.code);
          // 库里 vod_id 是小写形（如 ssis-001），表格里常写大写：
          // 已有行以库里实际 vod_id 为准，新行统一小写落库，
          // 免得同番号因大小写插成两行（findWork 已带 NOCASE）。
          final code =
              (existing?['vod_id'] as String?) ??
              row.code.trim().toLowerCase();
          if (existing == null) {
            if (!hasContent) {
              skip('只有番号、没有可写入的内容');
              continue;
            }
            final firstUrl = row.playUrls.firstOrNull ?? '';
            await tx.insertWork({
              'vod_id': code,
              'title': row.title ?? row.code,
              'pic_url': row.cover ?? '',
              'm3u8_url': firstUrl,
              'vod_play_url': firstUrl,
              'vod_play_from': '',
              'type_name': row.category ?? '',
            });
            if (row.playUrls.isNotEmpty) {
              await tx.replacePlayUrls(code, row.playUrls, '');
            }
            if (row.category != null) {
              await tx.setCategory(code, row.category!);
            }
            added++;
          } else {
            if (!hasContent) {
              skip('没有可更新的内容');
              continue;
            }
            final updates = <String, Object?>{};
            if (row.title != null) updates['title'] = row.title;
            if (row.cover != null) updates['pic_url'] = row.cover;
            if (row.category != null) {
              updates['type_name'] = row.category;
            }
            if (row.playUrls.isNotEmpty) {
              updates['m3u8_url'] = row.playUrls.first;
              updates['vod_play_url'] = row.playUrls.first;
            }
            if (updates.isNotEmpty) {
              await tx.updateWork(code, updates);
            }
            if (row.playUrls.isNotEmpty) {
              final playFrom = await tx.playFromOf(code);
              await tx.replacePlayUrls(code, row.playUrls, playFrom);
            }
            if (row.category != null) {
              await tx.setCategory(code, row.category!);
            }
            updated++;
          }
          // 女优：建人/关联（只加不删），头像随行更新。
          for (final name in row.actresses) {
            var cateId = await tx.findActressCateId(name);
            if (cateId == null) {
              await tx.insertActress(name, name, row.actressAvatar ?? '');
              cateId = name;
            } else if (row.actressAvatar != null) {
              await tx.updateActressAvatar(cateId, row.actressAvatar!);
            }
            await tx.linkActress(code, cateId);
          }
          for (final tag in row.tags) {
            await tx.addTag(code, tag);
          }
        }
      });
    } on ActressSqlImportCancelled {
      return const ActressTableUpdateResult(
        ok: false,
        error: '已取消，数据库未改动',
      );
    } catch (e) {
      return ActressTableUpdateResult(
        ok: false,
        error: e.toString().split('\n').first,
      );
    }
    return ActressTableUpdateResult(
      ok: true,
      totalRows: rows.length,
      added: added,
      updated: updated,
      skipped: skipped,
      skipReasons: skipReasons,
    );
  }
}

/// sqflite 实现：打开的是内部工作库（读写连接）。
class SqfliteActressTableStore implements ActressTableStore {
  SqfliteActressTableStore(this._executor);

  final DatabaseExecutor _executor;

  /// 从库文件路径打开（表格更新入口用，用完 [close]）。
  static Future<SqfliteActressTableStore> openPath(String dbPath) async {
    final db = await openDatabase(dbPath, singleInstance: false);
    return SqfliteActressTableStore(db);
  }

  Future<void> close() async {
    final executor = _executor;
    if (executor is Database) await executor.close();
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(ActressTableStore tx) body,
  ) async {
    final executor = _executor;
    if (executor is Database) {
      return executor.transaction(
        (txn) => body(SqfliteActressTableStore(txn)),
      );
    }
    // 已经在事务里（嵌套调用）：直接跑。
    return body(this);
  }

  @override
  Future<Map<String, Object?>?> findWork(String code) async {
    final rows = await _executor.query(
      'videos',
      columns: ['vod_id', 'title', 'pic_url', 'type_name'],
      where: 'vod_id = ? COLLATE NOCASE',
      whereArgs: [code],
      limit: 1,
    );
    return rows.firstOrNull;
  }

  @override
  Future<void> insertWork(Map<String, Object?> values) =>
      _executor.insert('videos', values);

  @override
  Future<void> updateWork(String code, Map<String, Object?> values) =>
      _executor.update(
        'videos',
        values,
        where: 'vod_id = ?',
        whereArgs: [code],
      );

  @override
  Future<void> replacePlayUrls(
    String code,
    List<String> urls,
    String playFrom,
  ) async {
    await _executor.delete(
      'video_play_urls',
      where: 'vod_id = ?',
      whereArgs: [code],
    );
    for (final url in urls) {
      await _executor.insert('video_play_urls', {
        'vod_id': code,
        'play_url': url,
        'play_from': playFrom,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  @override
  Future<String> playFromOf(String code) async {
    final rows = await _executor.query(
      'video_play_urls',
      columns: ['play_from'],
      where: 'vod_id = ? COLLATE NOCASE',
      whereArgs: [code],
      limit: 1,
    );
    if (rows.isEmpty) return '';
    return rows.first['play_from']?.toString() ?? '';
  }

  @override
  Future<void> setCategory(String code, String category) async {
    await _executor.insert('video_category', {
      'vod_id': code,
      'main_category': category,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> addTag(String code, String tag) async {
    await _executor.insert('video_tag', {
      'vod_id': code,
      'tag_name': tag,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  @override
  Future<String?> findActressCateId(String name) async {
    final byId = await _executor.query(
      'actresses',
      columns: ['cate_id'],
      where: 'cate_id = ?',
      whereArgs: [name],
      limit: 1,
    );
    if (byId.isNotEmpty) return byId.first['cate_id']?.toString();
    final byName = await _executor.query(
      'actresses',
      columns: ['cate_id'],
      where: 'name = ?',
      whereArgs: [name],
      limit: 1,
    );
    if (byName.isNotEmpty) return byName.first['cate_id']?.toString();
    final key = normalizeActressJsonName(name);
    if (key.isEmpty) return null;
    final all = await _executor.query('actresses', columns: ['cate_id', 'name']);
    for (final row in all) {
      final cateId = row['cate_id']?.toString() ?? '';
      final displayName = row['name']?.toString() ?? '';
      if (normalizeActressJsonName(cateId) == key ||
          normalizeActressJsonName(displayName) == key) {
        return cateId;
      }
    }
    return null;
  }

  @override
  Future<void> insertActress(
    String cateId,
    String name,
    String avatar,
  ) async {
    await _executor.insert('actresses', {
      'cate_id': cateId,
      'name': name,
      'avatar': avatar,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  @override
  Future<void> updateActressAvatar(String cateId, String avatar) =>
      _executor.update(
        'actresses',
        {'avatar': avatar},
        where: 'cate_id = ?',
        whereArgs: [cateId],
      );

  @override
  Future<void> linkActress(String code, String cateId) async {
    await _executor.insert('video_actress', {
      'vod_id': code,
      'cate_id': cateId,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
}
