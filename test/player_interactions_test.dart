import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:moyi/player_interactions.dart';

import 'player_fixtures.dart';

void main() {
  test('touching the right side temporarily boosts playback', () async {
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    await platform.open(Media('https://media.test/working.mp4'));
    final interactions = PlayerInteractions(
      player: player,
      available: () => true,
      baseSpeed: () => 1.5,
      onTogglePlayback: () {},
      onFullscreen: () {},
      onEpisode: (_) => '',
    );

    interactions.pointerDown(
      PointerDownEvent(
        pointer: 1,
        position: const Offset(90, 50),
        buttons: kPrimaryButton,
        kind: PointerDeviceKind.touch,
        timeStamp: Duration.zero,
      ),
      swipeEnabled: true,
      height: 100,
      width: 100,
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(platform.rates, contains(2));
    expect(interactions.feedback, isEmpty);

    interactions.pointerUp(
      PointerUpEvent(
        pointer: 1,
        position: const Offset(90, 50),
        buttons: 0,
        kind: PointerDeviceKind.touch,
        timeStamp: const Duration(milliseconds: 400),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(platform.rates.last, 1.5);
    expect(interactions.feedback, isEmpty);

    interactions.dispose();
    await player.dispose();
  });

  test('center touch keeps the existing temporary boost behavior', () async {
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    await platform.open(Media('https://media.test/working.mp4'));
    final interactions = PlayerInteractions(
      player: player,
      available: () => true,
      baseSpeed: () => 1,
      onTogglePlayback: () {},
      onFullscreen: () {},
      onEpisode: (_) => '',
    );

    interactions.pointerDown(
      PointerDownEvent(
        pointer: 1,
        position: const Offset(50, 50),
        buttons: kPrimaryButton,
        kind: PointerDeviceKind.touch,
        timeStamp: Duration.zero,
      ),
      swipeEnabled: true,
      height: 100,
      width: 100,
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(platform.rates, contains(2));
    expect(interactions.feedback, isEmpty);

    interactions.pointerCancel(
      PointerCancelEvent(
        pointer: 1,
        position: const Offset(50, 50),
        buttons: 0,
        kind: PointerDeviceKind.touch,
        timeStamp: const Duration(milliseconds: 400),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    interactions.dispose();
    await player.dispose();
  });

  test(
    'seek shows no overlay and reveals no controls while volume hints do',
    () async {
      final platform = ScriptedPlayer();
      final player = Player(platformPlayer: platform);
      await platform.open(Media('https://media.test/working.mp4'));
      final interactions = PlayerInteractions(
        player: player,
        available: () => true,
        baseSpeed: () => 1,
        onTogglePlayback: () {},
        onFullscreen: () {},
        onEpisode: (_) => '',
      );

      interactions.seek(5);
      await Future<void>.delayed(Duration.zero);
      expect(interactions.feedback, isEmpty);
      expect(interactions.feedbackRevealsControls, isFalse);

      interactions.seek(-5);
      await Future<void>.delayed(Duration.zero);
      expect(interactions.feedback, isEmpty);
      expect(interactions.feedbackRevealsControls, isFalse);

      interactions.changeVolume(5);
      expect(interactions.feedbackRevealsControls, isTrue);

      interactions.dispose();
      await player.dispose();
    },
  );

  test('horizontal drag seeks forward and backward by drag distance', () async {
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    await platform.open(Media('https://media.test/working.mp4'));
    final interactions = PlayerInteractions(
      player: player,
      available: () => true,
      baseSpeed: () => 1,
      onTogglePlayback: () {},
      onFullscreen: () {},
      onEpisode: (_) => '',
      onSeek: (target) async => player.seek(target),
    );

    interactions.pointerDown(
      PointerDownEvent(
        pointer: 1,
        position: const Offset(400, 200),
        buttons: kPrimaryButton,
        kind: PointerDeviceKind.touch,
        timeStamp: Duration.zero,
      ),
      swipeEnabled: true,
      height: 400,
      width: 800,
    );
    for (var step = 1; step <= 4; step++) {
      interactions.pointerMove(
        PointerMoveEvent(
          pointer: 1,
          position: Offset(400 + step * 60, 200),
          buttons: kPrimaryButton,
          kind: PointerDeviceKind.touch,
          timeStamp: Duration(milliseconds: 100 * step),
        ),
      );
    }
    expect(interactions.feedback, contains('/'));
    interactions.pointerUp(
      PointerUpEvent(
        pointer: 1,
        position: const Offset(640, 200),
        buttons: 0,
        kind: PointerDeviceKind.touch,
        timeStamp: const Duration(milliseconds: 420),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    // 向右拖 240/800 屏宽 → 全幅 2 分钟的 30% → 前进 36 秒。
    expect(player.state.position, const Duration(seconds: 36));

    interactions.pointerDown(
      PointerDownEvent(
        pointer: 2,
        position: const Offset(400, 200),
        buttons: kPrimaryButton,
        kind: PointerDeviceKind.touch,
        timeStamp: Duration.zero,
      ),
      swipeEnabled: true,
      height: 400,
      width: 800,
    );
    interactions.pointerMove(
      PointerMoveEvent(
        pointer: 2,
        position: const Offset(320, 200),
        buttons: kPrimaryButton,
        kind: PointerDeviceKind.touch,
        timeStamp: const Duration(milliseconds: 160),
      ),
    );
    interactions.pointerUp(
      PointerUpEvent(
        pointer: 2,
        position: const Offset(320, 200),
        buttons: 0,
        kind: PointerDeviceKind.touch,
        timeStamp: const Duration(milliseconds: 200),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    // 向左拖 80/800 屏宽 → 后退 12 秒。
    expect(player.state.position, const Duration(seconds: 24));

    interactions.dispose();
    await player.dispose();
  });

  test(
    'left half slow vertical drag adjusts brightness, fast flick switches',
    () async {
      final platform = ScriptedPlayer();
      final player = Player(platformPlayer: platform);
      await platform.open(Media('https://media.test/working.mp4'));
      final brightness = <double>[];
      var episodes = 0;
      final interactions = PlayerInteractions(
        player: player,
        available: () => true,
        baseSpeed: () => 1,
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
      expect(brightness, isNotEmpty);
      expect(brightness.first, greaterThan(.5));
      expect(interactions.feedback, contains('亮度'));
      interactions.pointerUp(
        PointerUpEvent(
          pointer: 1,
          position: const Offset(100, 80),
          buttons: 0,
          kind: PointerDeviceKind.touch,
          timeStamp: const Duration(milliseconds: 380),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(episodes, 0);

      interactions.pointerDown(
        PointerDownEvent(
          pointer: 2,
          position: const Offset(100, 200),
          buttons: kPrimaryButton,
          kind: PointerDeviceKind.touch,
          timeStamp: Duration.zero,
        ),
        swipeEnabled: true,
        height: 400,
        width: 800,
      );
      interactions.pointerMove(
        PointerMoveEvent(
          pointer: 2,
          position: const Offset(100, 90),
          buttons: kPrimaryButton,
          kind: PointerDeviceKind.touch,
          timeStamp: const Duration(milliseconds: 120),
        ),
      );
      interactions.pointerUp(
        PointerUpEvent(
          pointer: 2,
          position: const Offset(100, 90),
          buttons: 0,
          kind: PointerDeviceKind.touch,
          timeStamp: const Duration(milliseconds: 160),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(episodes, 1);

      interactions.dispose();
      await player.dispose();
    },
  );
}
