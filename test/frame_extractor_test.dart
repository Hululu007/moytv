import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/frame_extractor.dart';
import 'package:moyi/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('moyi/frame_extractor');
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
      if (h == null) return null;
      return h(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  PlaybackPlan plan() => const PlaybackPlan(
    url: 'http://127.0.0.1:9/x',
    headers: {'Referer': 'https://example.test/'},
  );

  test('原生返回字节：原样返回，参数带地址/头/5 秒位置', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    handler = (_) => bytes;
    final got = await FrameExtractor().extract(plan());
    expect(got, bytes);
    expect(calls.single.method, 'extractFrame');
    final args = calls.single.arguments as Map;
    expect(args['url'], 'http://127.0.0.1:9/x');
    expect(args['headers'], {'Referer': 'https://example.test/'});
    expect(args['positionUs'], 5000000);
  });

  test('原生返回空：返回 null', () async {
    handler = (_) => null;
    expect(await FrameExtractor().extract(plan()), isNull);
  });

  test('原生抛错：返回 null，不抛', () async {
    handler = (_) => throw PlatformException(code: 'frame_error');
    expect(await FrameExtractor().extract(plan()), isNull);
  });

  test('空地址：不调通道，直接返回 null', () async {
    const empty = PlaybackPlan(url: '');
    expect(await FrameExtractor().extract(empty), isNull);
    expect(calls, isEmpty);
  });
}
