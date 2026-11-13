import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/audio_background.dart';
import 'package:moyi/audio_media_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('moyi/audio_media');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  Object? Function(MethodCall call)? handler;

  setUp(() {
    calls.clear();
    handler = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final h = handler;
      if (h == null) return true;
      return h(call);
    });
    AudioMediaSession.setActionHandler(null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    AudioMediaSession.setActionHandler(null);
  });

  AudioLockscreenInfo info() {
    return const AudioLockscreenInfo(
      bookTitle: '测试书',
      chapterTitle: '第 3 集',
      coverUrl: 'https://example.com/cover.jpg',
      playing: true,
      positionMs: 61000,
      durationMs: 1800000,
      hasPrevious: true,
      hasNext: false,
      rate: 1.0,
    );
  }

  test('publish 把六项载荷原样发给原生侧', () async {
    expect(await AudioMediaSession.publish(info()), isTrue);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'publish');
    final args = calls.single.arguments as Map;
    expect(args['bookTitle'], '测试书');
    expect(args['chapterTitle'], '第 3 集');
    expect(args['coverUrl'], 'https://example.com/cover.jpg');
    expect(args['playing'], isTrue);
    expect(args['positionMs'], 61000);
    expect(args['durationMs'], 1800000);
    expect(args['hasPrevious'], isTrue);
    expect(args['hasNext'], isFalse);
  });

  test('updateState 只发播放态与进度', () async {
    expect(
      await AudioMediaSession.updateState(
        playing: false,
        positionMs: 120000,
        durationMs: 1800000,
        rate: 2.0,
      ),
      isTrue,
    );
    expect(calls.single.method, 'updateState');
    final args = calls.single.arguments as Map;
    expect(args, hasLength(4));
    expect(args['playing'], isFalse);
    expect(args['positionMs'], 120000);
    expect(args['durationMs'], 1800000);
    expect(args['rate'], 2.0);
  });

  test('updateState 负数与非数倍速先钳好再发', () async {
    await AudioMediaSession.updateState(
      playing: true,
      positionMs: -1,
      durationMs: -1,
      rate: double.nan,
    );
    final args = calls.single.arguments as Map;
    expect(args['positionMs'], 0);
    expect(args['durationMs'], 0);
    expect(args['rate'], 1.0);
  });

  test('release 发 release', () async {
    expect(await AudioMediaSession.release(), isTrue);
    expect(calls.single.method, 'release');
  });

  test('原生侧抛错时返回 false，不抛给调用方', () async {
    handler = (_) => throw PlatformException(code: 'boom');
    expect(await AudioMediaSession.publish(info()), isFalse);
    expect(
      await AudioMediaSession.updateState(
        playing: true,
        positionMs: 0,
        durationMs: 0,
        rate: 1.0,
      ),
      isFalse,
    );
    expect(await AudioMediaSession.release(), isFalse);
  });

  test('原生侧返回 null 时按 false 处理', () async {
    handler = (_) => null;
    expect(await AudioMediaSession.publish(info()), isFalse);
    expect(await AudioMediaSession.release(), isFalse);
  });

  Future<void> sendMediaAction(Object? arguments) {
    return messenger.handlePlatformMessage(
      'moyi/audio_media',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('mediaAction', arguments),
      ),
      (_) {},
    );
  }

  test('锁屏按键分发给注册的处理函数', () async {
    final received = <String>[];
    AudioMediaSession.setActionHandler(received.add);
    for (final action in ['play', 'pause', 'previous', 'next']) {
      await sendMediaAction({'action': action});
    }
    expect(received, ['play', 'pause', 'previous', 'next']);
  });

  test('未注册处理函数时按键不抛错', () async {
    await sendMediaAction({'action': 'pause'});
  });

  test('未知方法与非字符串按键被忽略', () async {
    final received = <String>[];
    AudioMediaSession.setActionHandler(received.add);
    await messenger.handlePlatformMessage(
      'moyi/audio_media',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('somethingElse', {'action': 'play'}),
      ),
      (_) {},
    );
    await sendMediaAction({'action': 42});
    await sendMediaAction('pause');
    expect(received, isEmpty);
  });
}
