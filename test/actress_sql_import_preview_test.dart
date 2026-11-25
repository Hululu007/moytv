// 女优库 .sql 导入预览截图：一测一张（调过 toImage 的测试在收尾时会
// 挂起，PNG 已落地，跑单测、超时杀掉只取 PNG；不要批量跑）。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_mytv_bind.dart';
import 'package:moyi/actress/actress_site_crawl.dart';
import 'package:moyi/actress/actress_sql_import.dart';
import 'package:moyi/actress/actress_sql_import_section.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir =
    '/home/hatch/workspace/moyi_actress_sql_only_20261125/preview';

late LocalStore _previewStore;
late MemoryActressDatabase _previewDb;
late ActressJsonFallback _previewFallback;
late _NoopCrawl _previewCrawl;

/// 不真爬：只记下触发的站。
class _NoopCrawl extends ActressSiteCrawlService {
  _NoopCrawl({required super.repository, required super.db});

  String? startedSite;

  @override
  Future<void> start({
    String site = 'mjv',
    int maxPagesPerCategory =
        ActressSiteCrawlService.defaultMaxPagesPerCategory,
    int enrichPerCategory =
        ActressSiteCrawlService.defaultEnrichPerCategory,
    int categoryConcurrency =
        ActressSiteCrawlService.defaultCategoryConcurrency,
    Duration timeBudget = ActressSiteCrawlService.defaultTimeBudget,
  }) async {
    startedSite = site;
  }
}

ThemeData _previewTheme(AppThemeMode mode) {
  final base = AppThemeConfig.forTheme(mode).toThemeData();
  TextStyle? cjk(TextStyle? style) => style?.copyWith(fontFamily: 'PreviewCJK');
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: cjk(base.appBarTheme.titleTextStyle),
    ),
  );
}

/// 预览主题 + 按钮字也走 PreviewCJK：树里 textButtonTheme 的
/// textStyle 没写 fontFamily，测试环境默认字体没有中文字形，
/// 按钮字会糊成方框；真机系统字体没这个问题，只改预览用主题。
ThemeData _previewThemeWithButtons(AppThemeMode mode) =>
    _previewTheme(mode).copyWith(
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: const TextStyle(
            fontFamily: 'PreviewCJK',
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    try {
      await tester.pump(const Duration(milliseconds: 100));
    } catch (_) {}
  }
  for (var i = 0; i < 10; i++) {
    try {
      if (tester.takeException() == null) break;
    } catch (_) {
      break;
    }
  }
}

/// 列表页种子数据（与 actress_list_preview_test 同款）：八木奈奈
///（本地有 MIDA-619）+ 测试二号，名册检查点全记完成。
Future<
    ({
      LocalStore store,
      MemoryActressDatabase db,
      ActressJsonFallback fallback,
      _NoopCrawl crawl,
    })> _seed() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  final db = MemoryActressDatabase();
  final a = await db.upsertRosterPerson(
    const RosterPerson(
      source: ActressRosterSourceId.chaoliu,
      sourceId: 'a1',
      name: '八木奈奈',
      sex: 'female',
    ),
  );
  await db.upsertWorks(a!.localId, [
    const RosterFilm(code: 'MIDA-619', title: '测试作品'),
  ]);
  await db.upsertRosterPerson(
    const RosterPerson(
      source: ActressRosterSourceId.whos,
      sourceId: 'b1',
      name: '测试二号',
      sex: 'female',
    ),
  );
  for (final source in ActressRosterSourceId.values) {
    for (final phase in const ['roster', 'films']) {
      await db.saveCheckpoint(
        ActressSyncCheckpoint(
          source: source.name,
          phase: phase,
          finished: true,
        ),
      );
    }
  }
  final temp = Directory.systemTemp.createTempSync();
  final jsonDir = Directory('${temp.path}/actress_json')
    ..createSync(recursive: true);
  File('${jsonDir.path}/mjv011.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'list': [
        {
          'vod_id': 'mjv-mida-619',
          'vod_name': 'MIDA-619 测试作品',
          'vod_pic': '',
          'vod_actor': '八木奈奈',
          'vod_director': '',
          'vod_remarks': '高清',
          'vod_pubdate': '2026-01-01',
          'vod_area': '日本',
          'vod_year': '2026',
          'vod_content': '',
          'vod_play_from': 'mjv011',
          'vod_play_url': '正片\$https://example.test/mida619.m3u8',
          'type_name': '有码',
          'vod_code': 'MIDA-619',
          'vod_actress_pic': '',
        },
      ],
      'parse': 0,
      'jx': 0,
      'last_update': '2026-11-20T00:00:00',
    }),
  );
  final fallback = ActressJsonFallback(localJsonDir: jsonDir);
  await fallback.load();
  final crawl = _NoopCrawl(repository: FixtureRepository(), db: db);
  return (store: store, db: db, fallback: fallback, crawl: crawl);
}

