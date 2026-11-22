// 女优库 MYTV 绑定（2026-11-20）：绑定解析、迁移、用户 m3u、
// json/m3u/现爬目录覆盖、内存库重读空实现、列表页通用模式渲染。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_generic_db.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_m3u_index.dart';
import 'package:moyi/actress/actress_mytv_bind.dart';
import 'package:moyi/actress/actress_roster_sources.dart';
import 'package:moyi/actress/actress_site_crawl.dart';
import 'package:moyi/actress/actress_sync.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Future<ActressHttpResponse> _unusedFetch(
  String url, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 20),
}) async => throw UnimplementedError('fake source must not fetch');

Future<LocalStore> _makeStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

class _CountingSyncService extends ActressSyncService {
  _CountingSyncService({required super.db, required super.sources})
    : super(fetch: _unusedFetch);

  var runs = 0;

  @override
  Future<ActressSyncResult> run({bool refresh = false}) {
    runs++;
    return super.run(refresh: refresh);
  }
}

/// 通用模式测试库：内存库 + 注入的通用读库。
class _GenericTestDb extends MemoryActressDatabase {
  _GenericTestDb(this.works, {GenericDbSchema? schema}) : _schema = schema;

  final List<GenericDbWork> works;
  final GenericDbSchema? _schema;

  @override
  Future<GenericDbReader?> genericReader() async =>
      GenericDbReader.test(works: works, schema: _schema);
}

