import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_home_view.dart';

import 'fixtures.dart';

// 「猜你想看」网格卡片：封面必然加载失败时也必须画标题。
//
// FixtureRepository.cover() 恒抛错，直链封面走 Image.network 在测试
// 环境也必然失败（默认假 HttpClient 回 400），卡片最终停在占位图
// 状态。修复前网格卡传 showTitle:false，NeonPoster 根本不画文字层，
// 占位卡上只剩封面自带的「共 N 集」标；修复后与热播推荐行同口径：
// NeonPoster 画标题 + 副标题（副标题带集数），封面不再画集数标，
// 防同角双画（见 neon_channel_view._tile 的既有口径）。
Drama _drama(String id, String title, int episodes) => Drama(
  id: id,
  source: 'hongguo',
  title: title,
  cover: 'https://example.test/$id.jpg',
  episodes: episodes,
  kind: 'video',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NeonHomeView(
            items: [
              _drama('g1', '猜你想看甲', 3),
              _drama('g2', '猜你想看乙', 5),
              _drama('g3', '猜你想看丙', 0),
            ],
            repository: FixtureRepository(),
            brand: '魔蚁TV',
            sourceLabel: '测试站 (3)',
            onOpen: (_) {},
            onSearch: () {},
            onSourceTap: () {},
            onLongPress: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    // 封面取图是普通 Future（仓库抛错后走直链网络图再失败），
    // pumpAndSettle 等不到它；用真时间轮询等占位态落定。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Finder inGrid(Finder matching) =>
      find.descendant(of: find.byType(SliverGrid), matching: matching);

  testWidgets('封面加载失败时猜你想看网格仍显示标题', (tester) async {
    await pumpHome(tester);

    // 三张卡的标题都必须在网格里出现（含 0 集、无集数标的那张）。
    expect(inGrid(find.text('猜你想看甲')), findsOneWidget);
    expect(inGrid(find.text('猜你想看乙')), findsOneWidget);
    expect(inGrid(find.text('猜你想看丙')), findsOneWidget);

    // 集数改由副标题承载（「3 集」），封面自带的「共 3 集」不再画，
    // 避免与副标题同角重叠双画。
    expect(inGrid(find.text('3 集')), findsOneWidget);
    expect(inGrid(find.text('共 3 集')), findsNothing);
    expect(inGrid(find.text('共 5 集')), findsNothing);

    // 卸掉整棵树，取消精选轮播的周期计时器。
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });
}
