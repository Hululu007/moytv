import 'package:flutter_test/flutter_test.dart';

import 'package:moyi/watchroom/player.dart';

void main() {
  group('roomPlayerReachedEnd', () {
    test('fires within the last second while playing', () {
      expect(
        roomPlayerReachedEnd(
          positionSeconds: 89,
          durationSeconds: 90,
          playing: true,
        ),
        isTrue,
      );
      expect(
        roomPlayerReachedEnd(
          positionSeconds: 89.5,
          durationSeconds: 90,
          playing: true,
        ),
        isTrue,
      );
    });

    test('does not fire before the last second', () {
      expect(
        roomPlayerReachedEnd(
          positionSeconds: 88.9,
          durationSeconds: 90,
          playing: true,
        ),
        isFalse,
      );
    });

    test('does not fire when paused', () {
      expect(
        roomPlayerReachedEnd(
          positionSeconds: 89.5,
          durationSeconds: 90,
          playing: false,
        ),
        isFalse,
      );
    });

    test('does not fire for very short or unknown durations', () {
      expect(
        roomPlayerReachedEnd(
          positionSeconds: 4.5,
          durationSeconds: 4.5,
          playing: true,
        ),
        isFalse,
      );
      expect(
        roomPlayerReachedEnd(
          positionSeconds: 100,
          durationSeconds: double.infinity,
          playing: true,
        ),
        isFalse,
      );
      expect(
        roomPlayerReachedEnd(
          positionSeconds: 10,
          durationSeconds: 0,
          playing: true,
        ),
        isFalse,
      );
    });
  });

  group('RoomPlayerHandle.fireCompleted', () {
    test('fires once per video key and again for the next episode', () {
      final handle = RoomPlayerHandle();
      addTearDown(handle.dispose);
      var calls = 0;
      handle.onCompleted = () => calls++;

      // 未开播（videoKey 为空）时不触发。
      handle.fireCompleted();
      expect(calls, 0);

      handle.videoKey = 'drama|0';
      handle.fireCompleted();
      expect(calls, 1);
      // 同一集里位置兜底与完播流都到，也只触发一次，不跳集。
      handle.fireCompleted();
      expect(calls, 1);

      // 下一集换了 videoKey，可以再触发。
      handle.videoKey = 'drama|1';
      handle.fireCompleted();
      expect(calls, 2);
    });
  });
}
