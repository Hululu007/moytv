import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/main.dart';
import 'package:moyi/xp_boot_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> readyStore() async {
    SharedPreferences.setMockInitialValues({
      'source': 'huangdou',
      'hiddenSites': '[]',
      'appThemeMode': 'win7',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  test('启动屏最短显示时长为 1000 毫秒', () {
    expect(xpBootMinDisplay, const Duration(milliseconds: 1000));
  });

  testWidgets('加载中显示 XP 启动屏：黑底 + 文字标识 + 加载条', (tester) async {
    await tester.pumpWidget(
      MoyiApp(repository: FixtureRepository(), store: null),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(XpBootScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('xp-boot-app-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('xp-boot-xp-mark')), findsOneWidget);
    expect(find.byKey(const ValueKey('xp-boot-load-bar')), findsOneWidget);
    expect(find.text('正在启动…'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.backgroundColor, Colors.black);
    // 先卸树停掉循环动画，再排空 MoyiApp 方向控制器的定时器。
    await tester.pumpWidget(Container());
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('store 就绪后最短时长未到仍显示启动屏，满 1 秒后进首页', (tester) async {
    final store = await readyStore();
    await tester.pumpWidget(
      MoyiApp(repository: FixtureRepository(), store: null),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(XpBootScreen), findsOneWidget);
    // 初始化 100 毫秒就好了：最短时长未到，启动屏继续显示。
    await tester.pumpWidget(
      MoyiApp(repository: FixtureRepository(), store: store),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(XpBootScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    // 推进到满 1 秒：门控打开，进首页。
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(XpBootScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('出错时显示错误文案与重新打开，点按触发重试', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      MoyiApp(
        repository: FixtureRepository(),
        store: null,
        bootstrapError: '初始化失败：测试错误',
        onRetry: () => retried = true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(XpBootScreen), findsOneWidget);
    expect(find.text('初始化失败：测试错误'), findsOneWidget);
    expect(find.byKey(const ValueKey('xp-boot-load-bar')), findsNothing);
    expect(find.text('重新打开'), findsOneWidget);
    await tester.tap(find.text('重新打开'));
    expect(retried, isTrue);
    await tester.pumpWidget(Container());
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('首建即有 store 时不显示启动屏（热启动路径）', (tester) async {
    final store = await readyStore();
    await tester.pumpWidget(
      MoyiApp(repository: FixtureRepository(), store: store),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(XpBootScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
    await tester.pumpWidget(Container());
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });
}
