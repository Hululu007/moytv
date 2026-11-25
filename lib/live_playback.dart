import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'core_bridge.dart';
import 'live_drm.dart';
import 'live_models.dart';
import 'live_repository.dart';
import 'live_settings.dart';
import 'live_sources.dart';
import 'models.dart';
import 'screen_awake.dart';
import 'tvbox_video_pane.dart';
import 'video_output_size.dart';
import 'sleep_timer.dart';

/// 直播解码模式：普通频道调 mpv 的 hwdec；DRM 频道走 EXO 时由
/// 直播页把同一取值映射成 EXO 的解码模式（见 live_screen 的
/// _exoDecoderMode）。默认自动，与今天不设 hwdec 时点播的默认值一致。
enum LiveDecoderMode { auto, hardware, software }

extension LiveDecoderModeX on LiveDecoderMode {
  String get label => switch (this) {
    LiveDecoderMode.auto => '自动',
    LiveDecoderMode.hardware => '硬解',
    LiveDecoderMode.software => '软解',
  };

  String get mpvValue => switch (this) {
    LiveDecoderMode.auto => 'auto-safe',
    LiveDecoderMode.hardware => 'mediacodec-copy',
    LiveDecoderMode.software => 'no',
  };

  LiveDecoderMode get next => switch (this) {
    LiveDecoderMode.auto => LiveDecoderMode.hardware,
    LiveDecoderMode.hardware => LiveDecoderMode.software,
    LiveDecoderMode.software => LiveDecoderMode.auto,
  };
}

/// 直播播放状态：顶部内嵌播放器与全屏播放共用同一实例，换台不重建引擎。
class LivePlaybackController extends ChangeNotifier {
  LivePlaybackController({
    required this.repository,
    this.createPlayer,
    this.buildVideoController = true,
  }) {
    sleepTimer.addListener(_sleepChanged);
    // 解码模式与睡眠默认时长是软件设置页「直播设置」节的偏好
    // （LiveSettingsStore 全局一份）：构造时先应用已加载的值
    // （含给睡眠计时器按默认时长起算），再订阅后续变化——
    // 设置页改了，这边立刻跟着应用。
    final liveSettings = LiveSettingsStore.instance;
    _decoderMode = liveSettings.settings.decoderMode;
    _appliedSleepMinutes = liveSettings.settings.sleepMinutes;
    if (_appliedSleepMinutes! > 0) {
      sleepTimer.startMinutes(_appliedSleepMinutes!);
    }
    liveSettings.addListener(_onLiveSettingsChanged);
    unawaited(liveSettings.ensureLoaded());
  }

  /// 已应用到睡眠计时器的设置页默认时长；null = 还没应用过。
  /// ⓘ 单里临时选的本次定时不在此列，偏好通知不冲它。
  int? _appliedSleepMinutes;

  void _onLiveSettingsChanged() {
    if (_disposed) return;
    final settings = LiveSettingsStore.instance.settings;
    if (_appliedSleepMinutes != settings.sleepMinutes) {
      _appliedSleepMinutes = settings.sleepMinutes;
      if (settings.sleepMinutes > 0) {
        sleepTimer.startMinutes(settings.sleepMinutes);
      } else if (sleepTimer.active) {
        sleepTimer.cancel();
      }
    }
    if (settings.decoderMode != _decoderMode) {
      unawaited(setDecoderMode(settings.decoderMode));
    }
  }

  static const maxRetries = 3;
  static const _reconnectDelay = Duration(seconds: 2);

  /// 起播后迟迟没有画面的判定时限。直播源的代理线路会返回正常清单却
  /// 一直卡在缓冲，不触发错误事件，只靠 error 回调永远等不到换线。
  static const _stallTimeout = Duration(seconds: 15);

  /// 点播（m3u 文件型）源的起播判定时限：点播地址是整部影片的 HLS，
  /// 清单本身 18–79KB、首个分片约 180KB，慢网下光取清单加首批分片
  /// 就要 30–90 秒才出第一帧；15 秒会把能播的片也判成断流。
  /// 直播源仍用 15 秒，死线路照旧快速换线。
  static const _vodStallTimeout = Duration(seconds: 90);

