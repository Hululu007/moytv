// 女优库加载优化（2026-11-26）回归测试：
// 1. 名单加载守卫：查询抛错不再永久转圈，进失败态（原因 + 重试），
//    重试能恢复；查询永不返回时超时（首屏 20 秒）后进失败态。
// 2. 名单进程级缓存：State 销毁重建（切区回来）命中缓存免查库。
// 3. NvkuEntryCache 名单槽与 dbStamp 的 -wal 分量（纯单元）。
// 4. 导入器收尾落库：索引集 + 汇总表在导入临时库阶段建好，归并
//    口径（作品数相加/头像取可加载/男优归并/最新日期取最大）对。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_mytv_bind.dart';
import 'package:moyi/actress/actress_nvku_cache.dart';
import 'package:moyi/actress/actress_sql_import.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Future<LocalStore> _makeStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

/// 名单查询可切换失败/挂起的内存库替身。
class _FlakyListDb extends MemoryActressDatabase {
  var failList = false;
  var hangList = false;
  var listCalls = 0;

  @override
  Future<List<ActressPerson>> listPersons({
    required ActressSexFilter sex,
    required ActressSort sort,
    required String query,
    required int offset,
    required int limit,
    String tag = '',
    String category = '',
    String videoTag = '',
  }) {
    listCalls++;
    if (failList) {
      return Future.error(StateError('模拟名单查询失败'));
    }
    if (hangList) {
      return Completer<List<ActressPerson>>().future;
    }
    return super.listPersons(
      sex: sex,
      sort: sort,
      query: query,
      offset: offset,
      limit: limit,
      tag: tag,
      category: category,
      videoTag: videoTag,
    );
  }
}

Future<void> _seedPerson(MemoryActressDatabase db, String name) async {
  await db.upsertRosterPerson(
    RosterPerson(
      source: ActressRosterSourceId.chaoliu,
      sourceId: 'id-$name',
      name: name,
      worksHint: 1,
    ),
  );
}

