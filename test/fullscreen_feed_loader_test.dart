// 全屏流加载器模式：打开取数、分类行恢复、分类重取、刷新重取、
// 失败重试；旧快照路径保持不动。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/center_feed_loader.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/fullscreen_feed_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Drama _drama(String id, String title) => Drama(
  id: id,
  source: 'hongguo',
  title: title,
  cover: 'https://x.test/$id.jpg',
  episodes: 2,
);

const _categories = [
  CatalogCategory('rec', '推荐'),
  CatalogCategory('love', '爱情'),
];

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<LocalStore> _store() async {
  SharedPreferences.setMockInitialValues({'hiddenSites': '[]'});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

Future<void> _pumpFeed(
  WidgetTester tester, {
  List<Drama> dramas = const [],
  List<CatalogCategory> categories = const [],
  String selectedCategory = '',
  ValueChanged<String>? onCategorySelected,
  Future<CenterFeedData> Function(String categoryId)? onLoadFeed,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: FullscreenFeedScreen(
        dramas: dramas,
        repository: FixtureRepository(),
        store: await _store(),
        categories: categories,
        selectedCategory: selectedCategory,
        onCategorySelected: onCategorySelected,
        onLoadFeed: onLoadFeed,
      ),
    ),
  );
}

void main() {
  testWidgets('加载器模式：打开即取数，分类行与首条都显示', (tester) async {
    final calls = <String>[];
    await _pumpFeed(
      tester,
      onLoadFeed: (categoryId) async {
        calls.add(categoryId);
        return CenterFeedData(
          dramas: [_drama('a', '红果剧A'), _drama('b', '红果剧B')],
          categories: _categories,
        );
      },
    );
    await _settle(tester);
    expect(calls, ['']);
    expect(find.text('红果剧A'), findsWidgets);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('爱情'), findsOneWidget);
    expect(find.byKey(const ValueKey('feed-refresh')), findsOneWidget);
  });

  testWidgets('加载器模式：点分类重取该分类', (tester) async {
    final calls = <String>[];
    await _pumpFeed(
      tester,
      onLoadFeed: (categoryId) async {
        calls.add(categoryId);
        if (categoryId == 'rec') {
          return CenterFeedData(
            dramas: [_drama('c', '推荐剧C')],
            categories: _categories,
          );
        }
        return CenterFeedData(
          dramas: [_drama('a', '红果剧A')],
          categories: _categories,
        );
      },
    );
    await _settle(tester);
    await tester.tap(find.text('推荐'));
    await _settle(tester);
    expect(calls, ['', 'rec']);
    expect(find.text('推荐剧C'), findsWidgets);
    expect(find.text('红果剧A'), findsNothing);
    await tester.tap(find.text('全部'));
    await _settle(tester);
    expect(calls, ['', 'rec', '']);
    expect(find.text('红果剧A'), findsWidgets);
  });

  testWidgets('加载器模式：点换一批重取同分类（重新随机混排）', (tester) async {
    var calls = 0;
    await _pumpFeed(
      tester,
      onLoadFeed: (_) async {
        calls++;
        return CenterFeedData(
          dramas: [_drama('a', '红果剧A')],
          categories: _categories,
        );
      },
    );
    await _settle(tester);
    expect(calls, 1);
    await tester.tap(find.byKey(const ValueKey('feed-refresh')));
    await _settle(tester);
    expect(calls, 2);
    expect(find.text('红果剧A'), findsWidgets);
  });

  testWidgets('加载器模式：取数失败显示重试，点重试恢复', (tester) async {
    var calls = 0;
    await _pumpFeed(
      tester,
      onLoadFeed: (_) async {
        calls++;
        if (calls == 1) throw AppFailure('网络错误');
        return CenterFeedData(
          dramas: [_drama('a', '红果剧A')],
          categories: _categories,
        );
      },
    );
    await _settle(tester);
    expect(find.text('加载失败，请重试'), findsOneWidget);
    expect(find.byKey(const ValueKey('feed-retry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('feed-retry')));
    await _settle(tester);
    expect(calls, 2);
    expect(find.text('红果剧A'), findsWidgets);
    expect(find.text('加载失败，请重试'), findsNothing);
  });

  testWidgets('加载器模式：取到空显示诚实空态', (tester) async {
    await _pumpFeed(
      tester,
      onLoadFeed: (_) async =>
          const CenterFeedData(dramas: [], categories: _categories),
    );
    await _settle(tester);
    expect(find.text('暂无可播短剧'), findsOneWidget);
  });

  testWidgets('旧快照路径：分类行显示，点分类只回调不取数', (tester) async {
    final selected = <String>[];
    await _pumpFeed(
      tester,
      dramas: [_drama('a', '快照剧A')],
      categories: _categories,
      onCategorySelected: selected.add,
    );
    await _settle(tester);
    expect(find.text('快照剧A'), findsWidgets);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('推荐'), findsOneWidget);
    expect(find.byKey(const ValueKey('feed-refresh')), findsNothing);
    await tester.tap(find.text('推荐'));
    await _settle(tester);
    expect(selected, ['rec']);
    expect(find.text('快照剧A'), findsWidgets);
  });

  testWidgets('旧快照路径：无分类参数时分类行不画', (tester) async {
    await _pumpFeed(tester, dramas: [_drama('a', '快照剧A')]);
    await _settle(tester);
    expect(find.text('快照剧A'), findsWidgets);
    expect(find.text('全部'), findsNothing);
  });
}
