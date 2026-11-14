import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moyi/app_build.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/feed_playability.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_channel_view.dart';
import 'package:moyi/neon/neon_home_view.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _NoPlayRepository extends FixtureRepository {
  @override
  Future<DramaDetail> detail(Drama drama) async => throw AppFailure('测试不播');
}

/// 每站只回本站条目：目录与分类都按请求站源 id 盖章，用于鉴别
/// 频道切站后是否只显示新站（FixtureRepository 每站都回混合页，
/// 分辨不出聚合泄漏）。
class _PerSourceRepository extends FixtureRepository {
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
    return CatalogPage([
      Drama(id: '$source:1', source: source, title: '剧-$source-1'),
      Drama(id: '$source:2', source: source, title: '剧-$source-2'),
    ]);
  }

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => [CatalogCategory.all, CatalogCategory('c-$source', '分类-$source')];

  @override
  Future<DramaDetail> detail(Drama drama) async => throw AppFailure('测试不播');
}

/// 验播放行全部：本文件测导航与切站，不测验播本身。
FeedPlayabilityVerifier _passThroughVerifier() => FeedPlayabilityVerifier(
  detailOf: (drama) async => DramaDetail(drama, [
    Episode({'id': '1', 'title': '第1集', 'currentEpisode': 1}, 1),
  ]),
  resolveOf: (drama, episode) async =>
      const PlaybackPlan(url: 'https://x.test/play.m3u8'),
  fetchHead: (url, headers, timeout) async => const FeedProbeResponse(
    statusCode: 200,
    headers: {'content-type': 'application/vnd.apple.mpegurl'},
    headBytes: [35, 69, 88, 84, 77, 51, 85],
  ),
);

const _categories = [
  CatalogCategory('', '全部'),
  CatalogCategory('short_play', '真人剧'),
  CatalogCategory('comic_series', '漫剧'),
  CatalogCategory('rec', '推荐'),
];