Future<void> _capturePng(
  WidgetTester tester,
  String name,
  Widget child,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _previewThemeWithButtons(AppThemeMode.purpleNeon),
        home: DefaultTextStyle(
          style: const TextStyle(fontFamily: 'PreviewCJK'),
          child: Scaffold(body: child),
        ),
      ),
    ),
  );
  await _settle(tester);
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data!.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$name.png').writeAsBytesSync(bytes);
}

Widget _sectionFrame(Widget section) => SingleChildScrollView(
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        width: double.infinity,
        color: Colors.black87,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: const Text(
          '预览 · 女优库设置 · 导入数据库（.sql）',
          style: TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontFamily: 'PreviewCJK',
          ),
        ),
      ),
      section,
    ],
  ),
);

void main() {
  setUp(() async {
    final seed = await _seed();
    _previewStore = seed.store;
    _previewDb = seed.db;
    _previewFallback = seed.fallback;
    _previewCrawl = seed.crawl;
    await ActressMytvBind.instance.ensureBound();
  });

  setUpAll(() async {
    try {
      final bytes = File(
        '/home/hatch/workspace/huoyi_new/cjk_subset.ttf',
      ).readAsBytesSync();
      final loader = FontLoader('PreviewCJK')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
  });

  testWidgets('preview sql import entry', (tester) async {
    await _capturePng(
      tester,
      'settings_import_entry',
      _sectionFrame(
        ActressSqlImportSection(
          bound: true,
          running: false,
          progress: null,
          error: null,
          lastResult: null,
          onImport: () {},
          onCancel: null,
        ),
      ),
    );
  });

  testWidgets('preview sql import progress', (tester) async {
    await _capturePng(
      tester,
      'settings_import_progress',
      _sectionFrame(
        ActressSqlImportSection(
          bound: true,
          running: true,
          progress: ActressSqlImportProgress(
            phase: '正在导入',
            statements: 1500,
            bytesRead: 209715200,
            totalBytes: 674981047,
          ),
          error: null,
          lastResult: null,
          onImport: null,
          onCancel: () {},
        ),
      ),
    );
  });

  testWidgets('preview sql import done', (tester) async {
    await _capturePng(
      tester,
      'settings_import_done',
      _sectionFrame(
        ActressSqlImportSection(
          bound: true,
          running: false,
          progress: null,
          error: null,
          lastResult: ActressSqlImportResult(
            ok: true,
            videos: 300,
            actresses: 30,
            playUrls: 480,
            covers: 300,
            avatars: 30,
          ),
          onImport: () {},
          onCancel: null,
        ),
      ),
    );
  });

  testWidgets('preview library after import', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(_previewStore.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _previewThemeWithButtons(AppThemeMode.purpleNeon),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'PreviewCJK'),
            child: Scaffold(
              body: Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: Colors.black87,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: const Text(
                      '预览 · 女优库列表页 · 导入后有数据（两人）',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontFamily: 'PreviewCJK',
                      ),
                    ),
                  ),
                  Expanded(
                    child: ActressListPage(
                      repository: FixtureRepository(),
                      store: _previewStore,
                      database: _previewDb,
                      fallback: _previewFallback,
                      crawlService: _previewCrawl,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    Directory(_previewDir).createSync(recursive: true);
    File(
      '$_previewDir/library_after_import.png',
    ).writeAsBytesSync(bytes);
  });
}
