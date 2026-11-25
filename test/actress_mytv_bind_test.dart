// 女优库 MYTV 绑定（2026-11-20，2026-11-25 只留 .sql 导入后绑定
// 只剩 json/m3u 目录与合并 JSON 导出，不再管数据库）：绑定解析、
// 迁移、用户 m3u、json/m3u/现爬目录覆盖、内存库重读空实现、
// 列表页没导入数据库的空态。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_m3u_index.dart';
import 'package:moyi/actress/actress_mytv_bind.dart';
import 'package:moyi/actress/actress_roster_sources.dart';
import 'package:moyi/actress/actress_site_crawl.dart';
import 'package:moyi/actress/actress_sync.dart';
import 'package:moyi/local_store.dart';
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

    test('绑定成功：json/m3u 目录是 MYTV 下的两子目录', () async {
      final result = await bind().ensureBound();
      expect(result.bound, isTrue);
      expect(result.jsonDir.path, '${ext.path}/MYTV/db');
      expect(result.m3uDir.path, '${ext.path}/MYTV/m3u');
      expect(Directory('${ext.path}/MYTV/db').existsSync(), isTrue);
      expect(Directory('${ext.path}/MYTV/m3u').existsSync(), isTrue);
      expect(result.mergedJsonExportPath, '${ext.path}/MYTV/mjv011.json');
      expect(result.note, isNull);
    });

    test('MYTV/db 里放 .db 文件也不认：绑定只管 json/m3u', () async {
      // 2026-11-25 只留 .sql 导入：用户往 MYTV/db 里放 女优库.db
      // 不再被读，绑定结果里也没有任何数据库字段。
      File('${ext.path}/MYTV/db/女优库.db')
        ..createSync(recursive: true)
        ..writeAsStringSync('video-db-bytes');
      final result = await bind().ensureBound();
      expect(result.bound, isTrue);
      expect(result.jsonDir.path, '${ext.path}/MYTV/db');
      expect(result.m3uDir.path, '${ext.path}/MYTV/m3u');
      expect(result.note, isNull);
    });

    test('外部存储不可用：未绑定，json/m3u 回落到 documents，不抛错', () async {
      final noExt = ActressMytvBind(
        externalRoot: () async => null,
        documentsDir: () async => docs,
      );
      final result = await noExt.ensureBound();
      expect(result.bound, isFalse);
      expect(result.jsonDir.path, '${docs.path}/actress_json');
      expect(result.m3uDir.path, '${docs.path}/actress_json');
      expect(result.note, contains('外部存储不可用'));
    });

    test('写不进去且没权限：needsPermission', () async {
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
      expect(result.note, contains('没有所有文件访问权限'));
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

    test('启动自动建目录：没库也建出 MYTV/db 与 MYTV/m3u', () async {
      // 2026-11-24 用户令：软件启动就自动生成文件夹和路径
      // MYTV/db，不等进演员库。helper 只是调 ensureBound，
      // 这里验它在空目录上建出两个子文件夹且不抛错。
      await ActressMytvBind.ensureFoldersAtStartup(bind());
      expect(Directory('${ext.path}/MYTV/db').existsSync(), isTrue);
      expect(Directory('${ext.path}/MYTV/m3u').existsSync(), isTrue);
    });

    test('启动自动建目录：解析抛错也不抛到启动流程', () async {
      final throwing = ActressMytvBind(
        externalRoot: () async => throw StateError('boom'),
        documentsDir: () async => docs,
      );
      await ActressMytvBind.ensureFoldersAtStartup(throwing);
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
    test('reloadIfChanged 返回未变', () async {
      final db = MemoryActressDatabase();
      final reload = await db.reloadIfChanged();
      expect(reload.reloaded, isFalse);
      expect(reload.error, isNull);
    });
  });

  group('列表页：没导入数据库的空态', () {
    late Directory temp;
    late MemoryActressDatabase db;

    setUp(() {
      temp = Directory.systemTemp.createTempSync();
      addTearDown(() => temp.deleteSync(recursive: true));
      db = MemoryActressDatabase();
    });

    testWidgets('没导入数据库：空态提示导入 .sql，不自动同步', (tester) async {
      final store = await _makeStore();
      final sync = _CountingSyncService(db: db, sources: const []);
      addTearDown(sync.dispose);
      final fallback = ActressJsonFallback(documentsDir: temp);
      // 2026-11-20：列表页 bootstrap 里 await 平台通道拿 MYTV
      // 绑定（真机上毫秒级）。pumpAndSettle 的假时钟等不到真异步
      // bootstrap（会超时），pump() 也不能放进 runAsync（会挂住）：
      // 按树里既定模式，延时放 runAsync、刷帧放外面（见 AGENTS.md）。
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: ActressListPage(
              repository: FixtureRepository(),
              store: store,
              database: _NoLibraryTestDb(),
              syncService: sync,
              fallback: fallback,
            ),
          ),
        );
      });
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 空库不再自动生成（2026-11-22 用户令最终口径）：不灌
      // 内置 json 种子、不走互联网同步，同步一次都不跑。
      expect(sync.runs, 0);
      // 2026-11-25 只留 .sql 导入：绑定行与“重新加载数据库”
      // 入口都删了，空态只剩这一句导入提示。
      expect(
        find.text('还没有导入数据库：请在设置里导入 .sql 数据库'),
        findsOneWidget,
      );
      expect(find.text('重新加载数据库'), findsNothing);
    });
  });
}

/// reloadIfChanged 报“还没有导入数据库”的测试库：模拟内部工作库
/// 还没建（用户还没导过 .sql）。
class _NoLibraryTestDb extends MemoryActressDatabase {
  @override
  Future<({bool reloaded, String? error})> reloadIfChanged({
    bool force = false,
  }) async {
    return (
      reloaded: false,
      error: '还没有导入数据库：请在设置里导入 .sql 数据库',
    );
  }
}
