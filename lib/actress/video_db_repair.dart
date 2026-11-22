import 'dart:async';

import 'package:sqflite/sqflite.dart';

import '../core_bridge.dart' show AppFailure;
import '../feed_playability.dart';

/// 一次视频库体检的结果。
class VideoDbRepairReport {
  const VideoDbRepairReport({
    required this.total,
    required this.alive,
    required this.dead,
    required this.unknown,
    required this.removed,
    required this.elapsed,
    required this.cancelled,
  });

  final int total;
  final int alive;

  /// 明确打不开的（404/410/连不上/地址非法）。
  final int dead;

  /// 403/超时之类测不准的：一律保留，不拿它当死链删。
  final int unknown;
  final int removed;
  final Duration elapsed;
  final bool cancelled;

  String get summary =>
      '共 $total 部：可播 $alive'
      '${unknown > 0 ? '，待确认 $unknown' : ''}'
      '，删除 $removed';
}

enum _Verdict { alive, dead, unknown }

/// 本地视频库（videos 表 + m3u8 直链）自愈：
///
/// - 逐条按库里存的地址验活（playlist 首段字节，不整段下载）；
/// - 404/410/域名解析失败/连接被拒/地址非法 → 判死链，删掉
///   （videos + video_actress + video_tag + video_category 一起清）；
/// - 401/403/超时/TLS 失败 → 测不准，一律保留，不误删能播的源；
/// - 删完重建 actress_rollup 汇总（演员作品数）与分类计数。
class VideoDbRepair {
  VideoDbRepair._();

  static const defaultConcurrency = 8;
  static const defaultTimeout = Duration(seconds: 8);

