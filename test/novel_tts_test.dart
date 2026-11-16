// FlutterTtsNovelTtsEngine：speak 返回值判失败、中文语音检测。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/novel_tts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_tts');

  dynamic speakResult = 1;
  dynamic installedResult;
  Object? installedError;
  dynamic languagesResult = const <String>[];
  Object? languagesError;

  setUp(() {
    speakResult = 1;
    installedResult = null;
    installedError = null;
    languagesResult = const <String>[];
    languagesError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'speak':
              return speakResult;
            case 'isLanguageInstalled':
              if (installedError != null) throw installedError!;
              return installedResult;
            case 'getLanguages':
              if (languagesError != null) throw languagesError!;
              return languagesResult;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('speak 平台返回 1 不抛错', () async {
    final engine = FlutterTtsNovelTtsEngine();
    var completed = false;
    await engine.speak('你好', () => completed = true);
    expect(completed, isFalse);
  });

  test('speak 平台返回 0 抛错', () async {
    speakResult = 0;
    final engine = FlutterTtsNovelTtsEngine();
    await expectLater(
      engine.speak('你好', () {}),
      throwsA(isA<StateError>()),
    );
  });

  test('speak 平台返回 false 抛错', () async {
    speakResult = false;
    final engine = FlutterTtsNovelTtsEngine();
    await expectLater(
      engine.speak('你好', () {}),
      throwsA(isA<StateError>()),
    );
  });

  test('装机检查报中文已装则有中文语音', () async {
    installedResult = true;
    final engine = FlutterTtsNovelTtsEngine();
    expect(await engine.hasChineseVoice(), isTrue);
  });

  test('装机检查否且语言列表无中文则明确没有', () async {
    installedResult = false;
    languagesResult = ['en-US', 'fr-FR'];
    final engine = FlutterTtsNovelTtsEngine();
    expect(await engine.hasChineseVoice(), isFalse);
  });

  test('语言列表里有 zh_CN 也算有中文语音', () async {
    installedResult = false;
    languagesResult = ['en-US', 'zh_CN'];
    final engine = FlutterTtsNovelTtsEngine();
    expect(await engine.hasChineseVoice(), isTrue);
  });

  test('两项检查都查出错时放行（未知不拦）', () async {
    installedError = PlatformException(code: 'err');
    languagesError = PlatformException(code: 'err');
    final engine = FlutterTtsNovelTtsEngine();
    expect(await engine.hasChineseVoice(), isTrue);
  });

  test('语言列表为空时放行（未知不拦）', () async {
    installedResult = false;
    languagesResult = const <String>[];
    final engine = FlutterTtsNovelTtsEngine();
    expect(await engine.hasChineseVoice(), isTrue);
  });
}
