import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/auto_refresh_gate.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_home_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Drama _drama(String id) => Drama(
  id: id,
  source: 'hongguo',
  title: 'hongguo-$id',
  cover: 'https://example.test/cover.jpg',
  kind: 'video',
);

void main() {
  Future<void> pumpView(
    WidgetTester tester, {
    Future<void> Function()? onRefresh,
    required VoidCallback onSourceTap,
    required VoidCallback onSearch,
    VoidCallback? onAvatar,
  }) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NeonHomeView(
            items: [_drama('row0'), _drama('row1'), _drama('row2')],
            repository: FixtureRepository(),
            brand: '魔蚁box',
            sourceLabel: '红果 (1)',
            onOpen: (_) {},
            onSearch: onSearch,
            onSourceTap: onSourceTap,
            onLongPress: (_) {},
            onRefresh: onRefresh,
            onAvatar: onAvatar,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('点 🔄 钮只触发刷新，不弹站点窗口', (tester) async {
    var refreshCalls = 0;
    var sourceCalls = 0;
    var searchCalls = 0;
    await pumpView(
      tester,
      onRefresh: () async => refreshCalls++,
      onSourceTap: () => sourceCalls++,
      onSearch: () => searchCalls++,
    );
    await tester.tap(find.byKey(const ValueKey('neon-top-refresh')));
    await tester.pump();
    expect(refreshCalls, 1);
    expect(sourceCalls, 0);
    expect(searchCalls, 0);
  });

  testWidgets('点标题什么都不触发（2026-11-18 19:49 令：点名称不弹）', (tester) async {
    var refreshCalls = 0;
    var sourceCalls = 0;
    await pumpView(
      tester,
      onRefresh: () async => refreshCalls++,
      onSourceTap: () => sourceCalls++,
      onSearch: () {},
    );
    expect(find.byKey(const ValueKey('neon-top-source')), findsNothing);
    await tester.tap(find.text('魔蚁box'));
    await tester.pump();
    expect(sourceCalls, 0);
    expect(refreshCalls, 0);
  });

  testWidgets('点图标触发换站源', (tester) async {
    var refreshCalls = 0;
    var sourceCalls = 0;
    await pumpView(
      tester,
      onRefresh: () async => refreshCalls++,
      onSourceTap: () => sourceCalls++,
      onSearch: () {},
      // 调用方把弹站点列表的回调传给 onAvatar（与 _neonHome 一致）。
      onAvatar: () => sourceCalls++,
    );
    await tester.tap(find.byKey(const ValueKey('neon-avatar')));
    await tester.pump();
    expect(sourceCalls, 1);
    expect(refreshCalls, 0);
  });

  testWidgets('点搜索钮只触发搜索', (tester) async {
    var refreshCalls = 0;
    var sourceCalls = 0;
    var searchCalls = 0;
    await pumpView(
      tester,
      onRefresh: () async => refreshCalls++,
      onSourceTap: () => sourceCalls++,
      onSearch: () => searchCalls++,
    );
    await tester.tap(find.byKey(const ValueKey('neon-top-search')));
    await tester.pump();
    expect(searchCalls, 1);
    expect(refreshCalls, 0);
    expect(sourceCalls, 0);
  });

  testWidgets('onRefresh 为空时点 🔄 钮不动', (tester) async {
    var sourceCalls = 0;
    await pumpView(tester, onSourceTap: () => sourceCalls++, onSearch: () {});
    await tester.tap(find.byKey(const ValueKey('neon-top-refresh')));
    await tester.pump();
    expect(sourceCalls, 0);
  });

  group('AutoRefreshGate 节流单元', () {
    test('从未刷过时应刷新', () {
      expect(AutoRefreshGate.shouldRefresh(null, DateTime(2026, 11, 16)), true);
    });

    test('节流窗内不刷新、满 5 分钟刷新', () {
      final last = DateTime(2026, 11, 16, 20, 0);
      expect(
        AutoRefreshGate.shouldRefresh(last, DateTime(2026, 11, 16, 20, 4, 59)),
        false,
      );
      expect(
        AutoRefreshGate.shouldRefresh(last, DateTime(2026, 11, 16, 20, 5)),
        true,
      );
      expect(
        AutoRefreshGate.shouldRefresh(last, DateTime(2026, 11, 16, 20, 6)),
        true,
      );
    });

    test('tryClaim 认领一次后窗内再认领失败，且失败不重置计时', () {
      final gate = AutoRefreshGate(lastRefresh: DateTime(2026, 11, 16, 20, 0));
      expect(gate.tryClaim(DateTime(2026, 11, 16, 20, 6)), true);
      expect(gate.tryClaim(DateTime(2026, 11, 16, 20, 7)), false);
      // 失败的认领没改时间戳：距成功认领满 5 分钟即可再次认领。
      expect(gate.tryClaim(DateTime(2026, 11, 16, 20, 11)), true);
    });

    test('markRefreshed 重置计时', () {
      final gate = AutoRefreshGate(lastRefresh: DateTime(2026, 11, 16, 20, 0));
      gate.markRefreshed(DateTime(2026, 11, 16, 20, 6));
      expect(gate.tryClaim(DateTime(2026, 11, 16, 20, 10)), false);
      expect(gate.tryClaim(DateTime(2026, 11, 16, 20, 11)), true);
    });

    test('新建的门默认记一次刚刷过，立即认领失败', () {
      final gate = AutoRefreshGate();
      expect(gate.tryClaim(), false);
    });
  });

  group('切回首页页签通知', () {
    const tabCategories = [
      CatalogCategory('', '全部'),
      CatalogCategory('short_play', '真人剧'),
      CatalogCategory('rec', '推荐'),
    ];

    Future<void> pumpDramaHome(
      WidgetTester tester, {
      required VoidCallback onHomeTabSelected,
    }) async {
      SharedPreferences.setMockInitialValues({
        'hiddenSites': '[]',
        'appThemeMode': 'purpleNeon',
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      final searchController = TextEditingController();
      addTearDown(searchController.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: HongguoDramaHome(
            dramas: [_drama('row0')],
            repository: FixtureRepository(),
            store: store,
            onOpenDrama: (_) {},
            onOpenFeed: () {},
            onPickSource: () {},
            sourceLabel: '红果 (1)',
            feedEnabled: true,
            categories: tabCategories,
            selectedCategory: 'rec',
            onCategorySelected: (_) {},
            searchController: searchController,
            searchHint: '搜索',
            onSearchChanged: (_) {},
            onSearchSubmitted: (_) {},
            onOpenGlobalSearch: () {},
            onAvatarPressed: () {},
            onFilterPressed: () {},
            onRankingsPressed: () {},
            onNewPressed: () {},
            filtersActive: false,
            newActive: false,
            onOpenSaved: ({required bool history}) {},
            hideCapsuleBar: true,
            onHomeTabSelected: onHomeTabSelected,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('切走再切回首页只通知一次，同页签重复点按不通知', (tester) async {
      var calls = 0;
      await pumpDramaHome(tester, onHomeTabSelected: () => calls++);
      expect(calls, 0);
      await tester.tap(find.byKey(const ValueKey('drama-nav-channel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(calls, 0);
      await tester.tap(find.byKey(const ValueKey('drama-nav-home')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(calls, 1);
      await tester.tap(find.byKey(const ValueKey('drama-nav-home')));
      await tester.pump();
      expect(calls, 1);
      await tester.tap(find.byKey(const ValueKey('drama-nav-multimedia')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(calls, 1);
      await tester.tap(find.byKey(const ValueKey('drama-nav-home')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(calls, 2);
    });
  });

  group('前台自动刷新端到端', () {
    Future<void> pumpHome(
      WidgetTester tester,
      _CountingRepository repo,
      AutoRefreshGate gate,
    ) async {
      SharedPreferences.setMockInitialValues({
        'hiddenSites': '[]',
        'appThemeMode': 'purpleNeon',
        'source': 'hongguo',
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [homeRouteObserver],
          theme: AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData(),
          home: HomeScreen(
            repository: repo,
            store: store,
            autoRefreshGate: gate,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('回前台刷新一次、窗内不再刷、手点 🔄 照样刷且重置计时', (tester) async {
      final repo = _CountingRepository();
      final gate = AutoRefreshGate(
        lastRefresh: DateTime.now().subtract(const Duration(minutes: 6)),
      );
      await pumpHome(tester, repo, gate);
      expect(repo.catalogCalls, greaterThan(0));
      expect(repo.categoriesCalls, greaterThan(0));
      final baseCatalog = repo.catalogCalls;
      final baseCategories = repo.categoriesCalls;

      // ① 回到前台 → 自动刷新一次。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(repo.catalogCalls, greaterThan(baseCatalog));
      expect(repo.categoriesCalls, greaterThan(baseCategories));

      // ② 节流窗内再回前台 → 不刷新。
      final snapCatalog = repo.catalogCalls;
      final snapCategories = repo.categoriesCalls;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(repo.catalogCalls, snapCatalog);
      expect(repo.categoriesCalls, snapCategories);

      // ③ 节流窗内手点 🔄 → 照样刷新，且手动刷完重置计时。
      await tester.tap(find.byKey(const ValueKey('neon-top-refresh')));
      await settle(tester);
      expect(repo.catalogCalls, greaterThan(snapCatalog));
      expect(repo.categoriesCalls, greaterThan(snapCategories));
      final snap2Catalog = repo.catalogCalls;
      final snap2Categories = repo.categoriesCalls;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(repo.catalogCalls, snap2Catalog);
      expect(repo.categoriesCalls, snap2Categories);
    });
  });
}

/// 计数仓库：只记目录与分类的调用次数，其余走 FixtureRepository。
class _CountingRepository extends FixtureRepository {
  var catalogCalls = 0;
  var categoriesCalls = 0;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    catalogCalls++;
    return super.catalog(
      source,
      page: page,
      query: query,
      category: category,
      force: force,
      filters: filters,
    );
  }

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    categoriesCalls++;
    return super.categories(source, force: force);
  }
}
