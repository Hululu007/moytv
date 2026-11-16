import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _MineRepository extends FixtureRepository {
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

  Future<void> pumpMine(
    WidgetTester tester, {
    int? requestedTab,
    bool hideCapsuleBar = true,
    void Function({required bool history})? onOpenSaved,
    VoidCallback? onSettingsPressed,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: HongguoDramaHome(
          dramas: const [baseDrama],
          repository: _MineRepository(),
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
          onOpenSaved: onOpenSaved ?? ({required bool history}) {},
          onSettingsPressed: onSettingsPressed,
          requestedTab: requestedTab,
          hideCapsuleBar: hideCapsuleBar,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('我的页新版：三个分组与全部条目在位', (tester) async {
    await pumpMine(
      tester,
      requestedTab: HongguoDramaHome.mineTabIndex,
      onSettingsPressed: () {},
    );
    // 头：头像 + 我的 + 站源标签。
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('红果 (1)'), findsOneWidget);
    // 三个分组标题。
    expect(find.text('帐户'), findsOneWidget);
    expect(find.text('内容'), findsOneWidget);
    expect(find.text('外观与设置'), findsOneWidget);
    // 帐户组：登录行 + 云端 4 项（未登录、计数 0）。
    expect(find.text('红果账号'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(find.text('账户收藏'), findsOneWidget);
    expect(find.text('云端历史续播'), findsOneWidget);
    expect(find.text('已上线预约'), findsOneWidget);
    expect(find.text('待上线预约'), findsOneWidget);
    expect(find.text('0 部'), findsNWidgets(4));
    // 内容组与外观组（第三组在首屏下，滚到可见再断言）。
    expect(find.text('追剧'), findsOneWidget);
    expect(find.text('最近观看'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('设置'), 200);
    // 14 版：主题切换行已从“我的”页删除，设置是唯一主题入口。
    expect(find.text('主题切换'), findsNothing);
    expect(find.textContaining('12 套主题'), findsNothing);
    expect(find.text('设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击行为不变：追剧/最近观看/设置回调（主题行已删）', (tester) async {
    final savedCalls = <bool>[];
    var settingsPressed = false;
    await pumpMine(
      tester,
      requestedTab: HongguoDramaHome.mineTabIndex,
      onOpenSaved: ({required bool history}) => savedCalls.add(history),
      onSettingsPressed: () => settingsPressed = true,
    );
    await tester.tap(find.text('追剧'));
    await tester.pump();
    await tester.tap(find.text('最近观看'));
    await tester.pump();
    expect(savedCalls, [false, true]);
    await tester.scrollUntilVisible(find.text('设置'), 200);
    await tester.tap(find.text('设置'));
    await tester.pump();
    expect(settingsPressed, isTrue);
    expect(find.text('主题切换'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('我的页不显示顶部芯片行', (tester) async {
    await pumpMine(
      tester,
      requestedTab: HongguoDramaHome.mineTabIndex,
      onSettingsPressed: () {},
    );
    expect(
      find.byKey(const ValueKey('drama-internal-nav')),
      findsNothing,
    );
    expect(find.text('我的'), findsOneWidget);
  });

  testWidgets('其它页仍显示顶部芯片行（只拿掉我的页）', (tester) async {
    await pumpMine(
      tester,
      requestedTab: HongguoDramaHome.multimediaTabIndex,
    );
    expect(
      find.byKey(const ValueKey('drama-internal-nav')),
      findsOneWidget,
    );
  });
}
