// 女优库左上角站点筛选（2026-11-19）：默认全部，选站过滤列表并触发该站现爬。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_detail_page.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_mytv_bind.dart';
import 'package:moyi/actress/actress_roster_sources.dart';
import 'package:moyi/actress/actress_site_crawl.dart';
import 'package:moyi/actress/actress_sync.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

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

/// 不真同步：空源同步服务（站点筛选测的不是同步；默认真同步服务
/// 带潮流/whos 两个源，见下面 pumpPage 的 runAsync 说明）。
class _NoopSync extends ActressSyncService {
  _NoopSync({required super.db})
    : super(sources: const [], fetch: _unusedFetch);

  static Future<ActressHttpResponse> _unusedFetch(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 20),
  }) async =>
      throw UnimplementedError('test sync must not fetch');
}

void main() {
  late MemoryActressDatabase db;
  late ActressJsonFallback fallback;
  late _NoopCrawl crawl;
  late _NoopSync sync;
  late LocalStore store;
  late File localMjvFile;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
  });

  setUp(() async {
    db = MemoryActressDatabase();
    // A：八木奈奈，本地有一部 MIDA-619（本地 mjv011.json 里有这部）；
    // B：测试二号，JSON 里没有。
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
    // 三家名册 roster/films 检查点全记完成，列表页不自动跑名册同步。
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
    // 本地 mjv011.json 里给八木奈奈放一部 MIDA-619（2026-11-22 前
    // 这部在随包 mjv JSON 里，随包已删，改写本地文件）；另放两条
    // 样例行（详情页兜底不显示的测试用，不是八木奈奈）。
    final temp = Directory.systemTemp.createTempSync();
    addTearDown(() => temp.deleteSync(recursive: true));
    final jsonDir = Directory('${temp.path}/actress_json')
      ..createSync(recursive: true);
    Map<String, dynamic> row({
      required String vodId,
      required String code,
      required String actor,
    }) => {
      'vod_id': vodId,
      'vod_name': '$code 测试作品',
      'vod_pic': '',
      'vod_actor': actor,
      'vod_director': '',
      'vod_remarks': '高清',
      'vod_pubdate': '2026-01-01',
      'vod_area': '日本',
      'vod_year': '2026',
      'vod_content': '',
      'vod_play_from': 'mjv011',
      'vod_play_url': '正片\$https://example.test/${code.toLowerCase()}.m3u8',
      'type_name': '有码',
      'vod_code': code,
      'vod_actress_pic': '',
    };
    localMjvFile = File('${jsonDir.path}/mjv011.json')
      ..writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'list': [
            row(vodId: 'mjv-mida-619', code: 'MIDA-619', actor: '八木奈奈'),
            row(vodId: 'mjv-sample-1', code: 'SSIS-901', actor: '样例女优甲'),
            row(vodId: 'mjv-sample-2', code: 'SSIS-902', actor: '样例女优乙'),
          ],
          'parse': 0,
          'jx': 0,
          'last_update': '2026-11-20T00:00:00',
        }),
      );
    fallback = ActressJsonFallback(localJsonDir: jsonDir);
    await fallback.load();
    crawl = _NoopCrawl(repository: FixtureRepository(), db: db);
    sync = _NoopSync(db: db);
    // MYTV 绑定预解析（树里既定做法，见 actress_count_fix_test.dart）：
    // 列表页 bootstrap 开头 await ensureBound()，它里面有异步文件
    // IO（探针写/删），在 widget 测试 FakeAsync 下挂起；setUp 在
    // 真实异步区，先解析完缓存起来，页内再调直接回缓存值。
    await ActressMytvBind.instance.ensureBound();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // 列表页 bootstrap 里 await 平台通道拿 MYTV 绑定；FakeAsync 下
    // 平台通道等不到返回，按树里老办法包在 runAsync 里跑（见
    // actress_sync_crawler_test.dart 同款与 AGENTS.md），否则首屏
    // 转圈一直在转，pumpAndSettle 永远不定下来。
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: ActressListPage(
            repository: FixtureRepository(),
            store: store,
            database: db,
            fallback: fallback,
            crawlService: crawl,
            syncService: sync,
          ),
        ),
      );
      await tester.pumpAndSettle();
    });
  }

  testWidgets('默认全部显示两人；选 mjv 只留 JSON 里有的人，并触发 mjv 现爬', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(find.text('八木奈奈'), findsOneWidget);
    expect(find.text('测试二号'), findsOneWidget);
    expect(find.text('全部'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('actress-site-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('mjv').last);
    await tester.pumpAndSettle();

    expect(find.text('八木奈奈'), findsOneWidget);
    expect(find.text('测试二号'), findsNothing);
    expect(crawl.startedSite, 'mjv');
  });

  testWidgets('选 whos 触发 whos 现爬（服务侧报缺口，不编假蜘蛛）', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('actress-site-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('whos').last);
    await tester.pumpAndSettle();
    expect(crawl.startedSite, 'whos');
  });

  /// 从本地 mjv011.json 里取第 index 个可兜底样例（有番号、有女优名、
  /// 有直链，且不是八木奈奈——setUp 里的 A 号就是她，本地已有
  /// MIDA-619，按名合并后会把唯一一条当“本地已有”跳过）。
  ({String name, String code}) pickDetailSample(int index) {
    final doc =
        jsonDecode(localMjvFile.readAsStringSync()) as Map<String, dynamic>;
    final rows = (doc['list'] as List).cast<Map<String, dynamic>>().where(
      (row) =>
          (row['vod_code'] as String).isNotEmpty &&
          (row['vod_actor'] as String).isNotEmpty &&
          (row['vod_actor'] as String) != '八木奈奈' &&
          (row['vod_play_url'] as String).startsWith('正片\$https://'),
    ).toList();
    final row = rows[index];
    return (
      name: row['vod_actor'] as String,
      code: row['vod_code'] as String,
    );
  }

  Future<int> makeDetailPersonId(String name, String sourceId) async {
    final person = await db.upsertRosterPerson(
      RosterPerson(
        source: ActressRosterSourceId.chaoliu,
        sourceId: sourceId,
        name: name,
        sex: 'female',
      ),
    );
    return person!.localId;
  }

  Future<void> pumpDetail(WidgetTester tester, int localId) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ActressDetailPage(
          localId: localId,
          repository: FixtureRepository(),
          store: store,
          database: db,
          fallback: fallback,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('详情页兜底一直不显示：本地零作品时只见暂无作品', (
    tester,
  ) async {
    // 兜底一直不显示，只后台兜底播放（用户 2026-11-20 定）：本地
    // 零作品时只显示“暂无作品”，兜底条目不渲染成卡片（数据仍在
    // 后台加载，供点播链路兜底用）。
    final sample = pickDetailSample(0);
    final localId = await makeDetailPersonId(sample.name, 'c1');
    await pumpDetail(tester, localId);
    expect(find.text('暂无作品'), findsOneWidget);
    expect(find.textContaining('兜底作品'), findsNothing);
    expect(find.text(sample.code), findsNothing);
    expect(find.text('mjv'), findsNothing);
  });

  testWidgets('详情页兜底一直不显示：本地有作品时只见本地作品', (
    tester,
  ) async {
    final sample = pickDetailSample(1);
    final localId = await makeDetailPersonId(sample.name, 'c2');
    await db.upsertWorks(localId, [
      const RosterFilm(code: 'ZZZZ-000', title: '本地占位'),
    ]);
    await pumpDetail(tester, localId);
    expect(find.text('本地占位'), findsOneWidget);
    // 兜底条目不渲染：样本番号与站名都不应出现在页面上。
    expect(find.textContaining('兜底作品'), findsNothing);
    expect(find.text(sample.code), findsNothing);
    expect(find.text('mjv'), findsNothing);
  });
}
