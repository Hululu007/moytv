import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_build.dart';
import 'package:moyi/app_drawer.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/bottom_tab_bar.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Future<LocalStore> _makeStore([Map<String, Object> seeds = const {}]) async {
  SharedPreferences.setMockInitialValues(seeds);
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

Future<void> _pumpBar(
  WidgetTester tester, {
  required AppThemeMode mode,
  required int index,
  required ValueChanged<int> onSelect,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppThemeConfig.forTheme(mode).toThemeData(),
      home: Scaffold(
        body: const SizedBox.shrink(),
        bottomNavigationBar: MoyiBottomTabBar(
          index: index,
          onSelect: onSelect,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('显示方案默认全部抽屉加全部内容', (tester) async {
    final store = await _makeStore();
    for (final mode in AppThemeMode.values) {
      expect(
        store.displayScheme(mode),
        const ThemeDisplayScheme.defaults(),
      );
    }
  });

  testWidgets('显示方案按主题分别存取', (tester) async {
    final store = await _makeStore();
    await store.setDisplayScheme(
      AppThemeMode.purpleNeon,
      const ThemeDisplayScheme(
        navStyle: NavStyle.bottomTabs,
        contentTier: ContentTier.manhua,
      ),
    );
    expect(
      store.displayScheme(AppThemeMode.purpleNeon),
      const ThemeDisplayScheme(
        navStyle: NavStyle.bottomTabs,
        contentTier: ContentTier.manhua,
      ),
    );
    expect(
      store.displayScheme(AppThemeMode.lightClean),
      const ThemeDisplayScheme.defaults(),
    );
  });

  testWidgets('显示方案解析容忍旧值与非法值', (tester) async {
    final store = await _makeStore({
      'themeScheme_purpleNeon': 'bottomTabs',
      'themeScheme_lightClean': 'bogus:xx',
      'themeScheme_goldVip': 'bottomTabs:adult',
    });
    expect(
      store.displayScheme(AppThemeMode.purpleNeon),
      const ThemeDisplayScheme(navStyle: NavStyle.bottomTabs),
    );
    expect(
      store.displayScheme(AppThemeMode.lightClean),
      const ThemeDisplayScheme.defaults(),
    );
    expect(
      store.displayScheme(AppThemeMode.goldVip),
      const ThemeDisplayScheme(
        navStyle: NavStyle.bottomTabs,
        contentTier: ContentTier.adult,
      ),
    );
  });

  for (final mode in [AppThemeMode.purpleNeon, AppThemeMode.lightClean]) {
    final config = AppThemeConfig.forTheme(mode);
    testWidgets('底栏颜色随主题走 ${config.themeName}', (tester) async {
      await _pumpBar(tester, mode: mode, index: 1, onSelect: (_) {});
      expect(find.text('片库'), findsOneWidget);
      expect(find.text('直播'), findsOneWidget);
      expect(find.text('听书'), findsOneWidget);
      expect(find.text('阅读'), findsOneWidget);
      expect(find.text('我的'), findsOneWidget);
      final selectedLabel = tester.widget<Text>(find.text('直播'));
      expect(selectedLabel.style?.color, config.selectedText);
      final unselectedLabel = tester.widget<Text>(find.text('片库'));
      expect(unselectedLabel.style?.color, config.textSecondary);
      final pill = find.ancestor(
        of: find.text('直播'),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).color == config.selectedBg,
        ),
      );
      expect(pill, findsOneWidget);
      final dots = find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).shape == BoxShape.circle &&
            (widget.decoration as BoxDecoration).color ==
                config.primaryColor,
      );
      expect(dots, findsOneWidget);
      for (final element in find.byType(Text).evaluate()) {
        expect(
          (element.widget as Text).overflow,
          isNot(TextOverflow.ellipsis),
        );
      }
    });
  }

  testWidgets('底栏 5 个 Tab 点按回传下标', (tester) async {
    final tapped = <int>[];
    await _pumpBar(tester, mode: AppThemeMode.purpleNeon, index: 0, onSelect: tapped.add);
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byKey(ValueKey('moyi-bottom-tab-$i')));
      await tester.pump();
    }
    expect(tapped, [0, 1, 2, 3, 4]);
  });

  testWidgets('切主题后底栏立即变色', (tester) async {
    await _pumpBar(tester, mode: AppThemeMode.purpleNeon, index: 0, onSelect: (_) {});
    final neonLabel = tester.widget<Text>(find.text('片库'));
    expect(
      neonLabel.style?.color,
      AppThemeConfig.forTheme(AppThemeMode.purpleNeon).selectedText,
    );
    await _pumpBar(tester, mode: AppThemeMode.lightClean, index: 0, onSelect: (_) {});
    final lightLabel = tester.widget<Text>(find.text('片库'));
    expect(
      lightLabel.style?.color,
      AppThemeConfig.forTheme(AppThemeMode.lightClean).selectedText,
    );
  });

  testWidgets('设置导航样式项弹窗切换写回当前主题方案', (tester) async {
    final store = await _makeStore();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData(),
        home: SettingsScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('导航样式'), findsOneWidget);
    expect(find.text('当前：抽屉 · 随当前主题'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nav-style-entry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('底部标签'), findsOneWidget);
    await tester.tap(find.text('底部标签'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      store.displayScheme(AppThemeMode.purpleNeon).navStyle,
      NavStyle.bottomTabs,
    );
    expect(find.text('当前：底部标签 · 随当前主题'), findsOneWidget);
  });

  Future<LocalStore> pumpHome(
    WidgetTester tester, {
    NavStyle navStyle = NavStyle.bottomTabs,
    String source = 'huangdou',
  }) async {
    SharedPreferences.setMockInitialValues({
      'source': source,
      'hiddenSites': '[]',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await store.setDisplayScheme(
      AppThemeMode.purpleNeon,
      ThemeDisplayScheme(navStyle: navStyle),
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeRouteObserver],
        home: HomeScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    return store;
  }

  Future<void> switchToLive(
    WidgetTester tester, {
    String drawerKey = 'open-app-drawer',
  }) async {
    await tester.tap(find.byKey(ValueKey(drawerKey)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final live = find.descendant(
      of: find.byType(Drawer),
      matching: find.text('直播'),
    );
    expect(live, findsOneWidget);
    await tester.tap(live);
    await tester.pump();
    // 等抽屉关闭动画（250ms）跑完再点底栏，否则点落在关闭中的遮罩上。
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 把 [finder] 拖进视口：懒加载 ListView 折叠下的行未构建，
  /// ensureVisible/scrollUntilVisible 在此不可靠，直接拖动并按存在性校验。
  Future<void> dragIntoView(
    WidgetTester tester,
    Finder finder,
    Finder scrollable,
  ) async {
    for (var i = 0; i < 12; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.drag(scrollable, const Offset(0, -200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    throw StateError('widget 拖 12 次仍未出现');
  }

  Future<HomeZone> currentZone(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('open-app-drawer')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final drawer = tester.widget<AppDrawer>(find.byType(AppDrawer));
    await tester.tapAt(const Offset(700, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return drawer.zone;
  }

  testWidgets('首页短剧分支无外层底栏切直播区出现底栏', (tester) async {
    await pumpHome(tester, source: 'hongguo');
    expect(find.byKey(const ValueKey('moyi-bottom-tab-0')), findsNothing);
    await switchToLive(tester, drawerKey: 'neon-avatar');
    expect(await currentZone(tester), HomeZone.live);
    for (var i = 0; i < 5; i++) {
      expect(find.byKey(ValueKey('moyi-bottom-tab-$i')), findsOneWidget);
    }
  }, skip: !allSourcesEnabled);

  testWidgets('首页底栏 Tab 切区与我的页主题行可达选择界面', (tester) async {
    await pumpHome(tester, source: 'hongguo');
    await switchToLive(tester, drawerKey: 'neon-avatar');
    await tester.tap(find.byKey(const ValueKey('moyi-bottom-tab-3')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(await currentZone(tester), HomeZone.novel);
    await tester.tap(find.byKey(const ValueKey('moyi-bottom-tab-4')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await dragIntoView(
      tester,
      find.byKey(const ValueKey('mine-theme-entry')),
      find.byType(ListView),
    );
    expect(find.byKey(const ValueKey('mine-theme-entry')), findsOneWidget);
    expect(find.text('最近观看'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mine-theme-entry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('app-theme-lightClean')), findsOneWidget);
  }, skip: !allSourcesEnabled);

  testWidgets('抽屉入口在底部标签样式下保留', (tester) async {
    await pumpHome(tester);
    await switchToLive(tester);
    await tester.tap(find.byKey(const ValueKey('open-app-drawer')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await dragIntoView(
      tester,
      find.text('主题切换'),
      find.descendant(
        of: find.byType(Drawer),
        matching: find.byType(ListView),
      ),
    );
    expect(find.text('主题切换'), findsOneWidget);
  }, skip: !allSourcesEnabled);

  testWidgets('短剧首页默认页签不是我的页', (tester) async {
    final store = await _makeStore();
    final searchController = TextEditingController();
    addTearDown(searchController.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: HongguoDramaHome(
          dramas: const [],
          repository: FixtureRepository(),
          store: store,
          onOpenDrama: (_) {},
          onOpenFeed: () {},
          onPickSource: () {},
          sourceLabel: '测试',
          feedEnabled: false,
          categories: const [],
          selectedCategory: '',
          onCategorySelected: (_) {},
          searchController: searchController,
          searchHint: '',
          onSearchChanged: (_) {},
          onSearchSubmitted: (_) {},
          onOpenGlobalSearch: () {},
          onMenuPressed: () {},
          onFilterPressed: () {},
          onRankingsPressed: () {},
          onNewPressed: () {},
          filtersActive: false,
          newActive: false,
          onOpenSaved: ({required bool history}) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('最近观看'), findsNothing);
  });

  testWidgets('短剧首页 requestedTab 直达我的页', (tester) async {
    final store = await _makeStore();
    final searchController = TextEditingController();
    addTearDown(searchController.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: HongguoDramaHome(
          dramas: const [],
          repository: FixtureRepository(),
          store: store,
          onOpenDrama: (_) {},
          onOpenFeed: () {},
          onPickSource: () {},
          sourceLabel: '测试',
          feedEnabled: false,
          categories: const [],
          selectedCategory: '',
          onCategorySelected: (_) {},
          searchController: searchController,
          searchHint: '',
          onSearchChanged: (_) {},
          onSearchSubmitted: (_) {},
          onOpenGlobalSearch: () {},
          onMenuPressed: () {},
          onFilterPressed: () {},
          onRankingsPressed: () {},
          onNewPressed: () {},
          filtersActive: false,
          newActive: false,
          onOpenSaved: ({required bool history}) {},
          requestedTab: HongguoDramaHome.mineTabIndex,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('最近观看'), findsOneWidget);
    for (var i = 0; i < 12; i++) {
      if (find.byKey(const ValueKey('mine-theme-entry')).evaluate().isNotEmpty) {
        break;
      }
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.byKey(const ValueKey('mine-theme-entry')), findsOneWidget);
  });
}
