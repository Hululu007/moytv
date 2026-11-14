import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _TheaterTestRepository extends FixtureRepository {
  @override
  Future<DramaDetail> detail(Drama drama) async =>
      throw AppFailure('测试不播');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const categories = [
    CatalogCategory('', '全部'),
    CatalogCategory('novel', '小说'),
    CatalogCategory('audio', '听书'),
    CatalogCategory('local:冒险', '冒险', local: true),
    CatalogCategory('local:剧情', '剧情', local: true),
  ];

  const drama = Drama(
    id: 'hongguo:1',
    source: 'hongguo',
    title: '普通短剧一',
    cover: 'https://x.test/base.jpg',
    episodes: 3,
  );

  Future<String?> pumpTheater(
    WidgetTester tester, {
    required List<String> picked,
  }) async {
    SharedPreferences.setMockInitialValues({'hiddenSites': '[]'});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: HongguoDramaHome(
          dramas: const [drama],
          repository: _TheaterTestRepository(),
          store: store,
          onOpenDrama: (_) {},
          onOpenFeed: () {},
          onPickSource: () {},
          sourceLabel: '红果 (1)',
          feedEnabled: true,
          categories: categories,
          selectedCategory: '',
          onCategorySelected: picked.add,
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
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // 底部导航“片单”进剧场页。
    await tester.tap(find.text('片单'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    return null;
  }

  testWidgets('剧场分类一级与二级分两排显示', (tester) async {
    await pumpTheater(tester, picked: []);
    expect(find.text('小说'), findsOneWidget);
    expect(find.text('冒险'), findsOneWidget);
    final level1Top = tester.getTopLeft(find.text('小说')).dy;
    final level2Top = tester.getTopLeft(find.text('冒险')).dy;
    expect(level2Top, greaterThan(level1Top));
    // 一级同排。
    expect(
      tester.getTopLeft(find.text('听书')).dy,
      tester.getTopLeft(find.text('小说')).dy,
    );
  });

  testWidgets('剧场点二级分类回传本地筛选 id', (tester) async {
    final picked = <String>[];
    await pumpTheater(tester, picked: picked);
    await tester.tap(find.text('冒险'));
    expect(picked, ['local:冒险']);
  });
}
