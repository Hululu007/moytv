import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/xigua/playback_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 播放设置页「去广告」开关：与播放器菜单里的开关共用
// PlaybackPreferences.adBlock（默认开），拨动后立即落盘。
void main() {
  Future<LocalStore> freshStore() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  testWidgets('去广告开关默认开，拨动后写入偏好', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = await freshStore();
    expect(store.playbackPreferences.adBlock, isTrue);
    await tester.pumpWidget(
      MaterialApp(home: PlaybackSettingsScreen(store: store)),
    );
    await tester.pump();
    final tile = find.byKey(const ValueKey('settings-adblock-switch'));
    await tester.scrollUntilVisible(tile, 200);
    await tester.pump();
    expect(tile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    await tester.tap(tile);
    await tester.pump();
    expect(store.playbackPreferences.adBlock, isFalse);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.tap(tile);
    await tester.pump();
    expect(store.playbackPreferences.adBlock, isTrue);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
  });

  testWidgets('已保存为关时开关显示关', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = await freshStore();
    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(adBlock: false),
    );
    await tester.pumpWidget(
      MaterialApp(home: PlaybackSettingsScreen(store: store)),
    );
    await tester.pump();
    final tile = find.byKey(const ValueKey('settings-adblock-switch'));
    await tester.scrollUntilVisible(tile, 200);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
  });
}
