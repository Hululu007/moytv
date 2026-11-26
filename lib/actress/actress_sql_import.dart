import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'actress_generic_db.dart';
import 'actress_models.dart' show preferLoadableAvatar;

/// 女优库 .sql 导入（2026-11-25 用户令）：把女优库.db 改成 .sql 后，
/// 从演员库设置里选 .sql / .sql.gz 文件导回手机，导完直接当主库用。
///
/// 流程：流式读 SQL（整文件不进内存）→ 临时库分批执行
/// （每 1000 条 INSERT 一个事务）→ 字段归一化（标准库直接过；
/// 字段不一样的库按字段名宽容映射建成标准表，见 _normalizeImport）
/// → 校验三项（作品数/播放地址大于 0；人数可为 0 只警告）
/// → 关主库连接 → 备份现库为 .bak → 临时库改名顶替主库。
/// 校验不过、取消、执行出错都在换库之前停下：原库一字不动，
/// 临时文件删掉。
/// 单条语句执行出错不炸整单：整批失败后逐条重跑，坏的跳过并
/// 按表计数、导完汇总写明；整批全灭也只跳过计数、不中途炸单
/// （2026-11-26 改，见下条）；只有文件读不出、临时库打不开这类
/// 真致命错误，或校验缺表/没作品/没播放地址（结构性失败）才
/// 整单失败。
/// .dump 的统计语句不进执行：ANALYZE 整类过滤，sqlite_stat1 /
/// sqlite_stat4 的写入一并过滤——它们是 ANALYZE 的统计产物、
/// 不是数据（导出侧同口径，见 actress_db_export.dart）。部分
/// 机型的 SQLite 不认 ANALYZE 的目标名 sqlite_schema（老版本
/// 只有 sqlite_master），这条语句在那些机型上必炸；更糟的是
/// sqlite_stat1 表靠 ANALYZE 创建，它一炸，后面 16 条 stat1
/// INSERT 整批全灭、按旧口径把整个导入拖死（2026-11-26 用户
/// 手机实报，v67 导入在部分机型上栽在这里）。
///
/// 红线：临时库只在导入时存在，导完即改名成主库；正式库的
/// journal_mode / synchronous 一个字不改（读写库不抄参考文件的
/// OFF/WAL 写法）。唯一例外是导入临时连接自己的提速 PRAGMA
/// （synchronous=OFF、journal_mode=MEMORY、大缓存）：只作用于
/// 这条临时连接、不写进库文件（关连接即失效，顶替后的主库被
/// App 打开时仍是默认档），临时库失败整单丢弃，降档不丢真数据
/// ——2026-11-25 全量剖析后加（执行占总时长约 97%）。
/// 导入失败绝不把半成品库留在主库路径上。

/// 视频库索引集（2026-11-26 加载优化：由开库时自建改为导入时
/// 落库，清单与旧开库自建的完全一致）：只 CREATE INDEX，不改数据。
/// - video_actress(cate_id)：点开一个人时按人名取自己的作品；
/// - video_actress(vod_id)：按番号查/播时反查；
/// - actresses(name)：按名归并/查找；
/// - videos(vod_play_from)：影视库站点去重（DISTINCT）无索引时
///   全表扫 34 万行、实测 1.8~8.3 秒，建后 0.05 秒；
/// - videos(vod_pubdate)：点开一个人 ORDER BY vod_pubdate 排序；
/// - video_category(vod_id)：worksForPerson / listFilms 的 LEFT JOIN；
/// - video_category(main_category)：categories() 的 GROUP BY；
/// - videos(type_name, vod_id) 覆盖索引：类型文件夹聚合与封面
///   MIN(vod_id)，真库实测聚合 604→59ms、封面 470→81ms。
const actressVideoIndexSqls = [
  'CREATE INDEX IF NOT EXISTS idx_moyi_va_cate ON video_actress(cate_id)',
  'CREATE INDEX IF NOT EXISTS idx_moyi_va_vod ON video_actress(vod_id)',
  'CREATE INDEX IF NOT EXISTS idx_moyi_act_name ON actresses(name)',
  'CREATE INDEX IF NOT EXISTS idx_moyi_v_play_from ON videos(vod_play_from)',
  'CREATE INDEX IF NOT EXISTS idx_moyi_v_pubdate ON videos(vod_pubdate)',
  'CREATE INDEX IF NOT EXISTS idx_moyi_vc_vod ON video_category(vod_id)',
  'CREATE INDEX IF NOT EXISTS idx_moyi_vc_cat ON video_category(main_category)',
  'CREATE INDEX IF NOT EXISTS idx_moyi_v_type_vod ON videos(type_name, vod_id)',
];

/// 导入进度：阶段 + 已执行语句数 + 已读字节 + 文件总字节。
class ActressSqlImportProgress {
  const ActressSqlImportProgress({
    required this.phase,
    required this.statements,
    required this.bytesRead,
    required this.totalBytes,
  });

  /// 阶段：正在导入 / 正在校验。
  final String phase;

  /// 已执行完的 SQL 语句数。
  final int statements;

  /// 已从 .sql 文件读入的字节数（.gz 按压缩后字节算）。
  final int bytesRead;

  /// .sql 文件总字节数（.gz 按压缩后大小算）。
  final int totalBytes;

  /// 0..1：按已读字节算的进度。
  double get fraction =>
      totalBytes <= 0 ? 0 : (bytesRead / totalBytes).clamp(0, 1);
}

/// 导入结果：成功时带四项验收数；失败时 [error] 非空、原库不动。
class ActressSqlImportResult {
  const ActressSqlImportResult({
    required this.ok,
    this.error,
    this.videos = 0,
    this.actresses = 0,
    this.playUrls = 0,
    this.covers = 0,
    this.avatars = 0,
    this.skipped = 0,
    this.skippedStatements = 0,
    this.skippedStatementTables = const {},
    this.skippedStatementSample,
    this.warnings = const [],
    this.needsReload = false,
  });

  final bool ok;

  /// 失败原因（成功时为空）。取消也走这里。
  final String? error;

  /// 作品数（videos 表行数）。
  final int videos;

  /// 人数（actresses 表行数）。
  final int actresses;

  /// 播放地址行数（video_play_urls 表行数）。
  final int playUrls;

  /// 有封面的作品数（pic_url 非空）。
  final int covers;

  /// 有头像的人数（avatar 非空）。
  final int avatars;

  /// 归一化时跳过的行数（没有播放地址的行，不进库）。
  final int skipped;