  final LiveRepository repository;

  /// 测试注入：替换 mpv 播放器的构造（真机不传，走默认 Player()）。
  final Player Function()? createPlayer;

  /// 测试注入：真实 VideoController 在测试环境建不起来（原生纹理
  /// 通道不存在），单测关掉它只验播放路由本身；真机恒为 true。
  final bool buildVideoController;

  late final sleepTimer = SleepTimerController(
    onExpire: () => unawaited(pauseForSleep()),
  );
  bool _sleepPaused = false;

  void _sleepChanged() {
    if (!_disposed) notifyListeners();
  }

  Future<void> pauseForSleep() async {
    if (_disposed) return;
    _sleepPaused = true;
    _generation++;
    _loading = false;
    _reconnect?.cancel();
    _stall?.cancel();
    _screenAwake.disable();
    try {
      await _player?.pause();
    } catch (_) {}
    try {
      await exoHandle.pause();
    } catch (_) {}
    if (!_disposed) notifyListeners();
  }

  final _screenAwake = ScreenAwake();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _reconnect;
  Timer? _stall;
  bool _frames = false;
  double _aspectRatio = 16 / 9;

  Player? _player;
  VideoController? _controller;
  LiveSource? _source;
  List<LiveChannel> _channels = const [];
  int _index = 0;
  int _generation = 0;
  int _retries = 0;
  int _route = 0;
  LiveDecoderMode _decoderMode = LiveDecoderMode.auto;
  bool _loading = false;
  bool _buffering = false;
  bool _disposed = false;
  String? _error;

  /// 播放中流的真实输出分辨率（videoParams 给出的显示尺寸）：
  /// 拿到之前为 null，界面不硬写分辨率；只随首帧/分辨率变化更新。
  Size? _videoSize;

  /// 播放中流的真实帧率：media_kit 的 videoParams 不带 fps 字段，
  /// 改从 mpv 属性读（先 estimated-vf-fps 实际输出帧率，没有再退
  /// container-fps 容器帧率）。两个都拿不到就保持 null，界面不
  /// 显示帧率，绝不编一个数。
  double? _videoFps;
  Timer? _fpsRetry;

  /// DRM 频道的 EXO 播放计划：非 null 表示当前频道走 EXO 核
  /// （TvboxVideoPane 消费，见 live_screen），mpv 完全不参与。
  /// 普通频道恒为 null，走原来的 mpv 路，一行不变。
  PlaybackPlan? _exoPlan;

  /// EXO pane 的播放句柄（暂停/继续/进度），直播页与全屏页共用。
  final TvboxPlaybackHandle exoHandle = TvboxPlaybackHandle();

  bool get usingExo => _exoPlan != null;
  PlaybackPlan? get exoPlan => _exoPlan;

  /// EXO pane 报上来的起播/播放失败：只记明确报错，不回头用
  /// mpv 无效重连（mpv 解不了 DRM，重连必然重复失败）。
  void reportExoError(String message) {
    if (_disposed || _exoPlan == null) return;
    _loading = false;
    final text = message.trim();
    _error = text.isEmpty ? 'DRM 频道播放失败' : 'DRM 频道播放失败：$text';
    notifyListeners();
  }

  /// EXO pane 报流结束：直播流结束即中断，按失败口径报错。
  void reportExoCompleted() {
    reportExoError('直播流已结束');
  }

  Player? get player => _player;
  VideoController? get controller => _controller;
  LiveSource? get source => _source;
  List<LiveChannel> get channels => _channels;
  LiveChannel? get channel => _channels.isEmpty
      ? null
      : _channels[_index.clamp(0, _channels.length - 1)];
  int get index => _index;
  int get count => _channels.length;
  bool get loading => _loading;
  bool get buffering => _buffering;
  bool get ready => _player != null;
  int get route => _route;
  LiveDecoderMode get decoderMode => _decoderMode;
  String? get error => _error;
  double get aspectRatio => _aspectRatio;
  Size? get videoSize => _videoSize;
  double? get videoFps => _videoFps;

