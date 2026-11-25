import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

/// 女优库 .sql 导入（2026-11-25 用户令）：把女优库.db 改成 .sql 后，
/// 从演员库设置里选 .sql / .sql.gz 文件导回手机，导完直接当主库用。
///
/// 流程：流式读 SQL（整文件不进内存）→ 临时库分批执行
/// （每 1000 条 INSERT 一个事务）→ 校验四项（作品数/人数/播放
/// 地址/封面/头像）→ 关主库连接 → 备份现库为 .bak → 临时库改名
/// 顶替主库。校验不过、取消、执行出错都在换库之前停下：原库一字
/// 不动，临时文件删掉。
///
/// 红线：临时库只在导入时存在，导完即改名成主库；journal_mode /
/// synchronous 一个字不改（读写库不抄参考文件的 OFF/WAL 写法）。
/// 导入失败绝不把半成品库留在主库路径上。

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
/// `--` 行注释（不在字符串里时）整行跳过。sqlite3 .dump 的输出
/// 就是这个格式：每条 INSERT 一行、建表跨行、字符串里可能有分号
/// 与换行。
class SqlStatementSplitter {
  final _buffer = StringBuffer();
  var _inString = false;

  /// 喂一行（不带换行符），返回这一行里切完的语句（0 条或多条）。
  List<String> addLine(String line) {
    final out = <String>[];
    var i = 0;
    // 行注释：不在字符串里时 `--` 后面整行不要。
    if (!_inString) {
      final comment = line.indexOf('--');
      if (comment == 0) return out;
      if (comment > 0) line = line.substring(0, comment);
    }
    while (i < line.length) {
      final c = line[i];
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
        error: '没有可替换的数据库路径（先绑定 MYTV）',
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
      var statements = 0;
      var bytesRead = 0;
      var lastReportedBytes = 0;
      final splitter = SqlStatementSplitter();
      final pendingInserts = <String>[];

      Future<void> flushInserts() async {
        if (pendingInserts.isEmpty) return;
        final batch = List<String>.of(pendingInserts);
        pendingInserts.clear();
        await executor!.executeBatch(batch);
        statements += batch.length;
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
          if (head == 'INSERT') {
            pendingInserts.add(statement);
            if (pendingInserts.length >= batchSize) {
              await flushInserts();
              checkCancelled();
            }
          } else {
            await flushInserts();
            await executor.execute(statement);
            statements++;
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
        if (head != 'BEGIN' && head != 'COMMIT') {
          if (head == 'INSERT') {
            pendingInserts.add(tail);
          } else {
            await executor.execute(tail);
            statements++;
          }
        }
      }
      await flushInserts();
      checkCancelled();

      // 校验（还在临时库上，不合格不换库）。
      onProgress(
        ActressSqlImportProgress(
          phase: '正在校验',
          statements: statements,
          bytesRead: bytesRead,
          totalBytes: totalBytes,
        ),
      );
      final counts = await _validate(executor);
      final warnings = <String>[];
      if (counts.covers == 0) warnings.add('导入的库里没有封面');
      if (counts.avatars == 0) warnings.add('导入的库里没有头像');
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
      return ActressSqlImportResult(
        ok: false,
        error: '导入失败：${e.toString().split('\n').first}',
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

  /// 语句头一个词（INSERT / CREATE / PRAGMA / BEGIN / COMMIT …）。
  static String _statementHead(String statement) {
    final text = statement.trimLeft();
    final end = text.indexOf(RegExp(r'\s|\('));
    final head = (end < 0 ? text : text.substring(0, end)).toUpperCase();
    // CREATE TABLE / CREATE INDEX / CREATE UNIQUE INDEX：头词都是 CREATE。
    return head;
  }

  /// 校验临时库：四张必备表都在、作品/人数/播放地址都大于 0。
  /// 失败抛错（调用方按“原库不动”收尾）。
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
    if (actresses == 0) throw StateError('导入的库里没有演员');
    if (playUrls == 0) throw StateError('导入的库里没有播放地址');
    return (
      videos: videos,
      actresses: actresses,
      playUrls: playUrls,
      covers: covers,
      avatars: avatars,
    );
  }
}
