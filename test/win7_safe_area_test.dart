import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Finder win7Key(String name) => find.byKey(ValueKey(name));

  Future<void> pumpWin7Home(WidgetTester tester) async {
    // 物理像素 = 逻辑像素：FakeViewPadding 按物理像素计，dpr 须为 1
    // 断言的 44/34 才与逻辑边距一致。
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    SharedPreferences.setMockInitialValues({
      'source': 'huangdou',
      'hiddenSites': '[]',
      'appThemeMode': 'win7',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeRouteObserver],
        theme: AppThemeConfig.forTheme(AppThemeMode.win7).toThemeData(),
        home: HomeScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('Win7 开窗：标题栏按钮在状态栏下方、可见可点', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
    addTearDown(tester.view.reset);
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-desktop-icon-library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final minimize = tester.getRect(win7Key('win7-window-minimize'));
    final close = tester.getRect(win7Key('win7-window-close'));
    // 标题栏（40 高）从状态栏下方开始，按钮整体在安全区内。
    expect(minimize.top, greaterThanOrEqualTo(44));
    expect(close.top, greaterThanOrEqualTo(44));
    expect(minimize.bottom, lessThanOrEqualTo(44 + 40));
    expect(close.bottom, lessThanOrEqualTo(44 + 40));
    // 按钮点得到：点最小化后窗口收起、桌面重现。
    await tester.tap(win7Key('win7-window-minimize'));
    await tester.pump();
    expect(win7Key('win7-desktop'), findsOneWidget);
  });

  testWidgets('Win7 开窗：窗口内容紧跟标题栏，不留死空', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
    addTearDown(tester.view.reset);
    await pumpWin7Home(tester);
    // 片库窗走目录顶栏分支（短剧窗钉住戏剧首页、无顶栏）。
    await tester.tap(win7Key('win7-desktop-icon-library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 窗口内顶栏的站源切换紧跟 40 高标题栏：标题文字底边不超 84，
    // 站源切换顶边在 84 之后、128 之前（再叠一份状态栏边距会是 128）。
    final title = tester.getRect(win7Key('win7-window-title'));
    expect(title.bottom, lessThanOrEqualTo(44 + 40));
    final sourceSwitch = tester.getRect(win7Key('source-switch'));
    expect(sourceSwitch.top, greaterThanOrEqualTo(44 + 40));
    expect(sourceSwitch.top, lessThan(44 + 40 + 44));
  });

  testWidgets('Win7 任务栏落在手势条上方', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
    addTearDown(tester.view.reset);
    await pumpWin7Home(tester);
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    final taskbar = tester.getRect(win7Key('win7-taskbar'));
    expect(taskbar.bottom, closeTo(size.height - 34, 1));
    expect(taskbar.height, 56);
  });
}
