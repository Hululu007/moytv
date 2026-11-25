// 数据库管理批测试（2026-11-25）：表格编解码/表格更新语义/导出/
// 后台任务控制器/管理页/无同步入口。全部走注入假实现，不碰平台通道。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_db_export.dart';
import 'package:moyi/actress/actress_db_info.dart';
import 'package:moyi/actress/actress_db_manage_page.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_spreadsheet.dart';
import 'package:moyi/actress/actress_sql_import.dart';
import 'package:moyi/actress/actress_sql_import_controller.dart';
import 'package:moyi/actress/actress_table_update.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

// ---------------------------------------------------------------------------
// 假表格存储：内存映射 + 快照回滚事务。
// ---------------------------------------------------------------------------
class FakeTableStore implements ActressTableStore {
  final works = <String, Map<String, Object?>>{};
  final urls = <String, List<String>>{};
  final urlFrom = <String, String>{};
  final categories = <String, String>{};
  final tags = <String, Set<String>>{};
  final actresses = <String, ({String name, String avatar})>{};
  final links = <String, Set<String>>{};
  var failOnCode = '';

  FakeTableStore copy() {
    final c = FakeTableStore();
    c.works.addAll({for (final e in works.entries) e.key: {...e.value}});
    c.urls.addAll({for (final e in urls.entries) e.key: [...e.value]});
    c.urlFrom.addAll(urlFrom);
    c.categories.addAll(categories);
    c.tags.addAll({for (final e in tags.entries) e.key: {...e.value}});
    c.actresses.addAll(actresses);
    c.links.addAll({for (final e in links.entries) e.key: {...e.value}});
    c.failOnCode = failOnCode;
    return c;
  }

  void absorb(FakeTableStore o) {
    works
      ..clear()
      ..addAll(o.works);
    urls
      ..clear()
      ..addAll(o.urls);
    urlFrom
      ..clear()
      ..addAll(o.urlFrom);
    categories
      ..clear()
      ..addAll(o.categories);
    tags
      ..clear()
      ..addAll(o.tags);
    actresses
      ..clear()
      ..addAll(o.actresses);
    links
      ..clear()
      ..addAll(o.links);
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(ActressTableStore tx) body,
  ) async {
    final working = copy();
    final result = await body(working);
    absorb(working);
    return result;
  }

  void _maybeFail(String code) {
    if (code == failOnCode) throw StateError('假存储故障 $code');
  }

  @override
  Future<Map<String, Object?>?> findWork(String code) async =>
      works[code.toLowerCase()];

  @override
  Future<void> insertWork(Map<String, Object?> values) async {
    final code = (values['vod_id'] as String).toLowerCase();
    _maybeFail(code);
    works[code] = {...values};
  }

  @override
  Future<void> updateWork(String code, Map<String, Object?> values) async {
    _maybeFail(code);
    works[code.toLowerCase()] = {...?works[code.toLowerCase()], ...values};
  }

  @override
  Future<void> replacePlayUrls(
    String code,
    List<String> newUrls,
    String playFrom,
  ) async {
    _maybeFail(code);
    urls[code.toLowerCase()] = [...newUrls];
    urlFrom[code.toLowerCase()] = playFrom;
  }

  @override
  Future<String> playFromOf(String code) async =>
      urlFrom[code.toLowerCase()] ?? '';

  @override
  Future<void> setCategory(String code, String category) async {
    categories[code.toLowerCase()] = category;
  }

  @override
  Future<void> addTag(String code, String tag) async {
    (tags[code.toLowerCase()] ??= {}).add(tag);
  }

  @override
  Future<String?> findActressCateId(String name) async {
    for (final e in actresses.entries) {
      if (e.key == name || e.value.name == name) return e.key;
    }
    return null;
  }

  @override
  Future<void> insertActress(String cateId, String name, String avatar) async {
    actresses[cateId] = (name: name, avatar: avatar);
  }

  @override
  Future<void> updateActressAvatar(String cateId, String avatar) async {
    final old = actresses[cateId];
    if (old != null) actresses[cateId] = (name: old.name, avatar: avatar);
  }

  @override
  Future<void> linkActress(String code, String cateId) async {
    (links[code.toLowerCase()] ??= {}).add(cateId);
  }
}

SpreadsheetWorkRow _row(
  String code, {
  String? title,
  String? cover,
  String? category,
  List<String> urls = const [],
  List<String> actresses = const [],
  String? avatar,
  List<String> tags = const [],
}) {
  final r = SpreadsheetWorkRow();
  r.code = code;
  r.title = title;
  r.cover = cover;
  r.category = category;
  r.playUrls = urls;
  r.actresses = actresses;
  r.actressAvatar = avatar;
  r.tags = tags;
  return r;
}

