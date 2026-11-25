import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/app_build.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/content_models.dart';
import 'package:moyi/content_zone_screen.dart';
import 'package:moyi/game_zone_page.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/home_zone.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/live_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/miniapp/mini_app_home_page.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 壳子底部栏的 8 个标签（与 home_screen.dart 的 _bottomTabBar 同一份
/// 定义）：片库/直播/听读/网盘/小程序/女优库/游戏区/我的（“我的”在
/// 最后一位，用户 2026-11-19 令），中间播放键固定居中（centerAfter: 4，
/// 网盘之后、左右各 4 个页签，用户 2026-11-19 令）。
const _shellEntries = [
  (LucideIcons.clapperboard, '片库'),
  (LucideIcons.tv, '直播'),
  (LucideIcons.bookHeadphones, '听读'),
  (LucideIcons.hardDrive, '网盘'),
  (LucideIcons.layoutGrid, '小程序'),
  (LucideIcons.users, '演员库'),
  (LucideIcons.gamepad2, '游戏区'),
  (LucideIcons.user, '我的'),
];

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
  VoidCallback? onCenter,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppThemeConfig.forTheme(mode).toThemeData(),
      home: Scaffold(
        body: const SizedBox.shrink(),
        bottomNavigationBar: NeonCapsuleBar(
          entries: _shellEntries,
          index: index,
          onSelect: onSelect,
          onCenter: onCenter ?? () {},
          centerAfter: 4,
          tabKeyPrefix: 'shell-tab',
          centerKey: 'shell-center',
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('底部标签网盘图标是硬盘', (tester) async {
    await _pumpBar(
      tester,
      mode: AppThemeMode.purpleNeon,
      index: 0,
      onSelect: (_) {},
    );
    expect(find.text('网盘'), findsOneWidget);
    expect(find.byIcon(LucideIcons.hardDrive), findsOneWidget);
    expect(find.byIcon(LucideIcons.film), findsNothing);
  });

  testWidgets('多媒体已改名：旧名不存在，网盘 + 硬盘图标在', (tester) async {
    await _pumpBar(
      tester,
      mode: AppThemeMode.purpleNeon,
      index: 0,
      onSelect: (_) {},
    );
    expect(find.text('多媒体'), findsNothing);
    expect(find.text('网盘'), findsOneWidget);
    expect(find.byIcon(LucideIcons.hardDrive), findsOneWidget);
  });

  testWidgets('显示方案默认：全部主题底部标签，全部内容', (tester) async {
    final store = await _makeStore();
    for (final mode in AppThemeMode.values) {
      expect(
        store.displayScheme(mode),
        const ThemeDisplayScheme(navStyle: NavStyle.bottomTabs),
      );
    }
  });

  // 导航样式是固定值（全部主题底部标签）：写抽屉也读回底部标签；
  // 内容档仍按主题分别存取。
  testWidgets('显示方案按主题分别存取（导航固定值覆盖写值）', (tester) async {
    final store = await _makeStore();
    await store.setDisplayScheme(
      AppThemeMode.purpleNeon,
      const ThemeDisplayScheme(
        navStyle: NavStyle.drawer,
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
      const ThemeDisplayScheme(navStyle: NavStyle.bottomTabs),
    );
  });

  testWidgets('显示方案解析容忍旧值与非法值', (tester) async {
    final store = await _makeStore({
      'themeScheme_purpleNeon': 'drawer',
      'themeScheme_lightClean': 'bogus:xx',
      'themeScheme_goldVip': 'bottomTabs:adult',
    });
    // 旧值里的导航段一律作废、读回固定值（底部标签）；内容档照旧解析。
    expect(
      store.displayScheme(AppThemeMode.purpleNeon),
      const ThemeDisplayScheme(navStyle: NavStyle.bottomTabs),
    );
    expect(
      store.displayScheme(AppThemeMode.lightClean),
      const ThemeDisplayScheme(navStyle: NavStyle.bottomTabs),
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
      for (final label in ['片库', '直播', '听读', '网盘', '小程序', '我的', '演员库', '游戏区']) {
        expect(find.text(label), findsOneWidget);
      }
      // 霓虹胶囊栏：选中 = primaryColor，无选中胶囊/圆点。
      final selectedLabel = tester.widget<Text>(find.text('直播'));
      expect(selectedLabel.style?.color, config.primaryColor);
      final unselectedLabel = tester.widget<Text>(find.text('片库'));
      expect(unselectedLabel.style?.color, config.textSecondary);
      final selectedIcon = tester.widget<Icon>(find.byIcon(LucideIcons.tv));
      expect(selectedIcon.color, config.primaryColor);
      for (final element in find.byType(Text).evaluate()) {
        expect((element.widget as Text).overflow, isNot(TextOverflow.ellipsis));
      }
    });
  }

  testWidgets('底栏 8 个 Tab 点按回传下标，中间播放键另回', (tester) async {
    final tapped = <int>[];
    var centerTapped = 0;
    await _pumpBar(
      tester,
      mode: AppThemeMode.purpleNeon,
      index: 0,
      onSelect: tapped.add,
      onCenter: () => centerTapped++,
    );
    for (var i = 0; i < 8; i++) {
      await tester.tap(find.byKey(ValueKey('shell-tab-$i')));
      await tester.pump();
    }
    expect(tapped, [0, 1, 2, 3, 4, 5, 6, 7]);
    await tester.tap(find.byKey(const ValueKey('shell-center')));
    await tester.pump();
    expect(centerTapped, 1);
    expect(tapped, [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  testWidgets('底栏顺序为片库/直播/听读/网盘/[播放键]/小程序/演员库/游戏区/我的', (tester) async {
    await _pumpBar(
      tester,
      mode: AppThemeMode.purpleNeon,
      index: 0,
      onSelect: (_) {},
    );
    const order = ['片库', '直播', '听读', '网盘', '小程序', '演员库', '游戏区', '我的'];
    var previousX = -1.0;
    for (final label in order) {
      expect(find.text(label), findsOneWidget);
      final x = tester.getTopLeft(find.text(label)).dx;
      expect(x, greaterThan(previousX));
      previousX = x;
    }
    // 中间播放键固定居中：在网盘与小程序之间，且中心点与胶囊栏
    // 中线重合（左右各 4 个等宽页签，用户 2026-11-19 令）。
    final centerX = tester.getCenter(find.byKey(const ValueKey('shell-center'))).dx;
    final mediaX = tester.getCenter(find.text('网盘')).dx;
    final miniAppX = tester.getCenter(find.text('小程序')).dx;
    expect(centerX, greaterThan(mediaX));
    expect(centerX, lessThan(miniAppX));
    final barCenterX = tester.getCenter(find.byType(NeonCapsuleBar)).dx;
    expect(centerX, closeTo(barCenterX, 0.5));
    // 网盘（硬盘）在我的（人形）左边。
    final driveX = tester.getTopLeft(find.byIcon(LucideIcons.hardDrive)).dx;
    final userX = tester.getTopLeft(find.byIcon(LucideIcons.user)).dx;
    expect(driveX, lessThan(userX));
  });

  testWidgets('切主题后底栏立即变色', (tester) async {
    await _pumpBar(
      tester,
      mode: AppThemeMode.purpleNeon,
      index: 0,
      onSelect: (_) {},
    );
    final neonLabel = tester.widget<Text>(find.text('片库'));
    expect(
      neonLabel.style?.color,
      AppThemeConfig.forTheme(AppThemeMode.purpleNeon).primaryColor,
    );
    await _pumpBar(
      tester,
      mode: AppThemeMode.lightClean,
      index: 0,
      onSelect: (_) {},
    );
    final lightLabel = tester.widget<Text>(find.text('片库'));
    expect(
      lightLabel.style?.color,
      AppThemeConfig.forTheme(AppThemeMode.lightClean).primaryColor,
    );
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    String source = 'huangdou',
    String theme = 'lightClean',
  }) async {
    SharedPreferences.setMockInitialValues({
      'source': source,
      'hiddenSites': '[]',
      'appThemeMode': theme,
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeRouteObserver],
        home: HomeScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> tapShellTab(WidgetTester tester, int index) async {
    await tester.tap(find.byKey(ValueKey('shell-tab-$index')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 当前区探针：看 body 里挂的是哪个屏（不走抽屉）。
  HomeZone? currentZone(WidgetTester tester) {
    if (find.byType(LiveScreen).evaluate().isNotEmpty) return HomeZone.live;
    final zones = find.byType(ContentZoneScreen).evaluate();
    if (zones.isNotEmpty) {
      final section = (zones.first.widget as ContentZoneScreen).section;
      return switch (section) {
        ContentSection.audio => HomeZone.audio,
        ContentSection.novel => HomeZone.novel,
        ContentSection.music => HomeZone.music,
      };
    }
    return null;
  }

  bool multimediaShown(WidgetTester tester) =>
      find.byKey(const ValueKey('multimedia-empty')).evaluate().isNotEmpty ||
      find.byKey(const ValueKey('multimedia-screen')).evaluate().isNotEmpty;

  testWidgets('底栏网盘进网盘屏、切其它区能离开、点片库能回', (tester) async {
    await pumpHome(tester);
    await tapShellTab(tester, 3);
    expect(multimediaShown(tester), isTrue);
    await tapShellTab(tester, 1);
    expect(currentZone(tester), HomeZone.live);
    expect(multimediaShown(tester), isFalse);
    await tapShellTab(tester, 3);
    expect(multimediaShown(tester), isTrue);
    await tapShellTab(tester, 0);
    expect(multimediaShown(tester), isFalse);
  }, skip: !allSourcesEnabled);

  testWidgets('底栏切区：直播→听读（默认听书）→页内子切换到阅读', (tester) async {
    await pumpHome(tester, source: 'hongguo');
    await tapShellTab(tester, 1);
    expect(currentZone(tester), HomeZone.live);
    await tapShellTab(tester, 2);
    expect(currentZone(tester), HomeZone.audio);
    await tester.tap(find.byKey(const ValueKey('listenread-novel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(currentZone(tester), HomeZone.novel);
  }, skip: !allSourcesEnabled);

  testWidgets('我的页里不再有主题切换行，设置行可达', (tester) async {
    await pumpHome(tester);
    await tapShellTab(tester, 7);
    expect(find.text('最近观看'), findsOneWidget);
    for (var i = 0; i < 12; i++) {
      if (find.text('设置').evaluate().isNotEmpty) {
        break;
      }
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('主题切换'), findsNothing);
    expect(find.text('设置'), findsOneWidget);
  }, skip: !allSourcesEnabled);

  testWidgets('底栏小程序进小程序首页', (tester) async {
    await pumpHome(tester);
    await tapShellTab(tester, 4);
    expect(find.byType(MiniAppHomePage), findsOneWidget);
    await tapShellTab(tester, 0);
    expect(find.byType(MiniAppHomePage), findsNothing);
  }, skip: !allSourcesEnabled);

  testWidgets('底栏女优库进女优库区、切其它区能离开、点片库能回', (tester) async {
    await pumpHome(tester);
    await tapShellTab(tester, 5);
    expect(find.byType(ActressListPage), findsOneWidget);
    await tapShellTab(tester, 1);
    expect(currentZone(tester), HomeZone.live);
    expect(find.byType(ActressListPage), findsNothing);
    await tapShellTab(tester, 5);
    expect(find.byType(ActressListPage), findsOneWidget);
    await tapShellTab(tester, 0);
    expect(find.byType(ActressListPage), findsNothing);
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
          onAvatarPressed: () {},
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

  // 底部标签 8 个 Tab 逐个点、各进各的页：听读在第 2 位（默认
  // 听书子区，页内子切换进阅读，再点标签回到上次的子区）、多媒
  // 体在第 3 位、小程序在第 4 位、女优库在第 5 位、
  // 游戏区在第 6 位、我的在第 7 位（最后一位）。红果源走短剧分支。
  testWidgets('底部标签 8 个 Tab 逐个点各进各的页', (tester) async {
    await pumpHome(tester, source: 'hongguo', theme: 'purpleNeon');
    expect(find.byType(NeonCapsuleBar), findsOneWidget);

    await tapShellTab(tester, 1);
    expect(currentZone(tester), HomeZone.live);
    await tapShellTab(tester, 2);
    expect(currentZone(tester), HomeZone.audio);
    // 听读页内子切换：阅读。
    await tester.tap(find.byKey(const ValueKey('listenread-novel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(currentZone(tester), HomeZone.novel);
    // 离开再点听读标签：回到上次的子区（阅读）。
    await tapShellTab(tester, 0);
    await tapShellTab(tester, 2);
    expect(currentZone(tester), HomeZone.novel);
    // 子切换回听书。
    await tester.tap(find.byKey(const ValueKey('listenread-audio')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(currentZone(tester), HomeZone.audio);
    await tapShellTab(tester, 3);
    expect(multimediaShown(tester), isTrue);
    await tapShellTab(tester, 4);
    expect(find.byType(MiniAppHomePage), findsOneWidget);
    await tapShellTab(tester, 5);
    expect(find.byType(ActressListPage), findsOneWidget);
    await tapShellTab(tester, 6);
    expect(find.byType(GameZonePage), findsOneWidget);
    await tapShellTab(tester, 7);
    expect(find.text('最近观看'), findsOneWidget);
    await tapShellTab(tester, 0);
    expect(currentZone(tester), isNull);
    expect(multimediaShown(tester), isFalse);
    expect(find.byType(MiniAppHomePage), findsNothing);
    expect(find.text('最近观看'), findsNothing);
    expect(find.byType(ActressListPage), findsNothing);
    expect(find.byType(GameZonePage), findsNothing);
  }, skip: !allSourcesEnabled);

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
          onAvatarPressed: () {},
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
      if (find.text('设置').evaluate().isNotEmpty) {
        break;
      }
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('主题切换'), findsNothing);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('短剧首页 requestedTab 直达小程序页', (tester) async {
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
          onAvatarPressed: () {},
          onFilterPressed: () {},
          onRankingsPressed: () {},
          onNewPressed: () {},
          filtersActive: false,
          newActive: false,
          onOpenSaved: ({required bool history}) {},
          requestedTab: HongguoDramaHome.miniAppTabIndex,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(MiniAppHomePage), findsOneWidget);
  });

  testWidgets('短剧首页 requestedTab 直达女优库页', (tester) async {
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
          onAvatarPressed: () {},
          onFilterPressed: () {},
          onRankingsPressed: () {},
          onNewPressed: () {},
          filtersActive: false,
          newActive: false,
          onOpenSaved: ({required bool history}) {},
          requestedTab: HongguoDramaHome.actressTabIndex,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(ActressListPage), findsOneWidget);
  });
}
