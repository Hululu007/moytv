import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'audio_background.dart';
import 'audio_capsule.dart';
import 'audio_history.dart';
import 'audio_media_session.dart';
import 'content_models.dart';
import 'core_bridge.dart';
import 'floating_window.dart';
import 'playback_foreground.dart';

/// 听书播放引擎的最小接口：控制器只依赖它，不直接碰 media_kit。
///
/// 生产用 [MediaKitAudioEngine]；测试注入假引擎，断言播控与后台输出。
abstract class AudioPlayerEngine {
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get playingStream;
  Stream<bool> get completedStream;
  Stream<String> get errorStream;

  bool get playing;
  Duration get position;
  Duration get duration;

  Future<void> open(String url);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> dispose();
}

/// media_kit 实现：与旧详情页私有播放器同一用法（open/setRate/play）。
class MediaKitAudioEngine implements AudioPlayerEngine {
  MediaKitAudioEngine() : _player = Player();

  final Player _player;

  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  Stream<Duration> get durationStream => _player.stream.duration;

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Stream<bool> get completedStream => _player.stream.completed;

  @override
  Stream<String> get errorStream => _player.stream.error;

  @override
  bool get playing => _player.state.playing;

  @override
  Duration get position => _player.state.position;

  @override
  Duration get duration => _player.state.duration;

  @override
  Future<void> open(String url) => _player.open(Media(url));

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> dispose() => _player.dispose();
}

/// 外部音频会话：自带播放器的另一条音频链路（片库/搜索播放页的音频模式）。
///
/// 它不归控制器播控，只把三路后台输出（前台服务保活、锁屏媒体会话、胶囊）
/// 交给控制器统一发布；锁屏按键经 [onAction] 回到归属方；另一路音频接管时
/// 经 [onTakeover] 通知归属方停掉本路，避免两路声音重叠。
/// 视频播放链不走这里：归属方只在音频模式下认领会话。
class ExternalAudioSession {
  const ExternalAudioSession({
    required this.ownerId,
    required this.infoProvider,
    required this.onAction,
    required this.onTakeover,
  });

  final String ownerId;

  /// 当前锁屏载荷：归属方每次被问都返回最新状态。
  final AudioLockscreenInfo Function() infoProvider;

  /// 锁屏按键：action 只会是 play / pause / previous / next。
  final void Function(String action) onAction;

  /// 另一路音频接管：归属方停掉本路播放，并放弃认领。
  final void Function() onTakeover;
}

