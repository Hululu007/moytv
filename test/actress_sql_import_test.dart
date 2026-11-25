import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_sql_import.dart';

/// 假执行器：只记 SQL、不碰真 sqlite（flutter test 里 sqflite
/// 跑不起来，见 test/actress_film_library_test.dart 头注释）。
/// INSERT 按表计数，校验查询按记下来的行数回答；CREATE 建的表
/// 名记下来，供“缺表”校验分支用。
class _RecordingExecutor implements SqlImportExecutor {
  final batches = <List<String>>[];
  final singles = <String>[];
  final tables = <String>{};
  final counts = <String, int>{};
  var closed = false;

  /// 遇到往这张表 INSERT 就抛错（换库失败注入用）。
  String? failOnTable;

  /// 含这个子串的语句执行时抛错（单条坏语句注入用）。
  String? failOnStatementContaining;

  /// 校验查询一律抛错。
  var failQuery = false;

  /// 失败注入判定：批量与单条执行共用（真 sqflite 里一条 INSERT
  /// 无论走批还是走单条都会失败）。
  void _checkFail(String sql) {
    final marker = failOnStatementContaining;
    if (marker != null && sql.contains(marker)) {
      throw StateError('fake fail on statement');
    }
    final table = RegExp(
      r'INSERT INTO\s+"?(\w+)',
      caseSensitive: false,
    ).firstMatch(sql)?.group(1)?.toLowerCase();
    if (table != null && failOnTable == table) {
      throw StateError('fake fail on $table');
    }
  }

  static String? _insertTable(String sql) {
    return RegExp(
      r'INSERT INTO\s+"?(\w+)',
      caseSensitive: false,
    ).firstMatch(sql)?.group(1)?.toLowerCase();
  }

  @override
  Future<void> execute(String sql) async {
    _checkFail(sql);
    singles.add(sql);
    final upper = sql.trimLeft().toUpperCase();
    if (upper.startsWith('CREATE TABLE')) {
      final name = RegExp(
        r'CREATE TABLE\s+"?(\w+)',
        caseSensitive: false,
      ).firstMatch(sql)?.group(1)?.toLowerCase();
      if (name != null) tables.add(name);
    }
    // 单条 INSERT 也计数：整批回滚后逐条重跑时校验数要对得上。
    final table = _insertTable(sql);
    if (table != null) counts[table] = (counts[table] ?? 0) + 1;
  }

