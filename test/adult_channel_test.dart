import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/feed_playability.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _AdultTestRepository extends FixtureRepository {
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
        const Drama(
          id: 'a2',
          source: 'adult1',
          title: '可见成人片二',
          cover: 'https://x.test/a2.jpg',
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
  Future<DramaDetail> detail(Drama drama) async => throw AppFailure('测试不播');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const categories = [
    CatalogCategory('', '全部'),
    CatalogCategory('short_play', '真人剧'),
    CatalogCategory('comic_series', '漫剧'),
    CatalogCategory('rec', '推荐'),
  ];

  Future<void> pumpHome(
    WidgetTester tester, {
    required List<Drama> dramas,
    required Set<String> hidden,
    bool withAdultSites = true,
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
          repository: _AdultTestRepository(),
          store: store,
          onOpenDrama: (_) {},
          onOpenFeed: () {},
          onPickSource: () {},
          sourceLabel: '红果 (1)',
          feedEnabled: dramas.isNotEmpty,
          categories: categories,
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
          // 本文件测可见性过滤与混排：验播放行全部，验播本身由
          // feed_playability_test 覆盖。
          playabilityVerifier: FeedPlayabilityVerifier(
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
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> openFeed(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(NeonBottomBar),
        matching: find.byIcon(LucideIcons.play),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  const baseDrama = Drama(
    id: 'hongguo:1',
    source: 'hongguo',
    title: '普通短剧一',
    cover: 'https://x.test/base.jpg',
    episodes: 3,
  );

  testWidgets('频道顺序为关注/漫剧/真人剧/成人视频/推荐', (tester) async {
    await pumpHome(tester, dramas: [baseDrama], hidden: {'adult-hidden'});
    await openFeed(tester);
    const order = ['关注', '漫剧', '真人剧', '成人视频', '推荐'];
    var previousX = -1.0;
    for (final label in order) {
      expect(find.text(label), findsOneWidget);
      final x = tester.getTopLeft(find.text(label)).dx;
      expect(x, greaterThan(previousX));
      previousX = x;
    }
  });

  testWidgets('成人频道只显示可见成人站的内容，藏起来的站不出现', (tester) async {
    await pumpHome(tester, dramas: [baseDrama], hidden: {'adult-hidden'});
    await openFeed(tester);
    await tester.tap(find.text('成人视频'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('可见成人片一'), findsOneWidget);
    expect(find.text('藏起来的成人片'), findsNothing);
  });

  testWidgets('无可见成人站时成人频道显示诚实空状态', (tester) async {
    await pumpHome(
      tester,
      dramas: [baseDrama],
      hidden: {'adult-hidden'},
      withAdultSites: false,
    );
    await openFeed(tester);
    await tester.tap(find.text('成人视频'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('暂无成人视频'), findsOneWidget);
    expect(find.text('没有可见的成人站，或成人站暂无内容。'), findsOneWidget);
  });

  testWidgets('推荐频道混入成人条目，滑到混入位置可见', (tester) async {
    final base = List.generate(
      8,
      (i) => Drama(
        id: 'hongguo:$i',
        source: 'hongguo',
        title: '普通短剧$i',
        cover: 'https://x.test/b$i.jpg',
        episodes: 2,
      ),
    );
    await pumpHome(tester, dramas: base, hidden: {'adult-hidden'});
    await openFeed(tester);
    // 成人取数在首帧后异步完成，混排随之落定。
    await tester.pump(const Duration(milliseconds: 300));
    // 初始页随机起播：逐页下滑，混入的成人条目应在某页出现。
    var found = false;
    for (var i = 0; i < 10 && !found; i++) {
      if (find.textContaining('可见成人片').evaluate().isNotEmpty) {
        found = true;
        break;
      }
      await tester.drag(find.byType(PageView), const Offset(0, -400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(found, isTrue);
    expect(find.text('藏起来的成人片'), findsNothing);
  });
}
