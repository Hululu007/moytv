import 'package:moyi/player_core.dart';
import 'package:moyi/player_core_fallback.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('classifyPlayerCoreFailure', () {
    test('decode failures', () {
      expect(
        classifyPlayerCoreFailure('解码器初始化失败'),
        CoreFailureKind.decode,
      );
      expect(
        classifyPlayerCoreFailure('Failed to initialize decoder'),
        CoreFailureKind.decode,
      );
      expect(
        classifyPlayerCoreFailure(
          'Playback failed',
          code: 'ERROR_CODE_DECODER_INIT_FAILED',
        ),
        CoreFailureKind.decode,
      );
      expect(
        classifyPlayerCoreFailure('MediaCodec video decoder error'),
        CoreFailureKind.decode,
      );
    });

    test('network failures', () {
      expect(
        classifyPlayerCoreFailure('网络连接超时'),
        CoreFailureKind.network,
      );
      expect(
        classifyPlayerCoreFailure('SocketException: connection reset by peer'),
        CoreFailureKind.network,
      );
      expect(
        classifyPlayerCoreFailure('HTTP error 503'),
        CoreFailureKind.network,
      );
    });

    test('format unsupported wins over codec wording', () {
      expect(
        classifyPlayerCoreFailure('格式不支持：codec 不被支持'),
        CoreFailureKind.formatUnsupported,
      );
      expect(
        classifyPlayerCoreFailure('Unsupported format: no suitable codec'),
        CoreFailureKind.formatUnsupported,
      );
    });

    test('unknown falls back to other', () {
      expect(classifyPlayerCoreFailure('播放接收已取消'), CoreFailureKind.other);
      expect(classifyPlayerCoreFailure(''), CoreFailureKind.other);
    });
  });

  group('fallback order', () {
    test('sequence is circular after the start core', () {
      expect(coreFallbackSequence(PlayerCore.mpv), [
        PlayerCore.exo,
        PlayerCore.ijk,
      ]);
      expect(coreFallbackSequence(PlayerCore.exo), [
        PlayerCore.ijk,
        PlayerCore.mpv,
      ]);
      expect(coreFallbackSequence(PlayerCore.ijk), [
        PlayerCore.mpv,
        PlayerCore.exo,
      ]);
    });

    test('controller never repeats a core and exhausts after all three', () {
      final controller = CoreFallbackController(start: PlayerCore.exo);
      expect(controller.advance(CoreFailureKind.other), PlayerCore.ijk);
      expect(controller.advance(CoreFailureKind.other), PlayerCore.mpv);
      expect(controller.advance(CoreFailureKind.other), isNull);
      expect(controller.attempts, [
        PlayerCore.exo,
        PlayerCore.ijk,
        PlayerCore.mpv,
      ]);
      expect(controller.tried.length, 3);
    });
  });

  group('mode filtering', () {
    test('off never advances', () {
      final controller = CoreFallbackController(
        start: PlayerCore.mpv,
        mode: CoreFallbackMode.off,
      );
      expect(controller.advance(CoreFailureKind.decode), isNull);
      expect(CoreFallbackMode.off.allows(CoreFailureKind.decode), isFalse);
    });

    test('decodeOnly blocks network and other, allows decode and format', () {
      expect(
        CoreFallbackMode.decodeOnly.allows(CoreFailureKind.network),
        isFalse,
      );
      expect(CoreFallbackMode.decodeOnly.allows(CoreFailureKind.other), isFalse);
      expect(CoreFallbackMode.decodeOnly.allows(CoreFailureKind.decode), isTrue);
      expect(
        CoreFallbackMode.decodeOnly.allows(CoreFailureKind.formatUnsupported),
        isTrue,
      );
      final controller = CoreFallbackController(
        start: PlayerCore.mpv,
        mode: CoreFallbackMode.decodeOnly,
      );
      expect(controller.advance(CoreFailureKind.network), isNull);
      expect(controller.attempts, [PlayerCore.mpv]);
    });

    test('playerOnly blocks network but allows core-side failures', () {
      expect(
        CoreFallbackMode.playerOnly.allows(CoreFailureKind.network),
        isFalse,
      );
      expect(CoreFallbackMode.playerOnly.allows(CoreFailureKind.other), isTrue);
      expect(CoreFallbackMode.playerOnly.allows(CoreFailureKind.decode), isTrue);
    });

    test('mode parse defaults to all and storage round-trips', () async {
      expect(CoreFallbackMode.parse(null), CoreFallbackMode.all);
      expect(CoreFallbackMode.parse('bogus'), CoreFallbackMode.all);
      expect(
        CoreFallbackMode.parse('decode_only'),
        CoreFallbackMode.decodeOnly,
      );
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(CoreFallbackModeStorage.read(prefs), CoreFallbackMode.all);
      await CoreFallbackModeStorage.write(prefs, CoreFallbackMode.playerOnly);
      expect(CoreFallbackModeStorage.read(prefs), CoreFallbackMode.playerOnly);
    });
  });

  group('runWithCoreFallback', () {
    test('falls through to the next core and succeeds, keeping position '
        'and episode', () async {
      final seen = <CoreFallbackAttempt>[];
      var livePosition = 12.0;
      final outcome = await runWithCoreFallback<String>(
        start: PlayerCore.mpv,
        mode: CoreFallbackMode.all,
        episodeIndex: 3,
        initialPositionSeconds: 10,
        currentPositionSeconds: () => livePosition,
        attempt: (attempt) async {
          seen.add(attempt);
          if (attempt.core == PlayerCore.mpv) {
            livePosition = 42.5;
            throw const CorePlaybackFailure(
              CoreFailureKind.decode,
              'decoder failed',
            );
          }
          return 'ok';
        },
      );
      expect(outcome.value, 'ok');
      expect(outcome.coreUsed, PlayerCore.exo);
      expect(outcome.attemptedCores, [PlayerCore.mpv, PlayerCore.exo]);
      expect(seen.length, 2);
      expect(seen[1].episodeIndex, 3);
      expect(seen[1].resumePositionSeconds, 42.5);
    });

    test('off mode surfaces the failure without switching cores', () async {
      var calls = 0;
      await expectLater(
        runWithCoreFallback<String>(
          start: PlayerCore.mpv,
          mode: CoreFallbackMode.off,
          episodeIndex: 0,
          initialPositionSeconds: 0,
          attempt: (attempt) async {
            calls++;
            throw const CorePlaybackFailure(
              CoreFailureKind.decode,
              'decoder failed',
            );
          },
        ),
        throwsA(
          isA<CoreFallbackExhausted>()
              .having((e) => e.attemptedCores, 'attempted', [PlayerCore.mpv])
              .having((e) => e.lastKind, 'kind', CoreFailureKind.decode),
        ),
      );
      expect(calls, 1);
    });

    test('decodeOnly mode does not switch on a network failure', () async {
      final cores = <PlayerCore>[];
      await expectLater(
        runWithCoreFallback<String>(
          start: PlayerCore.ijk,
          mode: CoreFallbackMode.decodeOnly,
          episodeIndex: 1,
          initialPositionSeconds: 5,
          attempt: (attempt) async {
            cores.add(attempt.core);
            throw StateError('SocketException: connection reset by peer');
          },
        ),
        throwsA(isA<CoreFallbackExhausted>()),
      );
      expect(cores, [PlayerCore.ijk]);
    });

    test('all cores failing throws and each core is tried exactly once',
        () async {
      final cores = <PlayerCore>[];
      CoreFallbackExhausted? caught;
      try {
        await runWithCoreFallback<String>(
          start: PlayerCore.exo,
          mode: CoreFallbackMode.all,
          episodeIndex: 2,
          initialPositionSeconds: 7,
          attempt: (attempt) async {
            cores.add(attempt.core);
            throw const CorePlaybackFailure(
              CoreFailureKind.other,
              'boom',
            );
          },
        );
      } on CoreFallbackExhausted catch (error) {
        caught = error;
      }
      expect(cores, [PlayerCore.exo, PlayerCore.ijk, PlayerCore.mpv]);
      expect(cores.toSet().length, 3);
      expect(caught, isNotNull);
      expect(caught?.attemptedCores, cores);
      expect(caught?.lastKind, CoreFailureKind.other);
    });
  });
}