void main() {
  group('名单加载守卫', () {
    late _FlakyListDb db;
    late FixtureRepository repository;
    late LocalStore store;
    late ActressJsonFallback fallback;

    setUp(() async {
      db = _FlakyListDb();
      repository = FixtureRepository();
      store = await _makeStore();
      fallback = ActressJsonFallback();
      await fallback.load();
      await ActressMytvBind.instance.ensureBound();
      NvkuEntryCache.clearForTest();
    });

    tearDown(() {
      NvkuEntryCache.clearForTest();
    });

    Widget page() {
      return MaterialApp(
        home: ActressListPage(
          repository: repository,
          store: store,
          database: db,
          fallback: fallback,
        ),
      );
    }

    testWidgets('名单查询抛错：进失败态有原因有重试，不再永久转圈', (tester) async {
      await _seedPerson(db, '守卫演员');
      db.failList = true;
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      // 失败态：文案 + 重试钮在，转圈不在。
      expect(
        find.byKey(const ValueKey('actress-list-load-error')),
        findsOneWidget,
      );
      expect(find.textContaining('加载失败'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('actress-list-retry')),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // 修好再点重试：名单回来。
      db.failList = false;
      await tester.tap(find.byKey(const ValueKey('actress-list-retry')));
      await tester.pumpAndSettle();
      expect(find.text('守卫演员'), findsWidgets);
      expect(
        find.byKey(const ValueKey('actress-list-load-error')),
        findsNothing,
      );
    });

    testWidgets('名单查询永不返回：首屏超时后进失败态', (tester) async {
      await _seedPerson(db, '超时演员');
      db.hangList = true;
      await tester.pumpWidget(page());
      // 推进假时钟越过首屏 20 秒超时（含路径解析 2 秒兜底）：
      // 失败态出现，不再转圈。
      await tester.pump(const Duration(seconds: 25));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('actress-list-load-error')),
        findsOneWidget,
      );
      expect(find.textContaining('加载超时'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('名单进程级缓存', () {
    late _FlakyListDb db;
    late FixtureRepository repository;
    late LocalStore store;
    late ActressJsonFallback fallback;

    setUp(() async {
      db = _FlakyListDb();
      repository = FixtureRepository();
      store = await _makeStore();
      fallback = ActressJsonFallback();
      await fallback.load();
      await ActressMytvBind.instance.ensureBound();
      NvkuEntryCache.clearForTest();
    });

    tearDown(() {
      NvkuEntryCache.clearForTest();
    });

    testWidgets('State 重建后命中进程级缓存，名单不再查库', (tester) async {
      await _seedPerson(db, '缓存演员');
      Widget page() {
        return MaterialApp(
          home: ActressListPage(
            repository: repository,
            store: store,
            database: db,
            fallback: fallback,
          ),
        );
      }

      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('缓存演员'), findsWidgets);
      final callsAfterFirst = db.listCalls;
      expect(callsAfterFirst, greaterThan(0));
      // 切区：State 销毁，再重建（模拟从别的区切回来）。
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('缓存演员'), findsWidgets);
      expect(db.listCalls, callsAfterFirst);
    });
  });

  group('NvkuEntryCache 名单槽与指纹', () {
    setUp(() {
      NvkuEntryCache.clearForTest();
    });

    tearDown(() {
      NvkuEntryCache.clearForTest();
    });

    ActressPerson person(String name) {
      return ActressPerson(localId: 1, displayName: name);
    }

    test('名单槽存取与 LRU 淘汰（上限 8）', () {
      for (var i = 0; i < 8; i++) {
        NvkuEntryCache.putPersonsFirstPage(
          'k$i',
          persons: [person('演员$i')],
          hasMore: false,
          rawOffset: 1,
        );
      }
      expect(NvkuEntryCache.personsFirstPage('k0'), isNotNull);
      // 第 9 个 key 挤掉最久未用的 k0（k0 刚被读过，挤掉的是 k1）。
      NvkuEntryCache.putPersonsFirstPage(
        'k8',
        persons: [person('演员8')],
        hasMore: true,
        rawOffset: 60,
      );
      expect(NvkuEntryCache.personsFirstPage('k8')!.hasMore, isTrue);
      expect(NvkuEntryCache.personsFirstPage('k8')!.rawOffset, 60);
      final evicted = [
        for (var i = 0; i < 8; i++)
          if (NvkuEntryCache.personsFirstPage('k$i') == null) i,
      ];
      expect(evicted, hasLength(1));
    });

    test('clear 一并清名单槽', () {
      NvkuEntryCache.putPersonsFirstPage(
        'k',
        persons: [person('演员')],
        hasMore: false,
        rawOffset: 1,
      );
      expect(NvkuEntryCache.personsFirstPage('k'), isNotNull);
      NvkuEntryCache.clear();
      expect(NvkuEntryCache.personsFirstPage('k'), isNull);
    });

    test('dbStamp 带 -wal 分量：wal 出现/变大指纹就变', () {
      final dir = Directory.systemTemp.createTempSync('nvku_stamp_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final dbFile = File('${dir.path}/x.db');
      dbFile.writeAsStringSync('12345');
      final before = NvkuEntryCache.dbStamp(dbFile.path);
      expect(before, isNotEmpty);
      File('${dir.path}/x.db-wal').writeAsStringSync('wal');
      final withWal = NvkuEntryCache.dbStamp(dbFile.path);
      expect(withWal, isNot(before));
      File('${dir.path}/x.db-wal').writeAsStringSync('walwalwal');
      expect(NvkuEntryCache.dbStamp(dbFile.path), isNot(withWal));
      // 不存在的文件：mtime/size 是哨兵值（0|-1），指纹稳定且与
      // 真文件不同——文件从无到有（导入落库）时指纹必变。
      final missing = NvkuEntryCache.dbStamp('${dir.path}/none.db');
      expect(missing, '0|-1|0');
      expect(missing, isNot(before));
    });
  });

  group('导入器收尾落库', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('sql_finalize_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('导入后落库：索引集 + 汇总表归并口径对', () async {
      final executor = _FinalizeExecutor();
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final importer = ActressSqlImporter(
        batchSize: 100,
        executorFactory: (tempPath) async {
          await File(tempPath).writeAsString('NEWDB');
          return executor;
        },
      );
      final result = await importer.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(result.ok, isTrue, reason: result.error);
      final all = [...executor.singles, ...executor.batches.expand((b) => b)];
      // 索引集逐条建进临时库。
      for (final name in [
        'idx_moyi_va_cate',
        'idx_moyi_va_vod',
        'idx_moyi_act_name',
        'idx_moyi_v_play_from',
        'idx_moyi_v_pubdate',
        'idx_moyi_vc_vod',
        'idx_moyi_vc_cat',
        'idx_moyi_v_type_vod',
      ]) {
        expect(
          all.any((s) => s.contains('CREATE INDEX') && s.contains(name)),
          isTrue,
          reason: '缺索引 $name',
        );
      }
      // 汇总表经临时表换名落库。
      expect(
        all.any(
          (s) => s.contains(
            'ALTER TABLE actress_rollup_new RENAME TO actress_rollup',
          ),
        ),
        isTrue,
      );
      // 归并口径：甲 = c-a(3 部) + c-b(4 部) = 7 部，头像取第二行的
      // 可加载地址，有一行男优就算男优，最新日期取最大 2024-03-04；
      // 乙 = c-b 4 部。
      final rollupInserts = all
          .where((s) => s.contains('INSERT INTO actress_rollup_new'))
          .join('\n');
      expect(
        rollupInserts,
        contains(
          "('甲',1,'https://cdn.example.com/a.jpg',7,'male','2024-03-04')",
        ),
      );
      expect(
        rollupInserts,
        contains("('乙',3,'https://cdn.example.com/b.jpg',4,'','2024-03-04')"),
      );
      // 签名与读侧口径一致：v2:actresses 行数/video_actress 行数。
      final signature =
          'v2:${executor.counts['actresses']}/${executor.counts['video_actress']}';
      expect(
        all.any(
          (s) =>
              s.contains('INSERT OR REPLACE INTO actress_rollup_meta') &&
              s.contains("'$signature'"),
        ),
        isTrue,
        reason: '签名应为 $signature',
      );
    });
  });
}

/// 记录型执行器（照 actress_sql_import_test 的 _RecordingExecutor
/// 口径）：跟踪建表与各表 INSERT 计数；汇总落库的查询按 SQL 内容
/// 回预置行（人数源计数/每类作品数/actresses 全行）。
class _FinalizeExecutor implements SqlImportExecutor {
  final batches = <List<String>>[];
  final singles = <String>[];
  final tables = <String>{};
  final counts = <String, int>{};
  var closed = false;

  static String? _insertTable(String sql) {
    return RegExp(
      r'INSERT INTO\s+"?(\w+)',
      caseSensitive: false,
    ).firstMatch(sql)?.group(1)?.toLowerCase();
  }

  @override
  Future<void> execute(String sql) async {
    singles.add(sql);
    final upper = sql.trimLeft().toUpperCase();
    if (upper.startsWith('CREATE TABLE')) {
      final name = RegExp(
        r'CREATE TABLE\s+(?:IF NOT EXISTS\s+)?"?(\w+)',
        caseSensitive: false,
      ).firstMatch(sql)?.group(1)?.toLowerCase();
      if (name != null) tables.add(name);
    }
    final table = _insertTable(sql);
    if (table != null) counts[table] = (counts[table] ?? 0) + 1;
  }

  @override
  Future<void> executeBatch(List<String> statements) async {
    batches.add(List<String>.of(statements));
    for (final sql in statements) {
      final table = _insertTable(sql);
      if (table != null) {
        // 多行 VALUES 按行数计（与真库行数对账的口径一致即可，
        // 本执行器只给签名断言提供 actresses/video_actress 计数，
        // 那两张表的样本语句是单行 INSERT）。
        counts[table] = (counts[table] ?? 0) + 1;
      }
    }
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql) async {
    // —— 收尾落库的查询（按内容回预置行）——
    if (sql.contains('actress_rollup_meta')) {
      return const []; // 无签名 → 走重建
    }
    if (sql.contains('(SELECT COUNT(*) FROM actresses)')) {
      return [
        {'a': counts['actresses'] ?? 0, 'v': counts['video_actress'] ?? 0},
      ];
    }
    if (sql.contains('FROM actress_rollup')) {
      return [
        {'c': 0},
      ];
    }
    if (sql.contains('GROUP BY va.cate_id')) {
      return [
        {'cate_id': 'c-a', 'n': 3, 'd': '2024-01-02'},
        {'cate_id': 'c-b', 'n': 4, 'd': '2024-03-04'},
      ];
    }
    if (sql.trim() == 'PRAGMA table_info(actresses)') {
      // 只认收尾落库查 sex 列的这一条；导入本体的架构探针也走
      // PRAGMA，必须落到下面的通用口径，不能被这里污染。
      return [
        {'name': 'cate_id'},
        {'name': 'name'},
        {'name': 'avatar'},
        {'name': 'sex'},
      ];
    }
    if (sql.contains('rowid AS rid')) {
      return [
        {'rid': 1, 'name': '甲', 'cate_id': 'c-a', 'avatar': '', 'sex': ''},
        {
          'rid': 2,
          'name': '甲',
          'cate_id': 'c-b',
          'avatar': 'https://cdn.example.com/a.jpg',
          'sex': 'male',
        },
        {
          'rid': 3,
          'name': '乙',
          'cate_id': 'c-b',
          'avatar': 'https://cdn.example.com/b.jpg',
          'sex': '',
        },
      ];
    }
    // —— 导入本体/校验的查询（与 _RecordingExecutor 同口径）——
    if (sql.contains('sqlite_master')) {
      return [
        for (final t in tables) {'name': t},
      ];
    }
    final table =
        RegExp(
              r'FROM\s+(\w+)',
              caseSensitive: false,
            ).firstMatch(sql)?.group(1)?.toLowerCase() ??
        '';
    return [
      {'COUNT(*)': counts[table] ?? 0},
    ];
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