const _baseDrama = Drama(
  id: 'hongguo:1',
  source: 'hongguo',
  title: '普通短剧一',
  cover: 'https://x.test/base.jpg',
  episodes: 3,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> makeStore() async {
    SharedPreferences.setMockInitialValues({'hiddenSites': '[]'});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  Future<void> pumpDramaHome(
    WidgetTester tester, {
    bool hideCapsuleBar = false,
    List<Drama> dramas = const [_baseDrama],
  }) async {
    final store = await makeStore();
    final searchController = TextEditingController();
    addTearDown(searchController.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: HongguoDramaHome(
          dramas: dramas,
          repository: _NoPlayRepository(),
          store: store,
          onOpenDrama: (_) {},
          onOpenFeed: () {},
          onPickSource: () {},
          sourceLabel: '红果 (1)',
          feedEnabled: dramas.isNotEmpty,
          categories: _categories,
          selectedCategory: 'rec',
          onCategorySelected: (_) {},
          searchController: searchController,
          searchHint: '搜索',
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
          hideCapsuleBar: hideCapsuleBar,
          playabilityVerifier: _passThroughVerifier(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  group('戏剧首页底栏覆盖（第 4 件）', () {
    testWidgets('藏胶囊栏时芯片行出现且胶囊栏消失', (tester) async {
      await pumpDramaHome(tester, hideCapsuleBar: true);
      expect(find.byType(NeonBottomBar), findsNothing);
      expect(find.byKey(const ValueKey('drama-internal-nav')), findsOneWidget);
      expect(find.byKey(const ValueKey('drama-nav-home')), findsOneWidget);
      expect(find.byKey(const ValueKey('drama-nav-channel')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('drama-nav-multimedia')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('drama-nav-feed')), findsOneWidget);
    });

    testWidgets('胶囊栏多媒体项进多媒体屏且无片单残留', (tester) async {
      await pumpDramaHome(tester);
      expect(find.text('多媒体'), findsOneWidget);
      expect(find.text('片单'), findsNothing);
      await tester.tap(find.text('多媒体'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('还没有登录任何网盘'), findsOneWidget);
      expect(find.text('片单'), findsNothing);
    });

    testWidgets('无覆盖时胶囊栏原样且无芯片行', (tester) async {
      await pumpDramaHome(tester);
      expect(find.byType(NeonBottomBar), findsOneWidget);
      expect(find.byKey(const ValueKey('drama-internal-nav')), findsNothing);
    });

    testWidgets('胶囊栏图标：频道🎞️/多媒体硬盘/中间播放三角', (tester) async {
      await pumpDramaHome(tester);
      expect(find.text('🎞️'), findsOneWidget);
      expect(find.byIcon(LucideIcons.hardDrive), findsOneWidget);
      expect(find.byIcon(LucideIcons.play), findsWidgets);
      expect(find.byIcon(LucideIcons.plus), findsNothing);
      expect(find.byIcon(LucideIcons.film), findsNothing);
      expect(find.byIcon(LucideIcons.layoutGrid), findsNothing);
    });

    testWidgets('芯片切换内层页签：频道/多媒体/推荐/首页', (tester) async {
      await pumpDramaHome(tester, hideCapsuleBar: true);
      expect(find.byType(NeonHomeView), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('drama-nav-channel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(NeonChannelView), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('drama-nav-multimedia')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // 未传网盘站：多媒体屏显示未登录提示。
      expect(find.text('还没有登录任何网盘'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('drama-nav-feed')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('关注'), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-back-home')), findsOneWidget);
      // 全屏流内芯片行不显示，返回首页走顶栏返回键。
      await tester.tap(find.byKey(const ValueKey('feed-back-home')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(NeonHomeView), findsOneWidget);
    });

    testWidgets('全屏流内返回键回到首页', (tester) async {
      await pumpDramaHome(tester, hideCapsuleBar: true);
      await tester.tap(find.byKey(const ValueKey('drama-nav-feed')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('关注'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('feed-back-home')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(NeonHomeView), findsOneWidget);
    });

    testWidgets('抽屉样式下全屏流无返回键', (tester) async {
      await pumpDramaHome(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(NeonBottomBar),
          matching: find.byIcon(LucideIcons.play),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('关注'), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-back-home')), findsNothing);
    });
  });

  group('首页 wiring（需 ALL_SOURCES）', () {
    Future<LocalStore> pumpHome(
      WidgetTester tester, {
      NavStyle navStyle = NavStyle.bottomTabs,
      String source = 'hongguo',
      AppRepository? repository,
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
          home: HomeScreen(
            repository: repository ?? _NoPlayRepository(),
            store: store,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      return store;
    }

    /// 在站源弹窗里选“全部站源”：先搜索过滤（弹窗滚到当前站后
    /// 首项会被裁剪，直接点按落空），再按行 key 点选，并断言弹窗
    /// 已关闭（防止点空后断言误读弹窗内的文字）。
    Future<void> pickAllSources(WidgetTester tester) async {
      await tester.enterText(
        find.byKey(const ValueKey('site-picker-search')),
        '全部',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final row = find.byKey(const ValueKey('site-picker-row-__all__'));
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(row);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('site-picker-dialog')), findsNothing);
    }

    testWidgets('底部标签样式下戏剧首页分支也显示底栏', (tester) async {
      await pumpHome(tester);
      expect(find.byType(HongguoDramaHome), findsOneWidget);
      expect(find.byKey(const ValueKey('moyi-bottom-tab-0')), findsOneWidget);
      expect(find.byType(NeonBottomBar), findsNothing);
      expect(find.byKey(const ValueKey('drama-nav-channel')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('drama-nav-channel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(NeonChannelView), findsOneWidget);
      expect(find.byKey(const ValueKey('moyi-bottom-tab-0')), findsOneWidget);
    }, skip: !allSourcesEnabled);

    testWidgets('导航样式即时切换不用重启', (tester) async {
      final store = await pumpHome(tester, navStyle: NavStyle.drawer);
      expect(find.byType(NeonBottomBar), findsOneWidget);
      expect(find.byKey(const ValueKey('moyi-bottom-tab-0')), findsNothing);
      await store.setDisplayScheme(
        AppThemeMode.purpleNeon,
        const ThemeDisplayScheme(navStyle: NavStyle.bottomTabs),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('moyi-bottom-tab-0')), findsOneWidget);
      expect(find.byType(NeonBottomBar), findsNothing);
      await store.setDisplayScheme(
        AppThemeMode.purpleNeon,
        const ThemeDisplayScheme(navStyle: NavStyle.drawer),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(NeonBottomBar), findsOneWidget);
      expect(find.byKey(const ValueKey('moyi-bottom-tab-0')), findsNothing);
    }, skip: !allSourcesEnabled);

    testWidgets('频道内切站后仍停在频道视图', (tester) async {
      await pumpHome(tester, navStyle: NavStyle.drawer);
      expect(find.byType(HongguoDramaHome), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(NeonBottomBar),
          matching: find.text('频道'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(NeonChannelView), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('neon-filter-all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await pickAllSources(tester);
      // 仍在戏剧首页的频道视图，内容已是新站（胶囊显示全部站源）。
      expect(find.byType(HongguoDramaHome), findsOneWidget);
      expect(find.byType(NeonChannelView), findsOneWidget);
      expect(find.text('全部站源'), findsOneWidget);
    }, skip: !allSourcesEnabled);

    testWidgets('切到直播区再回片库后钉住解除', (tester) async {
      await pumpHome(tester);
      expect(find.byType(HongguoDramaHome), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('drama-nav-channel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('neon-filter-all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await pickAllSources(tester);
      expect(find.byType(HongguoDramaHome), findsOneWidget);
      expect(find.text('全部站源'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('moyi-bottom-tab-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(HongguoDramaHome), findsNothing);
      await tester.tap(find.byKey(const ValueKey('moyi-bottom-tab-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 钉住已解除：非红果分组回通用分支。
      expect(find.byType(HongguoDramaHome), findsNothing);
    }, skip: !allSourcesEnabled);

    testWidgets('频道内切到单站后只显示该站内容', (tester) async {
      final repository = _PerSourceRepository();
      final store = await pumpHome(tester, repository: repository);
      final target = store.visibleSources.firstWhere(
        (site) => site.id != 'hongguo',
      );
      await tester.tap(find.byKey(const ValueKey('drama-nav-channel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(NeonChannelView), findsOneWidget);
      repository.requests.clear();
      await tester.tap(find.byKey(const ValueKey('neon-filter-all')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(
        find.byKey(const ValueKey('site-picker-search')),
        target.name,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final row = find.byKey(ValueKey('site-picker-row-${target.id}'));
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(row);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('site-picker-dialog')), findsNothing);
      // 数据层：频道目录加载只向新站请求（首个请求即新站）；其后
      // 若有请求，只能是推荐流成人混排的取样（只打 🔞 站），绝不
      // 能是其它普通站的目录聚合——那才是频道混站的泄漏。
      expect(repository.requests, isNotEmpty);
      expect(repository.requests.first, target.id);
      final namesById = {for (final site in store.sources) site.id: site.name};
      expect(
        repository.requests
            .skip(1)
            .every((id) => (namesById[id] ?? '').startsWith('🔞')),
        isTrue,
      );
      // 界面层：频道只显示新站的条目与分类，旧站内容已消失。
      expect(find.byType(NeonChannelView), findsOneWidget);
      expect(find.text('剧-${target.id}-1'), findsOneWidget);
      expect(find.text('剧-${target.id}-2'), findsOneWidget);
      expect(find.text('剧-hongguo-1'), findsNothing);
      expect(find.text('剧-hongguo-2'), findsNothing);
      expect(find.text('分类-${target.id}'), findsOneWidget);
      expect(find.text('分类-hongguo'), findsNothing);
    }, skip: !allSourcesEnabled);
  });
}
