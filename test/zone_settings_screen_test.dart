import 'package:moyi/home_zone.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/zone_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpZone(WidgetTester tester, HomeZone zone) async {
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
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // 片库设置页已废弃并入通用设置：片库区只剩通用设置入口，
  // 五项（播放设置/播放器选择/解析接口/内容源管理/未成年保护）
  // 一律不在这里出现。
  testWidgets('library zone settings are deprecated into generic settings', (
    tester,
  ) async {
    await pumpZone(tester, HomeZone.library);
    expect(find.text('片库设置'), findsNothing);
    expect(find.text('播放设置'), findsNothing);
    expect(find.text('播放器选择'), findsNothing);
    expect(find.text('解析接口'), findsNothing);
    expect(find.text('内容源管理'), findsNothing);
    expect(find.text('未成年保护'), findsNothing);
    expect(find.text('通用设置'), findsWidgets);
    expect(find.text('短剧区风格'), findsNothing);
    expect(find.text('点播区 UI 风格'), findsNothing);
  });

  testWidgets('live zone settings carry live entries only', (tester) async {
    await pumpZone(tester, HomeZone.live);
    expect(find.text('直播设置'), findsOneWidget);
    expect(find.text('直播源'), findsOneWidget);
    expect(find.text('播放设置'), findsOneWidget);
    expect(find.text('播放器选择'), findsOneWidget);
    expect(find.text('通用设置'), findsOneWidget);
    expect(find.text('短剧区风格'), findsNothing);
    expect(find.text('点播区 UI 风格'), findsNothing);
    expect(find.text('解析接口'), findsNothing);
    expect(find.text('内容源管理'), findsNothing);
    expect(find.text('未成年保护'), findsNothing);
  });
}
