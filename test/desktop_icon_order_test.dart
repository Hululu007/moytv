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
      ]);
    });
  });

  group('桌面图标顺序持久化', () {
    test('存取 round-trip', () async {
      SharedPreferences.setMockInitialValues({});
      final order = [
        Win7WindowKind.mine,
        Win7WindowKind.actress,
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
      // 手机尺寸视口：7 个图标在默认 600 高视口里排不下。
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
      // “我的”在最下，拖到“听书”身上：应挪到最上。
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('win7-desktop-icon-mine'))),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('win7-desktop-icon-audio'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(top(tester, 'mine'), lessThan(top(tester, 'audio')));
      expect(top(tester, 'audio'), lessThan(top(tester, 'novel')));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(desktopIconOrderKey)?.first, 'mine');
    });
  });
}