void main() {
  group('MYTV 绑定解析', () {
    late Directory temp;
    late Directory docs;
    late Directory ext;

    setUp(() {
      temp = Directory.systemTemp.createTempSync();
      addTearDown(() => temp.deleteSync(recursive: true));
      docs = Directory('${temp.path}/docs')..createSync();
      ext = Directory('${temp.path}/ext')..createSync();
    });

    ActressMytvBind bind() {
      return ActressMytvBind(
        externalRoot: () async => ext,
        hasAllFilesAccess: () async => true,
        documentsDir: () async => docs,
      );
    }

    test('有外置库：库路径是 MYTV/db/女优库.db，显示路径带 MYTV', () async {
      File('${ext.path}/MYTV/db/女优库.db')
        ..createSync(recursive: true)
        ..writeAsStringSync('video-db-bytes');
      final result = await bind().ensureBound();
      expect(result.bound, isTrue);
      expect(result.hasVideoDb, isTrue);
      expect(result.dbPath, '${ext.path}/MYTV/db/女优库.db');
      expect(result.displayPath, 'MYTV/db/女优库.db');
      expect(Directory('${ext.path}/MYTV/db').existsSync(), isTrue);
      expect(Directory('${ext.path}/MYTV/m3u').existsSync(), isTrue);
      expect(result.mergedJsonExportPath, '${ext.path}/MYTV/mjv011.json');
      expect(result.note, isNull);
    });

    test('没有外置库：dbPath 为空、显示未找到外置数据库、带放库提示', () async {
      final result = await bind().ensureBound();
      expect(result.bound, isTrue);
      expect(result.hasVideoDb, isFalse);
      expect(result.dbPath, isEmpty);
      expect(result.displayPath, '未找到外置数据库');
      expect(result.note, contains('未找到外置数据库'));
      expect(result.note, contains('MYTV/db/'));
      expect(Directory('${ext.path}/MYTV/db').existsSync(), isTrue);
      expect(Directory('${ext.path}/MYTV/m3u').existsSync(), isTrue);
    });

    test('外置库是空文件：按没有外置库处理', () async {
      File('${ext.path}/MYTV/db/女优库.db')
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      final result = await bind().ensureBound();
      expect(result.hasVideoDb, isFalse);
      expect(result.dbPath, isEmpty);
      expect(result.note, contains('未找到外置数据库'));
    });

    test('外部存储不可用：未绑定、dbPath 为空，不抛错', () async {
      final noExt = ActressMytvBind(
        externalRoot: () async => null,
        documentsDir: () async => docs,
      );
      final result = await noExt.ensureBound();
      expect(result.bound, isFalse);
      expect(result.hasVideoDb, isFalse);
      expect(result.dbPath, isEmpty);
      expect(result.displayPath, '未找到外置数据库');
      expect(result.note, contains('外部存储不可用'));
    });

    test('写不进去且没权限：needsPermission，dbPath 为空', () async {
      // 外部根是一份普通文件：建 MYTV/db 必然抛错，走权限分支。
      final fileRoot = File('${temp.path}/not-a-dir')
        ..writeAsStringSync('x');
      final noPerm = ActressMytvBind(
        externalRoot: () async => Directory(fileRoot.path),
        hasAllFilesAccess: () async => false,
        documentsDir: () async => docs,
      );
      final result = await noPerm.ensureBound();
      expect(result.bound, isFalse);
      expect(result.needsPermission, isTrue);
      expect(result.dbPath, isEmpty);
    });

    test('老 json 影子文件拷进 MYTV/db：只补没有的', () async {
      final legacyJsonDir = Directory('${docs.path}/actress_json')
        ..createSync();
      File('${legacyJsonDir.path}/mjv011.json')
          .writeAsStringSync('{"list": []}');
      final result = await bind().ensureBound();
      expect(result.bound, isTrue);
      expect(File('${ext.path}/MYTV/db/mjv011.json').existsSync(), isTrue);
    });
  });

  group('用户 m3u 兜底', () {
    late Directory temp;
    late Directory userDir;

    setUp(() {
      temp = Directory.systemTemp.createTempSync();
      addTearDown(() => temp.deleteSync(recursive: true));
      userDir = Directory('${temp.path}/m3u')..createSync();
    });

    WhosM3uIndex index({WhosM3uBytesReader? reader}) =>
        WhosM3uIndex(bytesReader: reader, userM3uDir: userDir);

    void writeM3u(String name, String body) {
      File('${userDir.path}/$name').writeAsStringSync(body);
    }

    test('用户 m3u 优先出：group-title 作女优名，标题里番号作 vodCode', () async {
      writeM3u(
        '女优合集1.m3u',
        '#EXTM3U\n'
        '#EXTINF:-1 group-title="波多野結衣",波多野結衣 SSIS-001 测试\n'
        'https://example.com/1.m3u8\n',
      );
      final entries = await index().entriesForActress('波多野結衣');
      expect(entries, isNotEmpty);
      // vodCode 是归一化番号键（normalizeAvCode 去掉 - 与前导零）。
      expect(entries.first.vodCode, 'SSIS1');
      expect(entries.first.playable, isTrue);
      expect(entries.first.playUrl, 'https://example.com/1.m3u8');
    });

    test('换文件自动重读：改内容后下次查出新内容', () async {
      writeM3u(
        '女优合集1.m3u',
        '#EXTM3U\n'
        '#EXTINF:-1 group-title="测试演员",测试演员 ABC-1\n'
        'https://example.com/old.m3u8\n',
      );
      final first = await index().entriesForActress('测试演员');
      expect(first.first.playUrl, 'https://example.com/old.m3u8');
      writeM3u(
        '女优合集1.m3u',
        '#EXTM3U\n'
        '#EXTINF:-1 group-title="测试演员",测试演员 ABC-2 新片\n'
        'https://example.com/new.m3u8\n',
      );
      final second = await index().entriesForActress('测试演员');
      expect(second.first.playUrl, 'https://example.com/new.m3u8');
      expect(second.first.vodCode, 'ABC2');
    });

    test('内置分片读失败不影响用户文件', () async {
      writeM3u(
        '女优合集1.m3u',
        '#EXTM3U\n'
        '#EXTINF:-1 group-title="测试演员",测试演员 ABC-1\n'
        'https://example.com/1.m3u8\n',
      );
      final broken = index(
        reader: (_) async => throw StateError('分片读失败'),
      );
      final entries = await broken.entriesForActress('测试演员');
      expect(entries, isNotEmpty);
      expect(entries.first.playUrl, 'https://example.com/1.m3u8');
    });
  });

  group('json 与现爬目录覆盖', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync();
      addTearDown(() => temp.deleteSync(recursive: true));
    });

    test('ActressJsonFallback 的 localJsonDir 覆盖：读新目录的 mjv011.json', () async {
      final newDir = Directory('${temp.path}/new_json')..createSync();
      final row = {
        'vod_id': 'mjv-test-1',
        'vod_name': '本地测试片',
        'vod_pic': '',
        'vod_actor': '测试演员',
        'vod_director': '',
        'vod_remarks': '',
        'vod_pubdate': '',
        'vod_area': '',
        'vod_year': '',
        'vod_content': '',
        'vod_play_from': 'mjv011',
        'vod_play_url': '正片\$https://example.com/1.m3u8',
        'type_name': '',
        'vod_code': 'ABC-1',
        'vod_actress_pic': '',
      };
      File('${newDir.path}/mjv011.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'list': [row],
          'parse': 0,
          'jx': 0,
          'last_update': '2026-11-20T00:00:00',
        }),
      );
      final fallback = ActressJsonFallback(localJsonDir: newDir);
      await fallback.load();
      expect(fallback.loaded, isTrue);
      final entries = fallback.entriesForActress('测试演员');
      expect(entries, isNotEmpty);
      expect(entries.first.vodName, '本地测试片');
    });

    test('现爬 bindLocalDir 实跑：mjv011.json 落在新目录不在旧目录', () async {
      final oldDir = Directory('${temp.path}/old_json')..createSync();
      final newDir = Directory('${temp.path}/new_json')..createSync();
      final db = MemoryActressDatabase();
      final crawl = ActressSiteCrawlService(
        repository: FixtureRepository(),
        db: db,
        localJsonDir: oldDir,
      );
      crawl.bindLocalDir(newDir);
      await crawl.start(
        site: 'mjv',
        maxPagesPerCategory: 1,
        enrichPerCategory: 0,
      );
      expect(File('${newDir.path}/mjv011.json').existsSync(), isTrue);
      expect(File('${oldDir.path}/mjv011.json').existsSync(), isFalse);
      expect(
        File('${newDir.path}/mjv011.json').readAsStringSync(),
        contains('mjv011'),
      );
    });
  });

  group('内存库重读空实现', () {
    test('reloadIfChanged 返回未变、genericReader 返回 null', () async {
      final db = MemoryActressDatabase();
      final reload = await db.reloadIfChanged();
      expect(reload.reloaded, isFalse);
      expect(reload.error, isNull);
      expect(await db.genericReader(), isNull);
    });
  });

  group('列表页：绑定行与手动重载', () {
    late Directory temp;
    late MemoryActressDatabase db;

    setUp(() {
      temp = Directory.systemTemp.createTempSync();
      addTearDown(() => temp.deleteSync(recursive: true));
      db = MemoryActressDatabase();
    });

    testWidgets('空库不再自动生成，绑定行如实显示未找到外置数据库', (
      tester,
    ) async {
      final store = await _makeStore();
      final sync = _CountingSyncService(db: db, sources: const []);
      addTearDown(sync.dispose);
      final fallback = ActressJsonFallback(documentsDir: temp);
      // 2026-11-20：列表页 bootstrap 里 await 平台通道拿 MYTV
      // 绑定（真机上毫秒级）；FakeAsync 下平台通道等不到返回，
      // 按树里老办法包在 runAsync 里跑（见 AGENTS.md）。
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: ActressListPage(
              repository: FixtureRepository(),
              store: store,
              database: db,
              syncService: sync,
              fallback: fallback,
            ),
          ),
        );
        await tester.pumpAndSettle();
        // 空库不再自动生成（2026-11-22 用户令最终口径）：不灌
        // 内置 json 种子、不走互联网同步，同步一次都不跑。
        expect(sync.runs, 0);
        // 绑定行在（测试环境没外部存储，未绑定、未找到外置数据库）。
        expect(find.text('数据库：未找到外置数据库'), findsOneWidget);
        // 手动重载入口常驻，点按后内存库没有变化。
        expect(find.text('重新加载数据库'), findsOneWidget);
        await tester.tap(find.text('重新加载数据库'));
        await tester.pumpAndSettle();
        expect(find.text('数据库没有变化'), findsOneWidget);
      });
    });

    testWidgets('通用模式：作品标题可见、“数据库字段”按钮在', (tester) async {
      final store = await _makeStore();
      final sync = _CountingSyncService(db: db, sources: const []);
      final genericDb = _GenericTestDb(
        const [
          GenericDbWork(
            id: 1,
            title: '通用测试作品一',
            code: 'ABC-1',
            playUrl: 'https://example.com/1.m3u8',
          ),
          GenericDbWork(
            id: 2,
            title: '通用测试作品二',
            code: 'XYZ-2',
            playUrl: 'https://example.com/2.m3u8',
          ),
        ],
        schema: classifyGenericTables({
          'videos': ['id', 'title', 'url'],
        }),
      );
      final fallback = ActressJsonFallback(documentsDir: temp);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: ActressListPage(
              repository: FixtureRepository(),
              store: store,
              database: genericDb,
              syncService: sync,
              fallback: fallback,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('演员库 · 外来数据库'), findsOneWidget);
        expect(find.text('通用测试作品一'), findsOneWidget);
        expect(find.text('通用测试作品二'), findsOneWidget);
        expect(find.text('外来数据库 · 表 videos · 2 条'), findsOneWidget);
        expect(find.text('数据库字段'), findsOneWidget);
        // 通用模式不跑同步（护栏），同步次数为 0。
        expect(sync.runs, 0);
        // 点“数据库字段”进查看页：表名与字段名列出来（表名在卡片标题与
        // 手动指定的表下拉里各出现一次，字段名在列清单与角色下拉里各
        // 出现一次）。
        await tester.tap(find.text('数据库字段'));
        await tester.pumpAndSettle();
        expect(find.text('数据库字段'), findsWidgets);
        expect(find.text('videos'), findsWidgets);
        expect(find.text('title'), findsWidgets);
        expect(find.text('url'), findsWidgets);
        expect(find.text('手动指定作品表'), findsOneWidget);
        // 手动映射已按自动认出的标题/播放地址预填，保存可用。
        // 保存按钮在字段页 ListView 底部，屏外没构建出来，先滚到可见。
        final saveButton = find.text('保存映射并重新加载');
        await tester.scrollUntilVisible(saveButton, 100);
        expect(saveButton, findsOneWidget);
        await tester.tap(saveButton);
        // 保存走真文件写（runAsync 下走真实 IO）：只 pumpAndSettle
        // 会在写没完成时就返回（没帧可刷了），先等它落盘、弹回、
        // 列表重读完再断言。
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        // 保存后回到列表，作品还在。
        expect(find.text('通用测试作品一'), findsOneWidget);
      });
    });
  });
}