void main() {
  group('表格编解码', () {
    test('CSV 往返：引号/逗号/换行/中文都原样', () {
      final grid = [
        ['番号', '标题'],
        ['SSIS-001', '带,逗号和"引号"\n和换行的标题'],
        ['ABC-002', '普通标题'],
      ];
      final text = encodeCsv(grid);
      expect(decodeCsv(text), grid);
    });

    test('XLSX 往返：解析出的行与原数据一致', () {
      final grid = [
        spreadsheetExportHeaders,
        ['SSIS-001', '标题一', '', 'https://a.test/1.m3u8', '女优甲', '', '有码', ''],
      ];
      final bytes = encodeXlsx(grid);
      final rows = parseSpreadsheetGrid(decodeXlsx(bytes));
      expect(rows.single.code, 'SSIS-001');
      expect(rows.single.title, '标题一');
      expect(rows.single.playUrls, ['https://a.test/1.m3u8']);
      expect(rows.single.actresses, ['女优甲']);
      expect(rows.single.category, '有码');
    });

    test('表头映射：中文列名与英文列名都认', () {
      final cn = parseSpreadsheetGrid([
        ['番号', '标题', '封面', '播放地址', '女优', '女优头像', '分类', '标签'],
        ['ssis-001', '题', 'c.jpg', 'https://a.test/1.m3u8', '甲、乙', 'av.jpg', '有码', '标签一'],
      ]);
      expect(cn.single.code, 'ssis-001');
      expect(cn.single.title, '题');
      expect(cn.single.playUrls, ['https://a.test/1.m3u8']);
      expect(cn.single.actresses, ['甲', '乙']);
      expect(cn.single.actressAvatar, 'av.jpg');
      expect(cn.single.category, '有码');
      expect(cn.single.tags, ['标签一']);
      final en = parseSpreadsheetGrid([
        ['code', 'title', 'cover', 'play_url', 'actress', 'avatar', 'category', 'tags'],
        ['ABC-1', 't', '', 'https://a.test/2.m3u8', '丙', '', '无码', ''],
      ]);
      expect(en.single.code, 'ABC-1');
      expect(en.single.actresses, ['丙']);
    });

    test('多值拆分：地址竖线/分号， 人名顿号/逗号', () {
      expect(splitPlayUrlCell('https://a/1 | https://a/2；https://a/3'),
          ['https://a/1', 'https://a/2', 'https://a/3']);
      expect(splitNamesCell('甲、乙,丙；丁'), ['甲', '乙', '丙', '丁']);
      expect(joinPlayUrlCell(['https://a/1', 'https://a/2']),
          'https://a/1 | https://a/2');
    });
  });

  group('表格更新语义', () {
    late FakeTableStore store;
    setUp(() {
      store = FakeTableStore();
      store.works['ssis-001'] = {
        'vod_id': 'ssis-001',
        'title': '旧标题',
        'pic_url': 'old.jpg',
        'm3u8_url': 'https://old.test/1.m3u8',
        'vod_play_url': 'https://old.test/1.m3u8',
      };
      store.urls['ssis-001'] = ['https://old.test/1.m3u8'];
      store.urlFrom['ssis-001'] = 'whos.tv';
      store.categories['ssis-001'] = '有码';
      store.actresses['女优甲'] = (name: '女优甲', avatar: '');
      store.links['ssis-001'] = {'女优甲'};
    });

    test('新增/更新/空字段不覆盖/多地址替换/建人/跳过计数', () async {
      final result = await const ActressTableUpdater().apply(
        store: store,
        rows: [
          // 更新：只给新标题与新地址，封面留空不覆盖。
          _row('SSIS-001',
              title: '新标题',
              urls: ['https://new.test/1.m3u8', 'https://new.test/2.m3u8']),
          // 新增：带女优与头像、分类、标签。
          _row('NEW-001',
              title: '新片',
              cover: 'n.jpg',
              category: '无码',
              urls: ['https://new.test/9.m3u8'],
              actresses: ['新人女优'],
              avatar: 'face.jpg',
              tags: ['标签X']),
          // 缺番号：跳过。
          _row(''),
          // 空行（只有番号没内容）：跳过，不动原行。
          _row('SSIS-001'),
        ],
      );
      expect(result.ok, isTrue);
      expect(result.added, 1);
      expect(result.updated, 1);
      expect(result.skipped, 2);
      final work = store.works['ssis-001']!;
      expect(work['title'], '新标题');
      expect(work['pic_url'], 'old.jpg', reason: '空单元格不覆盖封面');
      expect(work['m3u8_url'], 'https://new.test/1.m3u8');
      expect(store.urls['ssis-001'],
          ['https://new.test/1.m3u8', 'https://new.test/2.m3u8'],
          reason: '地址整表替换');
      expect(store.works.containsKey('new-001'), isTrue);
      expect(store.actresses['新人女优']?.avatar, 'face.jpg');
      expect(store.links['new-001'], contains('新人女优'));
      expect(store.tags['new-001'], contains('标签X'));
      expect(store.categories['new-001'], '无码');
    });

    test('没出现在表格里的作品不动', () async {
      store.works['keep-001'] = {'vod_id': 'keep-001', 'title': '保留'};
      await const ActressTableUpdater().apply(
        store: store,
        rows: [_row('SSIS-001', title: '改名')],
      );
      expect(store.works['keep-001']?['title'], '保留');
    });

    test('中途失败整体回滚', () async {
      store.failOnCode = 'boom-001';
      final result = await const ActressTableUpdater().apply(
        store: store,
        rows: [
          _row('SSIS-001', title: '不该落库的标题'),
          _row('BOOM-001', title: '触发故障'),
        ],
      );
      expect(result.ok, isFalse);
      expect(store.works['ssis-001']?['title'], '旧标题',
          reason: '同一事务里的先行更新必须回滚');
    });
  });

  _registerManageTests();
  _registerWidgetTests();
}

