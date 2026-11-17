import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:moyi/win7_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> pumpXpHome(
    WidgetTester tester, {
    String source = 'huangdou',
  }) async {
    // 7 个桌面图标在默认 600 高视口里排不下（第 7 个中心点在视口外、
    // 点按命中不了）；用手机尺寸视口（与预览测试一致）。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'source': source,
      'hiddenSites': '[]',
      'appThemeMode': 'xpWindows',
    });
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

  testWidgets('XP 桌面：山丘墙纸 + 7 图标 + Luna 任务栏 + 无胶囊栏', (tester) async {
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
    // “我的电脑”已从桌面拿掉（改成“我的”图标），多媒体窗只走开始菜单。
    expect(xpKey('xp-desktop-icon-multimedia'), findsNothing);
    // 默认顺序与 Win7 同一份：直播在片库后面，女优库在“我的”上面。
    double top(String name) =>
        tester.getTopLeft(xpKey('xp-desktop-icon-$name')).dy;
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
    expect(xpKey('xp-taskbar'), findsOneWidget);
    expect(xpKey('xp-start-button'), findsOneWidget);
    expect(find.text('开始'), findsOneWidget);
    expect(find.byType(NeonCapsuleBar), findsNothing);
    // Win7 外壳件一个都不出现。
    expect(find.byKey(const ValueKey('win7-desktop')), findsNothing);
    expect(find.byKey(const ValueKey('win7-taskbar')), findsNothing);
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
    expect(tester.widget<Text>(xpKey('xp-window-title')).data, '女优库');
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
}
