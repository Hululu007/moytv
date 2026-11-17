import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_build.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpHome(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'source': 'huangdou',
      'hiddenSites': '[]',
      // 默认主题已改 XP：本测试验通用外壳，显式钉住紫蓝霓虹。
      'appThemeMode': 'purpleNeon',
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

  Future<void> switchToLive(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('shell-tab-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  // 与 vod_return_zone_test 同一口径：默认开关时 HomeScreen 落到红果首页，
  // 没有目录顶栏可供断言，须在 ALL_SOURCES=true 下跑。
  testWidgets('片库区右上角没有齿轮', (tester) async {
    await pumpHome(tester);
    expect(find.byKey(const ValueKey('open-settings')), findsNothing);
  }, skip: !allSourcesEnabled);

  testWidgets('直播区右上角保留齿轮', (tester) async {
    await pumpHome(tester);
    await switchToLive(tester);
    expect(find.byKey(const ValueKey('open-settings')), findsOneWidget);
  }, skip: !allSourcesEnabled);
}