// ---------------------------------------------------------------------------
// 假导出存储：两张小表 + 若干作品行。
// ---------------------------------------------------------------------------
class FakeExportStore implements ActressExportStore {
  final tables = <String, List<Map<String, Object?>>>{
    'videos': [
      {'vod_id': 'ssis-001', 'title': '片一', 'pic_url': 'c1.jpg'},
      {'vod_id': 'abc-002', 'title': '片二', 'pic_url': ''},
    ],
    'actresses': [
      {'cate_id': '女优甲', 'name': '女优甲'},
    ],
  };
  final works = <SpreadsheetWorkRow>[];

  FakeExportStore() {
    works.add(
      _row('SSIS-001',
          title: '片一',
          cover: 'c1.jpg',
          category: '有码',
          urls: ['https://a.test/1.m3u8'],
          actresses: ['女优甲'],
          tags: ['标签一']),
    );
    works.add(_row('ABC-002', title: '片二', urls: ['https://a.test/2.m3u8']));
  }

  @override
  Future<List<String>> tableNames() async => tables.keys.toList();

  @override
  Future<String?> tableSql(String table) async =>
      'CREATE TABLE $table (vod_id TEXT)';

  @override
  Future<List<String>> indexSqls() async =>
      ['CREATE INDEX idx_videos_id ON videos (vod_id)'];

  @override
  Future<int> countRows(String table) async => tables[table]?.length ?? 0;

  @override
  Future<List<Map<String, Object?>>> rowsPage(
    String table,
    int offset,
    int limit,
  ) async {
    final rows = tables[table] ?? const [];
    if (offset >= rows.length) return const [];
    return rows.skip(offset).take(limit).toList();
  }

  @override
  Future<int> countWorks() async => works.length;

  @override
  Future<List<SpreadsheetWorkRow>> worksPage(int offset, int limit) async {
    if (offset >= works.length) return const [];
    return works.skip(offset).take(limit).toList();
  }

  @override
  Future<void> close() async {}
}

// ---------------------------------------------------------------------------
// 假导入器：可控制成功/失败/挂起（验忙碌互斥与取消）。
// ---------------------------------------------------------------------------
class FakeImporter extends ActressSqlImporter {
  FakeImporter({this.result, this.gate});
  final ActressSqlImportResult? result;
  final Future<void>? gate;
  var calls = 0;

