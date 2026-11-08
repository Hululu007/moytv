import 'package:moyi/app_drawer.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/zone_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpZone(
    WidgetTester tester,
    HomeZone zone, {
    VoidCallback? onHideMidnight,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: ZoneSettingsScreen(
          repository: FixtureRepository(),
          store: store,
          zone: zone,
          onHideMidnight: onHideMidnight,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('drama zone settings carry drama entries only', (tester) async {
    await pumpZone(tester, HomeZone.drama);
    expect(find.text('短剧设置'), findsOneWidget);
    expect(find.text('短剧区风格'), findsOneWidget);
    expect(find.text('播放设置'), findsOneWidget);
    expect(find.text('播放器选择'), findsOneWidget);
    expect(find.text('通用设置'), findsOneWidget);
    expect(find.text('点播区 UI 风格'), findsNothing);
    expect(find.text('解析接口'), findsNothing);
    expect(find.text('未成年保护'), findsNothing);
  });

  testWidgets('vod zone settings carry vod entries only', (tester) async {
    await pumpZone(tester, HomeZone.vod);
    expect(find.text('点播设置'), findsOneWidget);
    expect(find.text('点播区 UI 风格'), findsNothing);
    expect(find.text('播放设置'), findsOneWidget);
    expect(find.text('播放器选择'), findsOneWidget);
    expect(find.text('解析接口'), findsOneWidget);
    expect(find.text('内容源管理'), findsOneWidget);
    expect(find.text('通用设置'), findsOneWidget);
    expect(find.text('短剧区风格'), findsNothing);
    expect(find.text('未成年保护'), findsNothing);
  });

  testWidgets('midnight zone settings carry protection switch', (tester) async {
    var hidden = 0;
    await pumpZone(tester, HomeZone.midnight, onHideMidnight: () => hidden++);
    expect(find.text('午夜设置'), findsOneWidget);
    expect(find.text('未成年保护'), findsOneWidget);
    expect(find.text('解析接口'), findsOneWidget);
    expect(find.text('通用设置'), findsOneWidget);
    expect(find.text('短剧区风格'), findsNothing);
    expect(find.text('点播区 UI 风格'), findsNothing);
    expect(find.text('内容源管理'), findsNothing);
    await tester.tap(find.text('未成年保护'));
    await tester.pumpAndSettle();
    expect(hidden, 1);
  });

  testWidgets('live zone settings carry live entries only', (tester) async {
    await pumpZone(tester, HomeZone.live);
    expect(find.text('直播设置'), findsOneWidget);
    expect(find.text('直播源'), findsOneWidget);
    expect(find.text('播放器选择'), findsOneWidget);
    expect(find.text('通用设置'), findsOneWidget);
    expect(find.text('短剧区风格'), findsNothing);
    expect(find.text('点播区 UI 风格'), findsNothing);
    expect(find.text('解析接口'), findsNothing);
  });
}
