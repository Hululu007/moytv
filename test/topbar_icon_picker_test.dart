import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_home_view.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

// 顶栏口径（用户 2026-11-18 19:49 令，取代“第一位触发、头像第二
// 位”）：左上角点图标弹站点列表，点软件名称什么都不弹。

Drama _drama(String id) => Drama(
  id: id,
  source: 'hongguo',
  title: 'hongguo-$id',
  cover: 'https://example.test/cover.jpg',
  kind: 'video',
);

const _tabCategories = [
  CatalogCategory('', '全部'),
  CatalogCategory('short_play', '真人剧'),
  CatalogCategory('rec', '推荐'),
];

void main() {
  Future<void> pumpDramaHome(
    WidgetTester tester, {
    required VoidCallback onPickSource,
    required VoidCallback onAvatarPressed,
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
          onPickSource: onPickSource,
          sourceLabel: '红果 (1)',
          feedEnabled: true,
          categories: _tabCategories,
          selectedCategory: 'rec',
          onCategorySelected: (_) {},
          searchController: searchController,
          searchHint: '搜索',
          onSearchChanged: (_) {},
          onSearchSubmitted: (_) {},
          onOpenGlobalSearch: () {},
          onAvatarPressed: onAvatarPressed,
          onFilterPressed: () {},
          onRankingsPressed: () {},
          onNewPressed: () {},
          filtersActive: false,
          newActive: false,
          onOpenSaved: ({required bool history}) {},
          hideCapsuleBar: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('合并顶栏：点图标弹站点列表，不进我的', (tester) async {
    var pickCalls = 0;
    var avatarCalls = 0;
    await pumpDramaHome(
      tester,
      onPickSource: () => pickCalls++,
      onAvatarPressed: () => avatarCalls++,
    );
    expect(find.byKey(const ValueKey('drama-merged-topbar')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('neon-avatar')));
    await tester.pump();
    expect(pickCalls, 1);
    expect(avatarCalls, 0);
  });

  testWidgets('合并顶栏：点品牌块什么都不弹', (tester) async {
    var pickCalls = 0;
    var avatarCalls = 0;
    await pumpDramaHome(
      tester,
      onPickSource: () => pickCalls++,
      onAvatarPressed: () => avatarCalls++,
    );
    expect(find.text('魔蚁TV'), findsOneWidget);
    // 品牌块无任何手势目标：warnIfMissed 关掉“点空”警告，断言本身
    // 就是点按无反应。
    await tester.tap(
      find.byKey(const ValueKey('neon-top-source')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(pickCalls, 0);
    expect(avatarCalls, 0);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('合并顶栏：品牌块旁无下拉小箭头', (tester) async {
    await pumpDramaHome(tester, onPickSource: () {}, onAvatarPressed: () {});
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('drama-merged-topbar')),
        matching: find.byIcon(LucideIcons.chevronDown),
      ),
      findsNothing,
    );
  });

  testWidgets('NeonHomeView 顶栏：点图标走 onAvatar，点标题不触发换站源', (tester) async {
    var sourceCalls = 0;
    var avatarCalls = 0;
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
            onSearch: () {},
            onSourceTap: () => sourceCalls++,
            onLongPress: (_) {},
            onRefresh: () async {},
            onAvatar: () => avatarCalls++,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('neon-top-source')), findsNothing);
    expect(
      find.descendant(
        of: find.byType(NeonTopBar),
        matching: find.byIcon(LucideIcons.chevronDown),
      ),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('neon-avatar')));
    await tester.pump();
    expect(avatarCalls, 1);
    expect(sourceCalls, 0);
    await tester.tap(find.text('魔蚁box'));
    await tester.pump();
    expect(avatarCalls, 1);
    expect(sourceCalls, 0);
  });
}
