import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:whisper_cpp_flutter_plus/whisper_cpp_flutter_plus.dart';

/// 实时翻译字幕的识别引擎接口：服务层只认这套类型，不直接碰插件，
/// 测试时注入假引擎；真机上由 [PluginLiveSubtitleEngine] 接插件。
///
/// 音频约定：16kHz 单声道 s16le 原始字节块（A 路取流由 FFmpeg 解出），
/// 段起止时间以“音频流开始”为零点（服务层再锚到播放进度上）。

class LiveSubtitleRawSegment {
  const LiveSubtitleRawSegment({
    required this.text,
    required this.start,
    required this.end,
  });

  final String text;
  final Duration start;
  final Duration end;

  String get dedupeKey => '${start.inMilliseconds}|${text.trim()}';
}

class LiveSubtitleEngineUpdate {
  const LiveSubtitleEngineUpdate({
    required this.newConfirmed,
    required this.partialText,
  });

  /// 本轮新确认的段（去重后，只含之前没发过的段）。
  final List<LiveSubtitleRawSegment> newConfirmed;

  /// 暂定文本（下一轮可能被改写，仅作“正在听…”展示用）。
  final String partialText;
}

enum LiveSubtitleModelState {
  notDownloaded,
  downloading,
  downloaded,

  /// 本机无法检测（非安卓/iOS，或插件未就绪）。
  unknown,
}

abstract class LiveSubtitleEngine {
  /// 模型在本机的状态。
  Future<LiveSubtitleModelState> modelState(String modelId);

  /// 已下载模型的字节数（未下载返回 null）。
  Future<int?> downloadedModelBytes(String modelId);

  /// 下载模型（断点续传由插件负责），进度 0~1。
  /// [mirrorBaseUrl] 非空时从该镜像地址拼模型文件名下载
  /// （仍校验目录里的 SHA-256）；空则走插件内置的 Hugging Face 地址。
  Future<void> downloadModel(
    String modelId, {
    void Function(double progress)? onProgress,
    String? mirrorBaseUrl,
  });

  /// 删除已下载的模型文件。
  Future<void> deleteModel(String modelId);

  /// 加载模型进内存（下载后、识别前调一次）。
  Future<void> loadModel(String modelId);

  /// 流式识别：喂 s16le 音频块，出新确认的段与暂定文本。
  /// [language] 为 auto/ja/en/ko；[translate] 为真时 Whisper
  /// 直接出英文翻译（自带翻译只出英文，日→中仍需翻译段）。
  Stream<LiveSubtitleEngineUpdate> transcribeStream(
    Stream<Uint8List> pcm16Chunks, {
    required String language,
    required bool translate,
  });

  Future<void> dispose();
}

/// 识别引擎是否能在本机跑：插件只支持安卓与 iOS。
/// Windows/Linux/macOS 上 import 能编过，但方法通道不存在，
/// 调用会抛 MissingPluginException，所以调用前必须先判这里。
bool get liveSubtitleEngineSupported =>
    Platform.isAndroid || Platform.isIOS;

/// 插件适配：whisper_cpp_flutter_plus 0.5.x。
/// 注意：不用 withPerformanceMode(responsive)，它会关掉
/// tokenTimestamps，段时间戳就没了；默认选项保留时间戳。
class PluginLiveSubtitleEngine implements LiveSubtitleEngine {
  WhisperEngine? _engine;
  WhisperStreamTask? _task;
  bool _disposed = false;

  static WhisperModelDescriptor _descriptor(String modelId) {
    return WhisperModelCatalog.byId(modelId) ?? WhisperModelCatalog.tiny;
  }

  @override
  Future<LiveSubtitleModelState> modelState(String modelId) async {
    if (!liveSubtitleEngineSupported) {
      return LiveSubtitleModelState.unknown;
    }
    final manager = WhisperModelManager();
    try {
      final found = await manager.findCatalogModel(_descriptor(modelId));
      return found == null
          ? LiveSubtitleModelState.notDownloaded
          : LiveSubtitleModelState.downloaded;
    } on FormatException {
      // 插件约定：已缓存文件校验和不对时抛 FormatException，文件留给
      // 调用方处理；这里按“未下载”算，下载会覆盖它。
      return LiveSubtitleModelState.notDownloaded;
    } catch (_) {
      return LiveSubtitleModelState.unknown;
    } finally {
      manager.close();
    }
  }

  @override
  Future<int?> downloadedModelBytes(String modelId) async {
    if (!liveSubtitleEngineSupported) return null;
    final manager = WhisperModelManager();
    try {
      final found = await manager.findCatalogModel(_descriptor(modelId));
      if (found == null) return null;
      final file = File(found.path);
      if (!await file.exists()) return null;
      return await file.length();
    } catch (_) {
      return null;
    } finally {
      manager.close();
    }
  }