  /// 执行时出错被跳过的语句数（单条坏语句不炸整单：整批失败后
  /// 逐条重跑，坏的跳过计数、好的照常进库；整批全灭也只跳过
  /// 计数，结构不对由随后的校验整单拦下）。ANALYZE 等统计语句
  /// 是导入前就过滤掉的，不算跳过、不走这里。
  final int skippedStatements;

  /// 跳过语句按表计数（表名 → 条数）。
  final Map<String, int> skippedStatementTables;

  /// 第一条跳过语句的信息（头词 + 表名 + 出错原因，排查用）。
  final String? skippedStatementSample;

  /// 非致命提醒（例如封面/头像数为 0 时写在这里，不拦导入）。
  final List<String> warnings;

  /// true = 导入走到过关主库连接那步（换库成功或换库失败），
  /// 调用方须重读数据库恢复连接；false = 还没动主库，不用重读。
  final bool needsReload;
}

/// SQL 语句切分器：流式喂行，按分号切语句。
///
/// 只认单引号字符串里的分号（`'a;b'` 不切、`''` 是转义不是串尾），
/// 跨行字符串也认（vod_content 里有换行时一条 INSERT 占多行）。
/// 注释必须在字符串外才算数：`--` 行注释与 `/* */` 块注释都只在
/// 扫描确认不在字符串里时才丢弃——字符串值里的 `--`（如标题
/// `K1037 餌食牝 -- 北上尚子`）与 `/*`（如 `[真实故事/**女人]`）
/// 是数据，不能当注释切掉。2026-11-25 真文件导入失败的根因就是
/// 这个：旧写法在“行首不在字符串里”时拿整行找 `--` 截断，标题里
/// 的 `--` 被误杀，语句从中间断开、字符串状态错位，后面连环切坏
/// （手机报错 near "pfes" 即第二条语句的番号被吞进上一条里）。
/// sqlite3 .dump 的输出就是这个格式：每条 INSERT 一行、建表跨行、
/// 字符串里可能有分号与换行。
class SqlStatementSplitter {
  final _buffer = StringBuffer();
  var _inString = false;
  var _inBlockComment = false;

  /// 喂一行（不带换行符），返回这一行里切完的语句（0 条或多条）。
  List<String> addLine(String line) {
    final out = <String>[];
    var i = 0;
    while (i < line.length) {
      final c = line[i];
      if (_inBlockComment) {
        if (c == '*' && i + 1 < line.length && line[i + 1] == '/') {
          _inBlockComment = false;
          i += 2;
        } else {
          i++;
        }
        continue;
      }
      if (_inString) {
        if (c == "'") {
          if (i + 1 < line.length && line[i + 1] == "'") {
            _buffer.write("''");
            i += 2;
            continue;
          }
          _inString = false;
        }
        _buffer.write(c);
        i++;
        continue;
      }
      if (c == "'") {
        _inString = true;
        _buffer.write(c);
        i++;
        continue;
      }
      if (c == '-' && i + 1 < line.length && line[i + 1] == '-') {
        // 行注释只在字符串外才算数：本行剩余部分整段丢弃。
        break;
      }
      if (c == '/' && i + 1 < line.length && line[i + 1] == '*') {
        _inBlockComment = true;
        i += 2;
        continue;
      }
      if (c == ';') {
        _buffer.write(c);
        final statement = _buffer.toString().trim();
        _buffer.clear();
        if (statement.isNotEmpty) out.add(statement);
        i++;
        continue;
      }
      _buffer.write(c);
      i++;
    }
    // 行尾：字符串没闭合就是跨行字符串，补个换行留着。
    if (_inString) _buffer.write('\n');
    return out;
  }

  /// 流结束时收尾：残留的未闭合内容（正常 .dump 不应有）原样吐出。
  String? flush() {
    final rest = _buffer.toString().trim();
    _buffer.clear();
    _inString = false;
    _inBlockComment = false;
    return rest.isEmpty ? null : rest;
  }
}

/// 导入执行器：真正往库里写 SQL 的那一层。生产用 sqflite，
/// 测试用假实现（不碰真 sqlite，flutter test 里 sqflite 跑不起来）。
abstract class SqlImportExecutor {
  /// 执行一条非 INSERT 语句（建表、建索引、PRAGMA）。
  Future<void> execute(String sql);

  /// 一批 INSERT（一个事务内执行完）。
  Future<void> executeBatch(List<String> statements);

  /// 查一行（校验用）。
  Future<List<Map<String, Object?>>> query(String sql);

  Future<void> close();
}

/// sqflite 实现：批处理走 Batch，一次通道调用交一整批。
class SqfliteImportExecutor implements SqlImportExecutor {
  SqfliteImportExecutor(this._db);

  final Database _db;

  @override
  Future<void> execute(String sql) => _db.execute(sql);

  @override
  Future<void> executeBatch(List<String> statements) async {
    final batch = _db.batch();
    for (final statement in statements) {
      batch.execute(statement);
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql) => _db.rawQuery(sql);

  @override
  Future<void> close() => _db.close();
}

/// 取消导入：执行器之间检查 [isCancelled] 时抛这个，调用方按
/// “已取消，数据库未改动”收尾。
class ActressSqlImportCancelled implements Exception {}

/// 女优库 .sql 导入器。
class ActressSqlImporter {
  ActressSqlImporter({
    this.batchSize = 1000,
    Future<SqlImportExecutor> Function(String tempPath)? executorFactory,
  }) : _executorFactory =
           executorFactory ??
           ((tempPath) async {
             final db = await openDatabase(
               tempPath,
               singleInstance: false,
             );
             return SqfliteImportExecutor(db);
           });

  /// 每批 INSERT 条数：1000 条一个事务，失败只丢一批、进度可续报。
  final int batchSize;

  final Future<SqlImportExecutor> Function(String tempPath) _executorFactory;

  static const _requiredTables = {
    'videos',
    'actresses',
    'video_actress',
    'video_play_urls',
  };

