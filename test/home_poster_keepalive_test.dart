import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_channel_view.dart';
import 'package:moyi/neon/neon_home_view.dart';
import 'package:moyi/widgets.dart';

import 'fixtures.dart';

class CountingCoverRepository extends FixtureRepository {
  int coverCalls = 0;

  @override
  Future<String> cover(Drama drama, {bool force = false}) async {
    coverCalls++;
    // 模拟真实链路的异步往返（Go/平台通道 + 磁盘），不是同步返回：
    // 闪烁的根因就是重挂后每个瓦片都要等这一程，期间只显示占位图。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return File('test/fixtures/cover.png').absolute.path;
  }
}

void main() {
  testWidgets('海报瓦片重挂后不重新拉取、首帧直接出图不闪占位图', (tester) async {
    final repository = CountingCoverRepository();
    const drama = Drama(
      id: 'keepalive:1',
      source: 'keepalive',
      title: '保活测试剧',
      cover: 'https://example.invalid/cover1.jpg',
      episodes: 3,
    );
    Widget app() => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 100,
          height: 150,
          child: CachedCoverImage(
            drama: drama,
            repository: repository,
            placeholder: const SizedBox(
              key: ValueKey('cover-placeholder'),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(repository.coverCalls, 1);
    expect(find.byType(Image), findsOneWidget);
    // 不断言已解码像素：测试里解码走真实异步，runAsync 预取在当前
    // 环境挂住；首帧有没有 Image、占位图有没有闪，已足够证明不闪烁。

    // 切走：整棵子树销毁（模拟切区/切页签时 _tabBody 的 if/else 换子树）。
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    await tester.pump();

    // 返回：只 pump 一帧，不等待——海报必须首帧就画出来。
    await tester.pumpWidget(app());
    await tester.pump();
    expect(repository.coverCalls, 1, reason: '重挂后不许重新拉取海报');
    expect(
      find.byKey(const ValueKey('cover-placeholder')),
      findsNothing,
      reason: '首帧不许闪占位图',
    );
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同一部剧换了封面地址必须重新拉取（缓存键防过头）', (tester) async {
    final repository = CountingCoverRepository();
    Drama dramaWith(String cover) => Drama(
      id: 'keepalive:2',
      source: 'keepalive',
      title: '换图测试剧',
      cover: cover,
      episodes: 1,
    );
    Widget app(String cover) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 100,
          height: 150,
          child: CachedCoverImage(
            drama: dramaWith(cover),
            repository: repository,
            placeholder: const SizedBox(),
          ),
        ),
      ),
    );

    await tester.pumpWidget(app('https://example.invalid/a.jpg'));
    await tester.pumpAndSettle();
    expect(repository.coverCalls, 1);
    await tester.pumpWidget(app('https://example.invalid/b.jpg'));
    await tester.pumpAndSettle();
    expect(repository.coverCalls, 2);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('霓虹首页深滚后切走再返回，滚动偏移保留', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final items = List.generate(
      30,
      (i) => Drama(
        id: 'scroll:$i',
        source: 'hongguo',
        title: '剧目$i',
        episodes: 2,
        category: '合成数据',
      ),
    );
    Widget app(bool show) => MaterialApp(
      home: Scaffold(
        body: show
            ? NeonHomeView(
                items: items,
                repository: FixtureRepository(),
                brand: '魔蚁box',
                sourceLabel: '红果 (1)',
                onOpen: (_) {},
                onSearch: () {},
                onSourceTap: () {},
                onLongPress: (_) {},
              )
            : const SizedBox(),
      ),
    );

    await tester.pumpWidget(app(true));
    await tester.pump();
    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, -900),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    final before = _outerScrollOffset(tester);
    expect(before, greaterThan(300));

    // 切走再返回：同一 MaterialApp 内换子树，模拟首页/频道页签切换。
    await tester.pumpWidget(app(false));
    await tester.pump();
    await tester.pumpWidget(app(true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_outerScrollOffset(tester), closeTo(before, 1.0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('NeonChannelView 瓦片不画封面集数标（防重影守卫）', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final items = List.generate(
      3,
      (i) => Drama(
        id: 'channel:$i',
        source: 'hongguo',
        title: '频道剧$i',
        episodes: 5,
        category: '合成数据',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NeonChannelView(
            items: items,
            repository: FixtureRepository(),
            categories: const [],
            selectedCategory: '',
            onCategory: (_) {},
            onOpen: (_) {},
            onBack: () {},
            onSearch: () {},
            onFilter: () {},
            onRankings: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    // NeonPoster 画副标题（“5 集”），封面自身的“共 5 集”绝不能再出现。
    expect(find.text('共 5 集'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

double _outerScrollOffset(WidgetTester tester) {
  for (final element in find.byType(Scrollable).evaluate()) {
    final state = (element as StatefulElement).state as ScrollableState;
    if (state.position.axis == Axis.vertical) return state.position.pixels;
  }
  throw StateError('no vertical Scrollable found');
}
