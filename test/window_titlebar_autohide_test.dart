// 桌面窗口标题栏自动隐藏（用户 2026-11-18 令）：3 秒无操作收起、
// 点一下放下、收起时点按不点透、任务栏不动。Win7 / XP 两套框同测。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/win7_desktop.dart';
import 'package:moyi/xp_desktop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const contentKey = ValueKey('autohide-content');
  const buttonKey = ValueKey('autohide-content-button');

  /// 内容体：一个可点按钮（记点按次数）+ 占满的容器。
  Widget contentBody(void Function() onButtonTap) {
    return Container(
      key: contentKey,
      color: Colors.white,
      alignment: Alignment.center,
      child: GestureDetector(
        key: buttonKey,
        onTap: onButtonTap,
        child: Container(
          width: 120,
          height: 48,
          color: Colors.blue,
          alignment: Alignment.center,
          child: const Text('内容按钮'),
        ),
      ),
    );
  }

  Future<void> pumpWin7Frame(
    WidgetTester tester, {
    required Widget child,
    bool active = true,
    VoidCallback? onMinimize,
    VoidCallback? onClose,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 500,
            child: Win7WindowFrame(
              kind: Win7WindowKind.library,
              onMinimize: onMinimize ?? () {},
              onClose: onClose ?? () {},
              active: active,
              child: child,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpXpFrame(
    WidgetTester tester, {
    required Widget child,
    bool active = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 500,
            child: XpWindowFrame(
              kind: Win7WindowKind.library,
              onMinimize: () {},
              onClose: () {},
              active: active,
              child: child,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder win7Title() => find.byKey(const ValueKey('win7-window-title'));
  Finder xpTitle() => find.byKey(const ValueKey('xp-window-title'));

  testWidgets('Win7：3 秒无操作标题栏收起，内容区顶到顶边', (tester) async {
    await pumpWin7Frame(tester, child: contentBody(() {}));
    expect(win7Title(), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(contentKey)).dy, 32);
    await tester.pump(const Duration(seconds: 2));
    expect(win7Title(), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(win7Title(), findsNothing);
    expect(tester.getTopLeft(find.byKey(contentKey)).dy, 0);
  });

  testWidgets('Win7：收起后点一下屏幕，标题栏放下来', (tester) async {
    await pumpWin7Frame(tester, child: contentBody(() {}));
    await tester.pump(const Duration(seconds: 3));
    expect(win7Title(), findsNothing);
    await tester.tap(find.byKey(contentKey), warnIfMissed: false);
    await tester.pump();
    expect(win7Title(), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(contentKey)).dy, 32);
  });

  testWidgets('Win7：放下来后 3 秒无操作再收起', (tester) async {
    await pumpWin7Frame(tester, child: contentBody(() {}));
    await tester.pump(const Duration(seconds: 3));
    expect(win7Title(), findsNothing);
    await tester.tap(find.byKey(contentKey), warnIfMissed: false);
    await tester.pump();
    expect(win7Title(), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(win7Title(), findsNothing);
  });

  testWidgets('Win7：收起时点按只放栏、不触发底下按钮，再点才触发', (
    tester,
  ) async {
    var taps = 0;
    await pumpWin7Frame(tester, child: contentBody(() => taps++));
    await tester.pump(const Duration(seconds: 3));
    expect(win7Title(), findsNothing);
    // 收起时点按钮：只放下标题栏，按钮不触发（点按被遮罩吞掉，
    // 命中警告是预期的，关掉它）。
    await tester.tap(find.byKey(buttonKey), warnIfMissed: false);
    await tester.pump();
    expect(win7Title(), findsOneWidget);
    expect(taps, 0);
    // 标题栏已放下：再点按钮，正常触发。
    await tester.tap(find.byKey(buttonKey));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('Win7：点按重置计时，2 秒点一下、再过 2 秒还在', (tester) async {
    await pumpWin7Frame(tester, child: contentBody(() {}));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byKey(contentKey));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(win7Title(), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(win7Title(), findsNothing);
  });

  testWidgets('Win7：点标题栏也重置计时', (tester) async {
    await pumpWin7Frame(tester, child: contentBody(() {}));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(win7Title());
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(win7Title(), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(win7Title(), findsNothing);
  });

  testWidgets('Win7：拖动重置计时（按住 2 秒后移动，再过 2 秒还在）', (
    tester,
  ) async {
    await pumpWin7Frame(tester, child: contentBody(() {}));
    await tester.pump(const Duration(seconds: 2));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(contentKey)),
    );
    await tester.pump(const Duration(seconds: 2));
    await gesture.moveTo(
      tester.getCenter(find.byKey(contentKey)) + const Offset(0, 30),
    );
    await tester.pump(const Duration(seconds: 2));
    // 若移动不重置计时，标题栏应在第 5 秒收起；现在还在。
    expect(win7Title(), findsOneWidget);
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(win7Title(), findsNothing);
  });

  testWidgets('Win7：标题栏可见时最小化/关闭照常触发', (tester) async {
    var minimized = 0;
    var closed = 0;
    await pumpWin7Frame(
      tester,
      child: contentBody(() {}),
      onMinimize: () => minimized++,
      onClose: () => closed++,
    );
    await tester.tap(find.byKey(const ValueKey('win7-window-minimize')));
    await tester.pump();
    expect(minimized, 1);
    await tester.tap(find.byKey(const ValueKey('win7-window-close')));
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('Win7：任务栏始终可见可点，不受标题栏收起影响', (tester) async {
    Win7WindowKind? entryTapped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 500,
            child: Column(
              children: [
                Expanded(
                  child: Win7WindowFrame(
                    kind: Win7WindowKind.library,
                    onMinimize: () {},
                    onClose: () {},
                    child: contentBody(() {}),
                  ),
                ),
                Win7Taskbar(
                  openWindows: const [Win7WindowKind.library],
                  foreground: Win7WindowKind.library,
                  onStartTap: () {},
                  onEntryTap: (kind) => entryTapped = kind,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(win7Title(), findsNothing);
    final taskbar = find.byKey(const ValueKey('win7-taskbar'));
    expect(taskbar, findsOneWidget);
    expect(tester.getSize(taskbar).height, 48);
    await tester.tap(
      find.byKey(const ValueKey('win7-taskbar-entry-library')),
    );
    await tester.pump();
    expect(entryTapped, Win7WindowKind.library);
  });

  testWidgets('Win7：退后台停计时、回前台放下标题栏并重新计时', (
    tester,
  ) async {
    final active = ValueNotifier<bool>(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 500,
            child: ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (_, value, _) => Win7WindowFrame(
                kind: Win7WindowKind.library,
                onMinimize: () {},
                onClose: () {},
                active: value,
                child: contentBody(() {}),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 退后台：5 秒也不收起。
    active.value = false;
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(win7Title(), findsOneWidget);
    // 回前台：重新计时，3 秒后收起。
    active.value = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(win7Title(), findsNothing);
    // 收起后退后台再回前台：标题栏重新放下。
    active.value = false;
    await tester.pump();
    active.value = true;
    await tester.pump();
    expect(win7Title(), findsOneWidget);
  });

  testWidgets('XP：3 秒无操作收起，点一下放下来', (tester) async {
    await pumpXpFrame(tester, child: contentBody(() {}));
    expect(xpTitle(), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(contentKey)).dy, 32);
    await tester.pump(const Duration(seconds: 3));
    expect(xpTitle(), findsNothing);
    expect(tester.getTopLeft(find.byKey(contentKey)).dy, 0);
    await tester.tap(find.byKey(contentKey), warnIfMissed: false);
    await tester.pump();
    expect(xpTitle(), findsOneWidget);
  });

  testWidgets('XP：收起时点按只放栏、不触发底下按钮', (tester) async {
    var taps = 0;
    await pumpXpFrame(tester, child: contentBody(() => taps++));
    await tester.pump(const Duration(seconds: 3));
    expect(xpTitle(), findsNothing);
    await tester.tap(find.byKey(buttonKey), warnIfMissed: false);
    await tester.pump();
    expect(xpTitle(), findsOneWidget);
    expect(taps, 0);
    await tester.tap(find.byKey(buttonKey));
    await tester.pump();
    expect(taps, 1);
  });
}