  @override
  Future<void> downloadModel(
    String modelId, {
    void Function(double progress)? onProgress,
    String? mirrorBaseUrl,
  }) async {
    if (!liveSubtitleEngineSupported) {
      throw const LiveSubtitleEngineException('实时翻译字幕仅支持安卓与 iOS');
    }
    final manager = WhisperModelManager();
    try {
      final descriptor = _descriptor(modelId);
      final mirror = (mirrorBaseUrl ?? '').trim().replaceAll(
        RegExp(r'/+$'),
        '',
      );
      final Stream<ModelDownloadProgress> progressStream;
      if (mirror.isNotEmpty) {
        // 镜像下载：同名文件 + 目录校验码，断点续传与校验都由插件负责。
        // 镜像是用户自己填的地址，http 也放行：落盘后仍按目录
        // SHA-256 校验，校验不对不安装，中间人换不掉模型文件。
        progressStream = manager.download(
          Uri.parse('$mirror/${descriptor.fileName}'),
          descriptor.fileName,
          sha256Hex: descriptor.sha256,
          allowInsecureHttp: mirror.startsWith('http://'),
        );
      } else {
        progressStream = manager.downloadCatalogModel(descriptor);
      }
      await for (final progress in progressStream) {
        // fraction 在服务器没给总长度时为 null，用 0 代替。
        onProgress?.call((progress.fraction ?? 0.0).clamp(0.0, 1.0));
      }
    } finally {
      manager.close();
    }
  }

  @override
  Future<void> deleteModel(String modelId) async {
    final manager = WhisperModelManager();
    try {
      await manager.delete(_descriptor(modelId).fileName);
    } catch (_) {
      // 文件不在或删不掉不致命：设置页按“未下载”显示即可。
    } finally {
      manager.close();
    }
  }

  @override
  Future<void> loadModel(String modelId) async {
    if (!liveSubtitleEngineSupported) {
      throw const LiveSubtitleEngineException('实时翻译字幕仅支持安卓与 iOS');
    }
    if (_engine != null) return;
    final manager = WhisperModelManager();
    try {
      final found = await manager.findCatalogModel(_descriptor(modelId));
      if (found == null) {
        throw const LiveSubtitleEngineException('模型还没下载，请先下载模型');
      }
      _engine = await WhisperEngine.load(
        found.path,
        config: const WhisperConfig(backend: WhisperBackend.cpu),
      );
    } finally {
      manager.close();
    }
  }

  @override
  Stream<LiveSubtitleEngineUpdate> transcribeStream(
    Stream<Uint8List> pcm16Chunks, {
    required String language,
    required bool translate,
  }) {
    final engine = _engine;
    if (engine == null) {
      throw const LiveSubtitleEngineException('模型还没加载');
    }
    final controller = StreamController<LiveSubtitleEngineUpdate>();
    final emitted = <String>{};
    final chunkStream = pcm16Chunks.map(
      // RecordingChunk 是位置参数构造：(samples, sampleRate)。
      (bytes) => RecordingChunk(_s16leToFloat32(bytes), 16000),
    );
    late final WhisperStreamTask task;
    task = engine.transcribeStream(
      chunkStream,
      options: TranscribeOptions(
        language: language,
        translate: translate,
        tokenTimestamps: true,
      ),
      config: const WhisperStreamConfig(
        updateInterval: Duration(seconds: 2),
        windowDuration: Duration(seconds: 30),
        confirmationLag: Duration(seconds: 4),
      ),
    );
    _task = task;
    final subscription = task.updates.listen(
      (update) {
        if (controller.isClosed) return;
        final fresh = <LiveSubtitleRawSegment>[];
        for (final segment in update.confirmedSegments) {
          final text = segment.text.trim();
          if (text.isEmpty) continue;
          final raw = LiveSubtitleRawSegment(
            text: text,
            start: segment.start,
            end: segment.end,
          );
          if (emitted.add(raw.dedupeKey)) fresh.add(raw);
        }
        controller.add(
          LiveSubtitleEngineUpdate(
            newConfirmed: fresh,
            partialText: update.partialText.trim(),
          ),
        );
      },
      onError: (Object e) {
        if (!controller.isClosed) controller.addError(e);
      },
      onDone: () {
        if (!controller.isClosed) controller.close();
      },
    );
    controller.onCancel = () async {
      await subscription.cancel();
      await task.cancel();
    };
    return controller.stream;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _task?.cancel();
    _task = null;
    _engine?.dispose();
    _engine = null;
  }

  /// s16le 小端字节 → Float32（whisper.cpp 要的 mono 16kHz PCM）。
  static Float32List _s16leToFloat32(Uint8List bytes) {
    final count = bytes.lengthInBytes ~/ 2;
    final out = Float32List(count);
    final data = ByteData.view(bytes.buffer, bytes.offsetInBytes, count * 2);
    for (var i = 0; i < count; i++) {
      out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }
}

class LiveSubtitleEngineException implements Exception {
  const LiveSubtitleEngineException(this.message);

  final String message;

  @override
  String toString() => 'LiveSubtitleEngineException: $message';
}
