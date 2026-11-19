import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 戏剧首页分支（红果组）：每个站源/分类返回标题互不相同的条目。
class _DramaHomeRepository extends FixtureRepository {
  final catalogKeys = <String>[];

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => switch (source) {
    'hongguo' => const [
      CatalogCategory.all,
      CatalogCategory('short_play', '真人剧'),
      CatalogCategory('comic_series', '漫剧'),
    ],
    _ => const [
      CatalogCategory.all,
      CatalogCategory('cb', '乙类'),
    ],
  };

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    requests.add(source);
    catalogKeys.add('$source|$category');
    final label = category.isEmpty ? '全部' : category;
    return CatalogPage(
      [
        for (var i = 1; i <= 3; i++)
          Drama(
            id: '$source|$category|$i',
            source: source,
            title: 'D-$source-$label-$i',
            episodes: 1,
            category: '合成数据',
            kind: 'video',
          ),
      ],
      page: page,
      hasMore: false,
    );
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'source': 'hongguo',
      'hiddenSites': '[]',
      'appThemeMode': 'purpleNeon',
    });
    store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    // 红果是内置站，不必再注册；只注册第二个站作切换目标。
    SourceSite.importedSites['siteb'] = SourceSite(
      'siteb',
      'SiteB',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originBuiltin,
    );
    addTearDown(() {
      SourceSite.importedSites.remove('siteb');
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  Future<void> pumpHome(WidgetTester tester, AppRepository repository) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeRouteObserver],
        home: HomeScreen(repository: repository, store: store),
      ),
    );
  }

  Future<void> flushLoads(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('戏剧首页切分类后显示新分类内容', (tester) async {
    final repository = _DramaHomeRepository();
    await pumpHome(tester, repository);
    await flushLoads(tester);
    expect(find.text('D-hongguo-全部-1'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey('neon-home-category-category:真人剧')),
    );
    await flushLoads(tester);

    expect(repository.catalogKeys, contains('hongguo|short_play'));
    expect(find.text('D-hongguo-short_play-1'), findsWidgets);
    expect(find.text('D-hongguo-全部-1'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('戏剧首页切站点后显示新站内容', (tester) async {
    final repository = _DramaHomeRepository();
    await pumpHome(tester, repository);
    await flushLoads(tester);
    expect(find.text('D-hongguo-全部-1'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('neon-avatar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('site-picker-row-siteb')));
    await flushLoads(tester);

    expect(repository.catalogKeys, contains('siteb|'));
    expect(find.text('D-siteb-全部-1'), findsWidgets);
    expect(find.text('D-hongguo-全部-1'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
