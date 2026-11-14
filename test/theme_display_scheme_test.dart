import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moyi/app_build.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/content_tier_filter.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/theme_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _tierCategories = [
  CatalogCategory('', '全部'),
  CatalogCategory('short_play', '真人剧'),
  CatalogCategory('comic_series', '漫剧'),
  CatalogCategory('rec', '推荐'),
];

class _TierTestRepository extends FixtureRepository {
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => _tierCategories;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    if (category == 'comic_series') {
      return CatalogPage([
        Drama(
          id: 'c1',
          source: source,
          title: '漫剧甲',
          cover: 'https://x.test/c1.jpg',
          episodes: 2,
        ),
      ]);
    }
    if (category == 'short_play') {
      return CatalogPage([
        Drama(
          id: 'r1',
          source: source,
          title: '真人剧甲',
          cover: 'https://x.test/r1.jpg',
          episodes: 2,
        ),
      ]);
    }
    return CatalogPage([
      Drama(
        id: 'c1',
        source: source,
        title: '漫剧甲',
        cover: 'https://x.test/c1.jpg',
        episodes: 2,
      ),
      Drama(
        id: 'r1',
        source: source,
        title: '真人剧甲',
        cover: 'https://x.test/r1.jpg',
        episodes: 2,
      ),
    ]);
  }
}

/// 详情抛错的替身：feed 页起播在取详情处即止，不启动播放定时器，
// 避免测试结束时“仍有定时器待处理”失败（与 adult_channel_test 同法）。
class _NoPlayRepository extends FixtureRepository {
  @override
  Future<DramaDetail> detail(Drama drama) async =>
      throw AppFailure('测试不播');
}

class _AdultTierRepository extends FixtureRepository {
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    if (source == 'adult1') {
      return CatalogPage([
        const Drama(
          id: 'a1',
          source: 'adult1',
          title: '可见成人片一',
          cover: 'https://x.test/a1.jpg',
        ),
      ]);
    }
    if (source == 'adult-hidden') {
      return CatalogPage([
        const Drama(
          id: 'h1',
          source: 'adult-hidden',
          title: '藏起来的成人片',
          cover: 'https://x.test/h1.jpg',
        ),
      ]);
    }
    return CatalogPage([]);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async =>
      throw AppFailure('测试不播');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('内容档纯函数', () {
    test('频道键映射', () {
      expect(tierChannelKey(ContentTier.all), isNull);
      expect(tierChannelKey(ContentTier.manhua), 'comic');
      expect(tierChannelKey(ContentTier.liveAction), 'real');
      expect(tierChannelKey(ContentTier.adult), 'adult');
    });

    test('分类命中：按名与按 id', () {
      expect(tierCategoryId(ContentTier.manhua, _tierCategories), 'comic_series');
      expect(
        tierCategoryId(ContentTier.liveAction, _tierCategories),
        'short_play',
      );
      expect(
        tierCategoryId(ContentTier.manhua, [
          const CatalogCategory('xx', '漫剧'),
        ]),
        'xx',
      );
      expect(
        tierCategoryId(ContentTier.liveAction, [
          const CatalogCategory('short_play', '其它名'),
        ]),
        'short_play',
      );
    });

    test('命中不到与无分类档返回 null', () {
      expect(
        tierCategoryId(ContentTier.manhua, [
          const CatalogCategory('', '全部'),
        ]),
        isNull,
      );
      expect(tierCategoryId(ContentTier.all, _tierCategories), isNull);
      expect(tierCategoryId(ContentTier.adult, _tierCategories), isNull);
    });

    test('显示分类集合：锁档只留命中分类', () {
      final kept = tierCategories(ContentTier.manhua, _tierCategories);
      expect(kept.map((c) => c.id).toList(), ['comic_series']);
      expect(tierCategories(ContentTier.manhua, [CatalogCategory.all]), isEmpty);
      expect(tierCategories(ContentTier.all, _tierCategories), _tierCategories);
      expect(
        tierCategories(ContentTier.adult, _tierCategories),
        _tierCategories,
      );
    });
  });

