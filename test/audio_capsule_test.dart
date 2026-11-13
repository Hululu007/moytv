import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/audio_capsule.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('moyi/audio_capsule');
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
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('isPermissionGranted 透传原生侧结果', () async {
    handler = (call) => false;
    expect(await AudioCapsule.isPermissionGranted(), isFalse);
    expect(calls.single.method, 'isPermissionGranted');
  });

  test('ensureService 发 ensureService', () async {
    expect(await AudioCapsule.ensureService(), isTrue);
    expect(calls.single.method, 'ensureService');
  });

  test('show 带书名章节与播放态', () async {
    expect(
      await AudioCapsule.show(title: '测试书', chapter: '第 3 集', playing: true),
      isTrue,
    );
    expect(calls.single.method, 'show');
    final args = calls.single.arguments as Map;
    expect(args['title'], '测试书');
    expect(args['chapter'], '第 3 集');
    expect(args['playing'], isTrue);
  });

  test('hide 与 stop 各发对应方法', () async {
    expect(await AudioCapsule.hide(), isTrue);
    expect(await AudioCapsule.stop(), isTrue);
    expect(calls.map((c) => c.method), ['hide', 'stop']);
  });

  test('isShowing 透传原生侧结果', () async {
    handler = (call) => true;
    expect(await AudioCapsule.isShowing(), isTrue);
    expect(calls.single.method, 'isShowing');
  });

  test('原生侧抛错或返回 null 时一律返回 false', () async {
    handler = (_) => throw PlatformException(code: 'boom');
    expect(await AudioCapsule.isPermissionGranted(), isFalse);
    expect(await AudioCapsule.ensureService(), isFalse);
    expect(
      await AudioCapsule.show(title: 'x', chapter: 'y', playing: true),
      isFalse,
    );
    expect(await AudioCapsule.hide(), isFalse);
    expect(await AudioCapsule.stop(), isFalse);
    expect(await AudioCapsule.isShowing(), isFalse);

    handler = (_) => null;
    expect(await AudioCapsule.isPermissionGranted(), isFalse);
    expect(
      await AudioCapsule.show(title: 'x', chapter: 'y', playing: true),
      isFalse,
    );
  });
}
