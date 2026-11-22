import 'dart:async';
import 'dart:typed_data';

import 'live_subtitle_audio.dart';
import 'live_subtitle_engine.dart';
import 'live_subtitle_settings.dart';
import 'live_subtitle_translator.dart';

/// 实时翻译字幕运行状态。
enum LiveSubtitleRunState {
  idle,
  loadingModel,
  running,
  error,

  /// 本机跑不了（非安卓/iOS）。
  unsupported,
}

/// 一条实时字幕（时间以音频流开始为零点，服务层再锚到播放进度）。
class LiveSubtitleCue {
  const LiveSubtitleCue({
    required this.original,
    this.translated,
    required this.start,
    required this.end,
    this.englishOnly = false,
  });

  /// 识别出的原文（源语言）。
  final String original;

  /// 中文译文（未配置翻译服务时为 null）。
  final String? translated;

  final Duration start;
  final Duration end;

  /// 真：原文就是 Whisper 自带的英文翻译（未配置中文翻译服务时），
  /// 界面应标“英译”而不是当成中文。
  final bool englishOnly;

  String get key => '${start.inMilliseconds}';

  LiveSubtitleCue copyWith({String? translated}) => LiveSubtitleCue(
    original: original,
    translated: translated ?? this.translated,
    start: start,
    end: end,
    englishOnly: englishOnly,
  );

  /// 叠加层要画的行：有译文时按双语开关决定是否带原文行；
  /// 无译文时只画原文行。
  List<String> displayLines({required bool showOriginal}) {
    final text = translated?.trim() ?? '';
    if (text.isNotEmpty) {
      return showOriginal ? [original, text] : [text];
    }
    return [original];
  }
}

/// 实时翻译字幕服务：编排“取流 → 识别 → 翻译 → 出字幕”全链路。
///
/// 时间锚定：音频流从 0 开始，播放器从 startPosition 开始，两者
/// 用锚点对齐（anchorPlayerMs 对 anchorAudioMs）。播着播着漂了、
/// 或用户拖进度条后，调 [reanchor] 重新锚一次。
/// 翻译路线：配了 LibreTranslate 地址 → 每段确认后异步翻成中文；
/// 没配 → Whisper 直接出英文翻译（translate 模式），字幕标英译，
/// 绝不把英文冒充中文。
class LiveSubtitleService {
  LiveSubtitleService({
    required this.settings,
    LiveSubtitleEngine? engine,
    LiveSubtitleAudioExtractor? extractor,
    LiveSubtitleTranslator? translator,
  }) : _engine =
           engine ??
           (liveSubtitleEngineSupported
               ? PluginLiveSubtitleEngine()
               : null),
       _engineInjected = engine != null,
       _extractor = extractor ?? FfmpegLiveSubtitleAudioExtractor(),
       _translator = translator ?? buildLiveSubtitleTranslator(settings);

  final LiveSubtitleSettings settings;
  final LiveSubtitleEngine? _engine;

  /// 引擎是否显式注入（测试用假引擎）：注入即视为可用，平台判断
  /// 只约束默认的插件引擎。真机上从不注入，不影响平台判断。
  final bool _engineInjected;
  final LiveSubtitleAudioExtractor _extractor;
  final LiveSubtitleTranslator? _translator;

  final _cueController = StreamController<LiveSubtitleCue>.broadcast();
  final _stateController =
      StreamController<LiveSubtitleRunState>.broadcast();
  final _partialController = StreamController<String>.broadcast();
  final _downloadController = StreamController<double>.broadcast();

  LiveSubtitleRunState _state = LiveSubtitleRunState.idle;
  String? _statusMessage;
  String _partialText = '';

  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription<LiveSubtitleEngineUpdate>? _engineSubscription;
  StreamController<Uint8List>? _chunkController;

  /// 已确认的字幕（按 start 排序，播放器按需取当前一条）。
  final List<LiveSubtitleCue> _cues = [];

  /// 已喂给引擎的音频采样数（16kHz），用于音频时钟与重锚。
  int _audioSamplesFed = 0;

  int _anchorPlayerMs = 0;
  int _anchorAudioMs = 0;

  bool _running = false;
  bool _disposed = false;

  Stream<LiveSubtitleCue> get cueStream => _cueController.stream;
  Stream<LiveSubtitleRunState> get stateStream => _stateController.stream;
  Stream<String> get partialStream => _partialController.stream;
  Stream<double> get downloadProgress => _downloadController.stream;

  LiveSubtitleRunState get state => _state;
  String? get statusMessage => _statusMessage;
  String get partialText => _partialText;
  bool get isRunning => _running;
  bool get supported => liveSubtitleEngineSupported || _engineInjected;

  List<LiveSubtitleCue> get cues => List.unmodifiable(_cues);