  @override
  Future<ActressSqlImportResult> importFile({
    required String sqlPath,
    required String dbPath,
    required Future<void> Function() closeDatabase,
    void Function(ActressSqlImportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    calls++;
    onProgress?.call(
      const ActressSqlImportProgress(
        phase: '正在导入',
        statements: 10,
        bytesRead: 50,
        totalBytes: 100,
      ),
    );
    if (gate != null) await gate;
    if (isCancelled?.call() ?? false) {
      return const ActressSqlImportResult(ok: false, error: '已取消导入');
    }
    return result ??
        const ActressSqlImportResult(
          ok: true,
          videos: 3,
          actresses: 2,
          playUrls: 4,
          covers: 3,
          avatars: 1,
        );
  }
}

void _registerManageTests() {
  group('导出', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync());
    tearDown(() => temp.deleteSync(recursive: true));

    test('.sql 导出结构：建表在前、数据居中、索引在后、COMMIT 收尾', () async {
      final store = FakeExportStore();
      final out = '${temp.path}/out.sql';
      final result = await const ActressDbExporter().exportSql(
        store: store,
        outPath: out,
        compressed: false,
      );
      expect(result.ok, isTrue);
      final text = File(out).readAsStringSync();
      expect(text, contains('CREATE TABLE videos'));
      expect(text, contains('INSERT INTO "videos" VALUES(\'ssis-001\''));
      expect(text, contains('CREATE INDEX idx_videos_id'));
      expect(
        text.indexOf('CREATE INDEX'),
        greaterThan(text.indexOf('INSERT INTO actresses')),
      );
      expect(text.trimRight().endsWith('COMMIT;'), isTrue);
    });

    test('CSV 导出 → 改一行 → 表格更新 → 只那行变（往返链）', () async {
      final store = FakeExportStore();
      final out = '${temp.path}/out.csv';
      final result = await const ActressDbExporter().exportSpreadsheet(
        store: store,
        outPath: out,
        xlsx: false,
      );
      expect(result.ok, isTrue);
      final rows = spreadsheetRowsFromBytes(
        File(out).readAsBytesSync(),
        isXlsx: false,
      );
      expect(rows.map((r) => r.code), ['SSIS-001', 'ABC-002']);
      // 改第二行的标题，第一行原样。
      rows[1].title = '片二·改';
      final tableStore = FakeTableStore();
      tableStore.works['ssis-001'] = {
        'vod_id': 'ssis-001',
        'title': '片一',
        'pic_url': 'c1.jpg',
      };
      tableStore.works['abc-002'] = {
        'vod_id': 'abc-002',
        'title': '片二',
        'pic_url': '',
      };
      final update = await const ActressTableUpdater().apply(
        store: tableStore,
        rows: rows,
      );
      expect(update.ok, isTrue);
      expect(tableStore.works['abc-002']?['title'], '片二·改');
      expect(tableStore.works['ssis-001']?['title'], '片一');
    });
  });

