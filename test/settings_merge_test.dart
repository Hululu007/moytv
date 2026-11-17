import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/plugin_market_screen.dart';
import 'package:moyi/settings_screen.dart';
import 'package:moyi/xigua/playback_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> pumpSettings(
    WidgetTester tester, {
    VoidCallback? onHideAdult,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: SettingsScreen(
          repository: FixtureRepository(),
          store: store,
          onHideAdult: onHideAdult,
        ),
      ),
    );
    await tester.pump();
    return store;
  }

  /// 拖动设置列表直到目标项建出来：ListView 懒构建，折叠处之下的项
  /// 尚不存在于树里，scrollUntilVisible 会因取 .single 抛“无元素”。
  Future<void> reveal(WidgetTester tester, String keyName) async {
    final target = find.byKey(ValueKey(keyName));
    for (var i = 0; i < 15 && target.evaluate().isEmpty; i++) {
      await tester.drag(
        find.byKey(const ValueKey('settings-list')),
        const Offset(0, -500),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  testWidgets('generic settings carry all four merged entries', (
    tester,
  ) async {
    await pumpSettings(tester, onHideAdult: () {});
    // 顺序须与页面自上而下一致：reveal 只向下拖，找过下面再回头
    // 找上面的项时该项已滑出构建范围、树里不存在。
    // 内容源管理入口已搬到站点选择弹窗 + 号，不在设置里。
    for (final keyName in [
      'playback-settings-entry',
      'player-entry',
      'parse-settings-entry',
      'minor-protection-entry',
    ]) {
      await reveal(tester, keyName);
      expect(find.byKey(ValueKey(keyName)), findsOneWidget);
    }
  });

  testWidgets('minor protection entry only shows with the callback', (
    tester,
  ) async {
    await pumpSettings(tester);
    expect(
      find.byKey(const ValueKey('minor-protection-entry')),
      findsNothing,
    );
  });

  testWidgets('minor protection tap runs the callback', (tester) async {
    var hidden = 0;
    await pumpSettings(tester, onHideAdult: () => hidden++);
    await reveal(tester, 'minor-protection-entry');
    await tester.tap(find.byKey(const ValueKey('minor-protection-entry')));
    await tester.pump();
    expect(hidden, 1);
  });

  testWidgets('playback settings entry opens its sub page', (tester) async {
    await pumpSettings(tester, onHideAdult: () {});
    await reveal(tester, 'playback-settings-entry');
    await tester.tap(find.byKey(const ValueKey('playback-settings-entry')));
    await settle(tester);
    expect(find.byType(PlaybackSettingsScreen), findsOneWidget);
  });

  testWidgets('plugin market entry lives in generic settings', (
    tester,
  ) async {
    await pumpSettings(tester, onHideAdult: () {});
    await reveal(tester, 'plugin-market-entry');
    await tester.tap(find.byKey(const ValueKey('plugin-market-entry')));
    await settle(tester);
    expect(find.byType(PluginMarketScreen), findsOneWidget);
  });

  testWidgets('generic settings have no miniapp group left', (tester) async {
    await pumpSettings(tester, onHideAdult: () {});
    expect(find.text('小程序'), findsNothing);
  });
}
