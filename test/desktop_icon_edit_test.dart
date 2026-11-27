import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/win7_desktop.dart';
import 'package:moyi/xp_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Windows 主题桌面图标编辑（用户 2026-11-27 追加令）：长按进编辑
/// 态、拖到图标上互换格子、拖到空格移过去、落位持久化；非编辑态
/// 点按行为不变。Win7/XP 共用同一列组件与同一份存盘顺序。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpWin7(
    WidgetTester tester, {
    ValueChanged<Win7WindowKind>? onIconTap,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Win7Desktop(onIconTap: onIconTap ?? (_) {})),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> enterEdit(WidgetTester tester) async {
    await tester.longPress(
      find.byKey(const ValueKey('win7-desktop-icon-mine')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('编辑态点图标不开窗口，点完成退出后恢复', (tester) async {
    SharedPreferences.setMockInitialValues({});
    Win7WindowKind? tapped;
    await pumpWin7(tester, onIconTap: (kind) => tapped = kind);
    await enterEdit(tester);
    expect(find.byKey(const ValueKey('win7-desktop-edit-done')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('win7-desktop-icon-live')));
    await tester.pump();
    expect(tapped, isNull);
    await tester.tap(find.byKey(const ValueKey('win7-desktop-edit-done')));
    await tester.pump();
    expect(find.byKey(const ValueKey('win7-desktop-edit-done')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('win7-desktop-icon-live')));
    await tester.pump();
    expect(tapped, Win7WindowKind.live);
  });

  testWidgets('编辑态空格子出现，拖图标到空格移过去并存盘', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpWin7(tester);
    await enterEdit(tester);
    // 9 个图标、每列 8 个：第二列第 2 格起是空格（线性下标 9 起）。
    final emptySlot = find.byKey(
      const ValueKey('win7-desktop-icon-empty-9'),
    );
    expect(emptySlot, findsOneWidget);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('win7-desktop-icon-mine'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(tester.getCenter(emptySlot));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(desktopIconOrderKey);
    expect(stored?.last, 'mine');
    expect(stored?.first, 'listenRead');
    // 我的电脑落到了第二列（横坐标大于第一列图标）。
    final mineX = tester
        .getTopLeft(find.byKey(const ValueKey('win7-desktop-icon-mine')))
        .dx;
    final listenX = tester
        .getTopLeft(
          find.byKey(const ValueKey('win7-desktop-icon-listenRead')),
        )
        .dx;
    expect(mineX, greaterThan(listenX));
  });

  testWidgets('XP 桌面共用同一份顺序与编辑态', (tester) async {
    SharedPreferences.setMockInitialValues({
      desktopIconOrderKey: ['kof', 'mine'],
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: XpDesktop(onIconTap: (_) {}))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    double top(String name) => tester
        .getTopLeft(find.byKey(ValueKey('xp-desktop-icon-$name')))
        .dy;
    // 存过的顺序在 XP 桌面照样生效（拳皇在我的电脑上面）。
    expect(top('kof'), lessThan(top('mine')));
    await tester.longPress(
      find.byKey(const ValueKey('xp-desktop-icon-kof')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('xp-desktop-edit-done')), findsOneWidget);
  });
}