  void _ensurePlayer() {
    if (_player != null || _disposed) return;
    final player = createPlayer?.call() ?? Player();
    _player = player;
    // 直播流对 mpv 是非可寻址（non-seekable）源，demuxer 打开时会在 OSD/日志里
    // 打印 “not seekable … you can force it with -force -seekable=yes”。设为 yes
    // 后 mpv 用缓存强行可寻址，既消除该提示也支持直播内拖动。仅原生 mpv 生效，
    // Web 端 platform 非 NativePlayer 时跳过。
    final platform = player.platform;
    if (platform is NativePlayer) {
      unawaited(
        platform
            .setProperty('force-seekable', 'yes', waitForInitialization: true)
            .catchError((Object _) {}),
      );
    }
    _controller = buildVideoController ? VideoController(player) : null;
    _subscriptions.add(player.stream.error.listen(_onError));
    _subscriptions.add(
      player.stream.buffering.listen((value) {
        if (_disposed || value == _buffering) return;
        _buffering = value;
        if (!value && player.state.playing) {
          _stall?.cancel();
        }
        notifyListeners();
      }),
    );
    _subscriptions.add(
      player.stream.playing.listen((value) {
        // 唤醒锁跟着播放状态走：播就亮着、停就放掉。
        // 以前只在 pauseForSleep/dispose 时放，点暂停按钮走 playOrPause
        // 不碰唤醒锁，暂停后屏幕永不灭。ScreenAwake 是引用计数、
        // enable/disable 各有守卫，重复调是安全的。
        if (value) {
          _screenAwake.enable();
        } else {
          _screenAwake.disable();
        }
        if (_disposed || !value) return;
        _stall?.cancel();
        if (_error == null) return;
        _error = null;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      player.stream.videoParams.listen((parameters) {
        final size = videoDisplaySize(parameters);
        if (_disposed || size == null) return;
        _frames = true;
        _stall?.cancel();
        final ratio = size.width / size.height;
        final sizeChanged = _videoSize != size;
        if (sizeChanged) _videoSize = size;
        if (ratio.isFinite &&
            ratio > 0 &&
            (ratio - _aspectRatio).abs() > 0.01) {
          _aspectRatio = ratio;
          notifyListeners();
        } else if (sizeChanged) {
          notifyListeners();
        }
        if (_videoFps == null) {
          unawaited(_readVideoFps(player));
          // estimated-vf-fps 要等帧跑起来才有值，首帧刚到时可能
          // 还是 0；3 秒后再补读一次，还没有就不再纠缠。
          _fpsRetry ??= Timer(const Duration(seconds: 3), () {
            _fpsRetry = null;
            if (!_disposed && _videoFps == null && _frames) {
              unawaited(_readVideoFps(player));
            }
          });
        }
      }),
    );
  }

  /// 从 mpv 属性读当前流帧率；读不到保持 null（界面不显示）。
  Future<void> _readVideoFps(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    final generation = _generation;
    for (final property in const ['estimated-vf-fps', 'container-fps']) {
      try {
        final raw = await platform.getProperty(property);
        final value = double.tryParse(raw.trim());
        if (value != null && value > 0) {
          if (_disposed || generation != _generation) return;
          _videoFps = value;
          notifyListeners();
          return;
        }
      } catch (_) {}
    }
  }

  bool get _hasPlayback {
    final player = _player;
    if (player == null) return false;
    if (_frames) return true;
    return player.state.playing && !player.state.buffering;
  }

  void _armStallWatch() {
    _stall?.cancel();
    // 点播源（m3u 文件型，整部影片 HLS）出第一帧本来就慢，15 秒
    // 会把慢网下能播的片误判成断流；直播源保持 15 秒不变。
    final timeout = _source?.protocol == LiveProtocol.list
        ? _vodStallTimeout
        : _stallTimeout;
    _stall = Timer(timeout, () {
      if (_disposed || _error != null) return;
      // playing 事件与布防存在竞态：事件先到再布防时计时器无人取消，
      // 必须在触发时复核真实播放状态，避免正常播放被误判断流。
      if (_hasPlayback) return;
      _onError('当前线路长时间没有画面');
    });
  }

  /// 切换直播源或分类：重置频道表并按需播放第一条。
  Future<void> load(
    LiveSource source,
    List<LiveChannel> channels, {
    int index = 0,
    bool autoplay = true,
  }) async {
    _source = source;
    _channels = List.of(channels);
    _index = channels.isEmpty ? 0 : index.clamp(0, channels.length - 1);
    _retries = 0;
    _route = 0;
    _error = null;
    if (!autoplay || channels.isEmpty) {
      notifyListeners();
      return;
    }
    // DRM 频道不预建 mpv：它走 EXO，mpv 建出来也用不上，
    // 还会让「正在用哪个核」的判断失真。普通频道照旧预建。
    if (!channel!.hasDrm) {
      try {
        _ensurePlayer();
      } catch (error) {
        _error = '直播播放器无法启动：$error';
        notifyListeners();
        return;
      }
    }
    await play(_index);
  }

  Future<void> play(int index, {bool reconnect = false}) async {
    if (_disposed || _channels.isEmpty) return;
    if (reconnect && _sleepPaused) return;
    if (!reconnect) _sleepPaused = false;
    final channel = _channels[index.clamp(0, _channels.length - 1)];
    final source = _source;
    if (source == null) return;
    if (!reconnect) _retries = 0;
    if (!reconnect && index != _index) _route = 0;
    final token = ++_generation;
    _index = index;
    _loading = true;
    if (!reconnect) _error = null;
    notifyListeners();
    try {
      final plan = await _resolve(source, channel);
      if (_disposed || token != _generation) return;
      // DRM 频道改走 EXO 核：mpv 没有 DRM 解密能力，硬播只会
      // 失败重连。归一化不出 drm 时给明确报错，不黑屏死等、
      // 也不回头试 mpv。普通频道 _exoPlan 恒为 null，走下面
      // 原来的 mpv 路，一行不变。
      if (channel.hasDrm) {
        final drm = liveDrmForChannel(channel);
        if (drm == null) {
          _exoPlan = null;
          _loading = false;
          _error = '该频道带 DRM 加密，但授权信息不完整，暂时播不了';
          notifyListeners();
          return;
        }
        // 上一条普通频道可能还在 mpv 里出声，先停掉再切 EXO。
        try {
          await _player?.stop();
        } catch (_) {}
        if (_disposed || token != _generation) return;
        _exoPlan = PlaybackPlan(
          url: plan.url,
          headers: plan.headers,
          drm: drm,
          // session 每次起播都换新：切台/切线路/重连时 pane 靠它
          // 判定要重开，同一地址换了 drm 也不会漏重开。
          session: 'live-drm-$token-$_route',
        );
        _loading = false;
        _error = null;
        _screenAwake.enable();
        notifyListeners();
        return;
      }
      _exoPlan = null;
      _ensurePlayer();
      final player = _player;
      if (player == null) throw AppFailure('直播播放器无法启动');
      await _applyDecoderMode(player);
      _frames = false;
      // 换台先清掉上条流的分辨率与帧率，新流拿到 videoParams 后再
      // 显示，不拿旧流的数字冒充新台。
      _videoSize = null;
      _videoFps = null;
      _fpsRetry?.cancel();
      _fpsRetry = null;
      await player.open(
        Media(
          plan.url,
          httpHeaders: plan.headers.isEmpty ? null : plan.headers,
        ),
      );
      if (_sleepPaused) {
        await player.pause();
        return;
      }
      if (_disposed || token != _generation) return;
      _loading = false;
      _error = null;
      _screenAwake.enable();
      _armStallWatch();
      notifyListeners();
    } catch (error) {
      if (_disposed || token != _generation) return;
      _loading = false;
      _error = '$error';
      notifyListeners();
    }
  }

  /// 直连型直播源（面板 / 列表）支持在同一频道内切换线路。
  Future<LivePlayback> _resolve(LiveSource source, LiveChannel channel) {
    final multiRoute =
        source.protocol == LiveProtocol.pingtai ||
        source.protocol == LiveProtocol.list;
    if (_route > 0 && multiRoute && channel.urls.length > _route) {
      return Future.value(
        LivePlayback(url: channel.urls[_route], headers: channel.headers),
      );
    }
    return repository.playback(source, channel);
  }

  /// 切换到指定线路并重新播放。
  Future<void> playRoute(int route) {
    _route = route < 0 ? 0 : route;
    return play(_index);
  }

  /// 切换解码模式：hwdec 只在下一次打开流时生效，所以切完重播当前频道。
  Future<void> setDecoderMode(LiveDecoderMode mode) async {
    if (_disposed || mode == _decoderMode) return;
    _decoderMode = mode;
    notifyListeners();
    if (_channels.isEmpty) return;
    await play(_index);
  }

  /// 默认：线路回到第 1 条、解码回到自动。返回是否真的改动过，
  /// 调用方据此决定提示文案。改动过且有频道时重播当前频道。
  Future<bool> resetDefaults() async {
    if (_disposed) return false;
    final changed = _route != 0 || _decoderMode != LiveDecoderMode.auto;
    _route = 0;
    _decoderMode = LiveDecoderMode.auto;
    if (!changed) return false;
    notifyListeners();
    if (_channels.isEmpty) return true;
    await play(_index);
    return true;
  }

  /// 起播前应用当前解码模式：只在安卓原生 mpv 上设属性，其余平台
  /// 与测试替身直接跳过；属性设置失败绝不打断起播。
  Future<void> _applyDecoderMode(Player player) async {
    if (!Platform.isAndroid) return;
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('hwdec', _decoderMode.mpvValue);
      await platform.setProperty('hwdec-codecs', 'all');
    } catch (_) {}
  }

  /// 上一台 / 下一台，越界时环绕。
  void switchBy(int delta) {
    if (_channels.length < 2) return;
    final next = (_index + delta + _channels.length) % _channels.length;
    unawaited(play(next));
  }

  Future<void> retry() => play(_index, reconnect: true);

  /// 点播续播：跳到上次看到的位置。直播流不调这个方法；
  /// seek 失败（流不支持）只吞掉，不打断播放。
  Future<void> seekTo(Duration position) async {
    final player = _player;
    if (_disposed || player == null || position <= Duration.zero) return;
    try {
      await player.seek(position);
    } catch (_) {}
  }

  void _onError(String message) {
    if (_sleepPaused) return;
    if (_disposed) return;
    _loading = false;
    // 带 DRM 的频道本应走 EXO（见 play 的分流）；万一还有路径
    // 落到 mpv 的错误回调，也只报错不重连（mpv 解不了 DRM，
    // 重连只会重复失败）。
    if (channel?.hasDrm ?? false) {
      _error = '该频道带 DRM 加密，暂时播不了';
      notifyListeners();
      return;
    }
    _error = message.isEmpty ? '直播中断' : message;
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_sleepPaused) return;
    final channel = this.channel;
    // 线路数多于固定重试次数时必须走完整批线路：列表型源的可用线路可能排在
    // 最后一条，只允许推进 3 次就永远够不到它，用户只能手动一路切过去。
    final routes = channel?.urls.length ?? 0;
    final limit = routes > 1 ? routes : maxRetries;
    if (_retries >= limit) return;
    _retries++;
    // 实测列表型直播源的代理线路质量波动很大（同一批前缀会交替返回
    // 404/500 或掉到十几 KB/s），重连必须换线路，否则几次重试全部
    // 打在同一条已经劣化的线路上，表现为长时间转圈。
    if (channel != null && channel.urls.length > 1) {
      _route = (_route + 1) % channel.urls.length;
    }
    _reconnect?.cancel();
    _reconnect = Timer(_reconnectDelay, () {
      if (!_disposed) unawaited(play(_index, reconnect: true));
    });
  }

  @override
  void dispose() {
    _disposed = true;
    LiveSettingsStore.instance.removeListener(_onLiveSettingsChanged);
    sleepTimer.removeListener(_sleepChanged);
    sleepTimer.dispose();
    _reconnect?.cancel();
    _stall?.cancel();
    _fpsRetry?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _screenAwake.disable();
    _player?.dispose();
    _player = null;
    _controller = null;
    super.dispose();
  }
}
