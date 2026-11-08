import 'package:moyi/home_carousel.dart';
import 'package:moyi/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

/// 首页轮播 widget 测试：条目随站源数据变化、无图站点整区隐藏、
/// 自动轮播推进。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Drama drama(String id, {String cover = 'https://img.example/c.jpg'}) =>
      Drama(id: id, source: 's1', title: '剧$id', cover: cover);

  Future<void> mount(WidgetTester tester, List<Drama> items) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeCarousel(
            items: carouselItems(items),
            repository: FixtureRepository(),
            onOpen: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('切站后轮播条目随源变化', (tester) async {
    await mount(tester, [drama('a1'), drama('a2')]);
    expect(find.byKey(const ValueKey('home-carousel')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-carousel-item-a1')), findsOneWidget);
    // 模拟切换到 B 站：新数据到达
    await mount(tester, [drama('b1'), drama('b2')]);
    expect(find.byKey(const ValueKey('home-carousel-item-b1')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-carousel-item-a1')), findsNothing);
  });

  testWidgets('无图站点不渲染轮播区', (tester) async {
    await mount(tester, [drama('n1', cover: ''), drama('n2', cover: '  ')]);
    expect(find.byKey(const ValueKey('home-carousel')), findsNothing);
    await mount(tester, const []);
    expect(find.byKey(const ValueKey('home-carousel')), findsNothing);
  });

  testWidgets('自动轮播约 4 秒推进到下一条', (tester) async {
    await mount(tester, [drama('a1'), drama('a2'), drama('a3')]);
    expect(find.text('剧a1'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('剧a2'), findsOneWidget);
  });

  test('carouselItems 过滤无图与文件夹并截断 8 条', () {
    final items = [
      drama('v-first'),
      const Drama(id: 'folder1', source: 's1', title: '夹', kind: 'folder'),
      for (var i = 0; i < 10; i++) drama('v$i'),
      drama('nocover', cover: ''),
    ];
    final picked = carouselItems(items);
    expect(picked.length, 8);
    expect(picked.every((d) => d.cover.isNotEmpty && !d.isFolder), isTrue);
  });
}