  /// 导入一个 .sql / .sql.gz 文件，成功就顶替 [dbPath] 的主库。
  ///
  /// [closeDatabase] 只在校验通过、准备换库时才调（关主库连接，
  /// 好让文件改名）。校验不过/取消/执行出错时不调，主库连接还
  /// 在、文件也不动。
  Future<ActressSqlImportResult> importFile({
    required String sqlPath,
    required String dbPath,
    required Future<void> Function() closeDatabase,
    required void Function(ActressSqlImportProgress) onProgress,
    bool Function()? isCancelled,
  }) async {
    final sqlFile = File(sqlPath);
    if (dbPath.isEmpty) {
      return const ActressSqlImportResult(
        ok: false,
        error: '没有可替换的数据库路径',
      );
    }
    if (!await sqlFile.exists() || await sqlFile.length() == 0) {
      return const ActressSqlImportResult(
        ok: false,
        error: '选中的文件不存在或为空',
      );
    }
    final lower = sqlPath.toLowerCase();
    final isGz = lower.endsWith('.gz');
    if (!lower.endsWith('.sql') && !isGz) {
      return const ActressSqlImportResult(
        ok: false,
        error: '只认 .sql 或 .sql.gz 文件',
      );
    }
    final totalBytes = await sqlFile.length();
    final tempPath = '$dbPath.importing';
    final tempFile = File(tempPath);
    try {
      if (await tempFile.exists()) await tempFile.delete();
    } catch (_) {
      return const ActressSqlImportResult(
        ok: false,
        error: '临时库文件删不掉，请先确认没有别的导入在跑',
      );
    }

    SqlImportExecutor? executor;
    var closedDb = false;
    try {
      executor = await _executorFactory(tempPath);
      // .dump 开头自带 PRAGMA foreign_keys=OFF；这里再关一次，
      // 导入中途外键不拦批量写。
      await executor.execute('PRAGMA foreign_keys=OFF');
      // 导入提速（只作用于这条临时连接，见文件头红线说明）：
      // 关同步刷盘 + 回滚日志放内存 + 256MB 页缓存。逐条单独试，
      // 哪条被执行器拒了也不拦导入（慢一点而已）。
      for (final pragma in const [
        'PRAGMA journal_mode=MEMORY',
        'PRAGMA synchronous=OFF',
        'PRAGMA cache_size=-262144',
        'PRAGMA temp_store=MEMORY',
        'PRAGMA mmap_size=268435456',
      ]) {
        try {
          await executor.execute(pragma);
        } catch (_) {}
      }
      var statements = 0;
      var bytesRead = 0;
      var lastReportedBytes = 0;
      final splitter = SqlStatementSplitter();
      final pendingInserts = <String>[];
      // 索引后建：CREATE INDEX 先攒着，数据灌完再统一建（转储把
      // 索引写在前面的文件，逐行执行会让每条 INSERT 都维护索引，
      // 越灌越慢）。建索引仍在归一化之前：归一化改名表时索引跟
      // 着表走，不会丢。本文件自带的索引本来就写在末尾时无差别。
      final deferredIndexes = <String>[];
      // 坏语句跳过计数（单条坏语句不炸整单）：按表归类，第一条
      // 记下出错原因，导完写进结果与汇总，不静默。
      var skippedStatements = 0;
      final skippedByTable = <String, int>{};
      String? skippedSample;
      void recordSkip(String statement, Object error) {
        skippedStatements++;
        final table = _statementTable(statement);
        skippedByTable[table] = (skippedByTable[table] ?? 0) + 1;
        skippedSample ??= '${_statementHead(statement)} $table：'
            '${error.toString().split('\n').first}';
      }

      Future<void> flushInserts() async {
        if (pendingInserts.isEmpty) return;
        final batch = List<String>.of(pendingInserts);
        pendingInserts.clear();
        try {
          await executor!.executeBatch(batch);
          statements += batch.length;
        } catch (_) {
          // 整批失败多半是批里混了一条坏语句：整批已回滚，逐条
          // 重跑定位——坏的跳过计数、好的照常进库。整批全灭也
          // 不在这里炸单（2026-11-26 改）：部分机型上 .dump 尾
          // 部的统计类语句整批必失败，旧写法在这里抛 StateError
          // 把整个导入拖死（首条出错样本还是先前过滤漏掉的统计
          // 语句，排查极具误导性）。跳过数与首条出错样本都记进
          // 结果汇总、不静默；真把数据弄坏了，后面的校验（缺
          // 表/没作品/没播放地址）会整单拦下、原库照样不动。
          var okCount = 0;
          for (final statement in batch) {
            try {
              await executor!.execute(statement);
              okCount++;
            } catch (e) {
              recordSkip(statement, e);
            }
          }
          statements += okCount;
        }
        onProgress(
          ActressSqlImportProgress(
            phase: '正在导入',
            statements: statements,
            bytesRead: bytesRead,
            totalBytes: totalBytes,
          ),
        );
      }

      void checkCancelled() {
        if (isCancelled != null && isCancelled()) {
          throw ActressSqlImportCancelled();
        }
      }

      Stream<List<int>> byteStream = sqlFile.openRead();
      if (isGz) byteStream = byteStream.transform(gzip.decoder);
      final lines = byteStream
          .map((chunk) {
            bytesRead += chunk.length;
            return chunk;
          })
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        checkCancelled();
        for (final statement in splitter.addLine(line)) {
          final head = _statementHead(statement);
          if (head == 'BEGIN' || head == 'COMMIT') {
            // .dump 自带的事务起止：事务由这里按批管，跳过它自己的。
            continue;
          }
          if (_isStatisticsStatement(statement, head)) {
            // .dump 的统计语句（ANALYZE 与 sqlite_stat1/stat4
            // 的写入）：不是数据，不执行、也不计跳过（文件头注
            // 释有根因：部分机型执行 ANALYZE 必炸且连累真数据）。
            continue;
          }
          if (head == 'INSERT') {
            pendingInserts.add(statement);
            if (pendingInserts.length >= batchSize) {
              await flushInserts();
              checkCancelled();
            }
          } else if (head == 'CREATE' &&
              statement.toUpperCase().contains(' INDEX ')) {
            deferredIndexes.add(statement);
          } else {
            await flushInserts();
            try {
              await executor.execute(statement);
              statements++;
            } catch (e) {
              // 单条非 INSERT 语句出错同样跳过计数（建表失败会在
              // 后面校验缺表时按结构性失败整单拦下）。
              recordSkip(statement, e);
            }
          }
        }
        // 每读 1MB 报一次进度（读得比写快时进度条也走）。
        if (bytesRead - lastReportedBytes >= 1024 * 1024) {
          lastReportedBytes = bytesRead;
          onProgress(
            ActressSqlImportProgress(
              phase: '正在导入',
              statements: statements,
              bytesRead: bytesRead,
              totalBytes: totalBytes,
            ),
          );
        }
      }
      final tail = splitter.flush();
      if (tail != null) {
        final head = _statementHead(tail);
        if (head != 'BEGIN' &&
            head != 'COMMIT' &&
            !_isStatisticsStatement(tail, head)) {
          if (head == 'INSERT') {
            pendingInserts.add(tail);
          } else {
            try {
              await executor.execute(tail);
              statements++;
            } catch (e) {
              recordSkip(tail, e);
            }
          }
        }
      }
      await flushInserts();
      checkCancelled();

      // 数据灌完，统一补建攒下的索引（坏的同样跳过计数）。
      for (final indexSql in deferredIndexes) {
        try {
          await executor.execute(indexSql);
          statements++;
        } catch (e) {
          recordSkip(indexSql, e);
        }
      }
      checkCancelled();

      // 字段归一化：标准库直接过；字段不一样的库按字段名宽容映射
      // 建成标准表（缺播放地址的行跳过并计数）。
      var normalizedRows = 0;
      final skipped = await _normalizeImport(
        executor,
        onNormalized: (rows) {
          normalizedRows = rows;
          onProgress(
            ActressSqlImportProgress(
              phase: '正在归一化',
              statements: statements + rows,
              bytesRead: bytesRead,
              totalBytes: totalBytes,
            ),
          );
        },
      );
      checkCancelled();

      // 校验（还在临时库上，不合格不换库）。
      onProgress(
        ActressSqlImportProgress(
          phase: '正在校验',
          statements: statements + normalizedRows,
          bytesRead: bytesRead,
          totalBytes: totalBytes,
        ),
      );
      final counts = await _validate(executor);
      final warnings = <String>[];
      if (counts.covers == 0) warnings.add('导入的库里没有封面');
      if (counts.avatars == 0) warnings.add('导入的库里没有头像');
      if (counts.actresses == 0) warnings.add('导入的库里没有演员信息');
      if (skipped > 0) warnings.add('跳过 $skipped 行（没有播放地址）');
      if (skippedStatements > 0) {
        final byTable = skippedByTable.entries
            .map((e) => '${e.key} ${e.value} 条')
            .join('、');
        warnings.add('跳过 $skippedStatements 条出错语句（$byTable）');
      }
      // 收尾落库（2026-11-26 加载优化）：索引与汇总表在临时库阶段
      // 就建好，顶替后开库零自写、名单首进直接走汇总表（旧流程是
      // 开库同步建索引 + 3 秒后后台全量重建汇总表，与名单首查抢
      // 锁）。全程尽力而为：落库失败不拦导入（开库侧没有汇总表会
      // 走现算回退，功能不丢）、不计数、不加警告、不报进度。
      await _finalizeImportedDb(executor);
      await executor.close();
      executor = null;

      // 换库：关主库连接 → 备份现库 → 临时库改名顶替。
      try {
        await closeDatabase();
      } catch (_) {
        // 关连接失败不拦换库（文件改名才是关键一步）。
      }
      closedDb = true;
      final liveFile = File(dbPath);
      final bakPath = '$dbPath.bak';
      final liveExists = await liveFile.exists();
      if (liveExists) {
        await liveFile.copy(bakPath);
      }
      try {
        await tempFile.rename(dbPath);
      } catch (e) {
        // 改名失败：现库还在就不用动；现库没了就从备份恢复。
        if (!await liveFile.exists() && liveExists) {
          try {
            await File(bakPath).copy(dbPath);
          } catch (_) {}
        }
        return ActressSqlImportResult(
          ok: false,
          error: '换库失败：$e（已恢复原库）',
          needsReload: true,
        );
      }
      return ActressSqlImportResult(
        ok: true,
        videos: counts.videos,
        actresses: counts.actresses,
        playUrls: counts.playUrls,
        covers: counts.covers,
        avatars: counts.avatars,
        skipped: skipped,
        skippedStatements: skippedStatements,
        skippedStatementTables: skippedByTable,
        skippedStatementSample: skippedSample,
        warnings: warnings,
        needsReload: true,
      );
    } on ActressSqlImportCancelled {
      return ActressSqlImportResult(
        ok: false,
        error: '已取消，数据库未改动',
        needsReload: closedDb,
      );
    } catch (e) {
      // 失败原因只放原文：展示处（设置区、SnackBar）自己带
      // “导入失败：”前缀，这里再加就会叠成两层。
      return ActressSqlImportResult(
        ok: false,
        error: e.toString().split('\n').first,
        needsReload: closedDb,
      );
    } finally {
      try {
        await executor?.close();
      } catch (_) {}
      // 失败/取消后临时文件必须清掉，不留半成品库。
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
    }
  }

