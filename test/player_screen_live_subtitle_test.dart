import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/exo_subtitle.dart';
import 'package:moyi/live_subtitle_audio.dart';
import 'package:moyi/live_subtitle_engine.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

// 假识别引擎：loadModel 立即完成，transcribeStream 只转发测试里
// 手动喂的段更新；音频流消费掉，避免服务侧背压。
class _FakeLiveSubtitleEngine implements LiveSubtitleEngine {
  final updates = StreamController<LiveSubtitleEngineUpdate>.broadcast();
  bool loadCalled = false;
  bool disposed = false;

  @override
  Future<void> loadModel(String modelId) async {
    loadCalled = true;
  }

  @override
  Stream<LiveSubtitleEngineUpdate> transcribeStream(
    Stream<Uint8List> pcm16Chunks, {
    required String language,
    required bool translate,
  }) {
    unawaited(pcm16Chunks.listen((_) {}).asFuture<void>());
    return updates.stream;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!updates.isClosed) await updates.close();
  }

  @override
  Future<void> deleteModel(String modelId) async {}

  @override
  Future<int?> downloadedModelBytes(String modelId) async => null;

  @override
  Future<void> downloadModel(
    String modelId, {
    void Function(double progress)? onProgress,
    String? mirrorBaseUrl,
  }) async {}

  @override
  Future<LiveSubtitleModelState> modelState(String modelId) async =>
      LiveSubtitleModelState.downloaded;
}

// 假音频取流器：返回一条一直开着的空流，测试不靠它出片，
// 只靠假引擎手动喂段。
class _FakeLiveSubtitleAudioExtractor implements LiveSubtitleAudioExtractor {
  final chunks = StreamController<Uint8List>();

  @override
  Stream<Uint8List> extract({
    required String url,
    required Map<String, String> headers,
  }) => chunks.stream;

  @override
  Future<void> stop() async {
    if (!chunks.isClosed) {
      unawaited(chunks.close());
    }
  }
}

// 测试里不让任何真实 HTTP 跑起来：302 预解析（playback_redirect）
// 在 testWidgets 的假时钟下等不到 mock HttpClient 的响应流关闭，
// _play 会一直卡在“正在准备播放”；这里让请求直接抛错，探头
// fail-open 回原地址，播放链路继续走。翻译的 Google 请求抛错
// 也一样被服务层吞掉，不影响断言。
class _ThrowingHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _ThrowingHttpClient();
}

class _ThrowingHttpClient implements HttpClient {
  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('no network in widget test');
}

Future<void> _pumpPlayer(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: DefaultTextStyle(
        style: const TextStyle(fontFamily: 'PreviewCJK'),
        child: Scaffold(body: screen),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    try {
      await tester.pump(const Duration(milliseconds: 100));
    } catch (_) {}
  }
}

Future<PlayerScreen> _buildPlayer({
  required _FakeLiveSubtitleEngine engine,
  required _FakeLiveSubtitleAudioExtractor extractor,
}) async {
  final store = LocalStore(await SharedPreferences.getInstance());
  final repository = RouteRepository();
  final platform = ScriptedPlayer();
  final detail = await repository.detail(FixtureRepository.free);
  return PlayerScreen(
    detail: detail,
    initialIndex: 0,
    initialPosition: 0,
    repository: repository,
    store: store,
    playerFactory: () => Player(platformPlayer: platform),
    videoBuilder: (controls) => controls,
    liveSubtitleEngine: engine,
    liveSubtitleAudioExtractor: extractor,
  );
}

void main() {
  setUp(() {
    HttpOverrides.global = _ThrowingHttpOverrides();
    addTearDown(() {
      HttpOverrides.global = null;
    });
  });

  setUpAll(() async {
    try {
      final bytes = File(
        '/home/hatch/workspace/huoyi_new/cjk_subset.ttf',
      ).readAsBytesSync();
      final loader = FontLoader('PreviewCJK')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      final fallback = FontLoader('Roboto')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await fallback.load();
    } catch (_) {}
  });

  testWidgets('MPV 核播放时实时字幕行叠在播放器上', (tester) async {
    SharedPreferences.setMockInitialValues({
      'appThemeMode': 'purpleNeon',
      'moyi_live_subtitle_enabled': true,
      'moyi_live_subtitle_model': 'tiny',
      'moyi_live_subtitle_show_original': true,
    });
    final engine = _FakeLiveSubtitleEngine();
    final extractor = _FakeLiveSubtitleAudioExtractor();
    await _pumpPlayer(
      tester,
      await _buildPlayer(engine: engine, extractor: extractor),
    );
    // 等服务起起来（模型加载是假实现，立即完成）。
    var started = false;
    for (var i = 0; i < 40 && !started; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      started = engine.loadCalled;
    }
    expect(started, isTrue, reason: '实时字幕服务没有启动');
    // 假引擎吐一段确认字幕（0–30 秒，播放进度 0 秒正好落在段内）。
    engine.updates.add(
      const LiveSubtitleEngineUpdate(
        newConfirmed: [
          LiveSubtitleRawSegment(
            text: 'こんにちは、元気ですか',
            start: Duration.zero,
            end: Duration(seconds: 30),
          ),
        ],
        partialText: '',
      ),
    );
    await _settle(tester);
    expect(find.byType(ExoSubtitleOverlay), findsOneWidget);
    expect(
      find.textContaining('こんにちは、元気ですか'),
      findsOneWidget,
    );
    final overlay = tester.widget<ExoSubtitleOverlay>(
      find.byType(ExoSubtitleOverlay),
    );
    expect(overlay.lines, contains('こんにちは、元気ですか'));
    // 把播放页换掉走 dispose（停字幕服务、关取流器），再断言无异常。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('总开关关着时不启动实时字幕服务', (tester) async {
    SharedPreferences.setMockInitialValues({
      'appThemeMode': 'purpleNeon',
      'moyi_live_subtitle_enabled': false,
    });
    final engine = _FakeLiveSubtitleEngine();
    final extractor = _FakeLiveSubtitleAudioExtractor();
    await _pumpPlayer(
      tester,
      await _buildPlayer(engine: engine, extractor: extractor),
    );
    await _settle(tester);
    expect(engine.loadCalled, isFalse);
    expect(find.byType(ExoSubtitleOverlay), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
