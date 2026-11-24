import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/live_subtitle_audio.dart';
import 'package:moyi/live_subtitle_engine.dart';
import 'package:moyi/live_subtitle_service.dart';
import 'package:moyi/live_subtitle_settings.dart';

class FakeLiveSubtitleEngine implements LiveSubtitleEngine {
  FakeLiveSubtitleEngine({this.loadThrows});

  final LiveSubtitleEngineException? loadThrows;
  final updates = StreamController<LiveSubtitleEngineUpdate>.broadcast();
  bool loadCalled = false;
  bool disposed = false;

  @override
  Future<void> loadModel(String modelId) async {
    loadCalled = true;
    if (loadThrows != null) throw loadThrows!;
  }

  @override
  Stream<LiveSubtitleEngineUpdate> transcribeStream(
    Stream<Uint8List> pcm16Chunks, {
    required String language,
  }) {
    // 把音频消费掉，避免服务侧背压；测试只关心段更新。
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

class FakeLiveSubtitleAudioExtractor implements LiveSubtitleAudioExtractor {
  final chunks = StreamController<Uint8List>();

  @override
  Stream<Uint8List> extract({
    required String url,
    required Map<String, String> headers,
  }) => chunks.stream;

  @override
  Future<void> stop() async {
    if (!chunks.isClosed) {
      // 不等 close 的 future：单订阅控制器在无人监听时 close 的
      // future 永不完成（服务在 start() 提前返回时就没监听过），
      // 等它会把 dispose 挂住。
      unawaited(chunks.close());
    }
  }
}

const _testSegment = LiveSubtitleRawSegment(
  text: 'こんにちは',
  start: Duration(seconds: 1),
  end: Duration(seconds: 3),
);

LiveSubtitleService _buildService({
  LiveSubtitleSettings settings = const LiveSubtitleSettings(enabled: true),
  LiveSubtitleEngine? engine,
  LiveSubtitleAudioExtractor? extractor,
}) {
  return LiveSubtitleService(
    settings: settings,
    engine: engine ?? FakeLiveSubtitleEngine(),
    extractor: extractor ?? FakeLiveSubtitleAudioExtractor(),
  );
}

Future<void> _start(LiveSubtitleService service) => service.start(
  url: 'https://example.com/video.m3u8',
  headers: const {},
  startPosition: Duration.zero,
);

void main() {
  test('确认段出原文字幕，播放进度按锚点取字幕', () async {
    final engine = FakeLiveSubtitleEngine();
    final service = _buildService(engine: engine);
    final cues = <LiveSubtitleCue>[];
    service.cueStream.listen(cues.add);
    await _start(service);
    expect(service.state, LiveSubtitleRunState.running);
    expect(engine.loadCalled, isTrue);

    engine.updates.add(
      const LiveSubtitleEngineUpdate(
        newConfirmed: [_testSegment],
        partialText: '',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(cues.length, 1);
    expect(cues.single.original, 'こんにちは');
    expect(cues.single.displayLines(), ['こんにちは']);

    // 起始 0，音频 1~3 秒：播放 2 秒时有字幕，10 秒时没有。
    expect(service.cueAt(const Duration(seconds: 2))?.original, 'こんにちは');
    expect(service.cueAt(const Duration(seconds: 10)), isNull);
    // 段尾放宽 2 秒：4 秒时还在，6 秒时没了。
    expect(service.cueAt(const Duration(seconds: 4)), isNotNull);
    expect(service.cueAt(const Duration(seconds: 6)), isNull);

    await service.stop();
    expect(service.state, LiveSubtitleRunState.idle);
    await service.dispose();
    expect(engine.disposed, isTrue);
  });

  test('总开关关闭时不启动、不加载模型', () async {
    final engine = FakeLiveSubtitleEngine();
    final service = _buildService(
      settings: const LiveSubtitleSettings(enabled: false),
      engine: engine,
    );
    await _start(service);
    expect(service.state, LiveSubtitleRunState.idle);
    expect(engine.loadCalled, isFalse);
    await service.dispose();
  });

  test('模型没下载时报错并提示去设置下载', () async {
    final engine = FakeLiveSubtitleEngine(
      loadThrows: const LiveSubtitleEngineException('模型还没下载，请先下载模型'),
    );
    final service = _buildService(engine: engine);
    await _start(service);
    expect(service.state, LiveSubtitleRunState.error);
    expect(service.statusMessage, contains('设置'));
    await service.dispose();
  });

  test('加密源（播放器侧解密）直接报错不取音轨', () async {
    final engine = FakeLiveSubtitleEngine();
    final service = _buildService(engine: engine);
    await service.start(
      url: 'https://example.com/video.m3u8',
      headers: const {},
      startPosition: Duration.zero,
      encrypted: true,
    );
    expect(service.state, LiveSubtitleRunState.error);
    expect(engine.loadCalled, isFalse);
    await service.dispose();
  });

  test('reanchor 后时间轴按新锚点走', () async {
    final engine = FakeLiveSubtitleEngine();
    final extractor = FakeLiveSubtitleAudioExtractor();
    final service = _buildService(engine: engine, extractor: extractor);
    await _start(service);
    // 喂 32000 字节 = 16000 采样 = 1 秒音频时钟。
    extractor.chunks.add(Uint8List(32000));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(service.audioClockMs, 1000);

    engine.updates.add(
      const LiveSubtitleEngineUpdate(
        newConfirmed: [
          LiveSubtitleRawSegment(
            text: 'テスト',
            start: Duration(milliseconds: 500),
            end: Duration(milliseconds: 1500),
          ),
        ],
        partialText: '',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    // 没重锚前：播放 1 秒对应音频 1 秒，有字幕。
    expect(service.cueAt(const Duration(seconds: 1))?.original, 'テスト');
    // 拖到 30 秒处重锚：音频 1 秒锚到播放 30 秒。
    service.reanchor(const Duration(seconds: 30));
    expect(service.cueAt(const Duration(seconds: 31))?.original, 'テスト');
    expect(service.cueAt(const Duration(seconds: 29)), isNull);
    await service.dispose();
  });

  test('暂定文本走 partial 流', () async {
    final engine = FakeLiveSubtitleEngine();
    final service = _buildService(engine: engine);
    final partials = <String>[];
    service.partialStream.listen(partials.add);
    await _start(service);
    engine.updates.add(
      const LiveSubtitleEngineUpdate(newConfirmed: [], partialText: '正在说'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(partials, ['正在说']);
    expect(service.partialText, '正在说');
    await service.dispose();
  });
}