/// 听书播放应用级单例：播放器独立于详情页之外。
///
/// 详情页只挂接界面（监听状态、发播控指令），不拥有播放器：
/// 按返回离开详情页，播放继续；切后台继续播；回前台只同步状态，永不自动播。
/// 同时是两条音频链路的后台输出总线：自有播放与外部会话同一时刻只有一路
/// 持有输出，新一路认领时旧一路被停掉（播新章停旧声）。
class AudioPlaybackController extends ChangeNotifier
    with WidgetsBindingObserver {
  AudioPlaybackController({AudioPlayerEngine? engine})
    : _providedEngine = engine {
    try {
      WidgetsBinding.instance.addObserver(this);
      _observerAttached = true;
    } catch (_) {
      _observerAttached = false;
    }
    AudioMediaSession.setActionHandler(handleMediaAction);
  }

  static AudioPlaybackController? _instance;

  /// 应用级唯一实例。
  static AudioPlaybackController get instance =>
      _instance ??= AudioPlaybackController();

  @visibleForTesting
  static void installTestInstance(AudioPlaybackController controller) {
    _instance?.dispose();
    _instance = controller;
  }

  @visibleForTesting
  static void resetInstance() {
    _instance?.dispose();
    _instance = null;
  }

  final AudioPlayerEngine? _providedEngine;
  AudioPlayerEngine? _engine;
  bool _engineSubscribed = false;
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _observerAttached = false;
  bool _disposed = false;

  ContentSource? _source;
  ContentBookDetail? _detail;
  int _playingIndex = -1;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  double _rate = 1.0;
  bool _trackLoading = false;
  String _trackError = '';
  bool _autoRetried = false;
  ({int chapter, int ms})? _pendingSeek;
  int _generation = 0;

  final ManualPauseTracker _manualPause = ManualPauseTracker();
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  bool _mediaPublished = false;
  bool _capsuleVisible = false;
  int _lastMediaStateAtMs = 0;
  int _lastSavedAtMs = 0;
  int _lastSavedPositionMs = -1;

  bool _overlayPrompted = false;
  bool _promptInFlight = false;

  ExternalAudioSession? _external;

  /// 自有链路有没有在播的曲目。
  bool get _ownActive =>
      _detail != null &&
      _playingIndex >= 0 &&
      _playingIndex < _detail!.chapters.length;

  ContentSource? get source => _source;
  ContentBookDetail? get detail => _detail;
  int get playingIndex => _playingIndex;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;
  double get rate => _rate;
  bool get trackLoading => _trackLoading;
  String get trackError => _trackError;
  bool get manuallyPaused => _manualPause.manuallyPaused;
  bool get hasOwnTrack => _ownActive;

  /// 当前播的是否就是这本书：详情页重进时凭此决定显示真实状态还是闲置态。
  bool isCurrentBook(String sourceId, String bookId) {
    return _ownActive &&
        _source?.id == sourceId &&
        _detail?.book.id == bookId;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 引擎迟建：只在自有链路第一次起播时建播放器，外部会话认领不建。
  AudioPlayerEngine _ensureEngine() {
    final existing = _engine;
    if (existing != null) return existing;
    final engine = _providedEngine ?? MediaKitAudioEngine();
    _engine = engine;
    if (!_engineSubscribed) {
      _engineSubscribed = true;
      _subs.addAll([
        engine.positionStream.listen((value) {
          _position = value;
          unawaited(_saveResumeThrottled());
          _publishMediaStateThrottled();
          _notify();
        }),
        engine.durationStream.listen((value) {
          _duration = value;
          _applyPendingSeek();
          _notify();
        }),
        engine.playingStream.listen((value) {
          _playing = value;
          unawaited(_syncBackgroundOutputs());
          _notify();
        }),
        engine.completedStream.listen((completed) {
          if (completed == true) {
            unawaited(_saveResumeNow());
            next(auto: true);
          }
        }),
        engine.errorStream.listen((_) {
          if (_trackError.isNotEmpty) return;
          if (!_autoRetried) {
            final source = _source;
            final detail = _detail;
            if (source != null && detail != null && _playingIndex >= 0) {
              // playChapter 的同步前段会复位 _autoRetried，须在调用后
              // 重新立起，否则持续出错时会无限重试（旧页面同款暗病）。
              unawaited(playChapter(source, detail, _playingIndex));
              _autoRetried = true;
            }
          } else {
            _trackError = '音频播放出错';
            _notify();
          }
        }),
      ]);
    }
    return engine;
  }

  void _applyPendingSeek() {
    final pending = _pendingSeek;
    if (pending == null) return;
    if (pending.chapter != _playingIndex) return;
    if (_duration.inMilliseconds <= 0) return;
    final target = pending.ms.clamp(0, _duration.inMilliseconds);
    _pendingSeek = null;
    final engine = _engine;
    if (engine != null) unawaited(engine.seek(Duration(milliseconds: target)));
  }

  /// 播一章：先停掉外部链路的旧声，再取流起播。
  /// 慢取流回来的旧请求会被代次号拦住，不会盖掉用户后点的章节。
  Future<void> playChapter(
    ContentSource source,
    ContentBookDetail detail,
    int index, {
    int seekMs = 0,
  }) async {
    if (_disposed || source.section != ContentSection.audio) return;
    if (index < 0 || index >= detail.chapters.length) return;
    final generation = ++_generation;
    _takeoverExternal();
    _pendingSeek = seekMs > 0 ? (chapter: index, ms: seekMs) : null;
    _source = source;
    _detail = detail;
    _playingIndex = index;
    _trackLoading = true;
    _trackError = '';
    _autoRetried = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _notify();
    ContentAudioTrack track;
    try {
      track = await source.audioTrack(detail.book.id, detail.chapters[index]);
    } on AppFailure catch (e) {
      if (generation != _generation || _disposed) return;
      _pendingSeek = null;
      _trackLoading = false;
      _trackError = e.message;
      _notify();
      return;
    } catch (_) {
      if (generation != _generation || _disposed) return;
      _pendingSeek = null;
      _trackLoading = false;
      _trackError = '音频加载失败';
      _notify();
      return;
    }
    if (generation != _generation || _disposed) return;
    try {
      final engine = _ensureEngine();
      await engine.open(track.url);
      await engine.setRate(_rate);
      await engine.play();
    } catch (_) {
      if (generation != _generation || _disposed) return;
      _pendingSeek = null;
      _trackLoading = false;
      _trackError = '音频加载失败';
      _notify();
      return;
    }
    _manualPause.userPlayed();
    _trackLoading = false;
    _notify();
    unawaited(_saveChapterStart(index));
    unawaited(_syncBackgroundOutputs());
  }

  void next({bool auto = false}) {
    final detail = _detail;
    final source = _source;
    if (detail == null || source == null) return;
    if (_playingIndex + 1 >= detail.chapters.length) return;
    unawaited(playChapter(source, detail, _playingIndex + 1));
  }

  void previous() {
    final detail = _detail;
    final source = _source;
    if (detail == null || source == null) return;
    if (_playingIndex - 1 < 0) return;
    unawaited(playChapter(source, detail, _playingIndex - 1));
  }

  Future<void> toggle() async {
    if (_disposed || _trackLoading || !_ownActive) return;
    final engine = _engine;
    if (engine == null) return;
    if (_playing) {
      _manualPause.userPaused();
      await engine.pause();
    } else {
      _manualPause.userPlayed();
      await engine.play();
    }
  }

  Future<void> setRate(double rate) async {
    _rate = rate;
    final engine = _engine;
    if (engine != null) await engine.setRate(rate);
    _notify();
    unawaited(_syncBackgroundOutputs());
  }

  Future<void> seek(Duration position) async {
    _pendingSeek = null;
    final engine = _engine;
    if (engine != null) await engine.seek(position);
  }

  /// 停掉自有播放：保存进度、复位状态、撤掉三路输出（外部会话持有时不撤）。
  Future<void> stop() async {
    if (_disposed) return;
    _generation++;
    _pendingSeek = null;
    _manualPause.stopped();
    await _saveResumeNow();
    try {
      await _engine?.stop();
    } catch (_) {}
    _playingIndex = -1;
    _position = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    _trackLoading = false;
    _trackError = '';
    _notify();
    if (_external == null) await _releaseBackgroundOutputs();
  }

  // ---------- 外部音频会话 ----------

  /// 外部链路认领后台输出：自有播放若在播，先停掉它。
  void claimExternalAudio(ExternalAudioSession session) {
    if (_disposed) return;
    if (_external?.ownerId == session.ownerId) {
      _external = session;
      unawaited(_syncBackgroundOutputs());
      return;
    }
    _stopOwnForTakeover();
    _external = session;
    unawaited(_syncBackgroundOutputs());
  }

  /// 外部链路状态变了（播/停、进度、换集）：重发三路输出。
  void reportExternalAudio() {
    if (_disposed || _external == null) return;
    unawaited(_syncBackgroundOutputs());
  }

  /// 外部链路放弃会话（切回视频、退出播放页）：自有链路闲置时撤掉输出。
  void releaseExternalAudio(String ownerId) {
    if (_disposed || _external?.ownerId != ownerId) return;
    _external = null;
    if (!_ownActive) unawaited(_releaseBackgroundOutputs());
  }

  void _takeoverExternal() {
    final session = _external;
    _external = null;
    if (session != null) {
      try {
        session.onTakeover();
      } catch (_) {}
    }
  }

  void _stopOwnForTakeover() {
    if (!_ownActive) return;
    _generation++;
    _pendingSeek = null;
    unawaited(_saveResumeNow());
    try {
      unawaited(_engine?.stop().catchError((Object _) {}));
    } catch (_) {}
    _playingIndex = -1;
    _position = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    _trackLoading = false;
    _trackError = '';
    _notify();
  }

  // ---------- 生命周期与锁屏按键 ----------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    handleLifecycleState(state);
  }

  void handleLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (_external == null && !_ownActive) return;
    if (state == AppLifecycleState.resumed) {
      // 回前台只同步状态，永不自动播放：播着的本来就没停，
      // 手动暂停过的不替用户恢复（见 shouldAutoPlayOnResume）。
      final engine = _engine;
      if (engine != null && _ownActive) {
        try {
          _playing = engine.playing;
          _position = engine.position;
          _duration = engine.duration;
        } catch (_) {}
        _notify();
      }
      unawaited(_syncBackgroundOutputs());
    } else if (isAudioBackgroundState(state)) {
      // 切后台不暂停播放：前台服务保活，播放器继续播。
      unawaited(_saveResumeNow());
      unawaited(_syncBackgroundOutputs());
    } else if (state == AppLifecycleState.detached) {
      unawaited(_saveResumeNow());
      unawaited(_releaseBackgroundOutputs());
    }
  }

  /// 锁屏按键：外部会话持有时交给归属方，否则走自有播控。
  /// 锁屏上点的暂停同样算手动暂停，点播放算用户意图播放。
  void handleMediaAction(String action) {
    if (_disposed) return;
    final session = _external;
    if (session != null) {
      switch (action) {
        case 'play':
          _manualPause.userPlayed();
        case 'pause':
          _manualPause.userPaused();
      }
      try {
        session.onAction(action);
      } catch (_) {}
      return;
    }
    if (!_ownActive) return;
    switch (action) {
      case 'play':
        if (!_playing && !_trackLoading) {
          _manualPause.userPlayed();
          unawaited(_engine?.play());
        }
      case 'pause':
        if (_playing) {
          _manualPause.userPaused();
          unawaited(_engine?.pause());
        }
      case 'previous':
        if (_playingIndex > 0) previous();
      case 'next':
        next();
    }
  }

  // ---------- 三路后台输出 ----------

  AudioLockscreenInfo? _activeInfo() {
    final session = _external;
    if (session != null) {
      try {
        return session.infoProvider();
      } catch (_) {
        return null;
      }
    }
    if (!_ownActive) return null;
    final detail = _detail!;
    return AudioLockscreenInfo(
      bookTitle: detail.book.title,
      chapterTitle: detail.chapters[_playingIndex].title,
      coverUrl: detail.book.cover,
      playing: _playing,
      positionMs: _position.inMilliseconds,
      durationMs: _duration.inMilliseconds,
      hasPrevious: _playingIndex > 0,
      hasNext: _playingIndex + 1 < detail.chapters.length,
      rate: _rate,
    );
  }

  /// 三路输出同步：前台服务保活 + 锁屏界面 + 胶囊显隐。
  /// 暂停时也发布锁屏界面（显示播放按钮）；胶囊只在后台且在播时出现。
  Future<void> _syncBackgroundOutputs() async {
    final info = _activeInfo();
    if (info == null) return;
    if (info.playing) {
      unawaited(PlaybackForeground.acquire(info.bookTitle));
    } else {
      unawaited(PlaybackForeground.release());
    }
    _mediaPublished = await AudioMediaSession.publish(info);
    unawaited(_refreshCapsule());
  }

  /// 锁屏进度刷新：播着时每 5 秒推一次播放态，避免每帧都过通道。
  void _publishMediaStateThrottled() {
    if (!_ownActive || !_playing || !_mediaPublished) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastMediaStateAtMs < 5000) return;
    _lastMediaStateAtMs = now;
    unawaited(
      AudioMediaSession.updateState(
        playing: true,
        positionMs: _position.inMilliseconds,
        durationMs: _duration.inMilliseconds,
        rate: _rate,
      ),
    );
  }

  bool _capsuleWantedNow() {
    final info = _activeInfo();
    return info != null &&
        info.playing &&
        isAudioBackgroundState(_lifecycleState);
  }

  /// 胶囊显隐：后台 + 在播 + 悬浮窗权限，三件齐了才显示；
  /// 权限未给且从没提示过时跳一次系统授权页，之后不再骚扰，只留通知栏控制。
  Future<void> _refreshCapsule() async {
    if (!_capsuleWantedNow()) {
      await _hideCapsuleIfVisible();
      return;
    }
    final granted = await AudioCapsule.isPermissionGranted();
    if (_disposed) return;
    if (!_capsuleWantedNow()) {
      await _hideCapsuleIfVisible();
      return;
    }
    final info = _activeInfo()!;
    if (granted) {
      final ready = await AudioCapsule.ensureService();
      if (_disposed || !_capsuleWantedNow()) {
        await _hideCapsuleIfVisible();
        return;
      }
      if (ready) {
        _capsuleVisible = await AudioCapsule.show(
          title: info.bookTitle,
          chapter: info.chapterTitle,
          playing: true,
        );
        return;
      }
      await _hideCapsuleIfVisible();
      return;
    }
    await _maybePromptOverlayPermissionOnce();
  }

  Future<void> _hideCapsuleIfVisible() async {
    if (!_capsuleVisible) return;
    _capsuleVisible = false;
    await AudioCapsule.hide();
  }

  /// 只主动跳一次：查持久标记，未提示过才记下并跳系统授权页。
  /// 跳之前再核一次“后台且在播”，中途回前台/暂停了就不跳。
  Future<void> _maybePromptOverlayPermissionOnce() async {
    if (_overlayPrompted || _promptInFlight) return;
    _promptInFlight = true;
    try {
      final prompted = await AudioCapsulePermissionPrompt.hasPrompted();
      if (prompted) {
        _overlayPrompted = true;
        return;
      }
      if (!_capsuleWantedNow()) return;
      await AudioCapsulePermissionPrompt.markPrompted();
      _overlayPrompted = true;
      if (!_capsuleWantedNow()) return;
      await FloatingWindow.requestPermission();
    } catch (_) {
      // 授权页跳不出去（比如后台拉起被拦）也静默降级，不报错。
    } finally {
      _promptInFlight = false;
    }
  }

  /// 撤掉三路输出：前台服务标记、锁屏界面、胶囊服务。
  Future<void> _releaseBackgroundOutputs() async {
    _mediaPublished = false;
    _capsuleVisible = false;
    unawaited(PlaybackForeground.release());
    await AudioMediaSession.release();
    await AudioCapsule.stop();
  }

  // ---------- 续听进度 ----------

  AudioListenRecord _recordFor(int chapterIndex, int positionMs) {
    final detail = _detail;
    final source = _source;
    final chapter =
        detail != null &&
            chapterIndex >= 0 &&
            chapterIndex < detail.chapters.length
        ? detail.chapters[chapterIndex]
        : null;
    final book = detail?.book;
    return AudioListenRecord(
      sourceId: source?.id ?? '',
      sourceName: source?.name ?? '',
      bookId: book?.id ?? '',
      title: book?.title ?? '',
      cover: book?.cover ?? '',
      author: book?.author ?? '',
      chapterIndex: chapterIndex,
      chapterTitle: chapter?.title ?? '',
      positionMs: positionMs,
      durationMs: _duration.inMilliseconds,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _saveChapterStart(int index) async {
    if (_source?.section != ContentSection.audio) return;
    try {
      final record = _recordFor(index, 0);
      await saveAudioResume(record);
      await recordAudioHistory(record);
    } catch (_) {}
  }

  Future<void> _saveResumeNow() async {
    if (_source?.section != ContentSection.audio) return;
    if (_playingIndex < 0 || _position.inMilliseconds <= 0) return;
    try {
      final record = _recordFor(_playingIndex, _position.inMilliseconds);
      await saveAudioResume(record);
      await recordAudioHistory(record);
    } catch (_) {}
  }

  Future<void> _saveResumeThrottled() async {
    if (_source?.section != ContentSection.audio) return;
    if (_playingIndex < 0 || !_playing) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final positionMs = _position.inMilliseconds;
    if (positionMs <= 0) return;
    if (now - _lastSavedAtMs < 5000 &&
        (positionMs - _lastSavedPositionMs).abs() < 5000) {
      return;
    }
    _lastSavedAtMs = now;
    _lastSavedPositionMs = positionMs;
    try {
      final record = _recordFor(_playingIndex, positionMs);
      await saveAudioResume(record);
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    if (_observerAttached) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
      _observerAttached = false;
    }
    AudioMediaSession.setActionHandler(null);
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    final engine = _engine;
    _engine = null;
    if (engine != null) unawaited(engine.dispose().catchError((Object _) {}));
    super.dispose();
  }
}
