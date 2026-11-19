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
import 'package:moyi/actress/actress_site_crawl.dart';
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
  }) async {
    startedSite = site;
  }
}

void main() {
  late MemoryActressDatabase db;
  late ActressJsonFallback fallback;
  late _NoopCrawl crawl;
  late LocalStore store;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
  });

  setUp(() async {
    db = MemoryActressDatabase();
    // A：八木奈奈，本地有一部 MIDA-619（随包 mjv JSON 里有这部）；
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
    fallback = ActressJsonFallback(
      assetReader: (asset) async => File(asset).readAsString(),
    );
    await fallback.load();
    crawl = _NoopCrawl(repository: FixtureRepository(), db: db);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ActressListPage(
          repository: FixtureRepository(),
          store: store,
          database: db,
          fallback: fallback,
          crawlService: crawl,
        ),
      ),
    );
    await tester.pumpAndSettle();
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

  /// 从随包 mjv JSON 里取第 index 个可兜底样例（有番号、有女优名、
  /// 有直链，且不是八木奈奈——setUp 里的 A 号就是她，本地已有
  /// MIDA-619，按名合并后会把唯一一条当“本地已有”跳过）。
  ({String name, String code}) pickDetailSample(int index) {
    final doc =
        jsonDecode(
              File('assets/actress_json/mjv011.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
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

  testWidgets('详情页兜底区：本地零作品时也显示（不被暂无作品挡住）', (
    tester,
  ) async {
    // 本地零作品：以前“暂无作品”用 SliverFillRemaining，占满视口
    // 把后面的兜底区挡得进不了树；现在两边都空才用 FillRemaining，
    // 有兜底时“暂无作品”改普通 sliver，兜底区跟在后面。
    final sample = pickDetailSample(0);
    final localId = await makeDetailPersonId(sample.name, 'c1');
    await pumpDetail(tester, localId);
    expect(find.text('暂无作品'), findsOneWidget);
    // 兜底区不显示标题：卡直接跟在后面（用户令：不显示“兜底作品”提示）。
    expect(find.textContaining('兜底作品'), findsNothing);
    expect(find.text(sample.code), findsWidgets);
    expect(find.text('mjv'), findsWidgets);
  });

  testWidgets('详情页兜底区：本地有作品时兜底跟在后面，卡上显示番号与站', (
    tester,
  ) async {
    final sample = pickDetailSample(1);
    final localId = await makeDetailPersonId(sample.name, 'c2');
    await db.upsertWorks(localId, [
      const RosterFilm(code: 'ZZZZ-000', title: '本地占位'),
    ]);
    await pumpDetail(tester, localId);
    expect(find.text('本地占位'), findsOneWidget);
    // 兜底区不显示标题：卡直接跟在本地作品后面。
    expect(find.textContaining('兜底作品'), findsNothing);
    expect(find.text(sample.code), findsWidgets);
    expect(find.text('mjv'), findsWidgets);
  });
}
