import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/playback_preferences.dart';
import 'package:moyi/player_controls.dart';
import 'package:moyi/player_interactions.dart';

import 'player_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<PlayerControls> pumpControls(
    WidgetTester tester, {
    ValueChanged<bool>? onVisibility,
  }) async {
    // 按手机形态测；必须在测试体末尾复位（_verifyInvariants 在
    // 测试体返回后立即跑，tearDown/addTearDown 都赶不上）。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final player = Player(platformPlayer: ScriptedPlayer());
    final interactions = PlayerInteractions(
      player: player,
      available: () => true,
      baseSpeed: () => 1,
      onTogglePlayback: () {},
      onFullscreen: () {},
      onEpisode: (_) => '',
    );
    final controls = PlayerControls(
      player: player,
      interactions: interactions,
      enabled: true,
      fullscreen: false,
      showOnPlaybackReady: true,
      onFullscreen: () {},
      onBack: () {},
      onPrevious: () {},
      onNext: () {},
      title: '测试片',
      onTogglePlayback: () {},
      onEpisodes: () async {},
      onSpeed: () async {},
      onQuality: () async {},
      speed: 1,
      qualityLabel: '自动',
      onFocusSurface: () {},
      swipeEnabled: true,
      orientationMode: PlaybackOrientationMode.auto,
      onOrientationMode: (_) {},
      onControlsVisibilityChanged: onVisibility,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 390, height: 220, child: controls),
        ),
      ),
    );
    await tester.pump();
    return controls;
  }

  testWidgets('顶栏按钮两两不重叠', (tester) async {
    await pumpControls(tester);
    final buttons = [
      find.byTooltip('返回'),
      find.byTooltip('方向控制'),
      find.byTooltip('旋转与全屏'),
    ];
    for (final button in buttons) {
      expect(button, findsOneWidget);
    }
    final rects = buttons.map(tester.getRect).toList();
    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        expect(
          rects[i].overlaps(rects[j]),
          isFalse,
          reason: '顶栏按钮 $i 与 $j 重叠：${rects[i]} vs ${rects[j]}',
        );
      }
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('控制层显隐变化通知宿主', (tester) async {
    final seen = <bool>[];
    await pumpControls(tester, onVisibility: seen.add);
    // 初值经帧后回调发出一次。
    expect(seen, [true]);

    // 点手势面左缘中部（避开中央播放钮与上下控制行）切换显隐。
    final surface = find.byKey(const ValueKey('player-gesture-surface'));
    final origin = tester.getTopLeft(surface);
    await tester.tapAt(origin + const Offset(40, 110));
    await tester.pump(const Duration(milliseconds: 400));
    expect(seen, [true, false]);

    await tester.tapAt(origin + const Offset(40, 110));
    await tester.pump(const Duration(milliseconds: 400));
    expect(seen, [true, false, true]);

    // 值没变时不重复通知。
    await tester.pump(const Duration(milliseconds: 400));
    expect(seen, [true, false, true]);
    debugDefaultTargetPlatformOverride = null;
  });
}