  /// 收尾落库：给临时库建视频库索引集 + 名册汇总表。只在导入的
  /// 临时库上跑（顶替前），失败整段吞掉——导入本体已经校验通过，
  /// 落库只是加速，缺了它开库侧走现算回退。索引逐条建，单条失败
  /// 不影响其余。
  Future<void> _finalizeImportedDb(SqlImportExecutor executor) async {
    try {
      for (final sql in actressVideoIndexSqls) {
        try {
          await executor.execute(sql);
        } catch (_) {
          // 单个索引建不了不影响另一个，也不影响导入。
        }
      }
      await _buildImportedRollup(executor);
    } catch (_) {
      // 落库失败不拦导入：原库校验已过，顶替照常。
    }
  }

  /// 名册汇总表落库：算法与旧开库后台重建（已删的 _ensureVideoRollup）
  /// 一字不差——按名字归并同一个人（被拆成两行的作品数相加、头像
  /// 取第一条能加载的、最新作品日期取最大、有一行男优就算男优），
  /// 签名 `v2:actresses 行数/video_actress 行数` 与读侧口径一致；
  /// 转储自带汇总表且签名对得上时跳过重建（自家导出再导回的往返
  /// 不白跑一遍全量聚合）。先写临时表再换名，读侧要么见旧表要么
  /// 见新表；这里跑在导入临时库上，中途失败整单导入按失败收尾、
  /// 临时文件会被清掉，不留半成品。
  Future<void> _buildImportedRollup(SqlImportExecutor executor) async {
    final sourceCounts = await executor.query(
      'SELECT (SELECT COUNT(*) FROM actresses) AS a, '
      '(SELECT COUNT(*) FROM video_actress) AS v',
    );
    final aCount = (sourceCounts.first['a'] as num?)?.toInt() ?? 0;
    final vCount = (sourceCounts.first['v'] as num?)?.toInt() ?? 0;
    // 汇总表版本 v2：2026-11-24 头像归并改只接受能加载的地址后，
    // 旧版汇总表里已存的裸域名头像必须重建一次才掉；版本号写进
    // 签名，读侧/再导入时认得出（与旧重建同一口径）。
    final signature = 'v2:$aCount/$vCount';

    await executor.execute(
      'CREATE TABLE IF NOT EXISTS actress_rollup ('
      'name TEXT PRIMARY KEY, '
      'first_rowid INTEGER NOT NULL, '
      'avatar TEXT NOT NULL DEFAULT \'\', '
      'works INTEGER NOT NULL DEFAULT 0, '
      'sex TEXT NOT NULL DEFAULT \'\', '
      'last_date TEXT NOT NULL DEFAULT \'\')',
    );
    await executor.execute(
      'CREATE TABLE IF NOT EXISTS actress_rollup_meta ('
      'key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    final meta = await executor.query(
      "SELECT value FROM actress_rollup_meta WHERE key = 'signature' "
      'LIMIT 1',
    );
    final current = meta.isEmpty
        ? ''
        : (meta.first['value']?.toString() ?? '');
    final rollupRows = await executor.query(
      'SELECT COUNT(*) AS c FROM actress_rollup',
    );
    final rollupCount = rollupRows.isEmpty
        ? 0
        : ((rollupRows.first['c'] as num?)?.toInt() ?? 0);
    if (current == signature && rollupCount > 0) return;

    // 按名字归并：每类作品数 + 最新日期先算出来，再按人名累加。
    final perCate = await executor.query(
      'SELECT va.cate_id AS cate_id, COUNT(*) AS n, '
      'MAX(v.vod_pubdate) AS d '
      'FROM video_actress va '
      'LEFT JOIN videos v ON v.vod_id = va.vod_id '
      'GROUP BY va.cate_id',
    );
    final works = <String, int>{};
    final dates = <String, String>{};
    for (final row in perCate) {
      final cateId = row['cate_id']?.toString() ?? '';
      if (cateId.isEmpty) continue;
      works[cateId] = (row['n'] as num?)?.toInt() ?? 0;
      final d = row['d']?.toString() ?? '';
      if (d.isNotEmpty) dates[cateId] = d;
    }
    final hasSex = (await executor.query(
      'PRAGMA table_info(actresses)',
    )).any((r) => (r['name']?.toString() ?? '') == 'sex');
    final people = await executor.query(
      'SELECT rowid AS rid, name AS name, cate_id AS cate_id, '
      "COALESCE(NULLIF(avatar,''),'') AS avatar, "
      "${hasSex ? "COALESCE(NULLIF(sex,''),'')" : "''"} AS sex "
      'FROM actresses',
    );
    final byName = <String, _ImportRollupAcc>{};
    for (final row in people) {
      final name = row['name']?.toString() ?? '';
      final cateId = row['cate_id']?.toString() ?? '';
      if (name.isEmpty || cateId.isEmpty) continue;
      final acc = byName.putIfAbsent(
        name,
        () => _ImportRollupAcc((row['rid'] as num).toInt()),
      );
      final avatar = row['avatar']?.toString() ?? '';
      // 第一批有效头像才占坑：裸域名行在前也不赢，后面的完整
      // 头像照样能补进来；同名全是坏地址时留空（列表画圆圈）。
      acc.avatar = preferLoadableAvatar(acc.avatar, avatar);
      if ((row['sex']?.toString() ?? '') == 'male') acc.sex = 'male';
      acc.works += works[cateId] ?? 0;
      final d = dates[cateId];
      if (d != null && d.compareTo(acc.lastDate) > 0) acc.lastDate = d;
    }

    await executor.execute('DROP TABLE IF EXISTS actress_rollup_new');
    await executor.execute(
      'CREATE TABLE actress_rollup_new ('
      'name TEXT PRIMARY KEY, '
      'first_rowid INTEGER NOT NULL, '
      'avatar TEXT NOT NULL DEFAULT \'\', '
      'works INTEGER NOT NULL DEFAULT 0, '
      'sex TEXT NOT NULL DEFAULT \'\', '
      'last_date TEXT NOT NULL DEFAULT \'\')',
    );
    // 分批生成 INSERT（每条 200 行、每 2000 行提交一次）：临时库
    // 还没顶替，慢一点没关系，别把语句攒成一整坨撑爆内存。
    final names = byName.keys.toList();
    var pending = <String>[];
    Future<void> flushPending() async {
      if (pending.isEmpty) return;
      final batch = pending;
      pending = <String>[];
      await executor.executeBatch(batch);
    }

    final rowSql = StringBuffer();
    var rowsInStatement = 0;
    void appendRow(String name, _ImportRollupAcc acc) {
      if (rowsInStatement > 0) rowSql.write(',');
      rowSql.write(
        '(${_q(name)},${acc.firstRowid},${_q(acc.avatar)},${acc.works},'
        '${_q(acc.sex)},${_q(acc.lastDate)})',
      );
      rowsInStatement++;
      if (rowsInStatement >= 200) {
        pending.add(
          'INSERT INTO actress_rollup_new VALUES $rowSql',
        );
        rowSql.clear();
        rowsInStatement = 0;
      }
    }

    for (var i = 0; i < names.length; i++) {
      appendRow(names[i], byName[names[i]]!);
      if (pending.length >= 10) await flushPending();
    }
    if (rowsInStatement > 0) {
      pending.add('INSERT INTO actress_rollup_new VALUES $rowSql');
    }
    await flushPending();
    await executor.execute('DROP TABLE IF EXISTS actress_rollup');
    await executor.execute(
      'ALTER TABLE actress_rollup_new RENAME TO actress_rollup',
    );
    await executor.execute(
      'INSERT OR REPLACE INTO actress_rollup_meta (key, value) '
      "VALUES ('signature', ${_q(signature)})",
    );
  }

