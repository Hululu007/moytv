import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/content_zone_screen.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:moyi/win7_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> pumpWin7Home(
    WidgetTester tester, {
    // 真实非红果站 id：'missav' 不是站源 id，byId 会回落红果走戏剧首页
    // 分支，窗口里就没有顶栏，验不到“窗口内顶栏”。
    String source = 'huangdou',
  }) async {
    SharedPreferences.setMockInitialValues({
      'source': source,
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
    return store;
  }

  Finder win7Key(String name) => find.byKey(ValueKey(name));

  testWidgets('Win7 桌面：6 图标 + 任务栏 + 无胶囊栏', (tester) async {
    await pumpWin7Home(tester);
    expect(win7Key('win7-desktop'), findsOneWidget);
    for (final kind in Win7WindowKind.values) {
      if (kind == Win7WindowKind.live) continue;
      expect(
        win7Key('win7-desktop-icon-${kind.name}'),
        findsOneWidget,
        reason: kind.name,
      );
    }
    expect(win7Key('win7-desktop-icon-live'), findsNothing);
    expect(win7Key('win7-taskbar'), findsOneWidget);
    expect(win7Key('win7-start-button'), findsOneWidget);
    expect(find.byType(NeonCapsuleBar), findsNothing);
  });

  testWidgets('点片库图标开窗口：标题栏 + 最小化/关闭 + 窗口内顶栏', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-desktop-icon-library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(win7Key('win7-desktop'), findsNothing);
    expect(win7Key('win7-window-title'), findsOneWidget);
    expect(
      tester.widget<Text>(win7Key('win7-window-title')).data,
      '片库',
    );
    expect(win7Key('win7-window-minimize'), findsOneWidget);
    expect(win7Key('win7-window-close'), findsOneWidget);
    // 导航只在窗口内部：目录顶栏的站源切换在窗口里。
    expect(win7Key('source-switch'), findsOneWidget);
    expect(find.byType(NeonCapsuleBar), findsNothing);
  });

  testWidgets('点短剧图标开短剧窗口', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-desktop-icon-drama'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<Text>(win7Key('win7-window-title')).data,
      '短剧',
    );
    expect(win7Key('win7-window-close'), findsOneWidget);
  });

  testWidgets('关闭窗口回桌面，任务栏条目消失', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-desktop-icon-library'));
    await tester.pump();
    expect(win7Key('win7-taskbar-entry-library'), findsOneWidget);
    await tester.tap(win7Key('win7-window-close'));
    await tester.pump();
    expect(win7Key('win7-desktop'), findsOneWidget);
    expect(win7Key('win7-taskbar-entry-library'), findsNothing);
    expect(win7Key('win7-window-title'), findsNothing);
  });

  testWidgets('最小化后任务栏有条目，点条目恢复窗口', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-desktop-icon-library'));
    await tester.pump();
    await tester.tap(win7Key('win7-window-minimize'));
    await tester.pump();
    expect(win7Key('win7-desktop'), findsOneWidget);
    expect(win7Key('win7-taskbar-entry-library'), findsOneWidget);
    await tester.tap(win7Key('win7-taskbar-entry-library'));
    await tester.pump();
    expect(win7Key('win7-desktop'), findsNothing);
    expect(
      tester.widget<Text>(win7Key('win7-window-title')).data,
      '片库',
    );
  });

  testWidgets('点前台窗口的任务栏条目把它最小化', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-desktop-icon-library'));
    await tester.pump();
    await tester.tap(win7Key('win7-taskbar-entry-library'));
    await tester.pump();
    expect(win7Key('win7-desktop'), findsOneWidget);
    expect(win7Key('win7-taskbar-entry-library'), findsOneWidget);
  });

  testWidgets('切窗口保留状态：听读窗口实例不重建', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-desktop-icon-audio'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final zoneFinder = find.byType(
      ContentZoneScreen,
      skipOffstage: false,
    );
    expect(zoneFinder, findsOneWidget);
    final before = tester.state<State>(zoneFinder);
    // 切到片库窗口：先最小化听读窗口回桌面，再点片库图标；
    // 听读窗口退到任务栏，实例仍在树里（Offstage）。
    await tester.tap(win7Key('win7-window-minimize'));
    await tester.pump();
    await tester.tap(win7Key('win7-desktop-icon-library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<Text>(win7Key('win7-window-title')).data,
      '片库',
    );
    expect(zoneFinder, findsOneWidget);
    expect(identical(tester.state<State>(zoneFinder), before), isTrue);
    // 点任务栏条目恢复：还是同一个实例。
    await tester.tap(win7Key('win7-taskbar-entry-audio'));
    await tester.pump();
    expect(
      tester.widget<Text>(win7Key('win7-window-title')).data,
      '听书',
    );
    expect(identical(tester.state<State>(zoneFinder), before), isTrue);
  });

  testWidgets('多窗口任务栏切换', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-desktop-icon-library'));
    await tester.pump();
    await tester.tap(win7Key('win7-window-minimize'));
    await tester.pump();
    await tester.tap(win7Key('win7-desktop-icon-audio'));
    await tester.pump();
    expect(win7Key('win7-taskbar-entry-library'), findsOneWidget);
    expect(win7Key('win7-taskbar-entry-audio'), findsOneWidget);
    expect(
      tester.widget<Text>(win7Key('win7-window-title')).data,
      '听书',
    );
    await tester.tap(win7Key('win7-taskbar-entry-library'));
    await tester.pump();
    expect(
      tester.widget<Text>(win7Key('win7-window-title')).data,
      '片库',
    );
  });

  testWidgets('开始菜单开关与遮罩关闭', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-start-button'));
    await tester.pump();
    expect(win7Key('win7-start-menu'), findsOneWidget);
    // 遮罩中心被菜单面板盖住，点中心等于点面板：点面板左上角之外的
    // 可见遮罩区（左上角 10,10 在面板之外）。
    final scrimTopLeft = tester.getTopLeft(win7Key('win7-start-menu-scrim'));
    await tester.tapAt(scrimTopLeft + const Offset(10, 10));
    await tester.pump();
    expect(win7Key('win7-start-menu'), findsNothing);
  });

  testWidgets('开始菜单树展开与点站点开窗口', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-start-button'));
    await tester.pump();
    // 直播组是第 2 组（下标 1）：默认收起，点开后出现叶子。
    expect(win7Key('win7-tree-node-1-0'), findsNothing);
    await tester.tap(win7Key('win7-tree-node-1'));
    await tester.pump();
    expect(win7Key('win7-tree-node-1-0'), findsOneWidget);
    // 点第一个直播站点：开直播窗口、菜单关闭。
    await tester.tap(win7Key('win7-tree-node-1-0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(win7Key('win7-start-menu'), findsNothing);
    expect(
      tester.widget<Text>(win7Key('win7-window-title')).data,
      '直播',
    );
    expect(win7Key('win7-taskbar-entry-live'), findsOneWidget);
  });

  testWidgets('切主题生效：Win7 换紫蓝霓虹回胶囊壳', (tester) async {
    final store = await pumpWin7Home(tester);
    expect(win7Key('win7-desktop'), findsOneWidget);
    await store.setAppTheme(AppThemeMode.purpleNeon);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(win7Key('win7-desktop'), findsNothing);
    expect(win7Key('win7-taskbar'), findsNothing);
    expect(find.byType(NeonCapsuleBar), findsOneWidget);
  });
}