  /// 当前音频时钟（毫秒）：已喂的采样数 / 16。
  int get audioClockMs => _audioSamplesFed ~/ 16;

  void _setState(LiveSubtitleRunState next, [String? message]) {
    _state = next;
    _statusMessage = message;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  /// 设置页用的模型状态透传。
  Future<LiveSubtitleModelState> modelState(String modelId) async {
    final engine = _engine;
    if (engine == null) return LiveSubtitleModelState.unknown;
    return engine.modelState(modelId);
  }

  Future<int?> downloadedModelBytes(String modelId) async {
    final engine = _engine;
    if (engine == null) return null;
    return engine.downloadedModelBytes(modelId);
  }

  /// 设置页手动下载模型（不在播放时自动下载，避免用户播着视频
  /// 突然被扣 74MB 流量）。
  Future<void> downloadModel(
    String modelId, {
    void Function(double progress)? onProgress,
  }) async {
    final engine = _engine;
    if (engine == null) {
      throw const LiveSubtitleEngineException('实时翻译字幕仅支持安卓与 iOS');
    }
    await engine.downloadModel(
      modelId,
      mirrorBaseUrl: settings.modelMirrorUrl.trim().isEmpty
          ? null
          : settings.modelMirrorUrl.trim(),
      onProgress: (progress) {
        if (!_downloadController.isClosed) {
          _downloadController.add(progress);
        }
        onProgress?.call(progress);
      },
    );
  }

  Future<void> deleteModel(String modelId) async {
    final engine = _engine;
    if (engine == null) return;
    await engine.deleteModel(modelId);
  }

  /// 开始一路实时字幕：[startPosition] 为播放器起始进度。
  /// [encrypted] 为真表示播放器侧内存密钥解密，取不到音轨，直接报错。
  Future<void> start({
    required String url,
    required Map<String, String> headers,
    required Duration startPosition,
    bool encrypted = false,
  }) async {
    if (_running) await stop();
    if (_disposed) return;
    final engine = _engine;
    if (engine == null ||
        (!liveSubtitleEngineSupported && !_engineInjected)) {
      _setState(
        LiveSubtitleRunState.unsupported,
        '实时翻译字幕仅支持安卓与 iOS',
      );
      return;
    }
    if (!settings.enabled) return;
    if (url.trim().isEmpty) {
      _setState(LiveSubtitleRunState.error, '播放地址为空，无法取音轨');
      return;
    }
    if (encrypted) {
      _setState(LiveSubtitleRunState.error, '该源加密播放，无法取音轨做字幕');
      return;
    }
    _setState(LiveSubtitleRunState.loadingModel);
    try {
      await engine.loadModel(settings.modelId);
    } on LiveSubtitleEngineException catch (e) {
      _setState(
        LiveSubtitleRunState.error,
        e.message.contains('还没下载')
            ? '模型还没下载，请到设置 → 实时翻译字幕里下载模型'
            : e.message,
      );
      return;
    } catch (e) {
      _setState(LiveSubtitleRunState.error, '加载模型失败：$e');
      return;
    }

    _cues.clear();
    _audioSamplesFed = 0;
    _anchorPlayerMs = startPosition.inMilliseconds;
    _anchorAudioMs = 0;
    _running = true;
    _setState(LiveSubtitleRunState.running);

    final audioStream = _extractor.extract(url: url, headers: headers);
    final chunkController = StreamController<Uint8List>();
    _chunkController = chunkController;
    _audioSubscription = audioStream.listen(
      (Uint8List chunk) {
        _audioSamplesFed += chunk.lengthInBytes ~/ 2;
        if (!chunkController.isClosed) chunkController.add(chunk);
      },
      onError: (Object e) {
        if (!_running) return;
        _setState(
          LiveSubtitleRunState.error,
          e is LiveSubtitleAudioException ? e.message : '取音轨失败：$e',
        );
        unawaited(stop());
      },
      onDone: () {
        if (!chunkController.isClosed) chunkController.close();
      },
    );
    final useEnglishTranslate = _translator == null;
    try {
      final updates = engine.transcribeStream(
        chunkController.stream,
        language: settings.whisperLanguageCode,
        translate: useEnglishTranslate,
      );
      _engineSubscription = updates.listen(
        (update) => _onEngineUpdate(update, useEnglishTranslate),
        onError: (Object e) {
          if (!_running) return;
          _setState(LiveSubtitleRunState.error, '识别失败：$e');
          unawaited(stop());
        },
      );
    } catch (e) {
      await chunkController.close();
      _setState(LiveSubtitleRunState.error, '启动识别失败：$e');
      _running = false;
    }
  }

  void _onEngineUpdate(
    LiveSubtitleEngineUpdate update,
    bool useEnglishTranslate,
  ) {
    if (!_running || _disposed) return;
    if (update.partialText != _partialText) {
      _partialText = update.partialText;
      if (!_partialController.isClosed) {
        _partialController.add(_partialText);
      }
    }
    for (final segment in update.newConfirmed) {
      final cue = LiveSubtitleCue(
        original: segment.text,
        start: segment.start,
        end: segment.end,
        englishOnly: useEnglishTranslate,
      );
      _upsertCue(cue);
      if (!_cueController.isClosed) _cueController.add(cue);
      final translator = _translator;
      if (translator != null) {
        unawaited(_translateCue(cue, translator));
      }
    }
  }

  Future<void> _translateCue(
    LiveSubtitleCue cue,
    LiveSubtitleTranslator translator,
  ) async {
    String? translated;
    try {
      translated = await translator.translate(
        cue.original,
        source: settings.libreTranslateSourceCode,
        target: 'zh',
      );
    } on LiveSubtitleTranslationException {
      // 单段翻译失败不翻状态：字幕照常显示原文，不拿错误刷屏。
      return;
    } catch (_) {
      return;
    }
    if (translated == null || translated.trim().isEmpty) return;
    if (_disposed || !_running) return;
    final updated = cue.copyWith(translated: translated.trim());
    _upsertCue(updated);
    if (!_cueController.isClosed) _cueController.add(updated);
  }

  void _upsertCue(LiveSubtitleCue cue) {
    final index = _cues.indexWhere((c) => c.key == cue.key);
    if (index >= 0) {
      _cues[index] = cue;
    } else {
      _cues.add(cue);
      _cues.sort((a, b) => a.start.compareTo(b.start));
    }
    // 只留最近 200 条，防长视频内存一直涨。
    while (_cues.length > 200) {
      _cues.removeAt(0);
    }
  }

  /// 取 [playerPosition] 时刻应显示的字幕；没有返回 null。
  /// 段尾放宽 2 秒：字幕刚说完别立刻消失。
  LiveSubtitleCue? cueAt(Duration playerPosition) {
    if (_cues.isEmpty) return null;
    final audioMs =
        playerPosition.inMilliseconds - _anchorPlayerMs + _anchorAudioMs;
    LiveSubtitleCue? active;
    for (final cue in _cues) {
      if (cue.start.inMilliseconds <= audioMs &&
          audioMs <= cue.end.inMilliseconds + 2000) {
        active = cue;
      } else if (cue.start.inMilliseconds > audioMs) {
        break;
      }
    }
    return active;
  }

  /// 拖进度条 / 漂移过大时重新锚一次：以当前播放进度为准，
  /// 音频时钟取当前已喂的采样数。
  void reanchor(Duration playerPosition) {
    _anchorPlayerMs = playerPosition.inMilliseconds;
    _anchorAudioMs = audioClockMs;
  }

  Future<void> stop() async {
    _running = false;
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _engineSubscription?.cancel();
    _engineSubscription = null;
    final chunkController = _chunkController;
    _chunkController = null;
    if (chunkController != null && !chunkController.isClosed) {
      await chunkController.close();
    }
    await _extractor.stop();
    _partialText = '';
    if (_state != LiveSubtitleRunState.error &&
        _state != LiveSubtitleRunState.unsupported) {
      _setState(LiveSubtitleRunState.idle);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    _engine?.dispose();
    await _cueController.close();
    await _stateController.close();
    await _partialController.close();
    await _downloadController.close();
  }
}

/// 按设置组装翻译链：选定的通道优先，内置免费通道永远兜底。
///
/// 顺序与 `LiveSubtitleSettings.effectiveTranslationProvider` 对齐：
/// 选了但没配好（缺 Key / 缺地址）就回落到内置通道，不让字幕整条不出。
LiveSubtitleTranslator buildLiveSubtitleTranslator(
  LiveSubtitleSettings settings,
) {
  final fallback = GoogleTranslateTranslator();
  switch (settings.effectiveTranslationProvider) {
    case 'llm':
      return ChainTranslator([
        OpenAiCompatibleTranslator(
          baseUrl: settings.llmBaseUrl,
          apiKey: settings.llmApiKey,
          model: settings.llmModel,
          thinking: settings.llmThinking,
          context: settings.llmContext,
        ),
        fallback,
      ]);
    case 'mtran':
      return ChainTranslator([
        MtranServerTranslator(
          baseUrl: settings.mtranUrl,
          token: settings.mtranToken,
        ),
        fallback,
      ]);
    case 'libre':
      return ChainTranslator([
        LibreTranslateTranslator(baseUrl: settings.libreTranslateUrl),
        fallback,
      ]);
    default:
      if (settings.hasRemoteTranslator) {
        return ChainTranslator([
          LibreTranslateTranslator(baseUrl: settings.libreTranslateUrl),
          fallback,
        ]);
      }
      return fallback;
  }
}