  /// 语句头一个词（INSERT / CREATE / PRAGMA / BEGIN / COMMIT …）。
  /// 分号也算分隔符：转储尾巴的 `COMMIT;` 头词必须是 COMMIT，
  /// 否则事务起止跳过判定漏掉它、会被当普通语句执行（无活动
  /// 事务时报错，旧版没跳过韧性时会把导入在最后一步炸掉）。
  static String _statementHead(String statement) {
    final text = statement.trimLeft();
    final end = text.indexOf(RegExp(r'[\s(;]'));
    final head = (end < 0 ? text : text.substring(0, end)).toUpperCase();
    // CREATE TABLE / CREATE INDEX / CREATE UNIQUE INDEX：头词都是 CREATE。
    return head;
  }

  /// .dump 统计语句判定（导入前过滤，不执行、不计跳过）：
  /// ANALYZE 整类（带不带目标、目标是 sqlite_schema 还是
  /// sqlite_master 都算）；目标表是 sqlite_stat1 / sqlite_stat4
  /// 的写入类语句（INSERT/DELETE/UPDATE/CREATE/DROP）一并算。
  /// 判定锚在语句开头的结构上，不做全文子串匹配——数据值里
  /// 出现 sqlite_stat1 字样（如标题文本）不误伤。
  static bool _isStatisticsStatement(String statement, String head) {
    if (head == 'ANALYZE') return true;
    return RegExp(
      r'^(?:INSERT\s+INTO|DELETE\s+FROM|UPDATE|'
      r'CREATE\s+TABLE(?:\s+IF\s+NOT\s+EXISTS)?|'
      r'DROP\s+TABLE(?:\s+IF\s+EXISTS)?)\s+"?sqlite_stat[14]\b',
      caseSensitive: false,
    ).hasMatch(statement.trimLeft());
  }

