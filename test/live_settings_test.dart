// 直播设置挪进软件设置页的断言：偏好模型存取、设置页「直播
// 设置」节三项都在、改解码模式偏好真变（落盘 + 详情刷新）、
// 直播控制器跟随同一份偏好（构造读已存值、改偏好立刻应用、
// 睡眠默认时长真给计时器起算）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/live_playback.dart';
import 'package:moyi/live_repository.dart';
import 'package:moyi/live_settings.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LiveSettingsStore.instance.resetForTest();
  });

  test('偏好模型：默认值是自动解码、睡眠关闭', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final loaded = await LiveSettings.load(prefs);
    expect(loaded.decoderMode, LiveDecoderMode.auto);
    expect(loaded.sleepMinutes, 0);
    expect(loaded.sleepLabel, '关闭');
    expect(loaded.isDefault, isTrue);
  });

  test('偏好模型：保存后再读回原样；非法睡眠时长回落关闭', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const settings = LiveSettings(
      decoderMode: LiveDecoderMode.software,
      sleepMinutes: 60,
    );
    await settings.save(prefs);
    final loaded = await LiveSettings.load(prefs);
    expect(loaded.decoderMode, LiveDecoderMode.software);
    expect(loaded.sleepMinutes, 60);
    expect(loaded.sleepLabel, '60 分钟');
    expect(loaded.isDefault, isFalse);

    SharedPreferences.setMockInitialValues({LiveSettings.keySleepMinutes: 45});
    final prefs2 = await SharedPreferences.getInstance();
    final loaded2 = await LiveSettings.load(prefs2);
    expect(loaded2.sleepMinutes, 0);
  });

  test('偏好存储：改值落盘、恢复默认有改动才报改动', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = LiveSettingsStore.instance;
    await store.ensureLoaded();
    expect(await store.resetDefaults(), isFalse);
    await store.setDecoderMode(LiveDecoderMode.hardware);
    await store.setSleepMinutes(30);
    expect(
      prefs.getString(LiveSettings.keyDecoderMode),
      LiveDecoderMode.hardware.name,
    );
    expect(prefs.getInt(LiveSettings.keySleepMinutes), 30);
    expect(await store.resetDefaults(), isTrue);
    expect(store.settings.isDefault, isTrue);
    expect(prefs.getString(LiveSettings.keyDecoderMode), 'auto');
    expect(prefs.getInt(LiveSettings.keySleepMinutes), 0);
  });

  test('直播控制器跟随偏好：构造读已存值、改偏好立刻应用', () async {
    SharedPreferences.setMockInitialValues({
      LiveSettings.keyDecoderMode: 'hardware',
      LiveSettings.keySleepMinutes: 30,
    });
    final store = LiveSettingsStore.instance;
    await store.ensureLoaded();
    final playback = LivePlaybackController(repository: LiveRepository());
    addTearDown(playback.dispose);
    // 已存的解码模式构造时就生效，睡眠默认时长已给计时器起算。
    expect(playback.decoderMode, LiveDecoderMode.hardware);
    expect(playback.sleepTimer.active, isTrue);
    // 设置页那边改偏好，正在跑的控制器立刻跟着变。
    await store.setDecoderMode(LiveDecoderMode.software);
    expect(playback.decoderMode, LiveDecoderMode.software);
    await store.setSleepMinutes(0);
    expect(playback.sleepTimer.active, isFalse);
    await store.setSleepMinutes(15);
    expect(playback.sleepTimer.active, isTrue);
    await store.setSleepMinutes(0);
    expect(playback.sleepTimer.active, isFalse);
  });

  Future<LocalStore> pumpSettings(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    LiveSettingsStore.instance.resetForTest();
    final store = LocalStore(await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: SettingsScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pump();
    return store;
  }

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
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('设置页直播设置节：解码、睡眠、恢复默认三项都在', (tester) async {
    await pumpSettings(tester);
    await reveal(tester, 'live-decoder-entry');
    expect(find.text('直播设置'), findsOneWidget);
    expect(find.byKey(const ValueKey('live-decoder-entry')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-sleep-entry')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-reset-entry')), findsOneWidget);
    expect(find.textContaining('当前：自动'), findsOneWidget);
    expect(find.textContaining('当前：关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置页改解码模式：偏好真变、详情跟着刷新', (tester) async {
    await pumpSettings(tester);
    await reveal(tester, 'live-decoder-entry');
    await tester.tap(find.byKey(const ValueKey('live-decoder-entry')));
    await settle(tester);
    // 选项与原齿轮单一致：自动/硬解/软解三项。
    expect(find.text('自动'), findsOneWidget);
    expect(find.text('硬解'), findsOneWidget);
    expect(find.text('软解'), findsOneWidget);
    await tester.tap(find.text('硬解'));
    await settle(tester);
    final store = LiveSettingsStore.instance;
    expect(store.settings.decoderMode, LiveDecoderMode.hardware);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(LiveSettings.keyDecoderMode),
      LiveDecoderMode.hardware.name,
    );
    await reveal(tester, 'live-decoder-entry');
    expect(find.textContaining('当前：硬解'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置页睡眠定时可选时长、恢复默认还原并提示', (tester) async {
    await pumpSettings(tester);
    await reveal(tester, 'live-sleep-entry');
    await tester.tap(find.byKey(const ValueKey('live-sleep-entry')));
    await settle(tester);
    // 时长选项与原齿轮单一致：关闭/15/30/60/90 分钟。
    for (final label in ['关闭', '15 分钟', '30 分钟', '60 分钟', '90 分钟']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('30 分钟'));
    await settle(tester);
    final store = LiveSettingsStore.instance;
    expect(store.settings.sleepMinutes, 30);
    await reveal(tester, 'live-reset-entry');
    expect(find.textContaining('当前：30 分钟'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('live-reset-entry')));
    await settle(tester);
    expect(store.settings.isDefault, isTrue);
    expect(find.text('已恢复默认设置'), findsOneWidget);
    // 通知气泡 3 秒后自动关：把时间泵过去免得留挂起计时器。
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}
