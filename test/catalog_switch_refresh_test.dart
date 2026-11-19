import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 每个站源/分类返回标题互不相同的条目，界面显示内容可直接区分新旧。
class _DistinctRepository extends FixtureRepository {
  final catalogKeys = <String>[];

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [
    CatalogCategory.all,
    CatalogCategory('ca', '甲类'),
    CatalogCategory('cb', '乙类'),
  ];

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
            title: 'T-$source-$label-$i',
            episodes: 1,
            category: '合成数据',
          ),
      ],
      page: page,
      hasMore: false,
    );
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

/// 缓存里有旧内容：切类/切站时先显示缓存占位，随后必须被现抓结果覆盖。
class _CachedRepository extends _DistinctRepository {
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async {
    final label = category.isEmpty ? '全部' : category;
    return CatalogPage(
      [
        for (var i = 1; i <= 3; i++)
          Drama(
            id: 'stale|$source|$category|$i',
            source: source,
            title: '旧缓存-$source-$label-$i',
            episodes: 1,
            category: '合成数据',
          ),
      ],
      page: 1,
      hasMore: false,
      fresh: true,
    );
  }
}

/// 慢仓库：每次目录请求都等 300ms，模拟手机上的真实耗时。
class _SlowRepository extends _DistinctRepository {
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return super.catalog(
      source,
      page: page,
      query: query,
      category: category,
      force: force,
      filters: filters,
    );
  }
}

/// 抖动仓库：每个新（站源|分类）键的第一次目录请求抛错，之后成功。
/// 模拟手机上切站/切类后首次请求落空（盾、限流、内核未就绪）。
class _FlakyRepository extends _DistinctRepository {
  final _failedKeys = <String>{};

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    final key = '$source|$category';
    if (_failedKeys.add(key)) {
      throw AppFailure('模拟抖动：首次请求落空');
    }
    return super.catalog(
      source,
      page: page,
      query: query,
      category: category,
      force: force,
      filters: filters,
    );
  }
}

/// 缓存 + 抖动仓库：缓存里有旧内容，现抓第一次抛错、之后成功。
class _CachedFlakyRepository extends _CachedRepository {
  final _failedKeys = <String>{};

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    final key = '$source|$category';
    if (_failedKeys.add(key)) {
      throw AppFailure('模拟抖动：首次现抓落空');
    }
    return super.catalog(
      source,
      page: page,
      query: query,
      category: category,
      force: force,
      filters: filters,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'source': 'sitea',
      'hiddenSites': '[]',
      'appThemeMode': 'purpleNeon',
    });
    store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    SourceSite.importedSites['sitea'] = SourceSite(
      'sitea',
      'SiteA',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originBuiltin,
    );
    SourceSite.importedSites['siteb'] = SourceSite(
      'siteb',
      'SiteB',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originBuiltin,
    );
    addTearDown(() {
      SourceSite.importedSites.remove('sitea');
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

  testWidgets('切站点后界面显示新站内容，旧站内容消失', (tester) async {
    final repository = _DistinctRepository();
    await pumpHome(tester, repository);
    await flushLoads(tester);
    expect(find.text('T-sitea-全部-1'), findsWidgets);
    expect(find.text('T-siteb-全部-1'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('source-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('site-picker-row-siteb')));
    await flushLoads(tester);

    expect(repository.catalogKeys, contains('siteb|'));
    expect(find.text('T-siteb-全部-1'), findsWidgets);
    expect(find.text('T-sitea-全部-1'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('切分类后界面显示新分类内容，旧分类内容消失', (tester) async {
    final repository = _DistinctRepository();
    await pumpHome(tester, repository);
    await flushLoads(tester);
    expect(find.text('T-sitea-全部-1'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('category-category:乙类')));
    await flushLoads(tester);

    expect(repository.catalogKeys, contains('sitea|cb'));
    expect(find.text('T-sitea-cb-1'), findsWidgets);
    expect(find.text('T-sitea-全部-1'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('有缓存时切分类：旧缓存只作占位，现抓结果随后覆盖', (tester) async {
    final repository = _CachedRepository();
    await pumpHome(tester, repository);
    await flushLoads(tester);
    expect(find.text('T-sitea-全部-1'), findsWidgets);
    expect(find.text('旧缓存-sitea-全部-1'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('category-category:乙类')));
    await flushLoads(tester);

    expect(repository.catalogKeys, contains('sitea|cb'));
    expect(find.text('T-sitea-cb-1'), findsWidgets);
    expect(find.text('旧缓存-sitea-cb-1'), findsNothing);
    expect(find.text('T-sitea-全部-1'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('有缓存时切站点：现抓结果随后覆盖，不停在旧站缓存上', (tester) async {
    final repository = _CachedRepository();
    await pumpHome(tester, repository);
    await flushLoads(tester);
    expect(find.text('T-sitea-全部-1'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('source-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('site-picker-row-siteb')));
    await flushLoads(tester);

    expect(repository.catalogKeys, contains('siteb|'));
    expect(find.text('T-siteb-全部-1'), findsWidgets);
    expect(find.text('旧缓存-siteb-全部-1'), findsNothing);
    expect(find.text('T-sitea-全部-1'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('慢仓库连续切两次分类：最后一次胜出，不停在中间结果上', (tester) async {
    final repository = _SlowRepository();
    await pumpHome(tester, repository);
    await flushLoads(tester);
    expect(find.text('T-sitea-全部-1'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('category-category:甲类')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('category-category:乙类')));
    await flushLoads(tester);

    expect(find.text('T-sitea-cb-1'), findsWidgets);
    expect(find.text('T-sitea-ca-1'), findsNothing);
    expect(find.text('T-sitea-全部-1'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('慢仓库首屏加载中切站点：新站内容胜出，不停在旧站结果上', (tester) async {
    final repository = _SlowRepository();
    await pumpHome(tester, repository);
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(const ValueKey('source-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('site-picker-row-siteb')));
    await flushLoads(tester);

    expect(find.text('T-siteb-全部-1'), findsWidgets);
    expect(find.text('T-sitea-全部-1'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('抖动仓库切分类：首次落空后自动补拉，不用人手动刷新', (tester) async {
    final repository = _FlakyRepository();
    await pumpHome(tester, repository);
    await flushLoads(tester);
    expect(find.text('T-sitea-全部-1'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('category-category:乙类')));
    await flushLoads(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('T-sitea-cb-1'), findsWidgets);
    expect(find.text('T-sitea-全部-1'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('缓存+抖动切分类：现抓落空后自动补拉，不停在旧缓存上', (tester) async {
    final repository = _CachedFlakyRepository();
    await pumpHome(tester, repository);
    await flushLoads(tester);
    expect(find.text('T-sitea-全部-1'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('category-category:乙类')));
    await flushLoads(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('T-sitea-cb-1'), findsWidgets);
    expect(find.text('旧缓存-sitea-cb-1'), findsNothing);
    expect(find.text('T-sitea-全部-1'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('抖动仓库切站点：首次落空后自动补拉', (tester) async {
    final repository = _FlakyRepository();
    await pumpHome(tester, repository);
    await flushLoads(tester);
    expect(find.text('T-sitea-全部-1'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('source-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('site-picker-row-siteb')));
    await flushLoads(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('T-siteb-全部-1'), findsWidgets);
    expect(find.text('T-sitea-全部-1'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