  group('后台任务控制器', () {
    test('导入成功：代次涨、通知只消费一次、进度可查', () async {
      final controller = ActressDbTaskController();
      final importer = FakeImporter();
      controller.importerFactory = () => importer;
      controller.saveMeta = (_) async {};
      final seenProgress = <double>[];
      controller.addListener(() {
        final p = controller.sqlImportProgress;
        if (p != null) seenProgress.add(p.fraction);
      });
      final result = await controller.startSqlImport(
        sqlPath: '/tmp/x.sql',
        dbPath: '/tmp/db.db',
        closeDatabase: () async {},
      );
      expect(result?.ok, isTrue);
      expect(controller.swapGeneration, 1);
      expect(controller.dataGeneration, 1);
      expect(seenProgress, contains(0.5));
      final notice = controller.consumeImportNotice();
      expect(notice?.videos, 3);
      expect(controller.consumeImportNotice(), isNull,
          reason: '完成通知只弹一次');
    });

    test('忙碌互斥：导入挂起时第二个任务被拒', () async {
      final controller = ActressDbTaskController();
      final gate = Completer<void>();
      controller.importerFactory = () => FakeImporter(gate: gate.future);
      controller.saveMeta = (_) async {};
      final running = controller.startSqlImport(
        sqlPath: '/tmp/x.sql',
        dbPath: '/tmp/db.db',
        closeDatabase: () async {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.busy, isTrue);
      expect(controller.sqlImportRunning, isTrue);
      final second = await controller.startTableUpdate(
        filePath: '/tmp/t.csv',
        dbPath: '/tmp/db.db',
      );
      expect(second, isNull, reason: '有任务在跑时新任务先拦下');
      controller.cancelSqlImport();
      gate.complete();
      final result = await running;
      expect(result?.ok, isFalse, reason: '取消后导入不成功、旧库不动');
      expect(controller.swapGeneration, 0);
      expect(controller.busy, isFalse);
    });

    test('表格更新成功涨数据代次；notifyDbMutated 也涨', () async {
      final controller = ActressDbTaskController();
      final tableStore = FakeTableStore();
      controller.tableStoreOpener = (_) async => tableStore;
      final temp = Directory.systemTemp.createTempSync();
      addTearDown(() => temp.deleteSync(recursive: true));
      final dbFile = File('${temp.path}/db.db')..writeAsStringSync('x');
      final csv = File('${temp.path}/t.csv')
        ..writeAsStringSync(
          encodeCsv([
            spreadsheetExportHeaders,
            ['NEW-100', '新片', '', 'https://a.test/n.m3u8', '', '', '', ''],
          ]),
        );
      final before = controller.dataGeneration;
      final result = await controller.startTableUpdate(
        filePath: csv.path,
        dbPath: dbFile.path,
      );
      expect(result?.ok, isTrue);
      expect(result?.added, 1);
      expect(controller.dataGeneration, before + 1);
      controller.notifyDbMutated();
      expect(controller.dataGeneration, before + 2);
    });
  });
}

void _registerWidgetTests() {
  group('数据库管理页', () {
    late Directory temp;
    late String dbPath;
    setUp(() {
      temp = Directory.systemTemp.createTempSync();
      dbPath = '${temp.path}/女优库.db';
      File(dbPath).writeAsStringSync('FAKEDB');
    });
    tearDown(() => temp.deleteSync(recursive: true));

    Future<void> pumpPage(
      WidgetTester tester, {
      ActressDbTaskController? controller,
      Future<ActressDbInfo> Function(String)? infoLoader,
    }) async {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: ActressDbManagePage(
              dbPath: dbPath,
              closeDatabase: () async {},
              reloadDatabase: () async {},
              controller: controller,
              infoLoader:
                  infoLoader ??
                  (_) async => const ActressDbInfo(
                    exists: true,
                    fileBytes: 2048,
                    videos: 10,
                    actresses: 3,
                    playUrls: 12,
                  ),
              metaLoader: () async => null,
            ),
          ),
        );
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump(const Duration(milliseconds: 50));
        }
      });
    }

    Future<void> settleManual(WidgetTester tester) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump(const Duration(milliseconds: 50));
        }
      });
    }

    testWidgets('显示库信息计数', (tester) async {
      await pumpPage(tester);
      expect(find.textContaining('10'), findsWidgets);
      expect(find.textContaining('播放地址'), findsWidgets);
    });

    testWidgets('删除数据库：二次确认后删掉、回空态、代次涨', (tester) async {
      final controller = ActressDbTaskController();
      var info = const ActressDbInfo(
        exists: true,
        fileBytes: 6,
        videos: 10,
        actresses: 3,
        playUrls: 12,
      );
      await pumpPage(
        tester,
        controller: controller,
        infoLoader: (_) async => info,
      );
      final before = controller.dataGeneration;
      await tester.tap(find.text('删除'));
      await settleManual(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      info = const ActressDbInfo(exists: false);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('删除'),
        ),
      );
      await tester.runAsync(() async {
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump(const Duration(milliseconds: 50));
        }
      });
      expect(File(dbPath).existsSync(), isFalse);
      expect(controller.dataGeneration, before + 1,
          reason: '删库要通知全 App 自动刷新');
      expect(find.textContaining('还没有导入数据库'), findsWidgets);
    });

    testWidgets('导入进行中删除被拦', (tester) async {
      final controller = ActressDbTaskController();
      controller.sqlImportRunning = true;
      await pumpPage(tester, controller: controller);
      await tester.tap(find.text('删除'));
      await settleManual(tester);
      expect(find.textContaining('正在导入'), findsWidgets);
      expect(File(dbPath).existsSync(), isTrue);
    });
  });

  group('演员库无同步入口（2026-11-25 删除口径）', () {
    testWidgets('设置弹窗只有导入与数据库管理，没有同步/叠加/现爬', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      final db = MemoryActressDatabase();
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ActressListPage(
                repository: FixtureRepository(),
                store: store,
                database: db,
              ),
            ),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump(const Duration(milliseconds: 50));
        }
      });
      expect(
        find.byKey(const ValueKey('refresh-actress-library')),
        findsNothing,
        reason: '顶栏刷新同步钮已删',
      );
      await tester.tap(find.byKey(const ValueKey('open-actress-settings')));
      await tester.pumpAndSettle();
      expect(find.text('数据库管理'), findsWidgets);
      for (final gone in [
        '名册 / 作品同步',
        '开始同步',
        '继续同步',
        '全站叠加',
        '开始叠加',
        '任意站点爬取',
        '开始爬',
        '同步爬取',
      ]) {
        expect(find.text(gone), findsNothing, reason: '入口已删：$gone');
      }
    });
  });
}
