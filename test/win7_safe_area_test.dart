import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Finder win7Key(String name) => find.byKey(ValueKey(name));

  // 默认 flutter test 不带 ALL_SOURCES，注册表里只有红果：存档里的
  // huangdou 不在可见源里，初始化会回落红果走戏剧首页分支，窗口里
  // 没有目录顶栏。registerHuangdou 置真时按启动注册内置站的方式把
  // 它补进注册表，模拟全量变体（魔蚁box）；全量模式下注册表已有
  // 它，不重复注。只影响点名要验目录顶栏的用例。
  Future<void> pumpWin7Home(
    WidgetTester tester, {
    bool registerHuangdou = false,
  }) async {
    // 物理像素 = 逻辑像素：FakeViewPadding 按物理像素计，dpr 须为 1
    // 断言的 44/34 才与逻辑边距一致。
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    if (registerHuangdou &&
        !SourceSite.values.any((site) => site.id == 'huangdou')) {
      SourceSite.importedSites['huangdou'] = SourceSite.byId('huangdou');
      addTearDown(() => SourceSite.importedSites.remove('huangdou'));
    }
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
    // 标题栏（32 高）从状态栏下方开始，按钮整体在安全区内。
    expect(minimize.top, greaterThanOrEqualTo(44));
    expect(close.top, greaterThanOrEqualTo(44));
    expect(minimize.bottom, lessThanOrEqualTo(44 + 32));
    expect(close.bottom, lessThanOrEqualTo(44 + 32));
    // 按钮点得到：点最小化后窗口收起、桌面重现。
    await tester.tap(win7Key('win7-window-minimize'));
    await tester.pump();
    expect(win7Key('win7-desktop'), findsOneWidget);
  });

  testWidgets('Win7 开窗：窗口内容紧跟标题栏，不留死空', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
    addTearDown(tester.view.reset);
    await pumpWin7Home(tester, registerHuangdou: true);
    // 片库窗走目录顶栏分支（短剧窗钉住戏剧首页、无顶栏）。
    await tester.tap(win7Key('win7-desktop-icon-library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 窗口内顶栏的站源切换紧跟 32 高标题栏：标题文字底边不超 76，
    // 站源切换顶边在 76 之后、120 之前（再叠一份状态栏边距会是 120）。
    final title = tester.getRect(win7Key('win7-window-title'));
    expect(title.bottom, lessThanOrEqualTo(44 + 32));
    final sourceSwitch = tester.getRect(win7Key('source-switch'));
    expect(sourceSwitch.top, greaterThanOrEqualTo(44 + 32));
    expect(sourceSwitch.top, lessThan(44 + 32 + 44));
  });

  testWidgets('Win7 任务栏落在手势条上方', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
    addTearDown(tester.view.reset);
    await pumpWin7Home(tester);
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    final taskbar = tester.getRect(win7Key('win7-taskbar'));
    expect(taskbar.bottom, closeTo(size.height - 34, 1));
    expect(taskbar.height, 48);
  });
}
