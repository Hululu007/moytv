// 本站搜索（单站模式）：只搜当前一个站，只跑视频腿，不跑阅读腿；
// 不传 siteId 时保持原来的全部可见站 + 阅读腿行为。
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
  String? siteId,
  String? siteName,
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
        siteId: siteId,
        siteName: siteName,
        videoSearchOverride: videoSearch,
        bookSearchOverride: bookSearch,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

void main() {
  testWidgets('单站模式只向视频腿传一个站 id，不跑阅读腿，标题含站名', (
    tester,
  ) async {
    final store = await _makeStore();
    List<String>? capturedSources;
    var bookCalls = 0;
    await _pumpPage(
      tester,
      store: store,
      siteId: 'hongguo',
      siteName: '红果',
      videoSearch: (sources, query) async {
        capturedSources = sources;
        return CatalogPage([
          const Drama(id: 'hongguo:1', source: 'hongguo', title: '持续·短剧'),
        ]);
      },
      bookSearch: (_, _, _) async {
        bookCalls++;
      },
    );
    expect(capturedSources, ['hongguo']);
    expect(bookCalls, 0);
    expect(find.text('搜索：红果'), findsOneWidget);
    expect(find.text('全局搜索'), findsNothing);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.hintText, '搜本站');
    expect(find.text('持续·短剧'), findsOneWidget);
  });

  testWidgets('单站模式不给站名时标题写搜索本站', (tester) async {
    final store = await _makeStore();
    await _pumpPage(
      tester,
      store: store,
      siteId: 'hongguo',
      videoSearch: (_, _) async => CatalogPage(const []),
      bookSearch: (_, _, _) async {},
    );
    expect(find.text('搜索：本站'), findsOneWidget);
  });

  testWidgets('单站模式视频腿失败报整轮失败，不等阅读腿', (tester) async {
    final store = await _makeStore();
    var bookCalls = 0;
    await _pumpPage(
      tester,
      store: store,
      siteId: 'hongguo',
      siteName: '红果',
      videoSearch: (_, _) async => throw StateError('boom'),
      bookSearch: (_, _, _) async {
        bookCalls++;
      },
    );
    expect(bookCalls, 0);
    expect(find.text('搜索失败，请重试'), findsOneWidget);
    expect(find.text('暂无结果'), findsNothing);
  });

  testWidgets('无 siteId 时旧行为不变：视频腿传全部可见站，阅读腿照常跑', (
    tester,
  ) async {
    final store = await _makeStore();
    final expectedIds = store.visibleSources
        .where((s) => !s.isHtmlSite)
        .map((s) => s.id)
        .toList();
    // 默认单源构建下可见站只有一个（红果），不断言多于 1 个；
    // 旧行为的关键是“传全部可见站 + 跑阅读腿”，由下面三处断言锁定。
    expect(expectedIds, isNotEmpty);
    List<String>? capturedSources;
    var bookCalls = 0;
    await _pumpPage(
      tester,
      store: store,
      videoSearch: (sources, query) async {
        capturedSources = sources;
        return CatalogPage(const []);
      },
      bookSearch: (_, _, onGroup) async {
        bookCalls++;
        onGroup(_novelGroup('神瞳·小说'));
      },
    );
    expect(capturedSources, expectedIds);
    expect(bookCalls, 1);
    expect(find.text('全局搜索'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.hintText, '搜全部区域与站源');
    expect(find.text('神瞳·小说'), findsOneWidget);
  });
}
