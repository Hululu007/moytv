import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/content_zone_screen.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/mine_page.dart';
import 'package:moyi/multimedia_screen.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:moyi/site_icon.dart';
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
    // 预置的开始菜单固定列表（写进 mock 存表，覆盖首次随机抽）；
    // 为空时不写该键，菜单走首次随机抽。
    List<String>? pinnedSites,
  }) async {
    // 9 个桌面图标在默认 600 高视口里排不下（第 9 个中心点在视口外、
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
    final mockValues = <String, Object>{
      'source': source,
      'hiddenSites': '[]',
      'appThemeMode': 'win7',
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
        theme: AppThemeConfig.forTheme(AppThemeMode.win7).toThemeData(),
        home: HomeScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return store;
  }

  Finder win7Key(String name) => find.byKey(ValueKey(name));

  testWidgets('Win7 桌面：9 图标 + 任务栏 + 无胶囊栏', (tester) async {
    await pumpWin7Home(tester);
    expect(win7Key('win7-desktop'), findsOneWidget);
    for (final kind in Win7WindowKind.values) {
      if (kind == Win7WindowKind.drama) {
        continue;
      }
      // 游戏区没有桌面图标（只走底部标签与开始菜单），与短剧同口径跳过。
      if (kind == Win7WindowKind.gameZone) {
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
    // 游戏区同样没有桌面图标。
    expect(win7Key('win7-desktop-icon-gameZone'), findsNothing);
    // 默认顺序：我的电脑置顶第一位，其余按听读、片库、
    // 直播、小程序、女优库、游戏、网盘往下排；一列排满换
    // 第二列，所以按列优先比位置：同列看纵坐标递增，换列看
    // 横坐标递增。
    Offset pos(String name) =>
        tester.getTopLeft(win7Key('win7-desktop-icon-$name'));
    final order = [
      'mine',
      'listenRead',
      'library',
      'live',
      'miniApp',
      'actress',
      'game',
      'multimedia',
      'kof',
    ];
    for (var i = 1; i < order.length; i++) {
      final prev = pos(order[i - 1]);
      final curr = pos(order[i]);
      expect(
        curr.dy > prev.dy || curr.dx > prev.dx,
        isTrue,
        reason: '${order[i - 1]} 应在 ${order[i]} 前面',
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

  testWidgets('点“我的电脑”图标开“我的电脑”窗口：标题栏 + 我的页', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-desktop-icon-mine'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(win7Key('win7-desktop'), findsNothing);
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '我的电脑');
    expect(find.byType(MinePage), findsOneWidget);
    expect(win7Key('win7-taskbar-entry-mine'), findsOneWidget);
  });

  testWidgets('点“网盘”图标开“网盘”窗口：标题栏 + 网盘页', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-desktop-icon-multimedia'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(win7Key('win7-desktop'), findsNothing);
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '网盘');
    expect(find.byType(MultimediaScreen), findsOneWidget);
    expect(win7Key('win7-taskbar-entry-multimedia'), findsOneWidget);
  });

  testWidgets('桌面图标上色：9 个彩色底块 + “我的电脑”显示器图标', (tester) async {
    // “我的”窗口改叫“我的电脑”，图标换显示器样式（与网盘窗的
    // 整机图标区分）；普通壳底部标签的“我的”不在这套定义里，不动。
    expect(Win7WindowKind.mine.title, '我的电脑');
    expect(Win7WindowKind.multimedia.title, '网盘');
    expect(Win7WindowKind.mine.icon, Icons.desktop_windows);
    expect(
      Win7WindowKind.mine.icon,
      isNot(Win7WindowKind.multimedia.icon),
    );
    await pumpWin7Home(tester);
    expect(find.byType(DesktopIconBadge), findsNWidgets(9));
    expect(find.text('我的电脑'), findsOneWidget);
    expect(find.text('网盘'), findsOneWidget);
    expect(find.text('拳皇97'), findsOneWidget);
    expect(find.text('听读'), findsOneWidget);
    // 9 个底块渐变色各不相同（成套彩色，不撞色）。
    final gradients = tester
        .widgetList<DesktopIconBadge>(find.byType(DesktopIconBadge))
        .map((badge) => badge.kind.iconGradient.join(','))
        .toSet();
    expect(gradients.length, 9);
  });

  testWidgets('点“女优库”图标开女优库窗口：标题栏 + 列表页', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-desktop-icon-actress'));
    await tester.pump();
    expect(win7Key('win7-desktop'), findsNothing);
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '演员库');
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
    await tester.tap(win7Key('win7-desktop-icon-listenRead'));
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
    await tester.tap(win7Key('win7-taskbar-entry-listenRead'));
    await tester.pump();
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '听读');
    expect(identical(tester.state<State>(zoneFinder), before), isTrue);
  });

  testWidgets('多窗口任务栏切换', (tester) async {
    await pumpWin7Home(tester);
    await tester.tap(win7Key('win7-desktop-icon-library'));
    await tester.pump();
    await tester.tap(win7Key('win7-window-minimize'));
    await tester.pump();
    await tester.tap(win7Key('win7-desktop-icon-listenRead'));
    await tester.pump();
    expect(win7Key('win7-taskbar-entry-library'), findsOneWidget);
    expect(win7Key('win7-taskbar-entry-listenRead'), findsOneWidget);
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '听读');
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
    // 女优库是第 7 个顶级节点（下标 6）：无须展开，点按
    // 直接开女优库窗口、菜单关闭（末尾单叶现为游戏区，下标 7）。
    final leaf = win7Key('win7-tree-node-6');
    expect(leaf, findsOneWidget);
    await tester.tap(leaf);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(win7Key('win7-start-menu'), findsNothing);
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '演员库');
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
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '演员库');
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
        matching: find.text('演员库'),
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
      label: '网盘',
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
    const Win7TreeNode(label: '演员库', kind: Win7WindowKind.actress),
  ];

  Future<void> pumpWin7StartMenu(
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
          body: Win7StartMenu(
            groups: menuTestGroups(),
            onLeafTap: onLeafTap,
            onDismiss: onDismiss,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('随机抽固定：6 个不重复、只取有站点叶子、同种子同结果', () {
    final drawn = drawRandomPinnedSites(menuTestGroups(), 6, Random(42));
    expect(drawn.length, 6);
    expect(drawn.map((node) => node.siteId).toSet().length, 6);
    expect(drawn.every((node) => node.kind != null && node.siteId != null), isTrue);
    final again = drawRandomPinnedSites(menuTestGroups(), 6, Random(42));
    expect(
      again.map((node) => node.siteId).toList(),
      drawn.map((node) => node.siteId).toList(),
    );
  });

  test('随机抽固定：叶子不够时全取', () {
    final groups = [
      Win7TreeNode(
        label: '一组',
        children: [
          const Win7TreeNode(
            label: '甲',
            kind: Win7WindowKind.library,
            siteId: 'only-one',
          ),
        ],
      ),
    ];
    final drawn = drawRandomPinnedSites(groups, 6, Random(1));
    expect(drawn.map((node) => node.siteId).toList(), ['only-one']);
  });

  test('解析固定列表：按存序、未知与重复跳过、空表回空', () {
    final resolved = resolveStartMenuPinnedSites(
      menuTestGroups(),
      ['site-h', 'nope', 'site-a', 'site-h'],
    );
    expect(
      resolved.map((node) => node.siteId).toList(),
      ['site-h', 'site-a'],
    );
    expect(resolveStartMenuPinnedSites(menuTestGroups(), []), isEmpty);
  });

  test('解析固定列表：同 id 在多组出现取第一次出现的节点', () {
    final groups = [
      Win7TreeNode(
        label: '片库',
        children: [
          const Win7TreeNode(
            label: '甲站',
            kind: Win7WindowKind.library,
            siteId: 'dup',
          ),
        ],
      ),
      Win7TreeNode(
        label: '短剧',
        children: [
          const Win7TreeNode(
            label: '甲剧',
            kind: Win7WindowKind.drama,
            siteId: 'dup',
          ),
        ],
      ),
    ];
    final resolved = resolveStartMenuPinnedSites(groups, ['dup']);
    expect(resolved.length, 1);
    expect(resolved.single.label, '甲站');
    expect(resolved.single.kind, Win7WindowKind.library);
  });

  test('首次加载：从没存过抽 6 个存下来，第二次读同一份', () async {
    SharedPreferences.setMockInitialValues({});
    final first = await loadStartMenuPinnedSites(
      menuTestGroups(),
      random: Random(7),
    );
    expect(first.length, 6);
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(startMenuPinnedSitesKey)!;
    expect(stored.length, 6);
    expect(stored.toSet().length, 6);
    expect(stored, first.map((node) => node.siteId).toList());
    final second = await loadStartMenuPinnedSites(
      menuTestGroups(),
      random: Random(99),
    );
    expect(second.map((node) => node.siteId).toList(), stored);
  });

  test('加载：存过空表不再自动补抽', () async {
    SharedPreferences.setMockInitialValues({
      startMenuPinnedSitesKey: <String>[],
    });
    final loaded = await loadStartMenuPinnedSites(menuTestGroups());
    expect(loaded, isEmpty);
  });

  testWidgets('开始菜单双栏：左树 + 右固定栏 + 分隔线', (tester) async {
    await pumpWin7StartMenu(
      tester,
      mockPrefs: {
        startMenuPinnedSitesKey: ['site-b'],
      },
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    expect(win7Key('win7-start-menu-divider'), findsOneWidget);
    expect(win7Key('win7-start-menu-pinned'), findsOneWidget);
    expect(win7Key('win7-tree-node-0'), findsOneWidget);
    expect(win7Key('win7-start-menu-pinned-site-b'), findsOneWidget);
    expect(find.byType(SiteIcon), findsOneWidget);
  });

  testWidgets('组行显示区图标，网盘组行是硬盘图标', (tester) async {
    await pumpWin7StartMenu(
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
    await pumpWin7StartMenu(
      tester,
      mockPrefs: {
        startMenuPinnedSitesKey: <String>[],
      },
      onLeafTap: (kind, siteId) => taps.add((kind, siteId)),
      onDismiss: () {},
    );
    expect(find.text('长按左侧站点，固定到这里'), findsOneWidget);
    await tester.tap(win7Key('win7-tree-node-0'));
    await tester.pumpAndSettle();
    await tester.longPress(win7Key('win7-tree-node-0-0'));
    await tester.pumpAndSettle();
    expect(find.text('固定到快捷方式'), findsOneWidget);
    await tester.tap(find.text('固定到快捷方式'));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(win7Key('win7-start-menu-pinned-site-a'), findsOneWidget);
    // 长按没触发点按打开。
    expect(taps, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(startMenuPinnedSitesKey), ['site-a']);
  });

  testWidgets('长按组节点不弹菜单', (tester) async {
    await pumpWin7StartMenu(
      tester,
      mockPrefs: {
        startMenuPinnedSitesKey: <String>[],
      },
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    await tester.longPress(win7Key('win7-tree-node-0'));
    await tester.pumpAndSettle();
    expect(find.text('固定到快捷方式'), findsNothing);
    expect(find.text('取消固定'), findsNothing);
  });

  testWidgets('长按已固定点取消出右列并存盘', (tester) async {
    await pumpWin7StartMenu(
      tester,
      mockPrefs: {
        startMenuPinnedSitesKey: ['site-a', 'site-b'],
      },
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    expect(win7Key('win7-start-menu-pinned-site-a'), findsOneWidget);
    await tester.longPress(win7Key('win7-start-menu-pinned-site-a'));
    await tester.pumpAndSettle();
    expect(find.text('取消固定'), findsOneWidget);
    await tester.tap(find.text('取消固定'));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(win7Key('win7-start-menu-pinned-site-a'), findsNothing);
    expect(win7Key('win7-start-menu-pinned-site-b'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(startMenuPinnedSitesKey), ['site-b']);
  });

  testWidgets('点固定站点走 onLeafTap', (tester) async {
    final taps = <(Win7WindowKind, String?)>[];
    await pumpWin7StartMenu(
      tester,
      mockPrefs: {
        startMenuPinnedSitesKey: ['site-d'],
      },
      onLeafTap: (kind, siteId) => taps.add((kind, siteId)),
      onDismiss: () {},
    );
    await tester.tap(win7Key('win7-start-menu-pinned-site-d'));
    await tester.pumpAndSettle();
    expect(taps, [(Win7WindowKind.live, 'site-d')]);
  });

  testWidgets('固定后关掉重开还在', (tester) async {
    await pumpWin7StartMenu(
      tester,
      mockPrefs: {
        startMenuPinnedSitesKey: <String>[],
      },
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    await tester.tap(win7Key('win7-tree-node-0'));
    await tester.pumpAndSettle();
    await tester.longPress(win7Key('win7-tree-node-0-0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('固定到快捷方式'));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(win7Key('win7-start-menu-pinned-site-a'), findsOneWidget);
    // 重开一个新菜单实例：读存下来的那份，固定还在。
    await pumpWin7StartMenu(
      tester,
      resetPrefs: false,
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    expect(win7Key('win7-start-menu-pinned-site-a'), findsOneWidget);
  });

  testWidgets('首次打开随机固定 6 个不重复，存下来后重开不变', (tester) async {
    await pumpWin7StartMenu(
      tester,
      mockPrefs: {},
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    expect(find.byType(SiteIcon), findsNWidgets(6));
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(startMenuPinnedSitesKey)!;
    expect(stored.length, 6);
    expect(stored.toSet().length, 6);
    await pumpWin7StartMenu(
      tester,
      resetPrefs: false,
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    expect(find.byType(SiteIcon), findsNWidgets(6));
    final prefsAgain = await SharedPreferences.getInstance();
    expect(prefsAgain.getStringList(startMenuPinnedSitesKey), stored);
    double top(String id) =>
        tester.getTopLeft(win7Key('win7-start-menu-pinned-$id')).dy;
    for (var i = 1; i < stored.length; i++) {
      expect(top(stored[i]), greaterThan(top(stored[i - 1])));
    }
  });

  testWidgets('全取消后重开不再自动补抽', (tester) async {
    await pumpWin7StartMenu(
      tester,
      mockPrefs: {
        startMenuPinnedSitesKey: ['site-a'],
      },
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    await tester.longPress(win7Key('win7-start-menu-pinned-site-a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消固定'));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(find.text('长按左侧站点，固定到这里'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(startMenuPinnedSitesKey), <String>[]);
    await pumpWin7StartMenu(
      tester,
      resetPrefs: false,
      onLeafTap: (_, _) {},
      onDismiss: () {},
    );
    expect(find.text('长按左侧站点，固定到这里'), findsOneWidget);
    expect(find.byType(SiteIcon), findsNothing);
  });

  testWidgets('开始菜单双栏：右列固定站点点按开窗口', (tester) async {
    await pumpWin7Home(tester, pinnedSites: ['xiuguo']);
    await tester.tap(win7Key('win7-start-button'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(win7Key('win7-start-menu-divider'), findsOneWidget);
    expect(win7Key('win7-start-menu-pinned'), findsOneWidget);
    expect(win7Key('win7-start-menu-pinned-xiuguo'), findsOneWidget);
    await tester.tap(win7Key('win7-start-menu-pinned-xiuguo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(win7Key('win7-start-menu'), findsNothing);
    expect(tester.widget<Text>(win7Key('win7-window-title')).data, '直播');
    expect(win7Key('win7-taskbar-entry-live'), findsOneWidget);
  });
}
