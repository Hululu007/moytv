// 桌面图标顺序：默认顺序解析、持久化 round-trip、拖拽换位。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/win7_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<Win7WindowKind> defaults() => List.of(win7DesktopIcons);

  group('resolveDesktopIconOrder', () {
    test('没存过回默认顺序', () {
      expect(resolveDesktopIconOrder(null), defaults());
      expect(resolveDesktopIconOrder([]), defaults());
    });

    test('存过的完整顺序照用', () {
      final stored = [
        'mine',
        'actress',
        'game',
        'library',
        'live',
        'listenRead',
        'miniApp',
        'multimedia',
        'kof',
      ];
      expect(
        resolveDesktopIconOrder(stored).map((kind) => kind.name).toList(),
        stored,
      );
    });

    test('未知名字与重复名字丢弃', () {
      final resolved = resolveDesktopIconOrder([
        'bogus',
        'mine',
        'mine',
        'listenRead',
      ]);
      expect(resolved.first, Win7WindowKind.mine);
      expect(resolved[1], Win7WindowKind.listenRead);
      expect(resolved.length, win7DesktopIcons.length);
    });

    test('不在桌面列表里的种类丢弃、在表里的保留', () {
      final resolved = resolveDesktopIconOrder(['drama', 'multimedia', 'mine']);
      expect(resolved, isNot(contains(Win7WindowKind.drama)));
      expect(resolved[0], Win7WindowKind.multimedia);
      expect(resolved[1], Win7WindowKind.mine);
    });

    test('缺的种类按默认相对顺序追加到末尾', () {
      final resolved = resolveDesktopIconOrder(['mine', 'library']);
      expect(resolved.sublist(0, 2), [
        Win7WindowKind.mine,
        Win7WindowKind.library,
      ]);
      expect(resolved.sublist(2), [
        Win7WindowKind.listenRead,
        Win7WindowKind.live,
        Win7WindowKind.miniApp,
        Win7WindowKind.actress,
        Win7WindowKind.game,
        Win7WindowKind.multimedia,
        Win7WindowKind.kof,
      ]);
    });
  });

  group('桌面图标顺序持久化', () {
    test('存取 round-trip', () async {
      SharedPreferences.setMockInitialValues({});
      final order = [
        Win7WindowKind.mine,
        Win7WindowKind.actress,
        Win7WindowKind.game,
        Win7WindowKind.library,
        Win7WindowKind.live,
        Win7WindowKind.listenRead,
        Win7WindowKind.miniApp,
        Win7WindowKind.multimedia,
        Win7WindowKind.kof,
      ];
      await saveDesktopIconOrder(order);
      expect(await loadDesktopIconOrder(), order);
    });

    test('没存过读回默认顺序', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await loadDesktopIconOrder(), defaults());
    });
  });

  group('DesktopIconColumn', () {
    Future<void> pumpDesktop(
      WidgetTester tester, {
      ValueChanged<Win7WindowKind>? onIconTap,
    }) async {
      // 手机尺寸视口：9 个图标在默认 600 高视口里排不下。
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

    double top(WidgetTester tester, String name) =>
        tester.getTopLeft(find.byKey(ValueKey('win7-desktop-icon-$name'))).dy;

    testWidgets('存过的顺序渲染出来', (tester) async {
      SharedPreferences.setMockInitialValues({
        desktopIconOrderKey: [
          'mine',
          'actress',
          'library',
          'live',
          'listenRead',
          'miniApp',
        ],
      });
      await pumpDesktop(tester);
      expect(top(tester, 'mine'), lessThan(top(tester, 'actress')));
      expect(top(tester, 'actress'), lessThan(top(tester, 'library')));
      expect(top(tester, 'library'), lessThan(top(tester, 'live')));
    });

    testWidgets('点按图标仍开窗口（拖拽包裹不吞点按）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      Win7WindowKind? tapped;
      await pumpDesktop(tester, onIconTap: (kind) => tapped = kind);
      await tester.tap(find.byKey(const ValueKey('win7-desktop-icon-live')));
      expect(tapped, Win7WindowKind.live);
    });

    testWidgets('长按进编辑态、拖到图标上互换格子并存盘', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpDesktop(tester);
      // 先长按任意图标进编辑态（完成钮出现）。
      await tester.longPress(
        find.byKey(const ValueKey('win7-desktop-icon-game')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('win7-desktop-edit-done')),
        findsOneWidget,
      );
      // 编辑态把“游戏”拖到“听读”身上：两者互换格子（用户
      // 2026-11-27 令的互换语义，取代旧的插入顺延）。
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('win7-desktop-icon-game'))),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey('win7-desktop-icon-listenRead')),
        ),
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // 游戏去了听读的格子（第 2 位），听读去了游戏的格子（第 7 位）。
      expect(top(tester, 'game'), lessThan(top(tester, 'library')));
      expect(top(tester, 'listenRead'), greaterThan(top(tester, 'actress')));
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(desktopIconOrderKey);
      expect(stored?[1], 'game');
      expect(stored?[6], 'listenRead');
    });
  });

  group('桌面图标满列换列', () {
    test('默认顺序我的电脑置顶', () {
      expect(win7DesktopIcons.first, Win7WindowKind.mine);
      expect(win7DesktopIcons, [
        Win7WindowKind.mine,
        Win7WindowKind.listenRead,
        Win7WindowKind.library,
        Win7WindowKind.live,
        Win7WindowKind.miniApp,
        Win7WindowKind.actress,
        Win7WindowKind.game,
        Win7WindowKind.multimedia,
        Win7WindowKind.kof,
      ]);
    });

    test('splitDesktopIconsIntoColumns：不足一列只有一列', () {
      final order = [Win7WindowKind.mine, Win7WindowKind.listenRead];
      expect(splitDesktopIconsIntoColumns(order, 8), [order]);
    });

    test('splitDesktopIconsIntoColumns：超过一列从第 N+1 个起第二列', () {
      final columns = splitDesktopIconsIntoColumns(win7DesktopIcons, 3);
      expect(columns.length, 3);
      expect(columns[0], [
        Win7WindowKind.mine,
        Win7WindowKind.listenRead,
        Win7WindowKind.library,
      ]);
      expect(columns[1], [
        Win7WindowKind.live,
        Win7WindowKind.miniApp,
        Win7WindowKind.actress,
      ]);
      expect(columns[2], [
        Win7WindowKind.game,
        Win7WindowKind.multimedia,
        Win7WindowKind.kof,
      ]);
    });

    test('splitDesktopIconsIntoColumns：空顺序与过小每列数', () {
      expect(splitDesktopIconsIntoColumns([], 3), isEmpty);
      expect(
        splitDesktopIconsIntoColumns(
          [Win7WindowKind.mine, Win7WindowKind.listenRead],
          0,
        ),
        [
          [Win7WindowKind.mine],
          [Win7WindowKind.listenRead],
        ],
      );
    });

    test('desktopItemsPerColumn：向下取整、至少 1 个、无约束全放一列', () {
      expect(desktopItemsPerColumn(300, 100, 8), 3);
      expect(desktopItemsPerColumn(299, 100, 8), 2);
      expect(desktopItemsPerColumn(50, 100, 8), 1);
      expect(desktopItemsPerColumn(double.infinity, 100, 8), 8);
    });

    Future<void> pumpColumn(
      WidgetTester tester, {
      required double height,
    }) async {
      // 手机尺寸视口：SizedBox 的高度不能超过视口高，否则会被钳制；
      // 要求高于 844 时视口跟着长高（只影响本用例的布局约束）。
      final viewportHeight = height > 844 ? height : 844.0;
      tester.view.physicalSize = Size(390, viewportHeight);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: height,
              child: DesktopIconColumn(
                keyPrefix: 'win7-desktop-icon',
                onIconTap: (_) {},
                iconBuilder: (kind) => Column(
                  children: [
                    DesktopIconBadge(kind: kind),
                    const SizedBox(height: 4),
                    Text(
                      kind.title,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    Offset pos(WidgetTester tester, String name) => tester.getTopLeft(
      find.byKey(ValueKey('win7-desktop-icon-$name')),
    );

    testWidgets('受限高度换第二列：第二列首项在第一列右侧、同高', (tester) async {
      await pumpColumn(tester, height: 300);
      final context = tester.element(find.byType(DesktopIconColumn));
      final perColumn = desktopItemsPerColumn(
        300,
        desktopIconItemHeight(context),
        win7DesktopIcons.length,
      );
      expect(perColumn, lessThan(win7DesktopIcons.length));
      final first = pos(tester, win7DesktopIcons.first.name);
      final secondHead = pos(tester, win7DesktopIcons[perColumn].name);
      expect(secondHead.dx, greaterThan(first.dx));
      expect(secondHead.dy, moreOrLessEquals(first.dy, epsilon: 1));
    });

    testWidgets('高度足够时只有一列：顺序往下排、纵坐标递增', (tester) async {
      await pumpColumn(tester, height: 1100);
      for (var i = 1; i < win7DesktopIcons.length; i++) {
        expect(
          pos(tester, win7DesktopIcons[i].name).dy,
          greaterThan(pos(tester, win7DesktopIcons[i - 1].name).dy),
          reason: '${win7DesktopIcons[i - 1].name} 应在 '
              '${win7DesktopIcons[i].name} 上面',
        );
      }
    });
  });
}
