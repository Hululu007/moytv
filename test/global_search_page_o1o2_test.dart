// 搜索提速 O1+O2：视频腿流式逐站上屏、换词取消旧轮、超时保留已出结果。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/global_search_page.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRepository extends AppRepository {
  @override
  Future<void> initialize() async {}

  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      CatalogPage(const []);

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      CatalogPage(const []);

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => drama.cover;

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory.all];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async => CatalogPage(const []);

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, [
    Episode({'id': '1', 'title': '第1集', 'currentEpisode': 1}, 1),
  ]);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    bool adBlock = true,
    int quality = 0,
    int route = 0,
  }) async => const PlaybackPlan(url: 'https://x.test/a.m3u8');

  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async =>
      throw AppFailure('没有备用线路');

  @override
  Future<void> cancelPlayback() async {}

  @override
  Future<void> release(String session) async {}
}

Future<LocalStore> _makeStore() async {
  SharedPreferences.setMockInitialValues({});
  return LocalStore(await SharedPreferences.getInstance());
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required LocalStore store,
  required String query,
  Future<void> Function(
    List<String> sources,
    String query, {
    required void Function(String source, List<Drama> items) onSite,
    bool Function()? shouldStop,
  })?
  videoSearch,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: GlobalSearchPage(
        repository: _FakeRepository(),
        store: store,
        initialQuery: query,
        videoSearchProgressiveOverride: videoSearch,
        bookSearchOverride: (_, _, _) async {},
      ),
    ),
  );
}

Drama _drama(String source, String title) =>
    Drama(id: '$source:$title', source: source, title: title);

void main() {
  testWidgets('流式：先到的站先上屏，后到的追加，两站最终都在', (tester) async {
    final store = await _makeStore();
    Future<void> videoSearch(
      List<String> sources,
      String query, {
      required void Function(String source, List<Drama> items) onSite,
      bool Function()? shouldStop,
    }) async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      onSite('hongguo', [_drama('hongguo', '短剧A')]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      onSite('ghost1', [_drama('ghost1', '未知剧B')]);
    }

    await _pumpPage(tester, store: store, query: '持续', videoSearch: videoSearch);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.text('短剧A'), findsOneWidget);
    expect(find.text('未知剧B'), findsNothing);
    expect(find.text('正在搜索视频站源…', skipOffstage: false), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.text('短剧A'), findsOneWidget);
    expect(find.text('未知剧B'), findsOneWidget);
    expect(find.textContaining('正在搜索', skipOffstage: false), findsNothing);
  });

  testWidgets('换词取消旧轮：旧腿迟到回调不写回，新词结果照常上屏', (tester) async {
    final store = await _makeStore();
    var firstRoundStopSeen = false;
    Future<void> videoSearch(
      List<String> sources,
      String query, {
      required void Function(String source, List<Drama> items) onSite,
      bool Function()? shouldStop,
    }) async {
      if (query == '旧词') {
        onSite('hongguo', [_drama('hongguo', '旧剧A')]);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        firstRoundStopSeen = shouldStop?.call() ?? false;
        // 故意无视 shouldStop 迟到回调：页面代次 guard 必须拦住。
        onSite('ghost1', [_drama('ghost1', '旧剧B迟到')]);
      } else {
        onSite('hongguo', [_drama('hongguo', '新剧C')]);
      }
    }

    await _pumpPage(tester, store: store, query: '旧词', videoSearch: videoSearch);
    await tester.pump();
    await tester.pump();
    expect(find.text('旧剧A'), findsOneWidget);

    // 换词再搜：旧轮被取消，新轮结果上屏。
    await tester.enterText(find.byType(TextField), '新词');
    await tester.tap(find.text('搜索'));
    await tester.pump();
    await tester.pump();
    expect(find.text('新剧C'), findsOneWidget);
    expect(find.text('旧剧A'), findsNothing);

    // 旧腿迟到回调到达时：shouldStop 已真，且页面不写回。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(firstRoundStopSeen, isTrue);
    expect(find.text('旧剧B迟到'), findsNothing);
    expect(find.text('新剧C'), findsOneWidget);
  });

  testWidgets('视频腿超时保留已出结果，不报整轮失败', (tester) async {
    final store = await _makeStore();
    Future<void> videoSearch(
      List<String> sources,
      String query, {
      required void Function(String source, List<Drama> items) onSite,
      bool Function()? shouldStop,
    }) async {
      onSite('hongguo', [_drama('hongguo', '短剧A')]);
      await Completer<void>().future;
    }

    await _pumpPage(tester, store: store, query: '持续', videoSearch: videoSearch);
    await tester.pump();
    await tester.pump();
    expect(find.text('短剧A'), findsOneWidget);
    expect(find.text('正在搜索视频站源…', skipOffstage: false), findsOneWidget);

    await tester.pump(
      globalSearchVideoOverallTimeout + const Duration(seconds: 1),
    );
    await tester.pump();
    expect(find.text('短剧A'), findsOneWidget);
    expect(find.textContaining('正在搜索', skipOffstage: false), findsNothing);
    expect(find.text('搜索失败，请重试'), findsNothing);
  });
}