  static Future<_Verdict> _probe(String url, Duration timeout) async {
    final target = url.trim();
    if (target.isEmpty) return _Verdict.dead;
    final uri = Uri.tryParse(target);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return _Verdict.dead;
    }
    try {
      final response = await probeStreamHead(target, const {}, timeout);
      final code = response.statusCode;
      if (code >= 200 && code < 300) {
        // m3u8 要以 #EXTM3U 开头；返回别的（错误页）算测不准，不删。
        final text = String.fromCharCodes(
          response.headBytes.take(16).toList(growable: false),
        );
        if (target.toLowerCase().contains('.m3u8')) {
          return text.contains('#EXTM3U')
              ? _Verdict.alive
              : _Verdict.unknown;
        }
        return _Verdict.alive;
      }
      if (code == 404 || code == 410) return _Verdict.dead;
      return _Verdict.unknown;
    } catch (error) {
      final text = error.toString().toLowerCase();
      if (text.contains('not found') ||
          text.contains('failed host lookup') ||
          text.contains('connection refused') ||
          text.contains('network is unreachable') ||
          text.contains('no address associated')) {
        return _Verdict.dead;
      }
      if (error is AppFailure && text.contains('验播地址无效')) {
        return _Verdict.dead;
      }
      return _Verdict.unknown;
    }
  }

  /// 跑一次体检。 [path] 是库文件绝对路径（就地修改，调用方负责先备份）。
  static Future<VideoDbRepairReport> run(
    String path, {
    int concurrency = defaultConcurrency,
    Duration timeout = defaultTimeout,
    int scanLimit = 100000000,
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
    Future<void> Function()? onBeforeWrite,
  }) async {
    final stopwatch = Stopwatch()..start();
    final db = await openDatabase(path);
    try {
      final tables = <String>{
        for (final row in await db.rawQuery(
          "select name from sqlite_master where type='table'",
        ))
          (row['name'] as String? ?? ''),
      };
      if (!tables.contains('videos')) {
        throw AppFailure('这个文件不是视频库（没有 videos 表）');
      }

      final total = Sqflite.firstIntValue(
            await db.rawQuery('select count(*) from videos'),
          ) ??
          0;
      if (total == 0) {
        throw AppFailure('库里没有条目');
      }

      // 分批按 rowid 游标扫，避免一次性把 30 万行读进内存。
      final rows = <(String, String, int)>[];
      var cursor = 0;
      while (rows.length < scanLimit) {
        final batch = await db.rawQuery(
          'select rowid as rid, vod_id, m3u8_url from videos '
          'where rowid > ? order by rowid limit 2000',
          [cursor],
        );
        if (batch.isEmpty) break;
        for (final row in batch) {
          cursor = (row['rid'] as num).toInt();
          rows.add((
            row['vod_id']?.toString() ?? '',
            row['m3u8_url']?.toString() ?? '',
            cursor,
          ));
        }
      }

      final verdicts = List<_Verdict?>.filled(rows.length, null);
      var done = 0;
      var index = 0;
      var aborted = false;

      Future<void> worker() async {
        while (true) {
          if (cancelled?.call() ?? false) {
            aborted = true;
            return;
          }
          final i = index;
          if (i >= rows.length) return;
          index = i + 1;
          verdicts[i] = await _probe(rows[i].$2, timeout);
          done++;
          if (done % 20 == 0 || done == rows.length) {
            onProgress?.call(done, rows.length);
          }
        }
      }

      final workers = concurrency.clamp(1, 32);
      await Future.wait([for (var i = 0; i < workers; i++) worker()]);
      onProgress?.call(done, rows.length);

      final deadIds = <String>[];
      var alive = 0;
      var unknown = 0;
      for (var i = 0; i < rows.length; i++) {
        switch (verdicts[i]) {
          case _Verdict.dead:
            deadIds.add(rows[i].$1);
          case _Verdict.alive:
            alive++;
          case _Verdict.unknown:
          case null:
            unknown++;
        }
      }

      if (deadIds.isNotEmpty) {
        await onBeforeWrite?.call();
        const chunk = 500;
        for (var i = 0; i < deadIds.length; i += chunk) {
          final slice = deadIds.sublist(
            i,
            i + chunk > deadIds.length ? deadIds.length : i + chunk,
          );
          final marks = List.filled(slice.length, '?').join(',');
          await db.transaction((txn) async {
            await txn.rawDelete(
              'delete from videos where vod_id in ($marks)',
              slice,
            );
            if (tables.contains('video_actress')) {
              await txn.rawDelete(
                'delete from video_actress where vod_id in ($marks)',
                slice,
              );
            }
            if (tables.contains('video_tag')) {
              await txn.rawDelete(
                'delete from video_tag where vod_id in ($marks)',
                slice,
              );
            }
            if (tables.contains('video_category')) {
              await txn.rawDelete(
                'delete from video_category where vod_id in ($marks)',
                slice,
              );
            }
          });
        }
        await _rebuildRollup(db, tables);
      }

      return VideoDbRepairReport(
        total: rows.length,
        alive: alive,
        dead: deadIds.length,
        unknown: unknown,
        removed: deadIds.length,
        elapsed: stopwatch.elapsed,
        cancelled: aborted,
      );
    } finally {
      await db.close();
    }
  }

  static Future<void> _rebuildRollup(
    Database db,
    Set<String> tables,
  ) async {
    if (!tables.contains('actress_rollup') ||
        !tables.contains('actresses') ||
        !tables.contains('video_actress')) {
      return;
    }
    await db.transaction((txn) async {
      await txn.rawDelete('delete from actress_rollup');
      await txn.rawInsert('''
        insert into actress_rollup (name, first_rowid, avatar, works, sex, last_date)
        select a.name, a.rowid, coalesce(a.avatar,''), count(distinct va.vod_id),
               coalesce(a.sex,'female'), ''
          from actresses a
          join video_actress va on va.cate_id = a.cate_id
          join videos v on v.vod_id = va.vod_id
         group by a.cate_id
      ''');
      if (tables.contains('actress_rollup_meta')) {
        final people = Sqflite.firstIntValue(
              await txn.rawQuery('select count(*) from actress_rollup'),
            ) ??
            0;
        final links = Sqflite.firstIntValue(
              await txn.rawQuery('select count(*) from video_actress'),
            ) ??
            0;
        await txn.rawInsert(
          "insert or replace into actress_rollup_meta(key, value) values('signature', ?)",
          ['$people/$links'],
        );
      }
      if (tables.contains('index_categories')) {
        await txn.rawUpdate('''
          update index_categories set video_count = coalesce((
              select count(*) from video_category vc
                join videos v on v.vod_id = vc.vod_id
               where vc.main_category = index_categories.category_name), 0)
        ''');
      }
    });
  }
}
