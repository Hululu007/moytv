// 女优库列表页预览截图：左上角站点筛选器三态（全部 / mjv / whos）。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把三张放进同一个
// 测试体，也不要批量跑。
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
import 'package:moyi/actress/actress_site_crawl.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir =
    '/home/hatch/workspace/actress_sync_filter_20261119/preview';

// 预览种子（setUp 里填，测试体里用）：放文件级，_capture 是顶层函数。
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

/// 列表页种子数据：A 八木奈奈（本地有 MIDA-619，随包 mjv JSON 里有
/// 这部）、B 测试二号（JSON 里没有）；名册检查点全记完成，不自动跑同步。
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
  // 同步读（readAsStringSync）是双保险：种子在 setUp 里跑（FakeAsync
  // 区之外）本来就不卡；万一以后有人把 load 移回测试体内，同步读
  // 不走事件循环，也不会卡在文件读取上（实测教训：测试体内第一个
  // pump 之前 await 异步文件读取时，mjv011.json 的 fd 一直开着、
  // 测试进程在 epoll 里空等）。
  final fallback = ActressJsonFallback(
    assetReader: (asset) async => File(asset).readAsStringSync(),
  );
  await fallback.load();
  final crawl = _NoopCrawl(repository: FixtureRepository(), db: db);
  return (store: store, db: db, fallback: fallback, crawl: crawl);
}

Future<void> _capture(
  WidgetTester tester, {
  required String name,
  required String label,
  required Future<void> Function(WidgetTester tester) action,
  ActressSiteCrawlService? crawlService,
}) async {
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
        theme: _previewTheme(AppThemeMode.purpleNeon),
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
                  child: Text(
                    label,
                    style: const TextStyle(
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
                    crawlService: crawlService ?? _previewCrawl,
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
  await action(tester);
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

Future<void> _selectSite(WidgetTester tester, String site) async {
  await tester.tap(find.byKey(const ValueKey('actress-site-filter')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(site).last);
  await tester.pumpAndSettle();
}

void main() {
  // 种子放 setUp（FakeAsync 区之外，真实事件循环）：测试体内第一个
  // pump 之前 await 异步 I/O/通道调用时，绑定不投递完成事件，会
  // 一直卡住（实测卡在 fallback.load 的文件读取上）。
  setUp(() async {
    final seed = await _seed();
    _previewStore = seed.store;
    _previewDb = seed.db;
    _previewFallback = seed.fallback;
    _previewCrawl = seed.crawl;
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

  testWidgets('preview actress list all', (tester) async {
    await _capture(
      tester,
      name: 'actress_list_all',
      label: '预览 · 女优库列表页 · 站点筛选：全部（两人都在）',
      action: (tester) async {},
    );
  });

  testWidgets('preview actress list mjv', (tester) async {
    await _capture(
      tester,
      name: 'actress_list_mjv',
      label: '预览 · 女优库列表页 · 站点筛选：mjv（只留 JSON 里有的人）',
      action: (tester) async {
        await _selectSite(tester, 'mjv');
      },
    );
  });

  testWidgets('preview actress list whos', (tester) async {
    await _capture(
      tester,
      name: 'actress_list_whos',
      label: '预览 · 女优库列表页 · 站点筛选：whos（触发 whos 现爬，报缺口）',
      // whos 用真服务：选 whos 时它只发缺口错误（不碰仓库不写盘），
      // 列表页现爬横幅会显示缺口原因；假爬不发进度，横幅画不出来。
      crawlService: ActressSiteCrawlService(
        repository: FixtureRepository(),
        db: _previewDb,
      ),
      action: (tester) async {
        await _selectSite(tester, 'whos');
      },
    );
  });
}
