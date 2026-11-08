import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:moyi/xigua/player_interactions.dart';

import 'player_fixtures.dart';

void main() {
  test('xigua left half slow vertical drag adjusts brightness', () async {
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    await platform.open(Media('https://media.test/working.mp4'));
    final brightness = <double>[];
    var episodes = 0;
    final interactions = PlayerInteractions(
      player: player,
      available: () => true,
      baseSpeed: () => 1,
      holdSpeed: () => 2,
      swipeSeek: () => 60,
      onTogglePlayback: () {},
      onFullscreen: () {},
      onEpisode: (_) {
        episodes++;
        return '';
      },
      onBrightness: (value) async => brightness.add(value),
      currentBrightness: () => .5,
    );

    interactions.pointerDown(
      PointerDownEvent(
        pointer: 1,
        position: const Offset(100, 200),
        buttons: kPrimaryButton,
        kind: PointerDeviceKind.touch,
        timeStamp: Duration.zero,
      ),
      swipeEnabled: true,
      height: 400,
      width: 800,
    );
    for (var step = 1; step <= 3; step++) {
      interactions.pointerMove(
        PointerMoveEvent(
          pointer: 1,
          position: Offset(100, 200 - step * 40),
          buttons: kPrimaryButton,
          kind: PointerDeviceKind.touch,
          timeStamp: Duration(milliseconds: 120 * step),
        ),
      );
    }
    expect(brightness, isNotEmpty, reason: '慢速左半屏垂直拖动应触发亮度调整');
    expect(brightness.first, greaterThan(.5));
    expect(interactions.feedback, contains('亮度'));
    interactions.pointerUp(
      PointerUpEvent(
        pointer: 1,
        position: const Offset(100, 80),
        timeStamp: const Duration(milliseconds: 400),
      ),
    );
    expect(episodes, 0, reason: '亮度拖拽不应误触发切集');

    // 快速竖直 flick 仍走切集。
    interactions.pointerDown(
      PointerDownEvent(
        pointer: 2,
        position: const Offset(100, 200),
        buttons: kPrimaryButton,
        kind: PointerDeviceKind.touch,
        timeStamp: const Duration(seconds: 1),
      ),
      swipeEnabled: true,
      height: 400,
      width: 800,
    );
    for (var step = 1; step <= 3; step++) {
      interactions.pointerMove(
        PointerMoveEvent(
          pointer: 2,
          position: Offset(100, 200 - step * 50),
          buttons: kPrimaryButton,
          kind: PointerDeviceKind.touch,
          timeStamp:
              const Duration(seconds: 1) + Duration(milliseconds: 60 * step),
        ),
      );
    }
    interactions.pointerUp(
      PointerUpEvent(
        pointer: 2,
        position: const Offset(100, 50),
        timeStamp: const Duration(milliseconds: 1200),
      ),
    );
    expect(episodes, 1, reason: '快速上滑应仍切下一集');
    await player.dispose();
  });

  test('xigua 竖直慢拖起手带水平抖动应进亮度而非误锁进度拖拽', () async {
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    await platform.open(Media('https://media.test/working.mp4'));
    final brightness = <double>[];
    final interactions = PlayerInteractions(
      player: player,
      available: () => true,
      baseSpeed: () => 1,
      holdSpeed: () => 2,
      swipeSeek: () => 60,
      onTogglePlayback: () {},
      onFullscreen: () {},
      onEpisode: (_) => '',
      onBrightness: (value) async => brightness.add(value),
      currentBrightness: () => .5,
    );

    interactions.pointerDown(
      PointerDownEvent(
        pointer: 1,
        position: const Offset(100, 200),
        buttons: kPrimaryButton,
        kind: PointerDeviceKind.touch,
        timeStamp: Duration.zero,
      ),
      swipeEnabled: true,
      height: 400,
      width: 800,
    );
    // 起手帧近水平抖动（dx 15 > dy 8 的 1.5 倍）：旧逻辑会误进进度拖拽并锁死 _seeking，
    // 导致后续竖直慢拖再也进不了亮度分支。
    interactions.pointerMove(
      PointerMoveEvent(
        pointer: 1,
        position: const Offset(115, 192),
        buttons: kPrimaryButton,
        kind: PointerDeviceKind.touch,
        timeStamp: const Duration(milliseconds: 120),
      ),
    );
    // 继续竖直慢拖，elapsed 越过 260ms。
    interactions.pointerMove(
      PointerMoveEvent(
        pointer: 1,
        position: const Offset(113, 160),
        buttons: kPrimaryButton,
        kind: PointerDeviceKind.touch,
        timeStamp: const Duration(milliseconds: 300),
      ),
    );
    interactions.pointerMove(
      PointerMoveEvent(
        pointer: 1,
        position: const Offset(110, 120),
        buttons: kPrimaryButton,
        kind: PointerDeviceKind.touch,
        timeStamp: const Duration(milliseconds: 480),
      ),
    );

    expect(
      interactions.seeking,
      isFalse,
      reason: '近水平起手抖动不应误锁进度拖拽（需 dx 绝对位移超阈值才进 seek）',
    );
    expect(brightness, isNotEmpty, reason: '竖直慢拖应激活亮度调整');
    expect(brightness.first, greaterThan(.5));
    expect(interactions.feedback, contains('亮度'));
    await player.dispose();
  });
}