  group('主题卡显示内容选择', () {
    Future<LocalStore> pumpThemeScreen(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeConfig.forTheme(
            AppThemeMode.purpleNeon,
          ).toThemeData(),
          home: ThemeSettingsScreen(store: store),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      return store;
    }

    testWidgets('新装 8 张卡默认全部内容', (tester) async {
      await pumpThemeScreen(tester);
      expect(find.text('显示内容：全部内容'), findsNWidgets(8));
    });

    testWidgets('点档行改档不切主题', (tester) async {
      final store = await pumpThemeScreen(tester);
      await tester.tap(find.byKey(const ValueKey('theme-tier-goldVip')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('漫剧'), findsOneWidget);
      await tester.tap(find.text('漫剧'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        store.displayScheme(AppThemeMode.goldVip).contentTier,
        ContentTier.manhua,
      );
      expect(store.appTheme, AppThemeMode.purpleNeon);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('theme-tier-goldVip')),
          matching: find.text('显示内容：漫剧'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('每套主题的档独立存放', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await store.setDisplayScheme(
        AppThemeMode.goldVip,
        const ThemeDisplayScheme(contentTier: ContentTier.adult),
      );
      await store.setDisplayScheme(
        AppThemeMode.lightClean,
        const ThemeDisplayScheme(contentTier: ContentTier.manhua),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeConfig.forTheme(
            AppThemeMode.purpleNeon,
          ).toThemeData(),
          home: ThemeSettingsScreen(store: store),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('theme-tier-goldVip')),
          matching: find.text('显示内容：成人视频'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('theme-tier-lightClean')),
          matching: find.text('显示内容：漫剧'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('theme-tier-purpleNeon')),
          matching: find.text('显示内容：全部内容'),
        ),
        findsOneWidget,
      );
    });
  });

  group('短剧首页内容档锁定', () {
    const baseDrama = Drama(
      id: 'hongguo:1',
      source: 'hongguo',
      title: '普通短剧一',
      cover: 'https://x.test/base.jpg',
      episodes: 3,
    );

    Future<LocalStore> pumpDramaHome(
      WidgetTester tester, {
      List<Drama> dramas = const [baseDrama],
      ContentTier? contentTier,
      bool tierEmpty = false,
      AppRepository? repository,
      Set<String> hidden = const {},
      bool withAdultSites = false,
    }) async {
      SharedPreferences.setMockInitialValues({
        'hiddenSites': '[${hidden.map((id) => '"$id"').join(',')}]',
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      if (withAdultSites) {
        SourceSite.importedSites['adult1'] = const SourceSite(
          'adult1',
          '🔞可见成人站',
          '',
          section: SourceSite.sectionVideo,
        );
        SourceSite.importedSites['adult-hidden'] = const SourceSite(
          'adult-hidden',
          '🔞藏起来的成人站',
          '',
          section: SourceSite.sectionVideo,
        );
        addTearDown(() {
          SourceSite.importedSites.remove('adult1');
          SourceSite.importedSites.remove('adult-hidden');
        });
      }
      await tester.pumpWidget(
        MaterialApp(
          home: HongguoDramaHome(
            dramas: dramas,
            repository: repository ?? _NoPlayRepository(),
            store: store,
            onOpenDrama: (_) {},
            onOpenFeed: () {},
            onPickSource: () {},
            sourceLabel: '红果 (1)',
            feedEnabled: dramas.isNotEmpty,
            categories: _tierCategories,
            selectedCategory: 'rec',
            onCategorySelected: (_) {},
            searchController: TextEditingController(),
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
            contentTier: contentTier,
            tierEmpty: tierEmpty,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      return store;
    }

    Future<void> openFeed(WidgetTester tester) async {
      await tester.tap(find.byIcon(LucideIcons.plus));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('漫剧档频道行只留漫剧', (tester) async {
      await pumpDramaHome(tester, contentTier: ContentTier.manhua);
      await openFeed(tester);
      expect(find.text('漫剧'), findsOneWidget);
      expect(find.text('真人剧'), findsNothing);
      expect(find.text('推荐'), findsNothing);
      expect(find.text('关注'), findsNothing);
      expect(find.text('成人视频'), findsNothing);
    });

    testWidgets('不锁档时 5 个频道都在', (tester) async {
      await pumpDramaHome(tester);
      await openFeed(tester);
      for (final label in ['关注', '漫剧', '真人剧', '成人视频', '推荐']) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('档分类缺失时诚实空态且可切回', (tester) async {
      final store = await pumpDramaHome(
        tester,
        contentTier: ContentTier.manhua,
        tierEmpty: true,
      );
      expect(find.text('暂无漫剧'), findsOneWidget);
      expect(find.text('普通短剧一'), findsNothing);
      expect(find.text('切回全部内容'), findsOneWidget);
      expect(find.text('切换站点'), findsOneWidget);
      await tester.tap(find.text('切回全部内容'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        store.displayScheme(AppThemeMode.purpleNeon).contentTier,
        ContentTier.all,
      );
    });

    testWidgets('成人档锁定且藏起来的站不出现', (tester) async {
      await pumpDramaHome(
        tester,
        contentTier: ContentTier.adult,
        repository: _AdultTierRepository(),
        hidden: {'adult-hidden'},
        withAdultSites: true,
      );
      await openFeed(tester);
      // 成人流未取回前 feed 只显示转圈，频道行随内容一起出现。
      for (var i = 0; i < 10; i++) {
        if (find.text('可见成人片一').evaluate().isNotEmpty) break;
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.text('成人视频'), findsOneWidget);
      expect(find.text('推荐'), findsNothing);
      expect(find.text('可见成人片一'), findsOneWidget);
      expect(find.text('藏起来的成人片'), findsNothing);
    });
  });

  group('首页三件一起变', () {
    Future<LocalStore> pumpHome(
      WidgetTester tester, {
      AppRepository? repository,
    }) async {
      SharedPreferences.setMockInitialValues({
        'source': 'hongguo',
        'hiddenSites': '[]',
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [homeRouteObserver],
          home: HomeScreen(
            repository: repository ?? FixtureRepository(),
            store: store,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return store;
    }

    Future<void> switchToLive(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('neon-avatar')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final live = find.descendant(
        of: find.byType(Drawer),
        matching: find.text('直播'),
      );
      expect(live, findsOneWidget);
      await tester.tap(live);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('切主题后导航与内容档一起变', (tester) async {
      final store = await pumpHome(tester);
      expect(find.text('暂无漫剧'), findsNothing);
      // 先切到直播区：空态门住后短剧首页没有抽屉入口。
      await switchToLive(tester);
      expect(find.byKey(const ValueKey('moyi-bottom-tab-0')), findsNothing);
      await store.setDisplayScheme(
        AppThemeMode.goldVip,
        const ThemeDisplayScheme(
          navStyle: NavStyle.bottomTabs,
          contentTier: ContentTier.manhua,
        ),
      );
      await store.setAppTheme(AppThemeMode.goldVip);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 导航：外层底栏出现。
      expect(
        find.byKey(const ValueKey('moyi-bottom-tab-0')),
        findsOneWidget,
      );
      // 内容档：回片库后本站无漫剧分类，显示诚实空态。
      await tester.tap(find.byKey(const ValueKey('moyi-bottom-tab-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('暂无漫剧'), findsOneWidget);
      // 切回默认主题：两件一起复原。
      await store.setAppTheme(AppThemeMode.purpleNeon);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('暂无漫剧'), findsNothing);
      await switchToLive(tester);
      expect(find.byKey(const ValueKey('moyi-bottom-tab-0')), findsNothing);
    }, skip: !allSourcesEnabled);

    testWidgets('漫剧档驱动选类后内容只剩漫剧', (tester) async {
      final store = await pumpHome(tester, repository: _TierTestRepository());
      await store.setDisplayScheme(
        AppThemeMode.purpleNeon,
        const ThemeDisplayScheme(contentTier: ContentTier.manhua),
      );
      await tester.pump();
      var settled = false;
      for (var i = 0; i < 16 && !settled; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        settled =
            find.text('漫剧甲').evaluate().isNotEmpty &&
            find.text('真人剧甲').evaluate().isEmpty;
      }
      expect(settled, isTrue);
      expect(find.text('漫剧甲'), findsOneWidget);
      expect(find.text('真人剧甲'), findsNothing);
    }, skip: !allSourcesEnabled);
  });
}
