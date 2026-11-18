import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/feed_playability.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _NoPlayRepository extends FixtureRepository {
  @override
  Future<DramaDetail> detail(Drama drama) async => throw AppFailure('测试不播');
}

/// 验播放行全部：本文件测首页分类行与筛选入口，不测验播本身。
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
    SharedPreferences.setMockInitialValues({
      'hiddenSites': '[]',
      'appThemeMode': 'purpleNeon',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  Future<void> pumpDramaHome(
    WidgetTester tester, {
    bool hideCapsuleBar = false,
    ValueChanged<String>? onCategorySelected,
    VoidCallback? onFilterPressed,
    bool filtersActive = false,
  }) async {
    final store = await makeStore();
    final searchController = TextEditingController();
    addTearDown(searchController.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: HongguoDramaHome(
          dramas: const [_baseDrama],
          repository: _NoPlayRepository(),
          store: store,
          onOpenDrama: (_) {},
          onOpenFeed: () {},
          onPickSource: () {},
          sourceLabel: '红果 (1)',
          feedEnabled: true,
          categories: _categories,
          selectedCategory: 'rec',
          onCategorySelected: onCategorySelected ?? (_) {},
          searchController: searchController,
          searchHint: '搜索',
          onSearchChanged: (_) {},
          onSearchSubmitted: (_) {},
          onOpenGlobalSearch: () {},
          onAvatarPressed: () {},
          onFilterPressed: onFilterPressed ?? () {},
          onRankingsPressed: () {},
          onNewPressed: () {},
          filtersActive: filtersActive,
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

  group('霓虹首页分类 + 筛选行', () {
    testWidgets('窗口壳：合并顶栏下方有筛选胶囊与分类胶囊', (tester) async {
      await pumpDramaHome(tester, hideCapsuleBar: true);
      expect(find.byKey(const ValueKey('drama-merged-topbar')), findsOneWidget);
      expect(find.byKey(const ValueKey('neon-home-filter-row')), findsOneWidget);
      expect(find.byKey(const ValueKey('neon-home-filter')), findsOneWidget);
      expect(find.text('筛选'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('neon-home-category-')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('neon-home-category-short_play')),
        findsOneWidget,
      );
      // 分类行在合并顶栏下方，不盖住顶栏。
      final bar = tester.getRect(find.byKey(const ValueKey('drama-merged-topbar')));
      final row = tester.getRect(
        find.byKey(const ValueKey('neon-home-filter-row')),
      );
      expect(row.top, greaterThanOrEqualTo(bar.bottom - 1));
    });

    testWidgets('窗口壳：点分类胶囊切分类，点筛选胶囊打开筛选', (tester) async {
      final picked = <String>[];
      var filterCalls = 0;
      await pumpDramaHome(
        tester,
        hideCapsuleBar: true,
        onCategorySelected: picked.add,
        onFilterPressed: () => filterCalls++,
      );
      final chip = find.byKey(const ValueKey('neon-home-category-short_play'));
      await tester.ensureVisible(chip);
      await tester.pump();
      await tester.tap(chip);
      await tester.pump();
      expect(picked, ['short_play']);
      await tester.tap(find.byKey(const ValueKey('neon-home-filter')));
      await tester.pump();
      expect(filterCalls, 1);
    });

    testWidgets('胶囊栏壳：分类行随滚动区置顶，只出现一次', (tester) async {
      await pumpDramaHome(tester, hideCapsuleBar: false);
      expect(find.byKey(const ValueKey('neon-home-filter-row')), findsOneWidget);
      expect(find.byKey(const ValueKey('neon-home-filter')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('neon-home-category-comic_series')),
        findsOneWidget,
      );
    });
  });
}
