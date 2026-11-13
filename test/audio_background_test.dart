import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/audio_background.dart';

void main() {
  group('isAudioBackgroundState', () {
    test('paused 与 hidden 算后台', () {
      expect(isAudioBackgroundState(AppLifecycleState.paused), isTrue);
      expect(isAudioBackgroundState(AppLifecycleState.hidden), isTrue);
    });

    test('resumed、inactive、detached 不算后台', () {
      expect(isAudioBackgroundState(AppLifecycleState.resumed), isFalse);
      expect(isAudioBackgroundState(AppLifecycleState.inactive), isFalse);
      expect(isAudioBackgroundState(AppLifecycleState.detached), isFalse);
    });
  });

  group('ManualPauseTracker', () {
    test('初始未手动暂停', () {
      expect(ManualPauseTracker().manuallyPaused, isFalse);
    });

    test('用户暂停后标记置起，用户播放后清掉', () {
      final tracker = ManualPauseTracker();
      tracker.userPaused();
      expect(tracker.manuallyPaused, isTrue);
      tracker.userPlayed();
      expect(tracker.manuallyPaused, isFalse);
    });

    test('停止后标记置起，再播放清掉', () {
      final tracker = ManualPauseTracker();
      tracker.stopped();
      expect(tracker.manuallyPaused, isTrue);
      tracker.userPlayed();
      expect(tracker.manuallyPaused, isFalse);
    });

    test('多次暂停播放来回切换状态一致', () {
      final tracker = ManualPauseTracker();
      tracker.userPaused();
      tracker.userPaused();
      expect(tracker.manuallyPaused, isTrue);
      tracker.userPlayed();
      tracker.userPlayed();
      expect(tracker.manuallyPaused, isFalse);
    });
  });

  group('shouldAutoPlayOnResume', () {
    test('四种组合一律不自动恢复播放', () {
      for (final manuallyPaused in [false, true]) {
        for (final wasPlaying in [false, true]) {
          expect(
            shouldAutoPlayOnResume(
              manuallyPaused: manuallyPaused,
              wasPlaying: wasPlaying,
            ),
            isFalse,
            reason:
                'manuallyPaused=$manuallyPaused wasPlaying=$wasPlaying 时也不许自动播',
          );
        }
      }
    });
  });

  group('capsuleShouldShow', () {
    test('后台 + 在播 + 有权限才显示', () {
      expect(
        capsuleShouldShow(
          backgrounded: true,
          playing: true,
          overlayGranted: true,
        ),
        isTrue,
      );
    });

    test('任一条件不满足都不显示', () {
      expect(
        capsuleShouldShow(
          backgrounded: false,
          playing: true,
          overlayGranted: true,
        ),
        isFalse,
        reason: '前台不显示胶囊',
      );
      expect(
        capsuleShouldShow(
          backgrounded: true,
          playing: false,
          overlayGranted: true,
        ),
        isFalse,
        reason: '暂停时不显示胶囊',
      );
      expect(
        capsuleShouldShow(
          backgrounded: true,
          playing: true,
          overlayGranted: false,
        ),
        isFalse,
        reason: '权限拿不到时降级，只留通知栏控制',
      );
      expect(
        capsuleShouldShow(
          backgrounded: false,
          playing: false,
          overlayGranted: false,
        ),
        isFalse,
      );
    });
  });

  group('AudioLockscreenInfo', () {
    AudioLockscreenInfo info({
      String bookTitle = '测试书',
      String chapterTitle = '第 3 集',
      String coverUrl = 'https://example.com/cover.jpg',
      bool playing = true,
      int positionMs = 61000,
      int durationMs = 1800000,
      bool hasPrevious = true,
      bool hasNext = true,
      double rate = 1.5,
    }) {
      return AudioLockscreenInfo(
        bookTitle: bookTitle,
        chapterTitle: chapterTitle,
        coverUrl: coverUrl,
        playing: playing,
        positionMs: positionMs,
        durationMs: durationMs,
        hasPrevious: hasPrevious,
        hasNext: hasNext,
        rate: rate,
      );
    }

    test('载荷键固定为 9 个，不多带字段', () {
      final payload = info().toChannelPayload();
      expect(payload.keys.toSet(), {
        'bookTitle',
        'chapterTitle',
        'coverUrl',
        'playing',
        'positionMs',
        'durationMs',
        'hasPrevious',
        'hasNext',
        'rate',
      });
    });

    test('六项原值透传', () {
      final payload = info().toChannelPayload();
      expect(payload['bookTitle'], '测试书');
      expect(payload['chapterTitle'], '第 3 集');
      expect(payload['coverUrl'], 'https://example.com/cover.jpg');
      expect(payload['playing'], isTrue);
      expect(payload['positionMs'], 61000);
      expect(payload['durationMs'], 1800000);
      expect(payload['hasPrevious'], isTrue);
      expect(payload['hasNext'], isTrue);
      expect(payload['rate'], 1.5);
    });

    test('进度超过总时长时钳到总时长', () {
      final payload = info(
        positionMs: 2000000,
        durationMs: 1800000,
      ).toChannelPayload();
      expect(payload['positionMs'], 1800000);
    });

    test('负数进度与负数时长钳到 0', () {
      final payload = info(positionMs: -5, durationMs: -10).toChannelPayload();
      expect(payload['positionMs'], 0);
      expect(payload['durationMs'], 0);
    });

    test('倍速钳在 0.25 到 4 之间，非数回落 1', () {
      expect(info(rate: 0.1).toChannelPayload()['rate'], 0.25);
      expect(info(rate: 9.0).toChannelPayload()['rate'], 4.0);
      expect(info(rate: double.nan).toChannelPayload()['rate'], 1.0);
      expect(info(rate: double.infinity).toChannelPayload()['rate'], 1.0);
    });

    test('空封面与空标题原样透传，不编假值', () {
      final payload = info(
        bookTitle: '',
        chapterTitle: '',
        coverUrl: '',
      ).toChannelPayload();
      expect(payload['bookTitle'], '');
      expect(payload['chapterTitle'], '');
      expect(payload['coverUrl'], '');
    });
  });
}