  @override
  Future<void> executeBatch(List<String> statements) async {
    batches.add(List<String>.of(statements));
    // 先全检一遍再计数：真 sqflite 的批是原子的，一条坏全批回滚、
    // 一条不落库。
    for (final statement in statements) {
      _checkFail(statement);
    }
    for (final statement in statements) {
      final table = _insertTable(statement);
      if (table == null) continue;
      counts[table] = (counts[table] ?? 0) + 1;
    }
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql) async {
    if (failQuery) throw StateError('fake query fail');
    if (sql.contains('sqlite_master')) {
      return [
        for (final t in tables) {'name': t},
      ];
    }
    final table =
        RegExp(r'FROM\s+(\w+)', caseSensitive: false)
            .firstMatch(sql)
            ?.group(1)
            ?.toLowerCase() ??
        '';
    // 样本夹具：300 部全有封面、30 人全有头像，过滤计数就是全表数。
    return [
      {'COUNT(*)': counts[table] ?? 0},
    ];
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  group('SqlStatementSplitter 切分', () {
    test('字符串里的分号不切', () {
      final splitter = SqlStatementSplitter();
      final out = splitter.addLine(
        "INSERT INTO videos VALUES('a;b','x');",
      );
      expect(out, hasLength(1));
      expect(out.first, "INSERT INTO videos VALUES('a;b','x');");
    });

    test("'' 转义不是串尾", () {
      final splitter = SqlStatementSplitter();
      final out = splitter.addLine(
        "INSERT INTO videos VALUES('it''s; fine','x');",
      );
      expect(out, hasLength(1));
    });

    test('跨行字符串是一条语句', () {
      final splitter = SqlStatementSplitter();
      final first = splitter.addLine(
        "INSERT INTO videos VALUES('第一行",
      );
      expect(first, isEmpty);
      final second = splitter.addLine("第二行; 还有分号');");
      expect(second, hasLength(1));
      expect(
        second.first,
        "INSERT INTO videos VALUES('第一行\n第二行; 还有分号');",
      );
    });

    test('一行多条与 -- 注释', () {
      final splitter = SqlStatementSplitter();
      final out = splitter.addLine(
        'PRAGMA foreign_keys=OFF; -- 注释里的分号不算',
      );
      expect(out, ['PRAGMA foreign_keys=OFF;']);
      expect(splitter.addLine('-- 整行注释'), isEmpty);
    });

    test('建表跨行', () {
      final splitter = SqlStatementSplitter();
      expect(splitter.addLine('CREATE TABLE videos('), isEmpty);
      expect(splitter.addLine('vod_id TEXT PRIMARY KEY,'), isEmpty);
      final done = splitter.addLine('title TEXT);');
      expect(done, hasLength(1));
      expect(done.first.startsWith('CREATE TABLE videos('), isTrue);
    });

    test('字符串里的 -- 不是注释（真文件 k1037 根因）', () {
      final splitter = SqlStatementSplitter();
      final out = splitter.addLine(
        "INSERT INTO videos VALUES('k1037','K1037 餌食牝 -- 北上尚子','x');",
      );
      expect(out, hasLength(1));
      expect(out.first, contains('餌食牝 -- 北上尚子'));
      // 下一行不被污染：旧写法在这里会把下一条吞进上一条的
      // 字符串里，切出 near "pfes" 的合并坏语句。
      final next = splitter.addLine(
        "INSERT INTO videos VALUES('pfes-065','PFES-065','y');",
      );
      expect(next, hasLength(1));
      expect(
        next.first,
        "INSERT INTO videos VALUES('pfes-065','PFES-065','y');",
      );
    });

    test('字符串里的 /* 不是块注释', () {
      final splitter = SqlStatementSplitter();
      final out = splitter.addLine(
        "INSERT INTO videos VALUES('a','[真实故事/**女人]','x');",
      );
      expect(out, hasLength(1));
      expect(out.first, contains('[真实故事/**女人]'));
    });

    test('字符串外的块注释被丢弃（可跨行）', () {
      final splitter = SqlStatementSplitter();
      final out = splitter.addLine(
        'INSERT INTO videos /* 列注释; 不算分号 */ VALUES(1);',
      );
      expect(out, ['INSERT INTO videos  VALUES(1);']);
      final s2 = SqlStatementSplitter();
      expect(s2.addLine('/* 跨行注释'), isEmpty);
      expect(s2.addLine('还没完 */'), isEmpty);
      expect(
        s2.addLine('INSERT INTO videos VALUES(2);'),
        ['INSERT INTO videos VALUES(2);'],
      );
    });

    test('跨行字符串中间一行以 -- 开头也是数据', () {
      final splitter = SqlStatementSplitter();
      expect(
        splitter.addLine("INSERT INTO videos VALUES('第一行"),
        isEmpty,
      );
      final out = splitter.addLine("-- 这行在字符串里');");
      expect(out, hasLength(1));
      expect(out.first, contains('\n-- 这行在字符串里'));
    });

    test('语句后跟行注释不污染下一条', () {
      final splitter = SqlStatementSplitter();
      final out = splitter.addLine('INSERT INTO videos VALUES(1); -- 完了');
      expect(out, ['INSERT INTO videos VALUES(1);']);
      expect(
        splitter.addLine('INSERT INTO videos VALUES(2);'),
        ['INSERT INTO videos VALUES(2);'],
      );
    });
  });

  group('ActressSqlImporter 真夹具导入（300 行样本）', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('sql_import_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    /// 假执行器工厂：同时在临时库路径上落一个标记文件，模拟
    /// sqflite 建出来的临时库文件（换库改名要这个文件存在）。
    Future<SqlImportExecutor> Function(String) factoryFor(
      _RecordingExecutor executor, {
      String marker = 'NEWDB',
    }) {
      return (tempPath) async {
        await File(tempPath).writeAsString(marker);
        return executor;
      };
    }

    test('.sql 全链路：行数/播放地址/封面/头像都对上', () async {
      final executor = _RecordingExecutor();
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      var closeCalls = 0;
      final progress = <ActressSqlImportProgress>[];
      final importer = ActressSqlImporter(
        batchSize: 100,
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {
          closeCalls++;
        },
        onProgress: progress.add,
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(result.videos, 300);
      expect(result.actresses, 30);
      expect(result.playUrls, 480);
      expect(result.covers, 300);
      expect(result.avatars, 30);
      expect(result.warnings, isEmpty);
      expect(result.needsReload, isTrue);
      expect(closeCalls, 1);
      // 换库：现库被标记文件顶替，原库进了 .bak，临时文件没了。
      expect(await File(livePath).readAsString(), 'NEWDB');
      expect(await File('$livePath.bak').readAsString(), 'OLDDB');
      expect(await File('$livePath.importing').exists(), isFalse);
      // 分批：每批不超 100 条，INSERT 总数与夹具一致。
      expect(
        executor.batches.every((b) => b.length <= 100),
        isTrue,
      );
      final inserted = executor.batches.fold<int>(
        0,
        (sum, b) => sum + b.length,
      );
      expect(inserted, 27556);
      // .dump 自带的 BEGIN/COMMIT 没进执行器（事务由导入器按批管）。
      expect(
        executor.singles.any(
          (s) =>
              s.trim().toUpperCase() == 'BEGIN TRANSACTION' ||
              s.trim().toUpperCase() == 'COMMIT',
        ),
        isFalse,
      );
      // 进度报过、语句数单调涨、最后一次是校验阶段。
      expect(progress, isNotEmpty);
      expect(progress.last.phase, '正在校验');
      for (var i = 1; i < progress.length; i++) {
        expect(
          progress[i].statements >= progress[i - 1].statements,
          isTrue,
        );
      }
    });

    test('.sql.gz 同样能导', () async {
      final executor = _RecordingExecutor();
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final importer = ActressSqlImporter(
        batchSize: 1000,
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql.gz',
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(result.videos, 300);
      expect(result.playUrls, 480);
      expect(await File(livePath).readAsString(), 'NEWDB');
    });

    test('校验不过：空库不换库，原库一字不动', () async {
      final executor = _RecordingExecutor();
      final emptySql = File('${tempDir.path}/empty.sql');
      await emptySql.writeAsString(
        'PRAGMA foreign_keys=OFF;\n'
        'BEGIN TRANSACTION;\n'
        'CREATE TABLE videos(vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT);\n'
        'CREATE TABLE actresses(cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT);\n'
        'CREATE TABLE video_actress(vod_id TEXT, cate_id TEXT);\n'
        'CREATE TABLE video_play_urls(vod_id TEXT, play_url TEXT);\n'
        'COMMIT;\n',
      );
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      var closeCalls = 0;
      final importer = ActressSqlImporter(
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: emptySql.path,
        dbPath: livePath,
        closeDatabase: () async {
          closeCalls++;
        },
        onProgress: (_) {},
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('没有作品'));
      expect(closeCalls, 0);
      expect(result.needsReload, isFalse);
      expect(await File(livePath).readAsString(), 'OLDDB');
      expect(await File('$livePath.bak').exists(), isFalse);
      expect(await File('$livePath.importing').exists(), isFalse);
    });

    test('缺表：不是女优库不换库', () async {
      final executor = _RecordingExecutor();
      final badSql = File('${tempDir.path}/bad.sql');
      await badSql.writeAsString(
        'CREATE TABLE videos(vod_id TEXT PRIMARY KEY);\n'
        'INSERT INTO videos VALUES(\'x\');\n',
      );
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final importer = ActressSqlImporter(
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: badSql.path,
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('缺表'));
      expect(await File(livePath).readAsString(), 'OLDDB');
    });

    test('取消：停在换库前，原库不动', () async {
      final executor = _RecordingExecutor();
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      var closeCalls = 0;
      final importer = ActressSqlImporter(
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {
          closeCalls++;
        },
        onProgress: (_) {},
        isCancelled: () => true,
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('已取消'));
      expect(closeCalls, 0);
      expect(await File(livePath).readAsString(), 'OLDDB');
      expect(await File('$livePath.importing').exists(), isFalse);
    });

    test('执行中途出错：临时文件清掉，原库不动', () async {
      final executor = _RecordingExecutor()..failOnTable = 'video_tag';
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final importer = ActressSqlImporter(
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(result.ok, isFalse);
      expect(await File(livePath).readAsString(), 'OLDDB');
      expect(await File('$livePath.bak').exists(), isFalse);
      expect(await File('$livePath.importing').exists(), isFalse);
    });

    // 2026-11-25 导入防卡死（用户令）：取消/失败后原库必须还能
    // 正常用、能再导一次——不是只剩文件没动，而是下一步导入能成。
    // 假执行器世界里“能用”= 活库文件内容一字不动、无残留临时文件、
    // needsReload 为假（库连接没关过，App 接着用旧库）；再导一次
    // 走完整链路、行数对上。
    test('取消后原库仍可用、能再导一次', () async {
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      // 先导一次好的，活库成为 NEWDB。
      final first = ActressSqlImporter(
        executorFactory: factoryFor(_RecordingExecutor()),
      );
      final firstResult = await first.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(firstResult.ok, isTrue, reason: firstResult.error);
      expect(await File(livePath).readAsString(), 'NEWDB');
      // 再导一次，中途取消。
      var closeCalls = 0;
      final cancelled = ActressSqlImporter(
        executorFactory: factoryFor(_RecordingExecutor()),
      );
      final cancelResult = await cancelled.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {
          closeCalls++;
        },
        onProgress: (_) {},
        isCancelled: () => true,
      );
      expect(cancelResult.ok, isFalse);
      expect(cancelResult.error, contains('已取消'));
      expect(closeCalls, 0);
      expect(cancelResult.needsReload, isFalse);
      expect(await File(livePath).readAsString(), 'NEWDB');
      expect(await File('$livePath.bak').readAsString(), 'OLDDB');
      expect(await File('$livePath.importing').exists(), isFalse);
      // 取消后马上再导好的：能成，行数对上。
      final retryExecutor = _RecordingExecutor();
      final retry = ActressSqlImporter(
        executorFactory: factoryFor(retryExecutor),
      );
      final retryResult = await retry.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(retryResult.ok, isTrue, reason: retryResult.error);
      expect(retryResult.videos, 300);
      expect(retryResult.playUrls, 480);
      expect(await File(livePath).readAsString(), 'NEWDB');
      expect(await File('$livePath.bak').readAsString(), 'NEWDB');
      expect(await File('$livePath.importing').exists(), isFalse);
    });

    test('中途出错后原库仍可用、能再导一次', () async {
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final first = ActressSqlImporter(
        executorFactory: factoryFor(_RecordingExecutor()),
      );
      final firstResult = await first.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(firstResult.ok, isTrue, reason: firstResult.error);
      // 中途往 video_tag 插就抛错。
      final failing = ActressSqlImporter(
        executorFactory: factoryFor(
          _RecordingExecutor()..failOnTable = 'video_tag',
        ),
      );
      final failResult = await failing.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(failResult.ok, isFalse);
      expect(await File(livePath).readAsString(), 'NEWDB');
      expect(await File('$livePath.bak').readAsString(), 'OLDDB');
      expect(await File('$livePath.importing').exists(), isFalse);
      // 出错后马上再导好的：能成，行数对上。
      final retry = ActressSqlImporter(
        executorFactory: factoryFor(_RecordingExecutor()),
      );
      final retryResult = await retry.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(retryResult.ok, isTrue, reason: retryResult.error);
      expect(retryResult.videos, 300);
      expect(retryResult.playUrls, 480);
      expect(await File('$livePath.bak').readAsString(), 'NEWDB');
      expect(await File('$livePath.importing').exists(), isFalse);
    });

    test('非 .sql 文件直接拒绝', () async {
      final executor = _RecordingExecutor();
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final txt = File('${tempDir.path}/x.txt');
      await txt.writeAsString('hello');
      final importer = ActressSqlImporter(
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: txt.path,
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('.sql'));
    });

    // 2026-11-25 用户令：单条坏语句不许再炸掉整个导入——跳过
    // 计数、导完汇总写明；只有整批全灭（系统性）才整单失败。
    test('单条坏语句跳过计数、不炸整单', () async {
      final sql = File('${tempDir.path}/one_bad.sql');
      await sql.writeAsString(
        'CREATE TABLE videos(vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT, m3u8_url TEXT, vod_play_url TEXT, type_name TEXT);\n'
        'CREATE TABLE actresses(cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT);\n'
        'CREATE TABLE video_actress(vod_id TEXT, cate_id TEXT);\n'
        'CREATE TABLE video_play_urls(vod_id TEXT, play_url TEXT);\n'
        "INSERT INTO videos VALUES('v1','片一','p','m','u','成人影片');\n"
        "INSERT INTO videos VALUES('BAD','坏片','p','m','u','成人影片');\n"
        "INSERT INTO videos VALUES('v2','片二','p','m','u','成人影片');\n"
        "INSERT INTO video_play_urls VALUES('v1','u');\n"
        "INSERT INTO video_play_urls VALUES('v2','u');\n",
      );
      final executor = _RecordingExecutor()
        ..failOnStatementContaining = "'BAD'";
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final importer = ActressSqlImporter(
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: sql.path,
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(result.videos, 2);
      expect(result.playUrls, 2);
      expect(result.skippedStatements, 1);
      expect(result.skippedStatementTables, {'videos': 1});
      expect(result.skippedStatementSample, contains('videos'));
      expect(result.warnings.join('\n'), contains('跳过 1 条出错语句'));
      expect(await File(livePath).readAsString(), 'NEWDB');
    });

    // 转储自带的 BEGIN TRANSACTION; / COMMIT; 是事务包装，导入器
    // 自己按批管事务，必须跳过不执行：COMMIT; 的头词曾因带分号
    // 没被认出来、被真执行（无活动事务报错），全量验收抓到。
    test('转储的 BEGIN/COMMIT 包装不执行、不计数', () async {
      final sql = File('${tempDir.path}/wrapped.sql');
      await sql.writeAsString(
        'BEGIN TRANSACTION;\n'
        'CREATE TABLE videos(vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT, m3u8_url TEXT, vod_play_url TEXT, type_name TEXT);\n'
        'CREATE TABLE actresses(cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT);\n'
        'CREATE TABLE video_actress(vod_id TEXT, cate_id TEXT);\n'
        'CREATE TABLE video_play_urls(vod_id TEXT, play_url TEXT);\n'
        "INSERT INTO videos VALUES('v1','片一','p','m','u','成人影片');\n"
        "INSERT INTO video_play_urls VALUES('v1','u');\n"
        'COMMIT;\n',
      );
      // 执行到 COMMIT 就抛错：修前它会被真执行、记一条跳过。
      final executor = _RecordingExecutor()
        ..failOnStatementContaining = 'COMMIT';
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final importer = ActressSqlImporter(
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: sql.path,
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(result.videos, 1);
      expect(result.skippedStatements, 0);
      expect(
        executor.singles.where((s) => s.toUpperCase().contains('COMMIT')),
        isEmpty,
      );
    });

    test('整批全灭是系统性失败：整单失败、原库不动', () async {
      final sql = File('${tempDir.path}/all_bad.sql');
      await sql.writeAsString(
        'CREATE TABLE videos(vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT, m3u8_url TEXT, vod_play_url TEXT, type_name TEXT);\n'
        'CREATE TABLE actresses(cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT);\n'
        'CREATE TABLE video_actress(vod_id TEXT, cate_id TEXT);\n'
        'CREATE TABLE video_play_urls(vod_id TEXT, play_url TEXT);\n'
        "INSERT INTO videos VALUES('v1','片一','p','m','u','成人影片');\n"
        "INSERT INTO video_play_urls VALUES('v1','u');\n",
      );
      // 所有 INSERT 都执行失败（模拟库锁死/磁盘满那类系统性失败）。
      final executor = _RecordingExecutor()
        ..failOnStatementContaining = 'VALUES(';
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final importer = ActressSqlImporter(
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: sql.path,
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('全部执行失败'));
      // 失败原因不带“导入失败：”前缀（展示处自己带，防双层）。
      expect(result.error, isNot(startsWith('导入失败')));
      expect(await File(livePath).readAsString(), 'OLDDB');
      expect(await File('$livePath.importing').exists(), isFalse);
    });
  });
}
