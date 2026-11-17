import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/content_zone_screen.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/mine_page.dart';
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
    // 默认 flutter test 不带 ALL_SOURCES，注册表里只有红果：存档里的
    // huangdou 不在可见源里，初始化会回落红果走戏剧首页分支，同样
    // 验不到顶栏。置真时按启动注册内置站的方式把它补进注册表，模拟
    // 全量变体（魔蚁box）；全量模式下注册表已有它，不重复注。
    // 只影响点名要验目录顶栏的用例，其余用例沿用默认注册表。
    bool registerHuangdou = false,
  }) async {
    // 7 个桌面图标在默认 600 高视口里排不下（第 7 个中心点在视口外、
    // 点按命中不了）；用手机尺寸视口（与预览测试一致）。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (registerHuangdou &&
        !SourceSite.values.any((site) => site.id == source)) {
      SourceSite.importedSites[source] = SourceSite.byId(source);
      addTearDown(() => SourceSite.importedSites.remove(source));
    }
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

  testWidgets('Win7 桌面：7 图标 + 任务栏 + 无胶囊栏', (tester) async {
    await pumpWin7Home(tester);
    expect(win7Key('win7-desktop'), findsOneWidget);
    for (final kind in Win7WindowKind.values) {
      if (kind == Win7WindowKind.drama || kind == Win7WindowKind.multimedia) {
        continue;
      }
      expect(
        win7Key('win7-desktop-icon-${kind.name}'),
        findsOneWidget,
        reason: kind.name,
      );
    }
    // 短剧图标已从桌面拿掉（桌面有片库即够用），短剧窗只走开始菜单。
    expect(win7Key('win7-desktop-icon-drama'), findsNothing);
    // “我的电脑”已从桌面拿掉（改成“我的”图标），多媒体窗只走开始菜单。
    expect(win7Key('win7-desktop-icon-multimedia'), findsNothing);
    // 默认顺序：直播在片库后面，女优库在“我的”上面。
    double top(String name) =>
        tester.getTopLeft(win7Key('win7-desktop-icon-$name')).dy;
    final order = [
      'audio',
      'novel',
      'library',
      'live',
      'miniApp',
      'actress',
      'mine',
    ];
    for (var i = 1; i < order.length; i++) {
      expect(
        top(order[i]),
        greaterThan(top(order[i - 1])),
        reason: '${order[i - 1]} 应在 ${order[i]} 上面',
      );
    }
    expect(win7Key('win7-taskbar'), findsOneWidget);
    expect(win7Key('win7-start-button'), findsOneWidget);
    expect(find.byType(NeonCapsuleBar), findsNothing);
  });

  testWidgets('点片库图标开窗口：标题栏 + 最小化/关闭 + 窗口内顶栏', (tester) async {
    await pumpWin7Home(tester, registerHuangdou: true);
    await tester.tap(win7Key('win7-desktop-icon-library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(win7Key('win7-desktop'), findsNothing);
    expect(win7Key('win7-window-title'), findsOneWidget);
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '片库');
    expect(win7Key('win7-window-minimize'), findsOneWidget);
    expect(win7Key('win7-window-close'), findsOneWidget);
    // 导航只在窗口内部：目录顶栏的站源切换在窗口里。
    expect(win7Key('source-switch'), findsOneWidget);
    expect(find.byType(NeonCapsuleBar), findsNothing);
  });

  testWidgets('点“我的”图标开“我的”窗口：标题栏 + 我的页', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-desktop-icon-mine'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(win7Key('win7-desktop'), findsNothing);
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '我的');
    expect(find.byType(MinePage), findsOneWidget);
    expect(win7Key('win7-taskbar-entry-mine'), findsOneWidget);
  });

  testWidgets('点“女优库”图标开女优库窗口：标题栏 + 列表页', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-desktop-icon-actress'));
    await tester.pump();
    expect(win7Key('win7-desktop'), findsNothing);
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '女优库');
    expect(find.byType(ActressListPage), findsOneWidget);
    expect(win7Key('win7-taskbar-entry-actress'), findsOneWidget);
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
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '片库');
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
    final zoneFinder = find.byType(ContentZoneScreen, skipOffstage: false);
    expect(zoneFinder, findsOneWidget);
    final before = tester.state<State>(zoneFinder);
    // 切到片库窗口：先最小化听读窗口回桌面，再点片库图标；
    // 听读窗口退到任务栏，实例仍在树里（Offstage）。
    await tester.tap(win7Key('win7-window-minimize'));
    await tester.pump();
    await tester.tap(win7Key('win7-desktop-icon-library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '片库');
    expect(zoneFinder, findsOneWidget);
    expect(identical(tester.state<State>(zoneFinder), before), isTrue);
    // 点任务栏条目恢复：还是同一个实例。
    await tester.tap(win7Key('win7-taskbar-entry-audio'));
    await tester.pump();
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '听书');
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
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '听书');
    await tester.tap(win7Key('win7-taskbar-entry-library'));
    await tester.pump();
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '片库');
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
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '直播');
    expect(win7Key('win7-taskbar-entry-live'), findsOneWidget);
  });

  testWidgets('开始菜单女优库单叶开女优库窗口', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-start-button'));
    await tester.pump();
    // 女优库是末尾单叶（第 7 个顶级节点，下标 6）：无须展开，点按
    // 直接开女优库窗口、菜单关闭。
    final leaf = win7Key('win7-tree-node-6');
    expect(leaf, findsOneWidget);
    await tester.tap(leaf);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(win7Key('win7-start-menu'), findsNothing);
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '女优库');
    expect(find.byType(ActressListPage), findsOneWidget);
    expect(win7Key('win7-taskbar-entry-actress'), findsOneWidget);
  });

  testWidgets('Win7 片库窗顶栏女优库钮开女优库窗口', (tester) async {
    await pumpWin7Home(tester, registerHuangdou: true);
    await tester.tap(win7Key('win7-desktop-icon-library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('open-actress-library')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-actress-library')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '女优库');
    expect(find.byType(ActressListPage), findsOneWidget);
    expect(win7Key('win7-taskbar-entry-actress'), findsOneWidget);
    expect(win7Key('win7-taskbar-entry-library'), findsOneWidget);
  });

  testWidgets('Win7 女优库窗前台时切回普通主题仍是女优库区', (tester) async {
    final store = await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-desktop-icon-actress'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ActressListPage), findsOneWidget);
    await store.setAppTheme(AppThemeMode.purpleNeon);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 区域请求随窗口前台拨到了女优库：普通壳仍显示女优库页、底栏选中第 6 个标签。
    expect(win7Key('win7-desktop'), findsNothing);
    expect(find.byType(NeonCapsuleBar), findsOneWidget);
    expect(find.byType(ActressListPage), findsOneWidget);
    // 选中态按字重判（测试壳的 MaterialApp 主题写死 Win7，颜色不断言）。
    final barLabel = tester.widget<Text>(
      find.descendant(
        of: find.byType(NeonCapsuleBar),
        matching: find.text('女优库'),
      ),
    );
    expect(barLabel.style?.fontWeight, FontWeight.w700);
    final libraryLabel = tester.widget<Text>(
      find.descendant(
        of: find.byType(NeonCapsuleBar),
        matching: find.text('片库'),
      ),
    );
    expect(libraryLabel.style?.fontWeight, FontWeight.w500);
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
