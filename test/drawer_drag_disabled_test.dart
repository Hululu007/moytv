import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_drawer.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 小退回来抽屉自己开着、首页被盖住的回归测试（2026-11-15 用户手机实报）。
/// 根因判断：首页两个 Scaffold 都没禁边缘滑动打开抽屉，手势导航的边缘
/// 滑动（系统返回手势）会把抽屉拖出来；抽屉开着时切后台，回来仍开着。
/// 修法：两个 Scaffold 都加 drawerEnableOpenDragGesture: false，抽屉只许
/// 点左上角头像（或菜单键）打开。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpHome(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'source': 'huangdou',
      'hiddenSites': '[]',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeRouteObserver],
        home: HomeScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('边缘滑动打不开抽屉', (tester) async {
    await pumpHome(tester);
    expect(find.byType(AppDrawer), findsNothing);
    await tester.dragFrom(const Offset(2, 300), const Offset(300, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AppDrawer), findsNothing);
  });

  testWidgets('点左上角头像照样能开抽屉', (tester) async {
    await pumpHome(tester);
    // 当前泵出的首页是短剧组首页（HongguoDramaHome 分支），开抽屉的
    // 头像键是 neon-avatar；通用分支的 open-app-drawer 键走同一 _openDrawer。
    await tester.tap(find.byKey(const ValueKey('neon-avatar')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AppDrawer), findsOneWidget);
  });

  test('首页两个 Scaffold 都禁了边缘滑动打开抽屉', () {
    final src = File('lib/home_screen.dart').readAsStringSync();
    final count =
        'drawerEnableOpenDragGesture: false'.allMatches(src).length;
    expect(count, 2);
  });
}
