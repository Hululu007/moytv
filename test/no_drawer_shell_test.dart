import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_build.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpHome(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'source': 'huangdou',
      'hiddenSites': '[]',
      // 默认主题已改 XP：本测试验通用外壳，显式钉住紫蓝霓虹。
      'appThemeMode': 'purpleNeon',
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
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('首页树里没有抽屉组件', (tester) async {
    await pumpHome(tester);
    expect(find.byType(Drawer), findsNothing);
    expect(find.byType(NeonCapsuleBar), findsOneWidget);
    // 底栏 7 个标签都在（听书/阅读已并为“听读”一个标签）。
    for (final label in ['片库', '直播', '听读', '多媒体', '小程序', '我的', '女优库']) {
      expect(find.text(label), findsOneWidget);
    }
  }, skip: !allSourcesEnabled);

  testWidgets('头像点按进我的页，点片库回首页', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('open-mine-page')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('最近观看'), findsOneWidget);
    expect(find.byType(Drawer), findsNothing);
    await tester.tap(find.byKey(const ValueKey('shell-tab-0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('最近观看'), findsNothing);
    expect(find.byKey(const ValueKey('source-switch')), findsOneWidget);
  }, skip: !allSourcesEnabled);

  testWidgets('左边缘横滑拖不出任何东西，首页内容不动', (tester) async {
    await pumpHome(tester);
    expect(find.byKey(const ValueKey('source-switch')), findsOneWidget);
    // 手势导航的边缘滑动：从左边缘向右拖（原来会误触拖出抽屉）。
    await tester.dragFrom(const Offset(2, 400), const Offset(250, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Drawer), findsNothing);
    expect(find.byKey(const ValueKey('source-switch')), findsOneWidget);
    expect(find.byType(NeonCapsuleBar), findsOneWidget);
  }, skip: !allSourcesEnabled);

  testWidgets('前后台切换后首页内容仍在，不被任何状态盖住', (tester) async {
    await pumpHome(tester);
    expect(find.byKey(const ValueKey('source-switch')), findsOneWidget);
    // 小退：切后台再回前台。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Drawer), findsNothing);
    expect(find.byKey(const ValueKey('source-switch')), findsOneWidget);
    expect(find.byType(NeonCapsuleBar), findsOneWidget);
    // 切到小程序页签后小退，回来仍在小程序页。
    await tester.tap(find.byKey(const ValueKey('shell-tab-5')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Drawer), findsNothing);
    expect(find.text('小程序'), findsWidgets);
  }, skip: !allSourcesEnabled);
}
