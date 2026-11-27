import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/bottom_nav_config.dart';
import 'package:moyi/bottom_nav_manager_page.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 底部导航可编辑（用户 2026-11-27 令）：拖动排序、隐藏/恢复、自动
/// 补位、底线拦截、门禁不串、持久化。布局模型纯逻辑先测，再测组件
/// 与首页接线、管理页。

const _entries8 = <(Object, String)>[
  (LucideIcons.clapperboard, '片库'),
  (LucideIcons.tv, '直播'),
  (LucideIcons.bookHeadphones, '听读'),
  (LucideIcons.hardDrive, '网盘'),
  (LucideIcons.layoutGrid, '小程序'),
  (LucideIcons.users, '演员库'),
  (LucideIcons.gamepad2, '游戏区'),
  (LucideIcons.user, '我的'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('布局模型', () {
    test('默认布局：出厂顺序、全部显示', () {
      final layout = BottomNavLayout.defaults();
      expect(layout.visible, BottomNavTab.values);
      expect(layout.orderRaw, 'library,live,listen,pan,miniapp,actress,game,mine');
      expect(layout.hiddenRaw, '');
    });

    test('存量解析：未知/重复 id 丢弃，缺失页签按默认顺序补末尾', () {
      final layout = BottomNavLayout.fromStored('mine,bogus,library,mine', null);
      expect(layout.order.first, BottomNavTab.mine);
      expect(layout.order[1], BottomNavTab.library);
      expect(layout.order.length, 8);
      expect(layout.visible.length, 8);
    });

    test('存量解析：隐藏名单只认已知 id；全隐藏的坏存量兜底全显示', () {
      final layout = BottomNavLayout.fromStored(null, 'game,bogus');
      expect(layout.hidden, {BottomNavTab.gameZone});
      final broken = BottomNavLayout.fromStored(
        null,
        'library,live,listen,pan,miniapp,actress,game,mine',
      );
      expect(broken.visible, isNotEmpty);
      expect(broken.hidden, isEmpty);
    });

    test('拖动排序：可见序列内换位，跨中锚只是序列换位', () {
      final layout = BottomNavLayout.defaults();
      layout.moveVisible(0, 7);
      expect(layout.visible.first, BottomNavTab.live);
      expect(layout.visible.last, BottomNavTab.library);
      layout.moveVisible(7, 0);
      expect(layout.visible, BottomNavTab.values);
    });

    test('拖动排序：被隐藏页签在排列里原地不动', () {
      final layout = BottomNavLayout.defaults();
      layout.hide(BottomNavTab.live);
      layout.moveVisible(0, 2);
      // 可见序列：[片库 听读 网盘 …] 把片库移到第 2 位
      // -> [听读 网盘 片库 小程序 演员库 游戏区 我的]
      expect(layout.visible, [
        BottomNavTab.listenRead,
        BottomNavTab.cloudDrive,
        BottomNavTab.library,
        BottomNavTab.miniApp,
        BottomNavTab.actress,
        BottomNavTab.gameZone,
        BottomNavTab.mine,
      ]);
      // 直播仍排在片库原槽位附近（order 里下标 1 不动）。
      expect(layout.order[1], BottomNavTab.live);
    });

    test('隐藏底线：藏到只剩 1 个时再藏被拦', () {
      final layout = BottomNavLayout.defaults();
      for (final tab in BottomNavTab.values.take(7)) {
        expect(layout.hide(tab), isTrue);
      }
      expect(layout.visible, [BottomNavTab.mine]);
      expect(layout.hide(BottomNavTab.mine), isFalse);
      expect(layout.visible, [BottomNavTab.mine]);
    });

    test('隐藏后恢复：回到排列原位，不是追加到末尾', () {
      final layout = BottomNavLayout.defaults();
      layout.hide(BottomNavTab.cloudDrive);
      expect(layout.visible.contains(BottomNavTab.cloudDrive), isFalse);
      layout.show(BottomNavTab.cloudDrive);
      expect(layout.visible, BottomNavTab.values);
    });

    test('一键重置：顺序与隐藏全回出厂', () {
      final layout = BottomNavLayout.defaults();
      layout.moveVisible(0, 5);
      layout.hide(BottomNavTab.mine);
      layout.reset();
      expect(layout.visible, BottomNavTab.values);
      expect(layout.hidden, isEmpty);
    });

    test('门禁不串：门禁隐藏只影响渲染，不写进用户隐藏名单', () {
      final layout = BottomNavLayout.defaults();
      layout.hide(BottomNavTab.gameZone);
      final shown = layout.displayVisible(gateHidden: {BottomNavTab.actress});
      expect(shown.contains(BottomNavTab.actress), isFalse);
      expect(shown.contains(BottomNavTab.gameZone), isFalse);
      // 门禁集合没有污染用户偏好：actress 不在 hidden 里。
      expect(layout.hidden, {BottomNavTab.gameZone});
      // 门禁解除后 actress 按用户顺序原位回来。
      final lifted = layout.displayVisible();
      expect(lifted, [
        BottomNavTab.library,
        BottomNavTab.live,
        BottomNavTab.listenRead,
        BottomNavTab.cloudDrive,
        BottomNavTab.miniApp,
        BottomNavTab.actress,
        BottomNavTab.mine,
      ]);
    });

    test('持久化往返：存后再读，顺序与隐藏一致', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final layout = BottomNavLayout.defaults();
      layout.moveVisible(7, 0);
      layout.hide(BottomNavTab.live);
      await layout.save(prefs);
      final loaded = BottomNavLayout.load(prefs);
      expect(loaded.orderRaw, layout.orderRaw);
      expect(loaded.hiddenRaw, layout.hiddenRaw);
      expect(loaded.visible.first, BottomNavTab.mine);
    });
  });

  group('胶囊栏编辑态', () {
    Future<void> pumpEditingBar(
      WidgetTester tester, {
      required void Function(int from, int to) onReorder,
      required ValueChanged<int> onRemoveTab,
      bool removeEnabled = true,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeConfig.forTheme(AppThemeMode.lightClean).toThemeData(),
          home: Scaffold(
            body: const SizedBox.shrink(),
            bottomNavigationBar: NeonCapsuleBar(
              entries: _entries8,
              index: 0,
              onSelect: (_) {},
              onCenter: () {},
              centerAfter: 4,
              tabKeyPrefix: 'shell-tab',
              centerKey: 'shell-center',
              editing: true,
              onReorder: onReorder,
              onRemoveTab: onRemoveTab,
              removeEnabled: removeEnabled,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('编辑态每个页签都有减号，点按回传可见下标', (tester) async {
      final removed = <int>[];
      await pumpEditingBar(
        tester,
        onReorder: (_, _) {},
        onRemoveTab: removed.add,
      );
      for (var i = 0; i < 8; i++) {
        expect(
          find.byKey(ValueKey('shell-tab-remove-$i')),
          findsOneWidget,
          reason: '第 $i 个页签应有减号徽标',
        );
      }
      await tester.tap(find.byKey(const ValueKey('shell-tab-remove-6')));
      await tester.pump();
      expect(removed, [6]);
    });

    testWidgets('编辑态长按拖动：从第 0 个拖到第 2 个落位', (tester) async {
      final moves = <(int, int)>[];
      await pumpEditingBar(
        tester,
        onReorder: (from, to) => moves.add((from, to)),
        onRemoveTab: (_) {},
      );
      final start = tester.getCenter(find.byKey(const ValueKey('shell-tab-0')));
      final end = tester.getCenter(find.byKey(const ValueKey('shell-tab-2')));
      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(end);
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(moves, isNotEmpty);
      expect(moves.last.$1, 0);
      expect(moves.last.$2, 2);
    });

    testWidgets('非编辑态长按页签走 onLongPressTab（进编辑态入口）', (
      tester,
    ) async {
      final longPressed = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeConfig.forTheme(AppThemeMode.lightClean).toThemeData(),
          home: Scaffold(
            body: const SizedBox.shrink(),
            bottomNavigationBar: NeonCapsuleBar(
              entries: _entries8,
              index: 0,
              onSelect: (_) {},
              onCenter: () {},
              centerAfter: 4,
              tabKeyPrefix: 'shell-tab',
              onLongPressTab: longPressed.add,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.longPress(find.byKey(const ValueKey('shell-tab-3')));
      await tester.pump();
      expect(longPressed, [3]);
      // 非编辑态没有减号徽标。
      expect(find.byKey(const ValueKey('shell-tab-remove-3')), findsNothing);
    });
  });

  group('首页接线', () {
    Future<void> pumpHome(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'source': 'huangdou',
        'hiddenSites': '[]',
        'appThemeMode': 'lightClean',
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

    testWidgets('长按页签进编辑态，点减号隐藏游戏区并存偏好，点完成退出', (
      tester,
    ) async {
      await pumpHome(tester);
      await tester.longPress(find.byKey(const ValueKey('shell-tab-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('nav-edit-done')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-tab-remove-6')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('shell-tab-remove-6')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 游戏区已从栏里消失，其余页签自动补位（第 6 位由「我的」顶上）：
      // 网盘与小程序仍夹着圆钮。
      final barFinder = find.byType(NeonCapsuleBar);
      expect(
        find.descendant(of: barFinder, matching: find.text('游戏区')),
        findsNothing,
      );
      expect(
        find.descendant(of: barFinder, matching: find.text('我的')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('shell-tab-6')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-tab-7')), findsNothing);
      final centerX = tester
          .getCenter(find.byKey(const ValueKey('shell-center')))
          .dx;
      final panX = tester
          .getCenter(find.descendant(of: barFinder, matching: find.text('网盘')))
          .dx;
      final miniX = tester
          .getCenter(
            find.descendant(of: barFinder, matching: find.text('小程序')),
          )
          .dx;
      expect(centerX, greaterThan(panX));
      expect(centerX, lessThan(miniX));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(BottomNavLayout.hiddenKey), 'game');

      // 等隐藏成功的 SnackBar 消失再点完成，避免遮挡。
      await tester.pump(const Duration(seconds: 5));
      await tester.tap(find.byKey(const ValueKey('nav-edit-done')));
      await tester.pump();
      expect(find.byKey(const ValueKey('nav-edit-done')), findsNothing);
      expect(find.byKey(const ValueKey('shell-tab-remove-0')), findsNothing);
    });

    testWidgets('存量隐藏名单进首页：栏里只剩未隐藏页签且能正常点', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'source': 'huangdou',
        'hiddenSites': '[]',
        'appThemeMode': 'lightClean',
        BottomNavLayout.hiddenKey: 'live,game',
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
      // 直播/游戏区不在栏里；其余 6 个在，位置键按可见序列排。
      expect(find.text('直播'), findsNothing);
      expect(find.text('游戏区'), findsNothing);
      expect(find.byKey(const ValueKey('shell-tab-5')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-tab-6')), findsNothing);
    });
  });

  group('导航管理页', () {
    testWidgets('隐藏池恢复 + 隐藏 + 重置默认布局', (tester) async {
      SharedPreferences.setMockInitialValues({
        BottomNavLayout.hiddenKey: 'game',
      });
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        MaterialApp(home: BottomNavManagerPage(preferences: prefs)),
      );
      await tester.pump();
      // 游戏区在「已隐藏」里，带恢复钮。
      expect(find.byKey(const ValueKey('nav-manager-show-game')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-manager-show-game')));
      await tester.pump();
      expect(find.byKey(const ValueKey('nav-manager-show-game')), findsNothing);
      expect(find.byKey(const ValueKey('nav-manager-hide-game')), findsOneWidget);
      expect(prefs.getString(BottomNavLayout.hiddenKey), '');

      // 隐藏网盘再重置：确认框后全部回默认。
      await tester.tap(find.byKey(const ValueKey('nav-manager-hide-pan')));
      await tester.pump();
      expect(prefs.getString(BottomNavLayout.hiddenKey), 'pan');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('nav-manager-reset')),
        120,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('nav-manager-reset')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('重置'));
      await tester.pump();
      expect(prefs.getString(BottomNavLayout.hiddenKey), '');
      expect(
        prefs.getString(BottomNavLayout.orderKey),
        'library,live,listen,pan,miniapp,actress,game,mine',
      );
    });
  });
}
