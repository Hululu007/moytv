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
        'audio',
        'novel',
        'miniApp',
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
        'audio',
      ]);
      expect(resolved.first, Win7WindowKind.mine);
      expect(resolved[1], Win7WindowKind.audio);
      expect(resolved.length, win7DesktopIcons.length);
    });

    test('不在桌面列表里的种类丢弃', () {
      final resolved = resolveDesktopIconOrder(['drama', 'multimedia', 'mine']);
      expect(resolved, isNot(contains(Win7WindowKind.drama)));
      expect(resolved, isNot(contains(Win7WindowKind.multimedia)));
      expect(resolved.first, Win7WindowKind.mine);
    });

    test('缺的种类按默认相对顺序追加到末尾', () {
      final resolved = resolveDesktopIconOrder(['mine', 'library']);
      expect(resolved.sublist(0, 2), [
        Win7WindowKind.mine,
        Win7WindowKind.library,
      ]);
      expect(resolved.sublist(2), [
        Win7WindowKind.audio,
        Win7WindowKind.novel,
        Win7WindowKind.live,
        Win7WindowKind.miniApp,
        Win7WindowKind.actress,
        Win7WindowKind.game,
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
        Win7WindowKind.audio,
        Win7WindowKind.novel,
        Win7WindowKind.miniApp,
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
      // 手机尺寸视口：8 个图标在默认 600 高视口里排不下。
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
          'audio',
          'novel',
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

    testWidgets('长按拖拽换位置并存盘', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpDesktop(tester);
      // “游戏”在最下，拖到“听书”身上：应挪到听书上面。
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('win7-desktop-icon-game'))),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('win7-desktop-icon-audio'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(top(tester, 'game'), lessThan(top(tester, 'audio')));
      expect(top(tester, 'audio'), lessThan(top(tester, 'novel')));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(desktopIconOrderKey)?[1], 'game');
    });
  });

  group('桌面图标满列换列', () {
    test('默认顺序我的电脑置顶', () {
      expect(win7DesktopIcons.first, Win7WindowKind.mine);
      expect(win7DesktopIcons, [
        Win7WindowKind.mine,
        Win7WindowKind.audio,
        Win7WindowKind.novel,
        Win7WindowKind.library,
        Win7WindowKind.live,
        Win7WindowKind.miniApp,
        Win7WindowKind.actress,
        Win7WindowKind.game,
      ]);
    });

    test('splitDesktopIconsIntoColumns：不足一列只有一列', () {
      final order = [Win7WindowKind.mine, Win7WindowKind.audio];
      expect(splitDesktopIconsIntoColumns(order, 8), [order]);
    });

    test('splitDesktopIconsIntoColumns：超过一列从第 N+1 个起第二列', () {
      final columns = splitDesktopIconsIntoColumns(win7DesktopIcons, 3);
      expect(columns.length, 3);
      expect(columns[0], [
        Win7WindowKind.mine,
        Win7WindowKind.audio,
        Win7WindowKind.novel,
      ]);
      expect(columns[1], [
        Win7WindowKind.library,
        Win7WindowKind.live,
        Win7WindowKind.miniApp,
      ]);
      expect(columns[2], [Win7WindowKind.actress, Win7WindowKind.game]);
    });

    test('splitDesktopIconsIntoColumns：空顺序与过小每列数', () {
      expect(splitDesktopIconsIntoColumns([], 3), isEmpty);
      expect(
        splitDesktopIconsIntoColumns(
          [Win7WindowKind.mine, Win7WindowKind.audio],
          0,
        ),
        [
          [Win7WindowKind.mine],
          [Win7WindowKind.audio],
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
      // 手机尺寸视口：SizedBox 的高度不能超过视口高，否则会被钳制。
      tester.view.physicalSize = const Size(390, 844);
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
      await pumpColumn(tester, height: 800);
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
