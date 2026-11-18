import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:moyi/site_icon.dart';
import 'package:moyi/win7_desktop.dart';
import 'package:moyi/xp_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> pumpXpHome(
    WidgetTester tester, {
    String source = 'huangdou',
    // 预置的开始菜单固定列表（写进 mock 存表，覆盖首次随机抽）；
    // 为空时不写该键，菜单走首次随机抽。
    List<String>? pinnedSites,
  }) async {
    // 8 个桌面图标在默认 600 高视口里排不下（第 8 个中心点在视口外、
    // 点按命中不了）；用手机尺寸视口（与预览测试一致）。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final mockValues = <String, Object>{
      'source': source,
      'hiddenSites': '[]',
      'appThemeMode': 'xpWindows',
    };
    if (pinnedSites != null) {
      mockValues[startMenuPinnedSitesKey] = pinnedSites;
    }
    SharedPreferences.setMockInitialValues(mockValues);
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeRouteObserver],
        theme: AppThemeConfig.forTheme(AppThemeMode.xpWindows).toThemeData(),
        home: HomeScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return store;
  }

  Finder xpKey(String name) => find.byKey(ValueKey(name));

  testWidgets('XP 桌面：山丘墙纸 + 8 图标 + Luna 任务栏 + 无胶囊栏', (tester) async {
    await pumpXpHome(tester);
    expect(xpKey('xp-desktop'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    for (final kind in Win7WindowKind.values) {
      if (kind == Win7WindowKind.drama || kind == Win7WindowKind.multimedia) {
        continue;
      }
      expect(
        xpKey('xp-desktop-icon-${kind.name}'),
        findsOneWidget,
        reason: kind.name,
      );
    }
    // 短剧图标已从桌面拿掉（桌面有片库即够用），短剧窗只走开始菜单。
    expect(xpKey('xp-desktop-icon-drama'), findsNothing);
    // 多媒体窗口没有桌面图标，只走开始菜单（桌面顶上的“我的电脑”
    // 是“我的”窗口，与多媒体窗是两个窗口）。
    expect(xpKey('xp-desktop-icon-multimedia'), findsNothing);
    // 默认顺序与 Win7 同一份：我的电脑置顶第一位，其余按听书、
    // 阅读、片库、直播、小程序、女优库、游戏往下排。
    double top(String name) =>
        tester.getTopLeft(xpKey('xp-desktop-icon-$name')).dy;
    final order = [
      'mine',
      'audio',
      'novel',
      'library',
      'live',
      'miniApp',
      'actress',
      'game',
    ];
    for (var i = 1; i < order.length; i++) {
      expect(
        top(order[i]),
        greaterThan(top(order[i - 1])),
        reason: '${order[i - 1]} 应在 ${order[i]} 上面',
      );
    }
    expect(xpKey('xp-taskbar'), findsOneWidget);
    expect(xpKey('xp-start-button'), findsOneWidget);
    expect(find.text('开始'), findsOneWidget);
    expect(find.byType(NeonCapsuleBar), findsNothing);
    // Win7 外壳件一个都不出现。
    expect(find.byKey(const ValueKey('win7-desktop')), findsNothing);
    expect(find.byKey(const ValueKey('win7-taskbar')), findsNothing);
  });

  testWidgets('XP 桌面图标上色：8 个彩色底块 + “我的电脑”标签', (tester) async {
    await pumpXpHome(tester);
    expect(find.byType(DesktopIconBadge), findsNWidgets(8));
    expect(find.text('我的电脑'), findsOneWidget);
  });

  testWidgets('点片库图标开窗口：XP 标题栏 + 最小化/关闭', (tester) async {
    await pumpXpHome(tester);
    await tester.tap(xpKey('xp-desktop-icon-library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(xpKey('xp-desktop'), findsNothing);
    expect(xpKey('xp-window-title'), findsOneWidget);
    expect(tester.widget<Text>(xpKey('xp-window-title')).data, '片库');
    expect(xpKey('xp-window-minimize'), findsOneWidget);
    expect(xpKey('xp-window-close'), findsOneWidget);
    expect(find.byKey(const ValueKey('win7-window-title')), findsNothing);
  });

  testWidgets('关闭窗口回桌面，任务栏条目消失', (tester) async {
    await pumpXpHome(tester);
    await tester.tap(xpKey('xp-desktop-icon-library'));
    await tester.pump();
    expect(xpKey('xp-taskbar-entry-library'), findsOneWidget);
    await tester.tap(xpKey('xp-window-close'));
    await tester.pump();
    expect(xpKey('xp-desktop'), findsOneWidget);
    expect(xpKey('xp-taskbar-entry-library'), findsNothing);
    expect(xpKey('xp-window-title'), findsNothing);
  });

  testWidgets('最小化后任务栏有条目，点条目恢复窗口', (tester) async {
    await pumpXpHome(tester);
    await tester.tap(xpKey('xp-desktop-icon-library'));
    await tester.pump();
    await tester.tap(xpKey('xp-window-minimize'));
    await tester.pump();
    expect(xpKey('xp-desktop'), findsOneWidget);
    expect(xpKey('xp-taskbar-entry-library'), findsOneWidget);
    await tester.tap(xpKey('xp-taskbar-entry-library'));
    await tester.pump();
    expect(xpKey('xp-desktop'), findsNothing);
    expect(tester.widget<Text>(xpKey('xp-window-title')).data, '片库');
  });

  testWidgets('点前台窗口的任务栏条目把它最小化', (tester) async {
    await pumpXpHome(tester);
    await tester.tap(xpKey('xp-desktop-icon-library'));
    await tester.pump();
    await tester.tap(xpKey('xp-taskbar-entry-library'));
    await tester.pump();
    expect(xpKey('xp-desktop'), findsOneWidget);
    expect(xpKey('xp-taskbar-entry-library'), findsOneWidget);
  });

  testWidgets('多窗口任务栏切换', (tester) async {
    await pumpXpHome(tester);
    await tester.tap(xpKey('xp-desktop-icon-library'));
    await tester.pump();
    await tester.tap(xpKey('xp-window-minimize'));
    await tester.pump();
    // 短剧图标已从桌面拿掉（与 Win7 测试同款：第二窗口改用听书）。
    await tester.tap(xpKey('xp-desktop-icon-audio'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(xpKey('xp-taskbar-entry-library'), findsOneWidget);
    expect(xpKey('xp-taskbar-entry-audio'), findsOneWidget);
    expect(tester.widget<Text>(xpKey('xp-window-title')).data, '听书');
    await tester.tap(xpKey('xp-taskbar-entry-library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<Text>(xpKey('xp-window-title')).data, '片库');
  });

  testWidgets('开始菜单开关与遮罩关闭', (tester) async {
    await pumpXpHome(tester);
    await tester.tap(xpKey('xp-start-button'));
    await tester.pump();
    expect(xpKey('xp-start-menu'), findsOneWidget);
    expect(find.text('开始菜单'), findsOneWidget);
    final scrimTopLeft = tester.getTopLeft(xpKey('xp-start-menu-scrim'));
    await tester.tapAt(scrimTopLeft + const Offset(10, 10));
    await tester.pump();
    expect(xpKey('xp-start-menu'), findsNothing);
  });

  testWidgets('开始菜单树展开与点站点开窗口', (tester) async {
    await pumpXpHome(tester);
    await tester.tap(xpKey('xp-start-button'));
    await tester.pump();
    expect(xpKey('xp-tree-node-1-0'), findsNothing);
    await tester.tap(xpKey('xp-tree-node-1'));
    await tester.pump();
    expect(xpKey('xp-tree-node-1-0'), findsOneWidget);
    await tester.tap(xpKey('xp-tree-node-1-0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(xpKey('xp-start-menu'), findsNothing);
    expect(tester.widget<Text>(xpKey('xp-window-title')).data, '直播');
    expect(xpKey('xp-taskbar-entry-live'), findsOneWidget);
  });

  testWidgets('开始菜单女优库单叶开女优库窗口', (tester) async {
    await pumpXpHome(tester);
    await tester.tap(xpKey('xp-start-button'));
    await tester.pump();
    // 女优库是末尾单叶（第 7 个顶级节点，下标 6）：无须展开，点按
    // 直接开女优库窗口、菜单关闭。
    final leaf = xpKey('xp-tree-node-6');
    expect(leaf, findsOneWidget);
    await tester.tap(leaf);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(xpKey('xp-start-menu'), findsNothing);
    expect(tester.widget<Text>(xpKey('xp-window-title')).data, '演员库');
    expect(find.byType(ActressListPage), findsOneWidget);
    expect(xpKey('xp-taskbar-entry-actress'), findsOneWidget);
  });

  testWidgets('切主题生效：XP 换紫蓝霓虹回胶囊壳', (tester) async {
    final store = await pumpXpHome(tester);
    expect(xpKey('xp-desktop'), findsOneWidget);
    await store.setAppTheme(AppThemeMode.purpleNeon);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(xpKey('xp-desktop'), findsNothing);
    expect(xpKey('xp-taskbar'), findsNothing);
    expect(find.byType(NeonCapsuleBar), findsOneWidget);
  });

  testWidgets('切主题生效：XP 换 Win7 换外壳件', (tester) async {
    final store = await pumpXpHome(tester);
    await store.setAppTheme(AppThemeMode.win7);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(xpKey('xp-desktop'), findsNothing);
    expect(find.byKey(const ValueKey('win7-desktop')), findsOneWidget);
  });

  // ---- 开始菜单双栏与长按固定 ----

  // 8 个可固定叶子（site-a～site-h）+ 占位叶 + 无站点单叶。
  List<Win7TreeNode> menuTestGroups() => [
    Win7TreeNode(
      label: '片库',
      kind: Win7WindowKind.library,
      children: [
        const Win7TreeNode(
          label: '甲站',
          kind: Win7WindowKind.library,
          siteId: 'site-a',
        ),
        const Win7TreeNode(
          label: '乙站',
          kind: Win7WindowKind.library,
          siteId: 'site-b',
        ),
        const Win7TreeNode(
          label: '丙站',
          kind: Win7WindowKind.library,
          siteId: 'site-c',
        ),
      ],
    ),
    Win7TreeNode(
      label: '直播',
      kind: Win7WindowKind.live,
      children: [
        const Win7TreeNode(
          label: '丁台',
          kind: Win7WindowKind.live,
          siteId: 'site-d',
        ),
        const Win7TreeNode(
          label: '戊台',
          kind: Win7WindowKind.live,
          siteId: 'site-e',
        ),
      ],
    ),
    Win7TreeNode(
      label: '多媒体',
      kind: Win7WindowKind.multimedia,
      children: [
        const Win7TreeNode(
          label: '己盘',
          kind: Win7WindowKind.multimedia,
          siteId: 'site-f',
        ),
        const Win7TreeNode(
          label: '庚盘',
          kind: Win7WindowKind.multimedia,
          siteId: 'site-g',
        ),
        const Win7TreeNode(
          label: '辛盘',
          kind: Win7WindowKind.multimedia,
          siteId: 'site-h',
        ),
      ],
    ),
    Win7TreeNode(
      label: '空组',
      children: [const Win7TreeNode(label: '暂无可用站点')],
    ),
    const Win7TreeNode(label: '女优库', kind: Win7WindowKind.actress),
  ];

  Future<void> pumpXpStartMenu(
    WidgetTester tester, {
    Map<String, Object>? mockPrefs,
    bool resetPrefs = true,
    required void Function(Win7WindowKind kind, String? siteId) onLeafTap,
    required VoidCallback onDismiss,
  }) async {
    if (resetPrefs) SharedPreferences.setMockInitialValues(mockPrefs ?? {});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: XpStartMenu(
            groups: menuTestGroups(),
            onLeafTap: onLeafTap,
            onDismiss: onDismiss,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('开始菜单双栏：左树 + 右固定栏 + 分隔线', (tester) async {
    await pumpXpStartMenu(
      tester,
      mockPrefs: {
        startMenuPinnedSitesKey: ['site-b'],
      },
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    expect(xpKey('xp-start-menu-divider'), findsOneWidget);
    expect(xpKey('xp-start-menu-pinned'), findsOneWidget);
    expect(xpKey('xp-tree-node-0'), findsOneWidget);
    expect(xpKey('xp-start-menu-pinned-site-b'), findsOneWidget);
    expect(find.byType(SiteIcon), findsOneWidget);
  });

  testWidgets('组行显示区图标，多媒体组行是硬盘图标', (tester) async {
    await pumpXpStartMenu(
      tester,
      mockPrefs: {
        startMenuPinnedSitesKey: <String>[],
      },
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    expect(find.byIcon(Icons.storage), findsOneWidget);
    expect(find.byIcon(Icons.video_library), findsOneWidget);
    expect(find.byIcon(Icons.live_tv), findsOneWidget);
  });

  testWidgets('长按叶子出菜单，点固定进右列并存盘', (tester) async {
    final taps = <(Win7WindowKind, String?)>[];
    await pumpXpStartMenu(
      tester,
      mockPrefs: {
        startMenuPinnedSitesKey: <String>[],
      },
      onLeafTap: (kind, siteId) => taps.add((kind, siteId)),
      onDismiss: () {},
    );
    expect(find.text('长按左侧站点，固定到这里'), findsOneWidget);
    await tester.tap(xpKey('xp-tree-node-0'));
    await tester.pumpAndSettle();
    await tester.longPress(xpKey('xp-tree-node-0-0'));
    await tester.pumpAndSettle();
    expect(find.text('固定到快捷方式'), findsOneWidget);
    await tester.tap(find.text('固定到快捷方式'));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(xpKey('xp-start-menu-pinned-site-a'), findsOneWidget);
    // 长按没触发点按打开。
    expect(taps, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(startMenuPinnedSitesKey), ['site-a']);
  });

  testWidgets('长按组节点不弹菜单', (tester) async {
    await pumpXpStartMenu(
      tester,
      mockPrefs: {
        startMenuPinnedSitesKey: <String>[],
      },
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    await tester.longPress(xpKey('xp-tree-node-0'));
    await tester.pumpAndSettle();
    expect(find.text('固定到快捷方式'), findsNothing);
    expect(find.text('取消固定'), findsNothing);
  });

  testWidgets('长按已固定点取消出右列并存盘', (tester) async {
    await pumpXpStartMenu(
      tester,
      mockPrefs: {
        startMenuPinnedSitesKey: ['site-a', 'site-b'],
      },
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    expect(xpKey('xp-start-menu-pinned-site-a'), findsOneWidget);
    await tester.longPress(xpKey('xp-start-menu-pinned-site-a'));
    await tester.pumpAndSettle();
    expect(find.text('取消固定'), findsOneWidget);
    await tester.tap(find.text('取消固定'));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(xpKey('xp-start-menu-pinned-site-a'), findsNothing);
    expect(xpKey('xp-start-menu-pinned-site-b'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(startMenuPinnedSitesKey), ['site-b']);
  });

  testWidgets('点固定站点走 onLeafTap', (tester) async {
    final taps = <(Win7WindowKind, String?)>[];
    await pumpXpStartMenu(
      tester,
      mockPrefs: {
        startMenuPinnedSitesKey: ['site-d'],
      },
      onLeafTap: (kind, siteId) => taps.add((kind, siteId)),
      onDismiss: () {},
    );
    await tester.tap(xpKey('xp-start-menu-pinned-site-d'));
    await tester.pumpAndSettle();
    expect(taps, [(Win7WindowKind.live, 'site-d')]);
  });

  testWidgets('固定后关掉重开还在', (tester) async {
    await pumpXpStartMenu(
      tester,
      mockPrefs: {
        startMenuPinnedSitesKey: <String>[],
      },
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    await tester.tap(xpKey('xp-tree-node-0'));
    await tester.pumpAndSettle();
    await tester.longPress(xpKey('xp-tree-node-0-0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('固定到快捷方式'));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(xpKey('xp-start-menu-pinned-site-a'), findsOneWidget);
    // 重开一个新菜单实例：读存下来的那份，固定还在。
    await pumpXpStartMenu(
      tester,
      resetPrefs: false,
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    expect(xpKey('xp-start-menu-pinned-site-a'), findsOneWidget);
  });

  testWidgets('全取消后重开不再自动补抽', (tester) async {
    await pumpXpStartMenu(
      tester,
      mockPrefs: {
        startMenuPinnedSitesKey: ['site-a'],
      },
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    await tester.longPress(xpKey('xp-start-menu-pinned-site-a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消固定'));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(find.text('长按左侧站点，固定到这里'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(startMenuPinnedSitesKey), <String>[]);
    await pumpXpStartMenu(
      tester,
      resetPrefs: false,
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    expect(find.text('长按左侧站点，固定到这里'), findsOneWidget);
    expect(find.byType(SiteIcon), findsNothing);
  });

  testWidgets('开始菜单双栏：右列固定站点点按开窗口', (tester) async {
    await pumpXpHome(tester, pinnedSites: ['xiuguo']);
    await tester.tap(xpKey('xp-start-button'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(xpKey('xp-start-menu-divider'), findsOneWidget);
    expect(xpKey('xp-start-menu-pinned'), findsOneWidget);
    expect(xpKey('xp-start-menu-pinned-xiuguo'), findsOneWidget);
    await tester.tap(xpKey('xp-start-menu-pinned-xiuguo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(xpKey('xp-start-menu'), findsNothing);
    expect(tester.widget<Text>(xpKey('xp-window-title')).data, '直播');
    expect(xpKey('xp-taskbar-entry-live'), findsOneWidget);
  });
}