  /// 语句的目标表名（跳过计数按表归类用）：INSERT INTO / CREATE
  /// TABLE / ALTER TABLE / DROP TABLE 取表名，其余取头词小写。
  static String _statementTable(String statement) {
    final match = RegExp(
      r'(?:INSERT\s+INTO|CREATE\s+TABLE(?:\s+IF\s+NOT\s+EXISTS)?|'
      r'ALTER\s+TABLE|DROP\s+TABLE(?:\s+IF\s+EXISTS)?)\s+"?(\w+)',
      caseSensitive: false,
    ).firstMatch(statement.trimLeft());
    if (match != null) return match.group(1)!.toLowerCase();
    return _statementHead(statement).toLowerCase();
  }

  /// 校验临时库：四张必备表都在、作品与播放地址都大于 0。
  /// 人数可为 0（只警告、不拦：没演员信息的库作品仍可通过分类/
  /// 影视库看）。失败抛错（调用方按“原库不动”收尾）。
  Future<
    ({
      int videos,
      int actresses,
      int playUrls,
      int covers,
      int avatars,
    })
  > _validate(SqlImportExecutor executor) async {
    final tableRows = await executor.query(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final tables = {
      for (final row in tableRows) '${row['name']}',
    };
    final missing = _requiredTables.difference(tables);
    if (missing.isNotEmpty) {
      throw StateError('缺表：${missing.join('、')}，不是女优库');
    }
    Future<int> count(String sql) async {
      final rows = await executor.query(sql);
      if (rows.isEmpty) return 0;
      return (rows.first.values.first as num?)?.toInt() ?? 0;
    }

    final videos = await count('SELECT COUNT(*) FROM videos');
    final actresses = await count('SELECT COUNT(*) FROM actresses');
    final playUrls = await count('SELECT COUNT(*) FROM video_play_urls');
    final covers = await count(
      "SELECT COUNT(*) FROM videos WHERE pic_url IS NOT NULL AND pic_url <> ''",
    );
    final avatars = await count(
      "SELECT COUNT(*) FROM actresses WHERE avatar IS NOT NULL AND avatar <> ''",
    );
    if (videos == 0) throw StateError('导入的库里没有作品');
    if (playUrls == 0) throw StateError('导入的库里没有播放地址');
    return (
      videos: videos,
      actresses: actresses,
      playUrls: playUrls,
      covers: covers,
      avatars: avatars,
    );
  }

  /// 标准库关键列：四表齐且这些列都在，才算标准库、走快捷通道。
  static const _standardKeyColumns = <String, List<String>>{
    'videos': [
      'vod_id',
      'title',
      'pic_url',
      'm3u8_url',
      'vod_play_url',
      'type_name',
    ],
    'actresses': ['cate_id', 'name', 'avatar'],
    'video_actress': ['vod_id', 'cate_id'],
    'video_play_urls': ['vod_id', 'play_url'],
  };

  /// 标准表 DDL（与真库一致，见 REPORT §九）：归一化建表用；
  /// actresses 带 roster_id/claimed/sex 列，免得同步写时缺列失败。
  static const _standardTableDdl = <String, String>{
    'videos':
        'CREATE TABLE videos (vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT, m3u8_url TEXT, vod_remarks TEXT, vod_pubdate TEXT, vod_area TEXT, vod_year TEXT, vod_content TEXT, vod_play_from TEXT, vod_play_url TEXT, type_name TEXT, created_at TEXT)',
    'actresses':
        'CREATE TABLE actresses (cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT, created_at TEXT, sex TEXT, roster_id TEXT, claimed INTEGER)',
    'video_actress':
        'CREATE TABLE video_actress (vod_id TEXT, cate_id TEXT, PRIMARY KEY (vod_id, cate_id))',
    'video_play_urls':
        'CREATE TABLE video_play_urls (vod_id TEXT, play_url TEXT, play_from TEXT, PRIMARY KEY (vod_id, play_url))',
    'video_category':
        'CREATE TABLE video_category (vod_id TEXT PRIMARY KEY, main_category TEXT)',
    'video_tag':
        'CREATE TABLE video_tag (vod_id TEXT, tag_name TEXT, PRIMARY KEY (vod_id, tag_name))',
  };

  /// 头像列名（归一化后）：人物表与作品表独立头像列都认这些。
  static const _avatarColumnNames = {
    'avatar',
    'avatarurl',
    'head',
    'headimg',
    'headpic',
    'photo',
    'portrait',
    'face',
    '头像',
    'pic',
    'image',
  };

  static bool _isAvatarColumnName(String column) =>
      _avatarColumnNames.contains(normalizeDbFieldName(column));

  /// 字段不一样的 .sql 归一化（2026-11-25 用户令：不管什么字段的
  /// .sql 导入，都要能显示列表/封面/头像/播放链接、能播）：
  /// 先判标准库（四表齐且关键列在）→ 快捷通道，返回 0；
  /// 否则按字段名宽容映射，把作品表读行建成标准表。
  /// 缺播放地址的行跳过并计数（返回值）；缺失的可选字段按空处理。
  /// [onNormalized] 每读完一批作品行回调一次（累计已归一化行数），
  /// 调用方用它报“正在归一化”进度。
  Future<int> _normalizeImport(
    SqlImportExecutor executor, {
    required void Function(int rows) onNormalized,
  }) async {
    final tableRows = await executor.query(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final tables = <String>{
      for (final row in tableRows) '${row['name']}',
    }..removeWhere((t) => t.startsWith('sqlite_'));
    // 探每张表的列：答不出列信息（测试假执行器）时按老口径——
    // 四表齐当标准库，不齐报缺表。
    final tableColumns = <String, List<String>>{};
    final pkColumns = <String, String>{};
    var canInspect = true;
    for (final table in tables) {
      final cols = await executor.query(
        'PRAGMA table_info(${_ident(table)})',
      );
      final names = <String>[];
      for (final col in cols) {
        final name = col['name'];
        if (name == null) continue;
        names.add('$name');
        if (col['pk'] == 1) pkColumns[table] = '$name';
      }
      if (names.isEmpty) {
        canInspect = false;
        break;
      }
      tableColumns[table] = names;
    }
    if (!canInspect) {
      final missing = _requiredTables.difference(tables);
      if (missing.isNotEmpty) {
        throw StateError('缺表：${missing.join('、')}，不是女优库');
      }
      return 0;
    }
    if (_isStandardLibrary(tableColumns)) {
      // 标准库：可选表缺了就补建空表（首页分类/标签读它们）。
      for (final optional in ['video_category', 'video_tag']) {
        if (!tables.contains(optional)) {
          await executor.execute(_standardTableDdl[optional]!);
        }
      }
      return 0;
    }
    return _normalizeToStandard(
      executor,
      tables,
      tableColumns,
      pkColumns,
      onNormalized: onNormalized,
    );
  }

  bool _isStandardLibrary(Map<String, List<String>> tableColumns) {
    for (final entry in _standardKeyColumns.entries) {
      final columns = tableColumns[entry.key];
      if (columns == null) return false;
      final lower = columns.map((c) => c.toLowerCase()).toSet();
      for (final required in entry.value) {
        if (!lower.contains(required)) return false;
      }
    }
    return true;
  }

  /// 归一化本体：作品表读行 → 建标准表。已存在但结构不对的标准表
  /// 先改名成 <名>_source（数据不动），再建标准表。
  Future<int> _normalizeToStandard(
    SqlImportExecutor executor,
    Set<String> tables,
    Map<String, List<String>> tableColumns,
    Map<String, String> pkColumns, {
    required void Function(int rows) onNormalized,
  }) async {
    final schema = classifyGenericTables(tableColumns, pkColumns: pkColumns);
    var works = schema.worksTable;
    if (works != null) {
      final playCol = works.columnFor(GenericDbRole.playUrl);
      if (playCol != null && _isAvatarColumnName(playCol)) {
        // 唯一的“地址列”其实是头像列：这张表没有真播放地址。
        works = null;
      }
    }
    if (works == null) {
      throw StateError('认不出作品表：没有同时带标题与播放地址的表');
    }
    final titleCol = works.columnFor(GenericDbRole.title)!;
    final playCol = works.columnFor(GenericDbRole.playUrl)!;
    final persons =
        schema.personsTable ?? _personsTableFallback(schema, works);

    // 标准表名已存在但结构不对：先改名（数据不动），再建标准表。
    final renamed = <String, String>{};
    for (final name in _standardTableDdl.keys) {
      if (!tables.contains(name)) continue;
      var source = '${name}_source';
      if (tables.contains(source)) source = '${name}_source2';
      if (tables.contains(source)) {
        throw StateError('表名冲突：$name 与 $source 都已存在');
      }
      await executor.execute(
        'ALTER TABLE ${_ident(name)} RENAME TO ${_ident(source)}',
      );
      renamed[name] = source;
    }
    String sourceName(String original) => renamed[original] ?? original;
    for (final ddl in _standardTableDdl.values) {
      await executor.execute(ddl);
    }

    // 人物表：名 → cate_id 映射（作品行挂人用），头像一起进库。
    final nameToCateId = <String, String>{};
    if (persons != null) {
      final personsTable = sourceName(persons.table);
      final personsNameCol =
          persons.columnFor(GenericDbRole.title) ??
          persons.columnFor(GenericDbRole.actress);
      final personsAvatarCol =
          persons.columnFor(GenericDbRole.cover) ??
          _avatarColumn(persons.allColumns);
      final personsIdCol =
          persons.columnFor(GenericDbRole.code) ?? persons.idColumn;
      if (personsNameCol != null) {
        await _forEachRow(
          executor,
          personsTable,
          columns: [
            ?personsIdCol,
            personsNameCol,
            ?personsAvatarCol,
          ],
          onBatch: (rows) async {
            final inserts = <String>[];
            for (final row in rows) {
              final name = _cellText(row[personsNameCol]);
              if (name.isEmpty) continue;
              final id = personsIdCol == null
                  ? name
                  : _cellText(row[personsIdCol]);
              final cateId = id.isEmpty ? name : id;
              nameToCateId[name] = cateId;
              final avatar = personsAvatarCol == null
                  ? ''
                  : resolveCoverUrl(row[personsAvatarCol]);
              inserts.add(
                'INSERT OR IGNORE INTO actresses (cate_id, name, avatar, sex, roster_id, claimed) '
                "VALUES (${_q(cateId)}, ${_q(name)}, ${_q(avatar)}, '', '', 0)",
              );
            }
            if (inserts.isNotEmpty) await executor.executeBatch(inserts);
          },
        );
      }
    }

    // 作品表各角色列。
    final coverCol = works.columnFor(GenericDbRole.cover);
    final codeCol = works.columnFor(GenericDbRole.code);
    final categoryCol = works.columnFor(GenericDbRole.category);
    final actressCol = works.columnFor(GenericDbRole.actress);
    final dateCol = works.columnFor(GenericDbRole.date);
    // 作品表独立头像列：只认 avatar/avatarurl/头像，且不是封面列那一列。
    final worksAvatarCol = _avatarColumn(
      works.allColumns,
      exclude: coverCol,
    );
    final worksTable = sourceName(works.table);
    final playFrom = works.table;
    final readColumns = <String>{
      titleCol,
      playCol,
      ?codeCol,
      ?coverCol,
      ?categoryCol,
      ?actressCol,
      ?dateCol,
      ?worksAvatarCol,
    }.toList();
    var skipped = 0;
    var normalized = 0;
    await _forEachRow(
      executor,
      worksTable,
      columns: readColumns,
      onBatch: (rows) async {
        final videoInserts = <String>[];
        final urlInserts = <String>[];
        final categoryInserts = <String>[];
        final actressInserts = <String>[];
        final linkInserts = <String>[];
        for (final row in rows) {
          final playUrl = extractPlayUrl(row[playCol]);
          if (playUrl.isEmpty) {
            skipped++;
            continue;
          }
          final rowId = row['rowid'];
          final code = codeCol == null ? '' : _cellText(row[codeCol]);
          final vodId = code.isEmpty ? 'row-${rowId ?? ''}' : code;
          var title = _cellText(row[titleCol]);
          if (title.isEmpty) title = vodId;
          final cover = coverCol == null
              ? ''
              : resolveCoverUrl(row[coverCol]);
          final category = categoryCol == null
              ? ''
              : _cellText(row[categoryCol]);
          final date = dateCol == null ? '' : _cellText(row[dateCol]);
          videoInserts.add(
            'INSERT OR IGNORE INTO videos (vod_id, title, pic_url, m3u8_url, vod_remarks, vod_pubdate, vod_area, vod_year, vod_content, vod_play_from, vod_play_url, type_name) '
            "VALUES (${_q(vodId)}, ${_q(title)}, ${_q(cover)}, ${_q(playUrl)}, '', ${_q(date)}, '', '', '', ${_q(playFrom)}, ${_q(playUrl)}, ${_q(category)})",
          );
          urlInserts.add(
            'INSERT OR IGNORE INTO video_play_urls (vod_id, play_url, play_from) '
            "VALUES (${_q(vodId)}, ${_q(playUrl)}, ${_q(playFrom)})",
          );
          if (category.isNotEmpty) {
            categoryInserts.add(
              'INSERT OR IGNORE INTO video_category (vod_id, main_category) '
              "VALUES (${_q(vodId)}, ${_q(category)})",
            );
          }
          // 女优：作品行里的名字先挂进 actresses（头像只认作品表
          // 的独立头像列），再挂 video_actress 关联。
          final names = actressCol == null
              ? const <String>[]
              : _splitActressNames(_cellText(row[actressCol]));
          for (final name in names) {
            final cateId = nameToCateId[name] ?? name;
            final avatar = worksAvatarCol == null
                ? ''
                : resolveCoverUrl(row[worksAvatarCol]);
            actressInserts.add(
              'INSERT OR IGNORE INTO actresses (cate_id, name, avatar, sex, roster_id, claimed) '
              "VALUES (${_q(cateId)}, ${_q(name)}, ${_q(avatar)}, '', '', 0)",
            );
            linkInserts.add(
              'INSERT OR IGNORE INTO video_actress (vod_id, cate_id) '
              "VALUES (${_q(vodId)}, ${_q(cateId)})",
            );
          }
        }
        for (final batch in [
          videoInserts,
          urlInserts,
          categoryInserts,
          actressInserts,
          linkInserts,
        ]) {
          if (batch.isNotEmpty) await executor.executeBatch(batch);
        }
        normalized += rows.length;
        onNormalized(normalized);
      },
    );
    return skipped;
  }

  /// 人物表兜底：classify 没认出来时（比如头像列叫 avatar_url 被算
  /// 成播放地址列，或人名列只认出 actress 角色没认出 title 角色），
  /// 再按“有名列、且播放地址列全是头像列”扫一遍。分类字典表排除。
  GenericDbTableMapping? _personsTableFallback(
    GenericDbSchema schema,
    GenericDbTableMapping works,
  ) {
    for (final mapping in schema.tables) {
      if (mapping.table == works.table) continue;
      final normalizedTable = normalizeDbFieldName(mapping.table);
      if (normalizedTable == 'categories' ||
          normalizedTable == 'category') {
        continue;
      }
      final nameCol =
          mapping.columnFor(GenericDbRole.actress) ??
          mapping.columnFor(GenericDbRole.title);
      if (nameCol == null) continue;
      final playCol = mapping.columnFor(GenericDbRole.playUrl);
      if (playCol != null && !_isAvatarColumnName(playCol)) continue;
      return mapping;
    }
    return null;
  }

  /// 作品表/人物表里找头像列：第一个头像名、且不是封面列那一列。
  static String? _avatarColumn(
    List<String> columns, {
    String? exclude,
  }) {
    for (final column in columns) {
      if (column == exclude) continue;
      if (_isAvatarColumnName(column)) return column;
    }
    return null;
  }

  /// 分页读一张表（ORDER BY rowid，每页 [batchSize] 行），
  /// 读完一批调一次 [onBatch]。行里带 rowid 键。
  Future<void> _forEachRow(
    SqlImportExecutor executor,
    String table, {
    required List<String> columns,
    required Future<void> Function(List<Map<String, Object?>> rows) onBatch,
  }) async {
    final selectList = [
      'rowid',
      for (final c in columns) _ident(c),
    ].join(', ');
    var offset = 0;
    while (true) {
      final rows = await executor.query(
        'SELECT $selectList FROM ${_ident(table)} '
        'ORDER BY rowid LIMIT $batchSize OFFSET $offset',
      );
      if (rows.isEmpty) return;
      await onBatch(rows);
      offset += rows.length;
      if (rows.length < batchSize) return;
    }
  }

  /// SQL 字符串字面量：单引号加倍转义。
  static String _q(String value) => "'${value.replaceAll("'", "''")}'";

  /// SQL 标识符（表名/列名）：双引号包起来，双引号加倍转义。
  static String _ident(String name) => '"${name.replaceAll('"', '""')}"';

  /// 单元格取值：null → ''，其余转字符串去首尾空白。
  static String _cellText(Object? value) =>
      value == null ? '' : value.toString().trim();

  /// 女优名拆分：`A、B、C` / `A, B` / `A/B` / `A|B` 都拆，去重保序。
  static List<String> _splitActressNames(String text) {
    if (text.isEmpty) return const [];
    final names = <String>[];
    for (final part in text.split(RegExp(r'[、，,;；/｜|]+'))) {
      final name = part.trim();
      if (name.isNotEmpty && !names.contains(name)) names.add(name);
    }
    return names;
  }
}

/// 名册汇总累加器（导入时落库用，与旧开库重建的归并口径一致）：
/// 同一个人被拆成多行时，作品数相加、头像取第一条能加载的
/// （裸域名跳过）、最新作品日期取最大。
class _ImportRollupAcc {
  _ImportRollupAcc(this.firstRowid);

  final int firstRowid;
  String avatar = '';
  int works = 0;
  String lastDate = '';

  /// 性别按人归并（同一名字下有一行是男优就算男优）；默认未知
  /// （''），没有男优行只说明没确认过性别，不等于女。
  String sex = '';
}
