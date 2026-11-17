import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _EmptyFeedRepository extends FixtureRepository {
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

  const baseDrama = Drama(
    id: 'hongguo:1',
    source: 'hongguo',
    title: '普通短剧一',
    cover: 'https://x.test/base.jpg',
    episodes: 3,
  );

  Future<void> pumpHome(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        // 外层壳的安全区：真实首页由 home_screen 的 SafeArea 占一份。
        home: SafeArea(
          child: HongguoDramaHome(
            dramas: const [baseDrama],
            repository: _EmptyFeedRepository(),
            store: store,
            onOpenDrama: (_) {},
            onOpenFeed: () {},
            onPickSource: () {},
            sourceLabel: '红果 (1)',
            feedEnabled: true,
            categories: categories,
            selectedCategory: 'rec',
            onCategorySelected: (_) {},
            searchController: TextEditingController(),
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
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('推荐页顶栏只留一份安全边距，不叠死空白', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
    addTearDown(tester.view.reset);
    await pumpHome(tester);
    // 点胶囊播放键进推荐页。
    await tester.tap(
      find.descendant(
        of: find.byType(NeonBottomBar),
        matching: find.byIcon(LucideIcons.play),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 频道标签紧跟状态栏：顶边 44 + 4 内边距；叠两份会是 92。
    final label = tester.getRect(find.text('推荐'));
    expect(label.top, lessThan(60));
    expect(label.top, greaterThanOrEqualTo(44));
  });
}
