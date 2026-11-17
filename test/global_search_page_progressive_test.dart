// 全局搜索渐进显示：慢腿不挡快腿，回来一个显示一个；单腿失败
// 不拖垮另一腿的结果；视频腿超时有兜底收尾。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/content_models.dart';
import 'package:moyi/content_registry.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/global_search_page.dart';
import 'package:moyi/global_search_service.dart';
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

/// 阅读组：用注册表真实源对象（只读名，不调网络），条目现成。
GlobalSearchBookGroup _novelGroup(String title) {
  final source = ContentRegistry.sourcesFor(ContentSection.novel).first;
  return GlobalSearchBookGroup(
    section: ContentSection.novel,
    source: source,
    items: [ContentBook(id: title, title: title)],
  );
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required LocalStore store,
  Future<CatalogPage> Function(List<String> sources, String query)? videoSearch,
  Future<void> Function(
    String query,
    List<GlobalSearchBookTarget> targets,
    void Function(GlobalSearchBookGroup group) onGroup,
  )?
  bookSearch,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: GlobalSearchPage(
        repository: _FakeRepository(),
        store: store,
        initialQuery: '持续',
        videoSearchOverride: videoSearch,
        bookSearchOverride: bookSearch,
      ),
    ),
  );
}

void main() {
  testWidgets('慢视频腿不挡阅读组：阅读组先上屏，视频腿回了再补', (tester) async {
    final store = await _makeStore();
    final videoGate = Completer<CatalogPage>();
    Future<void> bookSearch(
      String query,
      List<GlobalSearchBookTarget> targets,
      void Function(GlobalSearchBookGroup group) onGroup,
    ) async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      onGroup(_novelGroup('神瞳·小说'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      onGroup(_novelGroup('神瞳·漫画'));
    }

    await _pumpPage(
      tester,
      store: store,
      videoSearch: (_, _) => videoGate.future,
      bookSearch: bookSearch,
    );
    await tester.pump();
    // 两腿都没回：全屏转圈。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('神瞳·小说'), findsNothing);

    // 第一组阅读结果上屏，两腿仍在等：底部只剩小提示。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.text('神瞳·小说'), findsOneWidget);
    expect(find.text('正在搜索更多站源…', skipOffstage: false), findsOneWidget);

    // 第二组也上屏，阅读腿结束，只剩视频腿待回。底部提示在列表
    // 末尾，两组结果会把它顶出测试视口，断言不过滤视口外元素。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.text('神瞳·漫画'), findsOneWidget);
    expect(find.text('正在搜索视频站源…', skipOffstage: false), findsOneWidget);

    // 视频腿回包：视频卡上屏，底部提示消失。
    videoGate.complete(
      CatalogPage([
        const Drama(id: 'hongguo:1', source: 'hongguo', title: '持续·短剧'),
      ]),
    );
    await tester.pump();
    expect(find.text('持续·短剧'), findsOneWidget);
    expect(find.textContaining('正在搜索', skipOffstage: false), findsNothing);
    expect(
      find.byType(CircularProgressIndicator, skipOffstage: false),
      findsNothing,
    );
  });

  testWidgets('视频腿抛错时阅读结果照常显示，不报整轮失败', (tester) async {
    final store = await _makeStore();
    await _pumpPage(
      tester,
      store: store,
      videoSearch: (_, _) async => throw StateError('boom'),
      bookSearch: (_, _, onGroup) async {
        onGroup(_novelGroup('神瞳·小说'));
      },
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.text('神瞳·小说'), findsOneWidget);
    expect(find.text('搜索失败，请重试'), findsNothing);
    expect(find.textContaining('正在搜索', skipOffstage: false), findsNothing);
  });

  testWidgets('两腿都失败才报整轮失败', (tester) async {
    final store = await _makeStore();
    await _pumpPage(
      tester,
      store: store,
      videoSearch: (_, _) async => throw StateError('boom'),
      bookSearch: (_, _, _) async => throw StateError('boom'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.text('搜索失败，请重试'), findsOneWidget);
    expect(find.text('暂无结果'), findsNothing);
  });

  testWidgets('两腿都空回“暂无结果”，不转圈不报错', (tester) async {
    final store = await _makeStore();
    await _pumpPage(
      tester,
      store: store,
      videoSearch: (_, _) async => CatalogPage(const []),
      bookSearch: (_, _, _) async {},
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.text('暂无结果'), findsOneWidget);
    expect(
      find.byType(CircularProgressIndicator, skipOffstage: false),
      findsNothing,
    );
    expect(find.text('搜索失败，请重试'), findsNothing);
  });

  testWidgets('视频腿 150 秒无回包则超时收尾，阅读结果不受影响', (tester) async {
    final store = await _makeStore();
    await _pumpPage(
      tester,
      store: store,
      videoSearch: (_, _) => Completer<CatalogPage>().future,
      bookSearch: (_, _, onGroup) async {
        onGroup(_novelGroup('神瞳·小说'));
      },
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.text('神瞳·小说'), findsOneWidget);
    expect(find.text('正在搜索视频站源…', skipOffstage: false), findsOneWidget);

    // 假时钟走到超时点：视频腿收尾，底部提示消失，结果仍在。
    await tester.pump(
      globalSearchVideoOverallTimeout + const Duration(seconds: 1),
    );
    await tester.pump();
    expect(find.text('神瞳·小说'), findsOneWidget);
    expect(find.textContaining('正在搜索', skipOffstage: false), findsNothing);
    expect(find.text('搜索失败，请重试'), findsNothing);
  });
}
