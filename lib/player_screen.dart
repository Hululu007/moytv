import 'dart:async';

import 'app_page_route.dart';

import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'audio_background.dart';
import 'audio_continue.dart';
import 'audio_playback.dart';
import 'app_layout.dart';
import 'app_orientation.dart';
import 'app_theme.dart';
import 'home_screen.dart';
import 'player_back.dart';
import 'atmosphere_background.dart';
import 'tv_theme.dart';
import 'core_bridge.dart';
import 'custom_headers.dart';
import 'jar_bridge.dart';
import 'jar_youtube_takeover.dart';
import 'danmaku_controller.dart';
import 'danmaku_overlay.dart';
import 'episode_frame_cache.dart';
import 'episode_preview_card.dart';
import 'exo_subtitle.dart';
import 'follow_state.dart';
import 'intro_outro_skip.dart';
import 'track_selection.dart';
import 'local_store.dart';
import 'live_subtitle_audio.dart';
import 'live_subtitle_engine.dart';
import 'live_subtitle_service.dart';
import 'live_subtitle_settings.dart';
import 'models.dart';
import 'nonvideo_content.dart';
import 'playback_loader.dart';
import 'playback_parse.dart';
import 'playback_headers.dart';
import 'playback_redirect.dart';
import 'playback_foreground.dart';
import 'playback_preloader.dart';
import 'playback_queue.dart';
import 'seamless_switch.dart';
import 'playback_sniffer.dart';
import 'playback_sniff_verify.dart';
import 'playback_recovery.dart';
import 'playback_error.dart';
import 'player_backend.dart';
import 'playback_preferences.dart';
import 'player_controls.dart';
import 'player_core.dart';
import 'player_core_fallback.dart';
import 'player_route.dart';
import 'ijk_video_pane.dart';
import 'network_speed.dart';
import 'tvbox_video_pane.dart';
import 'tvbox_player_bridge.dart';
import 'player_interactions.dart';
import 'player_menu.dart';
import 'television_controls.dart';
import 'tmdb/tmdb_config.dart';
import 'tmdb/tmdb_metadata.dart';
import 'tmdb/tmdb_service.dart';
import 'widgets.dart';
import 'sources_screen.dart';
import 'video_enhancement.dart';
import 'viewing_experience_settings.dart';
import 'picture_quality_applier.dart';
import 'video_output_size.dart';
import 'windows_playback_tuning.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.detail,
    required this.initialIndex,
    required this.repository,
    required this.store,
    this.initialPosition = 0,
    this.localOnly = false,
    this.allowOnlineFallback = true,
    this.mediaId,
    this.playerFactory,
    this.videoBuilder,
    this.queue,
    this.startFullscreen = false,
    this.embedded = false,
    this.embeddedFullscreen = false,
    this.onEmbeddedClose,
    this.onEmbeddedFullscreen,
    this.onEmbeddedIndexChanged,
    this.onPlaybackExhausted,
    this.onRetryProbe,
    this.onPlaybackStarted,
    this.liveSubtitleEngine,
    this.liveSubtitleAudioExtractor,
  });
  final DramaDetail detail;
  final int initialIndex;
  final double initialPosition;
  final bool localOnly;
  final bool allowOnlineFallback;
  final String? mediaId;
  final AppRepository repository;
  final LocalStore store;
  final PlaybackQueue? queue;
  final bool startFullscreen;
  final bool embedded;
  final bool embeddedFullscreen;
  final VoidCallback? onEmbeddedClose;
  final VoidCallback? onEmbeddedFullscreen;
  final ValueChanged<int>? onEmbeddedIndexChanged;

  /// 恢复耗尽回调（女优模块静默换线用）：在线播放恢复耗尽、错误界面
  /// 已显示时调一次，带播放器自身的 context 供调用方弹栈换线。
  /// 默认 null，现有调用行为一字不变；本地播放不调。
  final void Function(BuildContext)? onPlaybackExhausted;

  /// 重试重探回调（女优模块用）：报错屏点“重试播放”时调，返回
  /// true 表示调用方已换新线起播（本页不再原地重播），false
  /// 表示重探无果、本页原地重播。默认 null，现有行为一字不变。
  final Future<bool> Function(BuildContext)? onRetryProbe;

  /// 开始播放回调：播放器第一次真播起来（playing 为真且进度已走）
  /// 时调一次，带当前取流方案与集序号；换集/换线重播时再调一次。
  /// 默认 null，现有行为一字不变；本地播放（plan.local）不调。
  final void Function(BuildContext, PlaybackPlan, int episodeIndex)?
  onPlaybackStarted;
  @visibleForTesting
  final Player Function()? playerFactory;
  @visibleForTesting
  final Widget Function(Widget controls)? videoBuilder;

  /// 测试用注入：实时字幕的识别引擎与音频取流器。生产环境不传，
  /// 服务用默认插件引擎与 FFmpeg 取流；测试注入假实现以便出字幕行。
  @visibleForTesting
  final LiveSubtitleEngine? liveSubtitleEngine;
  @visibleForTesting
  final LiveSubtitleAudioExtractor? liveSubtitleAudioExtractor;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

/// 一套 MPV 播放器装置（Player + 画面控制器）。无缝换集时有
/// 两套：一套在播、一套待命预热，对调时整套换角色，Player
/// 对象本身不换绑到别的装置上。
class _MpvRig {
  const _MpvRig(this.id, this.player, this.video);

  final int id;
  final Player player;
  final VideoController? video;
}

/// 一套 EXO 面板装置（句柄 + 当前 plan + 待命 plan）。与 MPV
/// 装置同理：两套轮换，面板按装置 key 钉在原地，角色靠属性区分。
class _TvboxRig {
  final TvboxPlaybackHandle handle = TvboxPlaybackHandle();
  PlaybackPlan? plan;
  double startPosition = 0;
  bool autoplay = true;

  /// 本装置处于待命角色时要预热的 plan；null 表示没在待命。
  PlaybackPlan? standbyPlan;
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late _MpvRig _activeMpvRig;
  _MpvRig? _standbyMpvRig;

  /// 当前在播的 MPV 装置的播放器 / 画面控制器。全页所有控制
  /// 逻辑都只认这两件；无缝对调时换的是装置，读取点不用改。
  Player get _player => _activeMpvRig.player;
  VideoController? get _video => _activeMpvRig.video;

  /// media_kit Video 的 state，控制层显隐变化时用它抬/落字幕
  /// （setSubtitleViewPadding）。非 media_kit 核（Exo/IJK/TVBox）与
  /// 测试桩视频路径下不走 Video，这里保持 null，回调空操作。
  VideoState? _videoState;
  // 实时字幕（MPV 核）：TVBox 面在 TvboxVideoPane 里自带接线，
  // 这里给 media_kit 路径补一份——服务只在 MPV 核启动；Exo 核走
  // TvboxVideoPane 里那份，IJK 核暂未接。
  LiveSubtitleSettings? _liveSettings;
  LiveSubtitleService? _liveSubtitle;
  final List<StreamSubscription<dynamic>> _liveSubscriptions = [];
  String _livePartial = '';
  List<String> _liveLines = const [];
  late VideoEnhancementController _enhancement;
  late PictureQualityApplier _pictureQuality;
  late final PlaybackLoader _loader;
  late final PlaybackPreloader _preloader;
  bool _preloadEnabled = true;
  bool _seamlessEnabled = false;
  final _seamless = SeamlessStandbyManager();
  final List<StreamSubscription<dynamic>> _engineSubscriptions = [];
  Completer<bool>? _standbyExoFrame;
  late final DanmakuController _danmaku;
  int _seekSequence = 0;
  bool _danmakuEnabled = true;
  late PlayerInteractions _interactions;
  final _playerFocus = FocusNode(debugLabel: 'player-surface');
  final _videoPaneKey = GlobalKey();
  final _tvboxRigs = <_TvboxRig>[_TvboxRig(), _TvboxRig()];
  int _activeTvboxRigIndex = 0;
  _TvboxRig get _activeTvboxRig => _tvboxRigs[_activeTvboxRigIndex];
  _TvboxRig get _standbyTvboxRig => _tvboxRigs[1 - _activeTvboxRigIndex];
  TvboxPlaybackHandle get _tvboxHandle => _activeTvboxRig.handle;
  PlaybackBackendManager? _backendManager;
  CoreFallbackController? _coreFallback;
  CoreFallbackMode _fallbackMode = CoreFallbackMode.all;
  PlayerCore? _fallbackCoreOverride;
  String _lastCoreErrorMessage = '';
  final _ijkHandle = IjkPlaybackHandle();
  PlaybackPlan? _ijkPlan;
  double _ijkStartPosition = 0;
  bool _ijkAutoplay = true;
  late PlayerCore _core;
  final _menuRevision = ValueNotifier<int>(0);
  Set<String> _frameKeys = {};
  final Set<String> _frameCaptureAttempted = {};
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final _recovery = PlaybackRecovery();
  final IntroOutroSkipEngine _skipEngine = IntroOutroSkipEngine();
  String? _savedProgressKey;
  final _health = PlaybackHealth();
  late final NetworkSpeedTracker _speedTracker;
  Timer? _saveTimer;
  Timer? _healthTimer;
  Timer? _errorTimer;
  Timer? _pictureInPictureExitTimer;
  Future<void> _operations = Future<void>.value();
  late int _index;
  late final int _profileEpoch;
  int _openedIndex = -1;
  int _generation = 0;
  int _requestedQuality = 0;
  int _routeIndex = 0;
  bool _loading = true;
  bool _forceOnline = false;
  bool _localFailure = false;
  bool _fullscreen = false;
  bool _pageFullscreen = false;
  bool _windowFullscreen = false;
  bool _automaticFullscreenSuppressed = true;
  bool _panelOpen = false;
  bool _episodePanelVisible = true;
  bool _episodesReversed = false;
  bool _synopsisExpanded = false;
  final ScrollController _episodeStripController = ScrollController();
  TmdbConfig _tmdbConfig = const TmdbConfig();
  TmdbMetadata? _tmdb;
  bool _autoAdvance = true;
  bool _adBlock = true;
  bool? _systemFullscreen;
  Orientation? _lastOrientation;
  bool _closed = false;
  bool _acceptErrors = false;
  bool _foreground = true;
  bool _playIntent = true;
  bool _playbackServiceHeld = false;
  // 切后台只留音频时视频轨的状态：true = 已关掉视频轨。
  // vid 是播放器级选项，切集/自动连播换片也不复位，不用每集重复关。
  bool _videoTrackOff = false;
  bool _showControlsOnPlaybackReady = true;
  bool _pendingError = false;
  bool _pictureInPictureSupported = false;
  bool _pictureInPictureActive = false;
  bool _pictureInPictureRequested = false;
  bool _pictureInPictureHandlerInstalled = false;
  bool _brightnessAdjusted = false;
  double? _cachedBrightness;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  String _loadingMessage = '正在准备播放';
  String? _error;
  String? _saveWarning;
  PlaybackPlan? _plan;

  // 音轨/字幕轨（第 8 点，仅 MPV 核）：菜单打开时把 media_kit 当前
  // 轨道快照存进这两张表，菜单条目 id 据此找回轨道对象；
  // _externalSubUrl 记录当前选中的外挂字幕，_subtitlesOff 记录关字幕。
  final Map<String, AudioTrack> _audioTrackById = {};
  final Map<String, SubtitleTrack> _subtitleTrackById = {};
  String? _externalSubUrl;
  bool _subtitlesOff = false;
  NonVideoContent? _nonVideo;

  /// 开始播放回调已通知过的（集序号|取流地址）：同一集同一地址只
  /// 通知一次；换集/换线重播时地址变了再通知一次。
  String? _playbackStartedKey;

  /// 真播起来了就通知一次调用方：playing 为真且进度已走（帧真正在
  /// 走，不是在缓冲），且取流方案在线（本地播放不通知）。
  /// playing 翻转时进度可能还是 0，进度推进时 playing 可能刚翻回来，
  /// 所以 playing 监听、进度监听、健康定时三处都调这里，以先到为准。
  void _maybeNotifyPlaybackStarted() {
    final callback = widget.onPlaybackStarted;
    final plan = _plan;
    if (callback == null ||
        plan == null ||
        plan.local ||
        _closed ||
        !mounted) {
      return;
    }
    if (!_enginePlaying || _enginePosition <= Duration.zero) return;
    final key = '$_index|${plan.url}';
    if (_playbackStartedKey == key) return;
    _playbackStartedKey = key;
    callback(context, plan, _index);
  }
  bool _audioMode = false;
  OverlayEntry? _audioMiniBar;

  // 音频模式的后台输出认领：只在音频模式下向听书单例认领三路输出
  //（保活 + 锁屏 + 胶囊），视频播放链不走这里。
  late final String _externalAudioOwnerId =
      'player_screen@${identityHashCode(this)}';
  bool _externalAudioClaimed = false;
  int _lastExternalReportAtMs = 0;
  bool _lastExternalPlaying = false;
  int _lastExternalIndex = -1;

  void _removeAudioMiniBar() {
    _audioMiniBar?.remove();
    _audioMiniBar = null;
    AudioContinue.hide();
  }

  void _showAudioMiniBar() {
    if (_audioMiniBar != null) return;
    final title = widget.detail.drama.title;
    final rawEpisodeTitle = widget.detail.episodes[_index].title;
    final episode =
        rawEpisodeTitle.isEmpty || episodeTitleLooksLikeUrl(rawEpisodeTitle)
        ? '第 ${widget.detail.episodes[_index].number} 集'
        : rawEpisodeTitle;
    AudioContinue.show(title: title, episode: episode);
    final entry = OverlayEntry(
      builder: (overlayContext) {
        return Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Material(
            color: const Color(0xFF1B1B1B),
            elevation: 8,
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: 56,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '返回播放页',
                      onPressed: () {
                        _removeAudioMiniBar();
                        Navigator.of(overlayContext).maybePop();
                      },
                      icon: const Icon(Icons.headphones, color: Colors.white),
                    ),
                    Expanded(
                      child: ValueListenableBuilder<String>(
                        valueListenable: AudioContinue.title,
                        builder: (context, value, _) {
                          return Text(
                            value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white),
                          );
                        },
                      ),
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: AudioContinue.playing,
                      builder: (context, playing, _) {
                        return IconButton(
                          tooltip: playing ? '暂停' : '继续',
                          onPressed: () {
                            _togglePlayback();
                            AudioContinue.playing.value = _playIntent;
                          },
                          icon: Icon(
                            playing ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                          ),
                        );
                      },
                    ),
                    IconButton(
                      tooltip: '停止',
                      onPressed: () {
                        if (_playIntent) _togglePlayback();
                        _removeAudioMiniBar();
                        unawaited(_saveProgress());
                      },
                      icon: const Icon(Icons.stop, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    _audioMiniBar = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  double _speed = 1;
  double _aspectRatio = 9 / 16;

  /// 全屏方向判定用的宽高比：原生句柄（TVBox/Exo）与 IJK 不走
  /// media_kit，videoParams 永远不到，_aspectRatio 恒等于初始 9/16；
  /// 方向判定再拿它当竖屏片，就会把横屏片也锁竖屏（点全屏只剩
  /// 竖屏上下黑边、看起来像“不能全屏”）。这两条核在宽高比未知
  /// 时按 16/9 兜底，与直播侧默认一致；MPV 核仍用真实宽高比，
  /// 竖屏片进全屏照旧锁竖屏。
  double get _orientationAspectRatio =>
      (_useNativeHandle || _useIjkCore) ? 16 / 9 : _aspectRatio;

  double _resumePosition = 0;
  bool _rotating = false;
  bool _backPending = false;
  bool _fullscreenApplied = false;
  bool _television = false;
  TelevisionDecoder _televisionDecoder = TelevisionDecoder.optimized;
  PlaybackOrientationMode _orientationMode = PlaybackOrientationMode.auto;
  ParseInterface? _selectedParse;
  String _lastPageUrl = '';
  bool _sniffFallbackTried = false;

  /// 嗅探这一级在当前集内是否已消耗：不随 _play 重入复位（复位
  /// 会让「嗅探→递送→核播失败→再嗅探」死循环），只在换集时清。
  bool _sniffRungConsumed = false;
  bool _deepSniffer = true;
  bool _sniffEmbedded = false;
  String? _sniffPreviousError;
  bool get _televisionDecoderApplies => _television && Platform.isAndroid;
  AppOrientationController? _orientationController;
  bool _embeddedOrientationApplied = false;
  bool get _pictureInPictureVisible =>
      _pictureInPictureActive || _pictureInPictureRequested;
  bool get _canUsePictureInPicture =>
      !_television &&
      defaultTargetPlatform == TargetPlatform.android &&
      _pictureInPictureSupported;
  bool get _mobile =>
      !_television &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  bool get _useTvbox =>
      !_television &&
      Platform.isAndroid &&
      (widget.store.player == 'tvbox') &&
      (_plan?.decryptionKey.isEmpty ?? true) &&
      (_plan?.forceMpv != true) &&
      _backendManager?.current != PlaybackBackend.main;
  PlayerCore get _baseEffectiveCore =>
      effectivePlayerCore(stored: _core, siteId: widget.detail.drama.source);
  PlayerCore get _effectiveCore => _fallbackCoreOverride ?? _baseEffectiveCore;
  bool get _useExoCore =>
      !_television && Platform.isAndroid && _effectiveCore == PlayerCore.exo;
  bool get _useIjkCore => !_television && _effectiveCore == PlayerCore.ijk;
  bool get _useNativeHandle => _useTvbox || _useExoCore;
  Duration get _enginePosition => _useNativeHandle
      ? _tvboxHandle.position
      : _useIjkCore
      ? _ijkHandle.position
      : _player.state.position;
  Duration get _engineDuration => _useNativeHandle
      ? _tvboxHandle.duration
      : _useIjkCore
      ? _ijkHandle.duration
      : _player.state.duration;
  bool get _enginePlaying => _useNativeHandle
      ? _tvboxHandle.playing
      : _useIjkCore
      ? _ijkHandle.playing
      : _player.state.playing;
  VideoEnhancementController? get _enhancementForUi =>
      _enhancement.supported ? _enhancement : null;
  PlaybackPreferences get _preferences => PlaybackPreferences(
    speed: _useNativeHandle
        ? _tvboxHandle.speed
        : _useIjkCore
        ? _ijkHandle.speed
        : _speed,
    quality: _requestedQuality,
    autoAdvance: _autoAdvance,
    danmaku: _danmakuEnabled,
    preload: _preloadEnabled,
    seamless: _seamlessEnabled,
    adBlock: _adBlock,
    enhancement: _enhancement.preferences,
    televisionDecoder: _televisionDecoder,
    orientationMode: _orientationMode,
  );
  String get _qualityLabel => _plan?.local == true
      ? '本地原画'
      : _requestedQuality == 0
      ? '自动'
      : '${_requestedQuality}P';
  int get _routeCount => _plan?.local == true ? 1 : (_plan?.routeCount ?? 1);
  int get _currentRoute =>
      (_plan?.routeIndex ?? 0).clamp(0, _routeCount > 0 ? _routeCount - 1 : 0);
  String get _routeLabel => '线路 ${_currentRoute + 1}';
  String get _session => _plan?.session ?? '';
  double get _currentPosition =>
      _useNativeHandle &&
          _openedIndex == _index &&
          _tvboxHandle.position > Duration.zero
      ? _tvboxHandle.positionSeconds
      : _useIjkCore &&
            _openedIndex == _index &&
            _ijkHandle.position > Duration.zero
      ? _ijkHandle.positionSeconds
      : _openedIndex == _index && _player.state.position.inMilliseconds > 0
      ? _player.state.position.inMilliseconds / 1000
      : _resumePosition;
  Duration get _seekFallbackPosition => _useNativeHandle
      ? _tvboxHandle.position
      : _useIjkCore
      ? _ijkHandle.position
      : _player.state.position;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _index = widget.initialIndex;
    _profileEpoch = widget.store.profileEpoch;
    final preferences = widget.store.playbackPreferences;
    _speed = preferences.speed;
    _tvboxHandle.speed = preferences.speed;
    _ijkHandle.speed = preferences.speed;
    _core = PlayerCoreStorage.read(widget.store.preferences);
    _fallbackMode = CoreFallbackModeStorage.read(widget.store.preferences);
    _requestedQuality = preferences.quality;
    _autoAdvance = true;
    _danmakuEnabled = preferences.danmaku;
    _adBlock = preferences.adBlock;
    unawaited(_loadDeepSniffer());
    unawaited(_loadLiveSubtitleSettings());
    _preloadEnabled = true;
    _seamlessEnabled = preferences.seamless;
    _televisionDecoder = preferences.televisionDecoder;
    _orientationMode = preferences.orientationMode;
    _loader = PlaybackLoader(widget.repository);
    _preloader = PlaybackPreloader(widget.repository);
    unawaited(_loadParseSelection());
    unawaited(_loadTmdb(widget.detail.drama));
    unawaited(_loadFrameKeys());
    _danmaku = DanmakuController(widget.repository)
      ..setEnabled(_danmakuEnabled);
    widget.store.addListener(_accessChanged);
    _activeMpvRig = _createMpvRig(0);
    _bindPlayerHelpers(preferences);
    _speedTracker = NetworkSpeedTracker(
      sample: () => fetchMpvNetworkSpeedSample(_player),
    );
    _playerFocus.addListener(() {
      if (!_playerFocus.hasPrimaryFocus && !_closed) _interactions.cancel();
    });
    _configurePictureInPicture();
    unawaited(_readSystemBrightness());
    _bindEngineStreams();
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _maybeNotifyPlaybackStarted();
      _maybeSkipOutro();
      unawaited(_speedTracker.tick());
      _syncSeamlessWarm();
      if (!_closed &&
          _acceptErrors &&
          !_loading &&
          _error == null &&
          _health.stalled(
            position: _enginePosition,
            playing: _enginePlaying && _playIntent,
            foreground: _foreground,
            now: DateTime.now(),
          )) {
        unawaited(_recover());
      }
    });
    if (_profileEpoch != widget.store.profileEpoch) {
      _loading = false;
      _error = '当前用户已变更';
    } else {
      _play(_index, position: widget.initialPosition);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed) {
        widget.repository.catalogUpdates.publish(
          widget.repository.catalogUpdates.current(widget.detail.drama),
          retryCover: true,
        );
        if (!widget.embedded) unawaited(_applyOrientation());
      }
    });
  }

  /// 建一套 MPV 装置。主装置在 initState 建，待命装置在第一次
  /// 无缝预热时才建（不开无缝就永远只有一套，行为与原来一致）。
  _MpvRig _createMpvRig(int id) {
    final player =
        widget.playerFactory?.call() ??
        Player(
          // Windows 曾经开 verbose 日志（为了从日志里嗅探 GL 渲染器名），
          // 但 mpv 每行日志都要跨 FFI 生成一个 PlayerLog 事件回到 Dart，
          // 播放时每秒上千行，本身就是抖动的来源。渲染环境改由
          // VideoEnhancementController 按 vo/vo-passes 判定后，这里只留 error。
          configuration: const PlayerConfiguration(
            bufferSize: 32 * 1024 * 1024,
            logLevel: MPVLogLevel.error,
          ),
        );
    final video = widget.videoBuilder == null
        ? VideoController(
            player,
            configuration: const VideoControllerConfiguration(
              enableHardwareAcceleration: true,
            ),
          )
        : null;
    return _MpvRig(id, player, video);
  }

  /// 把绑死在单个 Player 上的三个辅助对象（画质增强 / 画质档 /
  /// 手势交互）绑到当前在播装置上。initState 调一次；无缝对调
  /// 后旧的先释放、再按当前偏好重建，指向新装置。
  void _bindPlayerHelpers(PlaybackPreferences preferences) {
    _enhancement = VideoEnhancementController(
      player: _player,
      video: _video,
      preferences: preferences.enhancement,
      category: widget.detail.drama.category,
      tags: widget.detail.drama.tags,
    );
    _pictureQuality = PictureQualityApplier(_player)
      ..apply(preferences.pictureQuality);
    _interactions = PlayerInteractions(
      player: _player,
      available: () =>
          !_closed &&
          widget.store.profileEpoch == _profileEpoch &&
          !_loading &&
          _error == null &&
          _foreground &&
          !_panelOpen,
      baseSpeed: () => _speed,
      swipeSeek: () => widget.store.playbackPreferences.swipeSeekSeconds,
      onTogglePlayback: _togglePlayback,
      onSeek: _seekTo,
      onFullscreen: widget.embedded ? _notifyEmbeddedFullscreen : _rotate,
      onEpisode: (direction) {
        if (widget.detail.episodes.length > 1) {
          final next = _index + direction;
          if (next < 0) return '已经是第一集';
          if (next >= widget.detail.episodes.length) return '已经是最后一集';
          unawaited(_play(next, showControlsOnReady: false));
          return '第 ${widget.detail.episodes[next].number} 集';
        }
        return _queueSwipe(direction);
      },
      onBrightness: _androidBrightness ? _setScreenBrightness : null,
      currentBrightness: _androidBrightness ? _currentBrightness : null,
    );
  }

  /// 订阅在播装置的引擎流。对调后先退订旧装置、再订新装置，
  /// 监听体都读 _player（当前装置），不用改。
  void _bindEngineStreams() {
    _engineSubscriptions.add(
      _player.stream.error.listen((error) {
        if (_enhancement.handlePlaybackError(error)) return;
        if (!_closed && _acceptErrors && mounted && error.trim().isNotEmpty) {
          _lastCoreErrorMessage = error;
          _queueRecovery();
        }
      }),
    );
    _engineSubscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed &&
            !_loading &&
            !_closed &&
            _acceptErrors &&
            _error == null) {
          final duration = _player.state.duration;
          if (duration <= Duration.zero ||
              _player.state.position < duration - const Duration(seconds: 2)) {
            _queueRecovery();
          } else if (_autoAdvance &&
              _foreground &&
              !_panelOpen &&
              _index + 1 < widget.detail.episodes.length) {
            _audioMode
                ? _playAudio(_index + 1)
                : _play(_index + 1, showControlsOnReady: false);
          } else {
            _playIntent = false;
            _interactions.cancel();
            unawaited(_player.pause());
            unawaited(_saveProgress());
          }
        }
      }),
    );
    _engineSubscriptions.add(
      _player.stream.position.listen((position) {
        _maybeNotifyPlaybackStarted();
        if (!_closed && _openedIndex == _index && position > Duration.zero) {
          _resumePosition = position.inMilliseconds / 1000;
        }
        _syncDanmaku();
        _syncPreload();
        _maybeSkipOutro();
        _maybeCaptureEpisodeFrame(position);
        _claimOrReportExternalAudio();
        if (_updateLiveSubtitleLines(position)) setState(() {});
      }),
    );
    for (final stream in [
      _player.stream.duration,
      _player.stream.buffer,
      _player.stream.playing,
      _player.stream.buffering,
      _player.stream.rate,
      _player.stream.completed,
    ]) {
      _engineSubscriptions.add(
        stream.listen((_) {
          _syncDanmaku();
          _syncPreload();
        }),
      );
    }
    _engineSubscriptions.add(
      _player.stream.playing.listen((playing) {
        _maybeNotifyPlaybackStarted();
        _claimOrReportExternalAudio();
        final plan = _plan;
        if (!playing || plan == null || plan.routeIndex == _routeIndex) {
          return;
        }
        if (mounted && !_closed) {
          setState(() => _routeIndex = plan.routeIndex);
        }
      }),
    );
    _engineSubscriptions.add(
      _player.stream.videoParams.listen((parameters) {
        final size = videoDisplaySize(parameters);
        if (size != null && mounted && !_closed) {
          final previousRatio = _aspectRatio;
          setState(() {
            _aspectRatio = size.width / size.height;
          });
          _scheduleSystemUi();
          if ((previousRatio >= 1) != (_aspectRatio >= 1)) {
            if (widget.embedded) {
              // 内嵌时 _applyOrientation 提前返回：已在全屏里才跟宽高比重锁，
              // 没全屏时详情页的方向不受播放器干预。
              if (widget.embeddedFullscreen) {
                unawaited(_syncEmbeddedOrientation());
              }
            } else {
              unawaited(_applyOrientation());
            }
          }
        }
      }),
    );
  }

  void _accessChanged() {
    if (!_closed &&
        (widget.store.profileEpoch != _profileEpoch || widget.store.locked)) {
      _preloader.clear();
      _discardSeamlessStandby();
      _enhancement.suspend();
      _playIntent = false;
      unawaited(_player.pause());
    }
    if (!_closed &&
        (widget.store.profileEpoch != _profileEpoch ||
            widget.store.locked ||
            !widget.store.allowsSource('hongguo'))) {
      _danmaku.setPlan(null);
    }
  }

  void _configurePictureInPicture() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _pictureInPictureHandlerInstalled = true;
    AppDevice.channel.setMethodCallHandler((call) async {
      if (call.method == 'pictureInPictureChanged') {
        final arguments = call.arguments;
        final active = arguments is Map && arguments['active'] == true;
        _setPictureInPictureStatus(active: active, delayHiddenPause: !active);
      }
    });
    unawaited(_refreshPictureInPictureStatus());
  }

  Future<void> _refreshPictureInPictureStatus() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'pictureInPictureStatus',
      );
      if (!mounted || _closed) return;
      _setPictureInPictureStatus(
        supported: status?['supported'] == true,
        active: status?['active'] == true,
      );
    } on PlatformException {
      if (mounted && !_closed) {
        _setPictureInPictureStatus(supported: false, active: false);
      }
    } on MissingPluginException {
      if (mounted && !_closed) {
        _setPictureInPictureStatus(supported: false, active: false);
      }
    }
  }

  void _setPictureInPictureStatus({
    bool? supported,
    bool? active,
    bool? requested,
    bool delayHiddenPause = false,
  }) {
    final nextSupported = supported ?? _pictureInPictureSupported;
    final nextActive = active ?? _pictureInPictureActive;
    final nextRequested =
        requested ?? (nextActive ? false : _pictureInPictureRequested);
    void assign() {
      _pictureInPictureSupported = nextSupported;
      _pictureInPictureActive = nextActive;
      _pictureInPictureRequested = nextRequested;
    }

    if (mounted && !_closed) {
      setState(assign);
    } else {
      assign();
    }
    if (_pictureInPictureVisible ||
        _lifecycleState == AppLifecycleState.resumed) {
      _pictureInPictureExitTimer?.cancel();
      _applyLifecycleVisibility();
      return;
    }
    _pictureInPictureExitTimer?.cancel();
    _applyLifecycleVisibility();
    if (delayHiddenPause) {
      _pictureInPictureExitTimer = Timer(const Duration(milliseconds: 700), () {
        if (!_closed &&
            !_pictureInPictureVisible &&
            _lifecycleState != AppLifecycleState.resumed) {
          _applyLifecycleVisibility();
        }
      });
    }
  }

  /// 切后台只留音频：视频轨一关，mpv 就不再解码视频帧，画面不渲染、
  /// GPU 不耗电，声音照常在后台播；回前台再开画面。
  /// 只动 media_kit 那路（TVBox/Exo 原生句柄没有这路子，不碰）。
  /// 画中画在前台不算后台，轨道保持开着。
  void _syncVideoTrack(bool visible) {
    if (_closed || _useNativeHandle) return;
    if (!visible && !_videoTrackOff && _enginePlaying) {
      _videoTrackOff = true;
      unawaited(_player.setVideoTrack(VideoTrack.no()));
    } else if (visible && _videoTrackOff) {
      _videoTrackOff = false;
      unawaited(_player.setVideoTrack(VideoTrack.auto()));
    }
  }

  void _applyLifecycleVisibility() {
    final windowsInactive =
        Platform.isWindows && _lifecycleState == AppLifecycleState.inactive;
    final visible =
        _lifecycleState == AppLifecycleState.resumed ||
        windowsInactive ||
        _pictureInPictureVisible;
    _foreground = visible;
    _syncVideoTrack(visible);
    _enhancement.setForeground(_foreground);
    _syncDanmaku();
    _syncPreload();
    _health.reset();
    if (!visible) _interactions.cancel();
    if (!_playbackServiceHeld &&
        shouldAcquirePlaybackService(
          playing: _enginePlaying,
          useTvbox: _useNativeHandle,
        )) {
      _playbackServiceHeld = true;
      unawaited(PlaybackForeground.acquire(widget.detail.drama.title));
    }
    if (!visible &&
        (_lifecycleState == AppLifecycleState.paused ||
            _lifecycleState == AppLifecycleState.hidden)) {
      unawaited(_saveProgress());
    }
    if (visible && _pendingError) {
      _queueRecovery();
    }
  }

  Future<void> _enterPictureInPicture() async {
    if (!_canUsePictureInPicture ||
        _closed ||
        _loading ||
        _error != null ||
        _panelOpen) {
      return;
    }
    _interactions.cancel();
    final rawRatio = _aspectRatio.isFinite && _aspectRatio > 0
        ? _aspectRatio
        : 16 / 9;
    final ratio = rawRatio.clamp(1 / 2.39, 2.39).toDouble();
    final width = ratio >= 1 ? (1000 * ratio).round() : 1000;
    final height = ratio >= 1 ? 1000 : (1000 / ratio).round();
    _setPictureInPictureStatus(requested: true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _closed) return;
    final sourceRect = _pictureInPictureSourceRect();
    final arguments = <String, int>{'width': width, 'height': height};
    if (sourceRect != null) arguments.addAll(sourceRect);
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'enterPictureInPicture',
        arguments,
      );
      if (!mounted || _closed) return;
      final supported = status?['supported'] == true;
      final active = status?['active'] == true;
      final requested = status?['requested'] == true;
      _setPictureInPictureStatus(
        supported: supported,
        active: active,
        requested: requested && !active,
      );
      if (!supported || (!active && !requested)) {
        _notice('当前设备不支持画中画');
      } else if (requested && !active) {
        _pictureInPictureExitTimer?.cancel();
        _pictureInPictureExitTimer = Timer(const Duration(seconds: 2), () {
          if (!_closed &&
              _pictureInPictureRequested &&
              !_pictureInPictureActive) {
            _setPictureInPictureStatus(requested: false);
          }
        });
      }
    } on PlatformException {
      _setPictureInPictureStatus(requested: false);
      _notice('无法进入画中画，请检查系统权限');
    } on MissingPluginException {
      _setPictureInPictureStatus(supported: false, requested: false);
      _notice('当前平台不支持画中画');
    }
  }

  Map<String, int>? _pictureInPictureSourceRect() {
    final paneContext = _videoPaneKey.currentContext;
    final renderObject = paneContext?.findRenderObject();
    if (paneContext == null ||
        renderObject is! RenderBox ||
        !renderObject.hasSize) {
      return null;
    }
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    final ratio =
        MediaQuery.maybeOf(paneContext)?.devicePixelRatio ??
        View.of(paneContext).devicePixelRatio;
    final left = (topLeft.dx * ratio).round().clamp(0, 100000);
    final top = (topLeft.dy * ratio).round().clamp(0, 100000);
    final right = ((topLeft.dx + size.width) * ratio).round().clamp(0, 100000);
    final bottom = ((topLeft.dy + size.height) * ratio).round().clamp(
      0,
      100000,
    );
    if (right <= left || bottom <= top) return null;
    return {'left': left, 'top': top, 'right': right, 'bottom': bottom};
  }

  void _syncPreload() {
    if (_closed) return;
    if (!_preloadEnabled ||
        !_foreground ||
        widget.localOnly ||
        _plan?.local == true ||
        _loading ||
        _error != null ||
        _openedIndex != _index ||
        widget.store.profileEpoch != _profileEpoch ||
        widget.store.locked ||
        _index + 1 >= widget.detail.episodes.length) {
      _preloader.clear();
      _discardSeamlessStandby();
      return;
    }
    final state = _player.state;
    if (!state.playing || state.buffering || !_playIntent) {
      _preloader.pause();
      return;
    }
    final duration = state.duration.inMilliseconds;
    final position = state.position.inMilliseconds;
    if (duration <= 0 ||
        position < 2000 ||
        (position < duration ~/ 2 && duration - position > 45000) ||
        state.buffer.inMilliseconds - position < 5000) {
      return;
    }
    _preloader.prepare(
      widget.detail.drama,
      _audioMode
          ? _audioEpisodeFor(_index + 1) ?? widget.detail.episodes[_index + 1]
          : widget.detail.episodes[_index + 1],
      quality: _requestedQuality,
      route: _routeIndex,
      adBlock: _adBlock,
    );
  }

  // ===== 无缝换集：待命预热与对调 =====
  //
  // 机制：预加载备好下一集 plan 后（peekReady 只看不取），按本集
  // 的内核路由把 plan 喂给待命装置预热首帧——EXO 是第二个面板
  // 暂停在起点备好首帧，MPV 是第二个 Player 静音打开待命；
  // SeamlessStandbyManager 只记账（目标集 / 内核 / 首帧是否就绪）。
  // 换集走 _play 时若待命已就绪且目标对得上，在 _trySeamlessSwap
  // 里对调装置、跳过停播重开；任何一环对不上就当无事发生，
  // _play 原路走完——这就是失败回落，不需要额外错误处理。
  // IJK 插件 prepare 完自动开播、没有暂停预热与首帧事件，
  // 双 mediacodec 实例又不可靠，恒不预热、切集走现行路（降级）。

  /// 播放进度驱动的预热同步：与 _syncPreload 同门槛（播到后段
  /// 才备下一集），但进度取通用引擎读数，原生核也驱动得动
  /// （原生核的进度不走 MPV 流，原 _syncPreload 实际只覆盖 MPV）。
  /// 由引擎流（MPV）与 1 秒健康定时器（全核）共同调用。
  void _syncSeamlessWarm() {
    if (_closed || !_seamlessEnabled || _audioMode) return;
    if (!_foreground ||
        widget.localOnly ||
        _plan?.local == true ||
        _loading ||
        _error != null ||
        _openedIndex != _index ||
        widget.store.profileEpoch != _profileEpoch ||
        widget.store.locked ||
        _index + 1 >= widget.detail.episodes.length) {
      return;
    }
    if (!_enginePlaying || !_playIntent) return;
    final duration = _engineDuration.inMilliseconds;
    final position = _enginePosition.inMilliseconds;
    if (duration <= 0 || position < 2000) return;
    if (position < duration ~/ 2 && duration - position > 45000) return;
    final nextEpisode = widget.detail.episodes[_index + 1];
    _preloader.prepare(
      widget.detail.drama,
      nextEpisode,
      quality: _requestedQuality,
      route: _routeIndex,
      adBlock: _adBlock,
    );
    final plan = _preloader.peekReady(
      widget.detail.drama,
      nextEpisode,
      quality: _requestedQuality,
      route: _routeIndex,
      adBlock: _adBlock,
    );
    if (plan == null || !seamlessPlanWarmable(plan)) return;
    final useNative =
        ((_useTvbox || _useExoCore) || plan.hasDrm) &&
        plan.decryptionKey.isEmpty &&
        !plan.forceMpv;
    final useIjk =
        _useIjkCore && plan.decryptionKey.isEmpty && !plan.forceMpv;
    if (useIjk) return;
    final kernel = useNative ? SeamlessKernel.exo : SeamlessKernel.mpv;
    // 测试桩 / 无画面控制器环境没有可预热的画面，跳过 MPV 预热。
    if (kernel == SeamlessKernel.mpv && _video == null) return;
    final key = seamlessStandbyKey(index: _index + 1, plan: plan);
    if (_seamless.key == key && _seamless.hasStandby) return;
    // 与 _play 落地时同样的自定义头变换，待命与正式播同一份头。
    final warmedPlan = plan.withHeaders(
      applyCustomHeaders(
        plan.url,
        plan.headers,
        enabled: widget.store.customHeadersEnabled,
        rules: widget.store.customHeaderRules,
      ),
    );
    final firstFrame = kernel == SeamlessKernel.exo
        ? _warmExoStandby(warmedPlan)
        : _warmMpvStandby(warmedPlan);
    unawaited(
      _seamless
          .warm(
            key: key,
            targetIndex: _index + 1,
            kernel: kernel,
            plan: warmedPlan,
            firstFrame: firstFrame,
          )
          .then((_) {
            // 预热落定为失败：拆掉内核侧待命，免得白占一个播放器；
            // 账已被更新的预热顶掉（key 不同）时不动新待命。
            if (!_closed &&
                _seamless.key == key &&
                _seamless.phase == SeamlessPhase.failed) {
              _teardownSeamlessKernel();
            }
          }),
    );
  }

  /// MPV 待命预热：待命装置静音、暂停打开下一集，等首帧参数
  /// 到达即算备好。平台属性先按正式播的同一套打上，对调后
  /// 解码行为与普通开播一致。
  Future<bool> _warmMpvStandby(PlaybackPlan plan) async {
    final rig = _standbyMpvRig ??= _createMpvRig(1);
    if (mounted && !_closed) setState(() {});
    final player = rig.player;
    try {
      await _applyMpvPlatformProperties(player, plan);
      await player.setVolume(0);
      await player.open(
        Media(plan.url, httpHeaders: plan.headers),
        play: false,
      );
    } catch (_) {
      return false;
    }
    final completer = Completer<bool>();
    late StreamSubscription<VideoParams> paramsSub;
    late StreamSubscription<String> errorSub;
    paramsSub = player.stream.videoParams.listen((params) {
      if (videoDisplaySize(params) != null && !completer.isCompleted) {
        completer.complete(true);
      }
    });
    errorSub = player.stream.error.listen((_) {
      if (!completer.isCompleted) completer.complete(false);
    });
    final result = await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => false,
    );
    await paramsSub.cancel();
    await errorSub.cancel();
    return result;
  }

  /// EXO 待命预热：把 plan 挂到待命面板（面板以待命模式打开、
  /// 暂停在起点），等面板报首帧。面板早已挂着同一条 plan 且
  /// 首帧已备好时直接算完成。
  Future<bool> _warmExoStandby(PlaybackPlan plan) {
    final rig = _standbyTvboxRig;
    final alreadyWarming =
        rig.standbyPlan != null &&
        rig.standbyPlan!.session == plan.session &&
        rig.standbyPlan!.url == plan.url;
    rig.standbyPlan = plan;
    rig.handle.speed = _speed;
    final completer = Completer<bool>();
    _standbyExoFrame = completer;
    if (mounted && !_closed) setState(() {});
    if (alreadyWarming && rig.handle.firstFrameReady) {
      scheduleMicrotask(() {
        if (!completer.isCompleted) completer.complete(true);
      });
    }
    return completer.future;
  }

  void _onStandbyExoFirstFrame() {
    final completer = _standbyExoFrame;
    if (completer != null && !completer.isCompleted) {
      completer.complete(true);
    }
  }

  void _onStandbyExoError(String _) {
    final completer = _standbyExoFrame;
    if (completer != null && !completer.isCompleted) {
      completer.complete(false);
    }
  }

  /// 拆内核侧待命（账面复位在 _discardSeamlessStandby 里做）：
  /// EXO 待命面板摘 plan 并停播，MPV 待命装置停播（装置留着
  /// 复用，不销毁）。没有待命时是空操作，不触发无谓重建。
  void _teardownSeamlessKernel() {
    final completer = _standbyExoFrame;
    _standbyExoFrame = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(false);
    }
    var changed = false;
    final rig = _standbyTvboxRig;
    if (rig.standbyPlan != null) {
      rig.standbyPlan = null;
      unawaited(rig.handle.stop());
      changed = true;
    }
    final mpvStandby = _standbyMpvRig;
    if (mpvStandby != null) {
      unawaited(mpvStandby.player.stop());
    }
    if (changed && mounted && !_closed) setState(() {});
  }

  void _discardSeamlessStandby() {
    if (_seamless.phase == SeamlessPhase.idle &&
        _standbyTvboxRig.standbyPlan == null) {
      return;
    }
    _seamless.discard();
    _teardownSeamlessKernel();
  }

  /// MPV 装置对调：待命装置升为在播，引擎流与三个辅助对象
  /// 全部改绑新装置，旧装置停播转待命（等下一次预热复用）。
  /// 控制层靠装置 id 的 key 强制重建，订阅自动跟上新装置。
  Future<void> _swapMpvRigs({required double volume}) async {
    final oldRig = _activeMpvRig;
    final newRig = _standbyMpvRig!;
    _activeMpvRig = newRig;
    _standbyMpvRig = oldRig;
    for (final subscription in _engineSubscriptions) {
      await subscription.cancel();
    }
    _engineSubscriptions.clear();
    _bindEngineStreams();
    final oldEnhancement = _enhancement;
    unawaited(oldEnhancement.close());
    unawaited(_pictureQuality.dispose());
    _interactions.dispose();
    _bindPlayerHelpers(widget.store.playbackPreferences);
    unawaited(oldRig.player.stop());
    await _player.setVolume(volume);
  }

  /// MPV 平台属性（解码/缓冲/画质管线）：正式开播前在 _play 里
  /// 打在在播装置上；无缝预热时打在待命装置上，保证对调前后
  /// 解码行为一致。从 _play 的安装段原样抽出，逻辑一字未改。
  Future<void> _applyMpvPlatformProperties(
    Player player,
    PlaybackPlan plan,
  ) async {
    final platform = player.platform;
    if (platform is NativePlayer) {
      if (Platform.isAndroid) {
        if (_televisionDecoderApplies) {
          final optimized =
              _televisionDecoder == TelevisionDecoder.optimized;
          await platform.setProperty(
            'hwdec',
            _televisionDecoder == TelevisionDecoder.software
                ? 'no'
                : 'mediacodec-copy',
          );
          await platform.setProperty('hwdec-codecs', 'all');
          await platform.setProperty(
            'opengl-pbo',
            optimized ? 'yes' : 'no',
          );
          await platform.setProperty(
            'video-latency-hacks',
            optimized ? 'yes' : 'no',
          );
          await platform.setProperty('scale', 'bilinear');
          await platform.setProperty('cscale', 'bilinear');
          await platform.setProperty('dscale', 'bilinear');
          await platform.setProperty('correct-downscaling', 'no');
          await platform.setProperty(
            'vd-lavc-skiploopfilter',
            optimized ? 'all' : 'default',
          );
          await platform.setProperty(
            'vd-lavc-skipidct',
            optimized ? 'all' : 'default',
          );
          await platform.setProperty('vd-lavc-threads', '2');
          await platform.setProperty(
            'demuxer-max-bytes',
            '${4 * 1024 * 1024}',
          );
          await platform.setProperty(
            'demuxer-max-back-bytes',
            '${1 * 1024 * 1024}',
          );
          await platform.setProperty('demuxer-readahead-secs', '5');
        } else {
          await platform.setProperty('hwdec', 'auto-safe');
          await platform.setProperty('hwdec-codecs', 'all');
          await platform.setProperty('vd-lavc-skiploopfilter', 'nonkey');
          await platform.setProperty('vd-lavc-threads', '4');
        }
        await platform.setProperty('vd-lavc-fast', 'yes');
        await platform.setProperty('video-sync', 'audio');
        await platform.setProperty('framedrop', 'vo');
      } else if (Platform.isWindows) {
        await WindowsPlaybackTuning.apply(platform, local: plan.local);
      }
      if (plan.local || plan.decryptionKey.isNotEmpty) {
        await platform.setProperty(
          'demuxer-lavf-o',
          [
            'seg_max_retry=3',
            'strict=experimental',
            'allowed_extensions=ALL',
            plan.local
                ? 'protocol_whitelist=[file,crypto,data]'
                : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
            if (plan.decryptionKey.isNotEmpty)
              'decryption_key=${plan.decryptionKey}',
          ].join(','),
        );
        await platform.setProperty('network-timeout', '20');
      }
    }
  }

  /// 换集落地时尝试无缝对调。命中条件：无缝开着、不是恢复/换线/
  /// 外部预备 plan、从头播、待命已就绪且目标集与内核都对得上。
  /// 命中则完成与正式开播等价的全部状态落地并返回 true，
  /// _play 不再走停播重开；任何不命中返回 false，原路照走。
  Future<bool> _trySeamlessSwap({
    required int index,
    required PlaybackPlan plan,
    required int ticket,
    required double position,
    required bool playWhenReady,
    required PlaybackRecoveryAction? recoveryAction,
    required int? routeSelection,
    required PlaybackPlan? preparedPlan,
  }) async {
    if (!_seamlessEnabled || _audioMode || _closed) return false;
    if (recoveryAction != null ||
        routeSelection != null ||
        preparedPlan != null) {
      return false;
    }
    if (position != 0 || !playWhenReady) return false;
    if (_seamless.phase != SeamlessPhase.ready ||
        _seamless.targetIndex != index) {
      return false;
    }
    final useNative =
        ((_useTvbox || _useExoCore) || plan.hasDrm) &&
        plan.decryptionKey.isEmpty &&
        !plan.forceMpv;
    final useIjk =
        _useIjkCore && plan.decryptionKey.isEmpty && !plan.forceMpv;
    if (useIjk) return false;
    final kernel = useNative ? SeamlessKernel.exo : SeamlessKernel.mpv;
    if (_seamless.kernel != kernel) {
      _discardSeamlessStandby();
      return false;
    }
    final key = seamlessStandbyKey(index: index, plan: plan);
    if (_seamless.take(key) == null) return false;
    var swapped = false;
    await _serialize(() async {
      if (_closed || ticket != _generation) return;
      _plan = plan;
      _backendManager = PlaybackBackendManager(
        initial: useNative ? PlaybackBackend.tvbox : PlaybackBackend.main,
      );
      _acceptErrors = true;
      if (useNative) {
        final demoted = _activeTvboxRig;
        _activeTvboxRigIndex = 1 - _activeTvboxRigIndex;
        final promoted = _activeTvboxRig;
        promoted.plan = plan;
        promoted.startPosition = 0;
        promoted.autoplay = _foreground && _playIntent;
        promoted.standbyPlan = null;
        demoted.plan = null;
        demoted.standbyPlan = null;
        unawaited(demoted.handle.stop());
        unawaited(promoted.handle.setSpeed(_speed));
        if (promoted.autoplay) {
          unawaited(promoted.handle.play());
        } else {
          unawaited(promoted.handle.pause());
        }
      } else {
        final volume = _player.state.volume;
        await _swapMpvRigs(volume: volume);
        await _interactions.applySpeed();
        _enhancement.mediaReady();
        if (_foreground && _playIntent) {
          await _player.play();
        } else {
          await _player.pause();
        }
        unawaited(_startLiveSubtitle(plan, 0));
      }
      _openedIndex = index;
      _health.reset();
      swapped = true;
      if (mounted && !_closed && ticket == _generation) {
        setState(() {
          _loading = false;
        });
        _danmaku.setPlan(plan);
        _syncDanmaku();
        _menuRevision.value++;
        _applyLifecycleVisibility();
      }
    });
    if (!swapped) {
      // 待命已被 take 消费但对调没落地（多为代次已过期、新 _play
      // 接管）：内核侧待命一并拆掉，免得残留一个备好首帧的播放器。
      _teardownSeamlessKernel();
    }
    return swapped;
  }

  void _syncDanmaku({bool discontinuity = false}) {
    if (_closed) return;
    final state = _player.state;
    _danmaku.update(
      position: state.position,
      duration: state.duration,
      speed: state.rate,
      playing: state.playing && _playIntent && !state.completed,
      buffering: state.buffering,
      foreground: _foreground,
      available:
          !_loading &&
          _error == null &&
          _openedIndex == _index &&
          widget.store.profileEpoch == _profileEpoch &&
          !widget.store.locked &&
          widget.store.allowsSource('hongguo'),
      discontinuity: discontinuity,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final television = AppLayout.isTelevision(context);
    if (_television != television) {
      _fullscreen = false;
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
    }
    _television = television;
    _orientationController = AppOrientationScope.maybeOf(context);
    final orientation = MediaQuery.orientationOf(context);
    if (_lastOrientation != null && _lastOrientation != orientation) {
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
      // 退出全屏回到竖屏合一页后，选集横排滚回当前集（FongMi 同款语义）
      if (!_showFullscreen) _scrollEpisodeStripToCurrent();
    }
    _lastOrientation = orientation;
    _scheduleSystemUi();
    if (widget.startFullscreen && !_fullscreenApplied) {
      _fullscreenApplied = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_closed) _rotate();
      });
    }
    if (widget.embedded &&
        widget.embeddedFullscreen &&
        !_embeddedOrientationApplied) {
      _embeddedOrientationApplied = true;
      unawaited(_syncEmbeddedOrientation());
    }
  }

  @override
  void didUpdateWidget(covariant PlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.embedded &&
        widget.embeddedFullscreen != oldWidget.embeddedFullscreen) {
      unawaited(_syncEmbeddedOrientation());
    }
  }

  void _scheduleSystemUi() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closed || (!_mobile && !_television)) return;
      final fullscreen = _showFullscreen;
      if (_systemFullscreen == fullscreen) return;
      _systemFullscreen = fullscreen;
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        ),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _applyLifecycleVisibility();
  }

  void _queueRecovery() {
    if (_closed || !_acceptErrors || _error != null) {
      return;
    }
    _pendingError = true;
    if (!_foreground || (_errorTimer?.isActive ?? false)) {
      return;
    }
    final ticket = _generation;
    final position = _player.state.position;
    _errorTimer = Timer(const Duration(milliseconds: 900), () {
      if (_closed || ticket != _generation || !_foreground || !_acceptErrors) {
        return;
      }
      _pendingError = false;
      final state = _player.state;
      if (state.playing &&
          !state.buffering &&
          (state.width ?? 0) > 0 &&
          state.position > position + const Duration(milliseconds: 300)) {
        // 已经自愈：撤销"原线路重试"的消耗。否则这条失败链会带着旧状态，
        // 之后偶发一次网络抖动就直接跳线，而不是先重试当前线路。
        _recovery.reset();
        return;
      }
      unawaited(_recover());
    });
  }

  Future<void> _recover() async {
    final current = _plan;
    if (_closed ||
        !_acceptErrors ||
        !_foreground ||
        current == null ||
        _error != null) {
      return;
    }
    _acceptErrors = false;
    _danmaku.setPlan(null);
    _errorTimer?.cancel();
    _pendingError = false;
    final position = _currentPosition;
    final action = current.local
        ? PlaybackRecoveryAction.stop
        : _recovery.next(current);
    if (action == PlaybackRecoveryAction.stop) {
      if (!current.local) {
        final next = _backendManager?.nextBackend();
        if (next != null) {
          _recovery.reset();
          await _play(_index, position: position, continueChain: true);
          return;
        }
        // 后端链已尽：MPV 路径的终态失败再走核间回退换核续播。
        if (_tryCoreFallback(_lastCoreErrorMessage)) return;
      }
      _resumePosition = position;
      final ticket = _generation;
      try {
        await _serialize(() async {
          if (_closed || ticket != _generation) {
            return;
          }
          try {
            await _saveProgress();
            _openedIndex = -1;
            await _player.stop();
          } finally {
            await widget.repository.release(current.session);
          }
        });
      } catch (_) {}
      // 梯子最后一级（核播失败侧）：恢复链与核间回退都耗尽、手里
      // 还有网页地址时，自动落嗅探兜底，与取流失败那条路同口径，
      // 不再让用户自己去点错误屏上的嗅探按钮。本集内只落一次
      // （_sniffRungConsumed），防嗅探递送的地址核播再失败时循环。
      if (mounted &&
          !_closed &&
          ticket == _generation &&
          !current.local &&
          !_sniffRungConsumed &&
          _deepSniffer) {
        final sniffPage = _lastPageUrl.isNotEmpty
            ? _lastPageUrl
            : (looksLikeWebPage(current.url) ? current.url : '');
        if (sniffPage.isNotEmpty) {
          _sniffRungConsumed = true;
          _sniffFallbackTried = true;
          _lastPageUrl = sniffPage;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_closed) _openSniffer();
          });
          return;
        }
      }
      if (mounted && !_closed && ticket == _generation) {
        setState(() {
          _loading = false;
          _localFailure = current.local;
          _error = current.local
              ? widget.allowOnlineFallback
                    ? '本地视频读取失败，请重试或重新下载；也可以手动改为在线播放。'
                    : '本地成品读取失败，请重试或重新生成。'
              : '自动恢复未成功，请检查网络后重试，也可换一集或选择其他清晰度。';
        });
        // 女优模块静默换线：非本地且回调非空时，下一帧通知调用方
        // （调用方弹栈换线；回调里不再写回本页状态）。
        final onExhausted = widget.onPlaybackExhausted;
        if (!current.local && onExhausted != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) onExhausted(context);
          });
        }
      }
      return;
    }
    await _play(
      _index,
      position: position,
      recoveryAction: action,
      continueChain: true,
    );
  }

  void _onTvboxCompleted() {
    if (_loading || _closed || !_acceptErrors || _error != null) return;
    final duration = _tvboxHandle.duration;
    if (duration <= Duration.zero ||
        _tvboxHandle.position < duration - const Duration(seconds: 2)) {
      _queueRecovery();
    } else if (_autoAdvance &&
        _foreground &&
        !_panelOpen &&
        _index + 1 < widget.detail.episodes.length) {
      _audioMode
          ? _playAudio(_index + 1)
          : unawaited(_play(_index + 1, showControlsOnReady: false));
    } else {
      _playIntent = false;
      _interactions.cancel();
      unawaited(_tvboxHandle.pause());
      unawaited(_saveProgress());
    }
  }

  void _onIjkCompleted() {
    if (_loading || _closed || !_acceptErrors || _error != null) return;
    final duration = _ijkHandle.duration;
    if (duration <= Duration.zero ||
        _ijkHandle.position < duration - const Duration(seconds: 2)) {
      _queueRecovery();
    } else if (_autoAdvance &&
        _foreground &&
        !_panelOpen &&
        _index + 1 < widget.detail.episodes.length) {
      _audioMode
          ? _playAudio(_index + 1)
          : unawaited(_play(_index + 1, showControlsOnReady: false));
    } else {
      _playIntent = false;
      _interactions.cancel();
      unawaited(_ijkHandle.pause());
      unawaited(_saveProgress());
    }
  }

  /// 耗尽通知（女优模块静默换线）：在线播放已到终态错误且回调非空
  /// 时，下一帧通知调用方（调用方弹栈换线；回调里不再写回本页
  /// 状态）。本地播放不通知；恢复耗尽那条路沿用它自己的通知。
  void _notifyPlaybackExhausted() {
    final onExhausted = widget.onPlaybackExhausted;
    if (onExhausted == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) onExhausted(context);
    });
  }

  /// 核间自动回退：当前核终态失败后，按档位与固定顺序换下一个核，
  /// 带当前进度与集数续播。只做会话内覆盖，不改全局选核设置。
  /// 返回 true 表示已换核重试，调用方不要再显示错误。
  bool _tryCoreFallback(String message) {
    if (_closed || _plan?.local == true) return false;
    _coreFallback ??= CoreFallbackController(
      start: _effectiveCore,
      mode: _fallbackMode,
    );
    final next = _coreFallback!.advance(
      classifyPlayerCoreFailure(message),
    );
    if (next == null) return false;
    final position = _currentPosition;
    _fallbackCoreOverride = next;
    _backendManager = null;
    _recovery.reset();
    _acceptErrors = true;
    unawaited(_play(_index, position: position, continueChain: true));
    return true;
  }

  void _onIjkError(String message) {
    if (_closed || _loading || _error != null) return;
    _lastCoreErrorMessage = message;
    if (_tryCoreFallback(message)) return;
    if (mounted) {
      setState(() {
        _loading = false;
        _error = message.isEmpty ? '播放失败' : message;
      });
    }
    // ijk 核终态错误：恢复链不接管这里，通知调用方换线。
    if (_plan?.local != true) _notifyPlaybackExhausted();
  }

  void _onTvboxError(String message) {
    if (_closed || _loading || _error != null) return;
    _lastCoreErrorMessage = message;
    final next = _backendManager?.nextBackend();
    if (next == PlaybackBackend.main) {
      final position = _tvboxHandle.positionSeconds > 0
          ? _tvboxHandle.positionSeconds
          : _activeTvboxRig.startPosition;
      unawaited(_play(_index, position: position, continueChain: true));
      return;
    }
    // 后端链已尽：再试核间回退（EXO 后端失败可换 MPV/IJK 核）。
    if (_tryCoreFallback(message)) return;
    if (mounted) {
      setState(() {
        _loading = false;
        _error = message.isEmpty ? '播放失败' : message;
      });
    }
    // 原生核终态错误：无下一核可切，通知调用方换线。
    if (_plan?.local != true) _notifyPlaybackExhausted();
  }

  void _togglePlayback() {
    if (_closed || _loading || _error != null) return;
    _interactions.cancel();
    if (_useNativeHandle) {
      _playIntent = !_tvboxHandle.playing;
      _health.reset();
      if (_playIntent && _tvboxHandle.completed) {
        unawaited(_play(_index));
        return;
      }
      if (_playIntent) {
        unawaited(_tvboxHandle.play());
      } else {
        unawaited(_tvboxHandle.pause());
      }
      if (!_playIntent) unawaited(_saveProgress());
      _syncDanmaku();
      return;
    }
    if (_useIjkCore) {
      _playIntent = !_ijkHandle.playing;
      _health.reset();
      if (_playIntent && _ijkHandle.completed) {
        unawaited(_play(_index));
        return;
      }
      if (_playIntent) {
        unawaited(_ijkHandle.play());
      } else {
        unawaited(_ijkHandle.pause());
      }
      if (!_playIntent) unawaited(_saveProgress());
      _syncDanmaku();
      return;
    }
    _playIntent = !_player.state.playing;
    if (_playIntent) _enhancement.mediaReady();
    _health.reset();
    if (_playIntent && _player.state.completed) {
      unawaited(_play(_index));
      return;
    }
    unawaited(_player.playOrPause());
    if (!_playIntent) unawaited(_saveProgress());
    _syncDanmaku();
  }

  Future<void> _saveProgress() async {
    if (_openedIndex < 0 || widget.store.profileEpoch != _profileEpoch) {
      return;
    }
    final position = _useNativeHandle
        ? _tvboxHandle.positionSeconds
        : _useIjkCore
        ? _ijkHandle.positionSeconds
        : _player.state.position.inMilliseconds / 1000;
    final duration = _useNativeHandle
        ? _tvboxHandle.durationSeconds
        : _useIjkCore
        ? _ijkHandle.durationSeconds
        : _player.state.duration.inMilliseconds / 1000;
    if (position < .1) {
      return;
    }
    final store = widget.store;
    final progressKey =
        '${widget.mediaId ?? widget.detail.drama.id}:$_openedIndex:$position:$duration';
    if (_savedProgressKey == progressKey && _saveWarning == null) {
      return;
    }
    final entry = WatchEntry(
      drama: widget.repository.catalogUpdates.current(widget.detail.drama),
      episode: widget.detail.episodes[_openedIndex].number,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    try {
      await Future<void>.value();
      if (store.profileEpoch != _profileEpoch) return;
      if (widget.mediaId == null) {
        await store.saveWatch(entry);
      } else {
        await store.saveMediaWatch(widget.mediaId!, entry);
      }
      _savedProgressKey = progressKey;
      if (mounted && !_closed && _saveWarning != null) {
        setState(() => _saveWarning = null);
      }
    } catch (_) {
      if (mounted && !_closed && _saveWarning == null) {
        setState(() => _saveWarning = '观看进度尚未保存，请检查存储空间后重试。');
      }
    }
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.catchError((Object _) {}).then((_) => operation());
    _operations = next;
    return next;
  }

  Episode? _audioEpisodeFor(int index) {
    if (index < 0 || index >= widget.detail.episodes.length) return null;
    final episode = widget.detail.episodes[index];
    final routes = episode.raw['routes'];
    if (routes is! List || routes.isEmpty) return null;
    final url = routes.first.toString();
    if (url.isEmpty) return null;
    final raw = Map<String, Object?>.from(episode.raw);
    raw['videoUrl'] = url;
    return Episode(raw, episode.number);
  }

  bool _isAudioEpisode(Episode episode) {
    final candidates = <String>[];
    for (final key in const ['videoUrl', 'episodeId', 'id', 'url']) {
      final value = episode.raw[key];
      if (value is String && value.isNotEmpty) candidates.add(value);
    }
    if (episode.id.isNotEmpty) candidates.add(episode.id);
    for (final candidate in candidates) {
      if (candidate.contains('hongguo-audio://')) return true;
      final lower = candidate.split('?').first.toLowerCase();
      if (lower.endsWith('.mp3') ||
          lower.endsWith('.m4a') ||
          lower.endsWith('.aac') ||
          lower.endsWith('.opus') ||
          lower.endsWith('.ogg') ||
          lower.endsWith('.wav')) {
        return true;
      }
    }
    return false;
  }

  void _playAudio(int index) {
    if (index < 0 || index >= widget.detail.episodes.length) return;
    if (_audioEpisodeFor(index) == null &&
        !_isAudioEpisode(widget.detail.episodes[index])) {
      return;
    }
    _audioMode = true;
    unawaited(_play(index, showControlsOnReady: false));
  }

  void _playText(int index) {
    _audioMode = false;
    unawaited(_play(index, showControlsOnReady: false));
  }

  /// 音频模式的锁屏载荷：与详情页听书链同一套六项。
  AudioLockscreenInfo _externalAudioInfo() {
    final state = _player.state;
    return AudioLockscreenInfo(
      bookTitle: widget.detail.drama.title,
      chapterTitle: '第 ${_index + 1} 集',
      coverUrl: widget.detail.drama.cover,
      playing: _enginePlaying,
      positionMs: state.position.inMilliseconds,
      durationMs: state.duration.inMilliseconds,
      hasPrevious: _index > 0,
      hasNext: _index + 1 < widget.detail.episodes.length,
      rate: _preferences.speed,
    );
  }

  /// 音频模式的后台输出认领与状态上报。
  ///
  /// 只在播着时认领（暂停时不抢），认领后播/停切换与换集立即上报，
  /// 进度节流 5 秒；切出音频模式或页面关闭时放弃认领。
  /// 认领会停掉详情页听书链的旧声（播新章停旧声），反之亦然。
  void _claimOrReportExternalAudio() {
    if (_closed || !_audioMode) {
      _releaseExternalAudio();
      return;
    }
    final playing = _enginePlaying;
    if (!_externalAudioClaimed) {
      if (!playing) return;
      _externalAudioClaimed = true;
      _lastExternalPlaying = playing;
      _lastExternalIndex = _index;
      _lastExternalReportAtMs = DateTime.now().millisecondsSinceEpoch;
      AudioPlaybackController.instance.claimExternalAudio(
        ExternalAudioSession(
          ownerId: _externalAudioOwnerId,
          infoProvider: _externalAudioInfo,
          onAction: _onExternalMediaAction,
          onTakeover: _onExternalTakeover,
        ),
      );
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (playing != _lastExternalPlaying || _index != _lastExternalIndex) {
      _lastExternalPlaying = playing;
      _lastExternalIndex = _index;
      _lastExternalReportAtMs = now;
      AudioPlaybackController.instance.reportExternalAudio();
      return;
    }
    if (now - _lastExternalReportAtMs >= 5000) {
      _lastExternalReportAtMs = now;
      AudioPlaybackController.instance.reportExternalAudio();
    }
  }

  void _releaseExternalAudio() {
    if (!_externalAudioClaimed) return;
    _externalAudioClaimed = false;
    AudioPlaybackController.instance.releaseExternalAudio(
      _externalAudioOwnerId,
    );
  }

  /// 锁屏按键回落：复用页内播控口径（播/停走总开关，上下集走 _playAudio）。
  void _onExternalMediaAction(String action) {
    if (_closed || !_audioMode || !mounted) return;
    switch (action) {
      case 'play':
        if (!_enginePlaying) _togglePlayback();
      case 'pause':
        if (_enginePlaying) _togglePlayback();
      case 'previous':
        if (_index > 0) _playAudio(_index - 1);
      case 'next':
        _playAudio(_index + 1);
    }
  }

  /// 另一路音频（详情页听书）接管：停掉本路，不再认领。
  /// 直接停引擎（不走总开关的加载门），并关掉 _playIntent，
  /// 这样加载中的一集也不会在就绪后自动播出来抢声。
  void _onExternalTakeover() {
    _externalAudioClaimed = false;
    if (_closed || !_audioMode) return;
    _playIntent = false;
    if (_useNativeHandle) {
      unawaited(_tvboxHandle.pause());
    } else if (_useIjkCore) {
      unawaited(_ijkHandle.pause());
    } else {
      unawaited(_player.pause());
    }
    unawaited(_saveProgress());
  }

  /// 实时字幕设置：initState 里异步加载；_startLiveSubtitle 里
  /// 设置还没到时会当场再读一次，免得 _play 先跑、设置后到导致
  /// 首集漏启动。
  Future<void> _loadLiveSubtitleSettings() async {
    final settings = await LiveSubtitleSettings.load();
    if (mounted) setState(() => _liveSettings = settings);
  }

  /// 实时字幕：只在总开关开着、平台支持（或测试注入了引擎）、
  /// 源不是播放器侧内存密钥解密时才启动。只给 MPV 核用——Exo 核
  /// 走 TvboxVideoPane 里那份，TVBox 核同理；IJK 核暂未接。
  /// 调用方不 await：模型首次加载要十几秒，服务在后台起，字幕行
  /// 到了再经 cue 流刷出来，不拖住播放与加载态。
  Future<void> _startLiveSubtitle(
    PlaybackPlan plan,
    double startPosition,
  ) async {
    var settings = _liveSettings;
    settings ??= await LiveSubtitleSettings.load();
    if (!mounted || _closed) return;
    _liveSettings ??= settings;
    if (!settings.enabled) return;
    if (plan.decryptionKey.isNotEmpty) return;
    if (widget.liveSubtitleEngine == null && !liveSubtitleEngineSupported) {
      return;
    }
    final service = LiveSubtitleService(
      settings: settings,
      engine: widget.liveSubtitleEngine,
      extractor: widget.liveSubtitleAudioExtractor,
    );
    _liveSubtitle = service;
    _liveSubscriptions.add(
      service.cueStream.listen((_) {
        if (mounted && _updateLiveSubtitleLines()) setState(() {});
      }),
    );
    _liveSubscriptions.add(
      service.partialStream.listen((partial) {
        if (!mounted) return;
        _livePartial = partial;
        if (_updateLiveSubtitleLines()) setState(() {});
      }),
    );
    await service.start(
      url: plan.url,
      headers: plan.headers,
      startPosition: Duration(milliseconds: (startPosition * 1000).round()),
    );
  }

  /// 停掉实时字幕服务并清掉行：换集、换核、切非视频内容、
  /// 退出播放页时调用。不在这里 setState——调用方随后自有一次
  /// setState（_play 的加载态、dispose 不需要）；位置 tick 与
  /// cue 流也会把行刷回空。
  Future<void> _stopLiveSubtitle() async {
    for (final subscription in _liveSubscriptions) {
      await subscription.cancel();
    }
    _liveSubscriptions.clear();
    final service = _liveSubtitle;
    _liveSubtitle = null;
    if (service != null) await service.dispose();
    _livePartial = '';
    _liveLines = const [];
  }

  /// 取当前播放进度对应的实时字幕行；没有则返回空（内嵌字幕仍由
  /// media_kit 自带的 SubtitleView 画，不走这里）。
  /// 有确认字幕时不画临时行，避免同一句话在两行里重复。
  List<String> _liveLinesAt(Duration position) {
    final service = _liveSubtitle;
    if (service == null || !service.isRunning) return const [];
    final cue = service.cueAt(position);
    if (cue != null) {
      return cue.displayLines();
    }
    if (_livePartial.isNotEmpty) return [_livePartial];
    return const [];
  }

  /// 按当前位置刷新实时字幕行；行内容变化时返回 true，调用方再 setState。
  bool _updateLiveSubtitleLines([Duration? position]) {
    final lines = _liveLinesAt(position ?? _enginePosition);
    if (lines.length == _liveLines.length) {
      var same = true;
      for (var i = 0; i < lines.length; i++) {
        if (lines[i] != _liveLines[i]) {
          same = false;
          break;
        }
      }
      if (same) return false;
    }
    _liveLines = lines;
    return true;
  }

  /// 跳过片头片尾（第 7 点，与西瓜播放器共用 intro_outro_skip 判定）：
  /// 本剧的分段设置。
  IntroOutroSettings get _introOutroSettings => widget.store.introOutroFor(
    widget.detail.drama.source,
    widget.detail.drama.id,
  );

  /// 起播位置过一遍片头判定：从头播或进度落在片头段内时挪到片头
  /// 结束处；进度已越过片头时原样返回，续播位置不被冲掉。
  double _applyIntroSkip(double position) {
    final decision = decideIntroSkip(
      enabled: widget.store.introOutroSkipEnabled,
      settings: _introOutroSettings,
      resumePositionSeconds: position,
    );
    return decision.targetSeconds ?? position;
  }

  /// 片尾判定（1 秒健康定时器与 media_kit 位置流共用）：进入片尾段
  /// 且有下一集时切下一集，每集只触发一次（引擎记已触发集）。
  void _maybeSkipOutro() {
    if (_closed ||
        _loading ||
        _error != null ||
        _openedIndex != _index ||
        _panelOpen ||
        !_playIntent) {
      return;
    }
    final fired = _skipEngine.consumeOutro(
      episodeKey: '${widget.detail.drama.id}:$_index',
      enabled: widget.store.introOutroSkipEnabled,
      settings: _introOutroSettings,
      positionSeconds: _enginePosition.inMilliseconds / 1000,
      durationSeconds: _engineDuration.inMilliseconds / 1000,
      hasNextEpisode: _index + 1 < widget.detail.episodes.length,
    );
    if (!fired) return;
    _audioMode
        ? _playAudio(_index + 1)
        : unawaited(_play(_index + 1, showControlsOnReady: false));
  }

  Future<void> _play(
    int index, {
    double position = 0,
    PlaybackRecoveryAction? recoveryAction,
    int? routeSelection,
    bool playWhenReady = true,
    PlaybackPlan? preparedPlan,
    bool showControlsOnReady = true,
    bool continueChain = false,
  }) async {
    if (_closed ||
        widget.store.profileEpoch != _profileEpoch ||
        index < 0 ||
        index >= widget.detail.episodes.length) {
      return;
    }
    position = _applyIntroSkip(position);
    _sniffEmbedded = false;
    final baseEpisode = widget.detail.episodes[index];
    if (!_audioMode && _isAudioEpisode(baseEpisode)) {
      _audioMode = true;
    }
    final playEpisode = _audioMode
        ? _audioEpisodeFor(index) ?? baseEpisode
        : baseEpisode;
    if (_audioMode &&
        identical(playEpisode, baseEpisode) &&
        !_isAudioEpisode(baseEpisode)) {
      _audioMode = false;
    }
    final earlyNonVideo = nonVideoFromEpisode(playEpisode);
    if (earlyNonVideo != null) {
      _audioMode = false;
      _preloader.clear();
      final previousIndex = _index;
      setState(() {
        _index = index;
        _loading = false;
        _error = null;
        _nonVideo = earlyNonVideo;
        _plan = null;
      });
      if (widget.embedded && previousIndex != index) {
        widget.onEmbeddedIndexChanged?.call(index);
      }
      unawaited(_stopLiveSubtitle());
      unawaited(_player.stop().catchError((Object _) {}));
      return;
    }
    _interactions.cancel();
    if (index != _index) _forceOnline = false;
    final canPreload =
        recoveryAction == null &&
        routeSelection == null &&
        _preloadEnabled &&
        !widget.localOnly;
    final warmed =
        preparedPlan ??
        (canPreload
            ? _preloader.take(
                widget.detail.drama,
                playEpisode,
                quality: _requestedQuality,
                route: _routeIndex,
                online: _forceOnline,
                adBlock: _adBlock,
              )
            : null);
    _preloader.clear();
    // 无缝候选：待命已备好这一集首帧时，本次切集全程不黑——
    // 不停当前播、不置加载态、不做 302 预解析（待命播放器自己
    // 跟跳转，落地按会话命中对调）。最后是否命中由
    // _trySeamlessSwap 按最终 plan 复核，未命中原路照走。
    final seamlessCandidate =
        _seamlessEnabled &&
        !_audioMode &&
        recoveryAction == null &&
        routeSelection == null &&
        preparedPlan == null &&
        position == 0 &&
        playWhenReady &&
        _seamless.phase == SeamlessPhase.ready &&
        _seamless.targetIndex == index;
    final ticket = ++_generation;
    _enhancement.suspend();
    _seekSequence++;
    _danmaku.setPlan(null);
    _acceptErrors = false;
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    if (!continueChain) {
      // 新的播放会话（换集/手动重试/手动换核）：核回退链从当前选核重开。
      _fallbackCoreOverride = null;
      _coreFallback = CoreFallbackController(
        start: _baseEffectiveCore,
        mode: _fallbackMode,
      );
      _lastCoreErrorMessage = '';
    }
    if (recoveryAction == null || routeSelection != null) {
      _recovery.reset();
      _playIntent = playWhenReady;
    }
    _resumePosition = position;
    _showControlsOnPlaybackReady = showControlsOnReady;
    var loadingMessage = switch (recoveryAction) {
      PlaybackRecoveryAction.alternative => '正在切换备用线路',
      PlaybackRecoveryAction.refresh => '正在重新获取播放地址',
      _ => '正在准备播放',
    };
    if (routeSelection != null) loadingMessage = '正在切换播放线路';
    final previousIndex = _index;
    setState(() {
      _index = index;
      _loading = !seamlessCandidate;
      _error = null;
      _localFailure = false;
      _loadingMessage = loadingMessage;
      _nonVideo = null;
      _sniffFallbackTried = false;
    });
    if (previousIndex != index) {
      _sniffRungConsumed = false;
    }
    if (widget.embedded && previousIndex != index) {
      widget.onEmbeddedIndexChanged?.call(index);
    }
    PlaybackPlan? prepared;
    PlaybackPlan? retained;
    bool installed = false;
    try {
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          return;
        }
        await _saveProgress();
        await _enhancement.beforeMedia();
        if (_closed || ticket != _generation) return;
        _openedIndex = -1;
        // 无缝候选时不停播：旧集继续出画直到对调瞬间才停，
        // 停播提前了就是黑屏（EXO/IJK 时 MPV 本就闲置，跳过无碍）。
        if (!seamlessCandidate) {
          await _player.stop();
        }
        final previous = _plan;
        _plan = null;
        if (recoveryAction == PlaybackRecoveryAction.alternative ||
            routeSelection != null) {
          retained = previous;
        } else if (previous != null) {
          await widget.repository.release(previous.session);
        }
      });
      if (_closed || ticket != _generation) {
        return;
      }
      if (retained != null) {
        if (routeSelection != null) {
          prepared = await _loader.selectRoute(retained!, routeSelection);
        } else {
          prepared = await _loader.fallback(retained!);
        }
      } else if (warmed != null) {
        prepared = await _loader.use(warmed);
      } else {
        prepared = await _loader.load(
          widget.detail.drama,
          playEpisode,
          quality: _requestedQuality,
          route: routeSelection ?? _routeIndex,
          localOnly: widget.localOnly,
          online: _forceOnline,
          adBlock: _adBlock,
        );
      }
      if (prepared == null) {
        return;
      }
      if (!prepared.local &&
          (prepared.needsParse || looksLikeWebPage(prepared.url))) {
        _lastPageUrl = prepared.url;
        final direct = await _tryYoutubeDirect(prepared);
        if (direct != null) prepared = direct;
      }
      if (!prepared.local && prepared.needsParse) {
        _lastPageUrl = prepared.url;
        if (JarBridge.isJarSource(widget.detail.drama.source)) {
          final parsed = applySelectedParse(
            url: prepared.url,
            needsParse: true,
            selected: _selectedParse,
          );
          if (parsed != null && parsed != prepared.url) {
            prepared = prepared.withUrl(parsed);
          } else {
            throw AppFailure(
              '需要解析但未配置解析接口（取流地址=${prepared.url}），请在解析设置中添加解析接口',
            );
          }
        } else {
          final apis = await ParseInterfaceStore.loadEnabled();
          if (apis.isEmpty) {
            throw AppFailure(
              '需要解析但未配置解析接口（取流地址=${prepared.url}），请在解析设置中添加解析接口',
            );
          }
          if (prepared.session.isNotEmpty) {
            await widget.repository.release(prepared.session);
          }
          prepared = await widget.repository.resolveParse(prepared, apis);
        }
      } else if (!prepared.local &&
          looksLikeWebPage(prepared.url) &&
          !JarBridge.isJarSource(widget.detail.drama.source)) {
        _lastPageUrl = prepared.url;
        final parsed = applySelectedParse(
          url: prepared.url,
          needsParse: false,
          selected: _selectedParse,
        );
        if (parsed != null && parsed != prepared.url) {
          prepared = prepared.withUrl(parsed);
        } else {
          final apis = await ParseInterfaceStore.loadEnabled();
          final pageUrl = prepared.url;
          if (apis.isNotEmpty) {
            if (prepared.session.isNotEmpty) {
              await widget.repository.release(prepared.session);
            }
            try {
              prepared = await widget.repository.resolveParse(prepared, apis);
            } catch (_) {
              throw AppFailure('解析接口全部失败（取流地址=$pageUrl）');
            }
          } else {
            throw AppFailure('播放地址是网页、需要解析但未配置解析接口（取流地址=$pageUrl）');
          }
        }
      }
      var plan = prepared;
      plan = plan.withHeaders(
        applyCustomHeaders(
          plan.url,
          plan.headers,
          enabled: widget.store.customHeadersEnabled,
          rules: widget.store.customHeaderRules,
        ),
      );
      if (!_audioMode) {
        final lower = plan.url.split('?').first.toLowerCase();
        if (lower.endsWith('.mp3') ||
            lower.endsWith('.m4a') ||
            lower.endsWith('.aac') ||
            lower.endsWith('.opus') ||
            lower.endsWith('.ogg') ||
            lower.endsWith('.wav')) {
          _audioMode = true;
        }
      }
      final planNonVideo = parseNonVideoUrl(plan.url, headers: plan.headers);
      if (planNonVideo != null) {
        if (plan.session.isNotEmpty) {
          await widget.repository.release(plan.session);
        }
        setState(() {
          _loading = false;
          _error = null;
          _nonVideo = planNonVideo;
          _plan = null;
        });
        return;
      }
      // 302 预解析（非视频分流之后）：会跳转的地址先跟到最终地址，
      // 三条播放路径共用解析后的 plan，跳转行为一致；解析失败时
      // 返回原地址，行为与原来一致（见 playback_redirect）。
      if (!seamlessCandidate && shouldPreResolveRedirects(plan)) {
        final resolved = await resolvePlaybackRedirects(plan.url, plan.headers);
        plan = plan.withUrl(resolved.url).withHeaders(resolved.headers);
      }
      // 无缝对调：待命装置已备好这一集首帧时直接换装置落地，
      // 不停播重开。命中才走，未命中与原来一字不差。
      if (await _trySeamlessSwap(
        index: index,
        plan: plan,
        ticket: ticket,
        position: position,
        playWhenReady: playWhenReady,
        recoveryAction: recoveryAction,
        routeSelection: routeSelection,
        preparedPlan: preparedPlan,
      )) {
        installed = true;
        return;
      }
      // 换集/换核/重试：先停掉上一集的实时字幕服务，免得旧行的
      // 识别结果跑到新集的画面上；新服务在 MPV 分支打开后起。
      await _stopLiveSubtitle();
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          await widget.repository.release(plan.session);
          return;
        }
        if (plan.url.isEmpty) {
          throw AppFailure('站源未返回播放地址，请重试');
        }
        if (!continueChain) {
          _backendManager = null;
        }
        // 带 DRM 的计划只有 EXO 核能解：与 decryptionKey 强制 mpv
        // 对称，这里强制走原生（tvbox/EXO）后端；decryptionKey
        // 非空时仍按既有口径回 mpv，两者互斥、后者优先。
        final useNativeForPlan =
            ((_useTvbox || _useExoCore) || plan.hasDrm) &&
            plan.decryptionKey.isEmpty &&
            !plan.forceMpv;
        final useIjkForPlan =
            _useIjkCore && plan.decryptionKey.isEmpty && !plan.forceMpv;
        _backendManager ??= PlaybackBackendManager(
          initial: useNativeForPlan
              ? PlaybackBackend.tvbox
              : PlaybackBackend.main,
        );
        if (!useNativeForPlan && !useIjkForPlan) {
          await _applyMpvPlatformProperties(_player, plan);
        }
        _plan = plan;
        installed = true;
        _acceptErrors = true;
        if (_closed || ticket != _generation) {
          return;
        }
        if (useNativeForPlan) {
          _activeTvboxRig.plan = plan;
          _activeTvboxRig.startPosition = position;
          _activeTvboxRig.autoplay = _foreground && _playIntent;
        } else if (useIjkForPlan) {
          _ijkPlan = plan;
          _ijkStartPosition = position;
          _ijkAutoplay = _foreground && _playIntent;
        } else {
          // 空 UA 的计划（115 直链契约：播放 UA 必须与取链的空 UA
          // 一致）：media_kit 拼不出 mpv 的空值头字面量 `User-Agent;`，
          // 改走 mpv 属性 http-header-fields 设整张字段表，Media 本身
          // 不带头（带了会在 on_load 钩子里覆盖掉属性）。没有空 UA 时
          // 清掉属性防上一份计划的字段表串过来，其余头照旧走 Media。
          Map<String, String>? mediaHeaders = plan.headers;
          final platform = _player.platform;
          if (platform is NativePlayer) {
            final fields = mpvHttpHeaderFields(plan.headers);
            if (fields != null) {
              await platform.setProperty(
                'http-header-fields',
                mpvHeaderFieldsPropertyValue(fields),
              );
              mediaHeaders = null;
            } else {
              await platform.setProperty('http-header-fields', '');
            }
          }
          await _player.open(
            Media(
              plan.url,
              httpHeaders: mediaHeaders,
              start: position > 0
                  ? Duration(milliseconds: (position * 1000).round())
                  : null,
            ),
            play: _foreground && _playIntent,
          );
          _externalSubUrl = null;
          _subtitlesOff = false;
          await _loadDefaultExternalSubtitle(plan);
          // MPV 核：播放器打开后在后台起实时字幕（不 await，
          // 模型加载不拖住加载态）；Exo/TVBox 核走 TvboxVideoPane
          // 里那份，不在这里起。
          unawaited(_startLiveSubtitle(plan, position));
        }
        if (_closed || ticket != _generation) {
          return;
        }
        _openedIndex = index;
        if (!_useNativeHandle && !_useIjkCore) _enhancement.mediaReady();
        _health.reset();
        if (!_useNativeHandle && !_useIjkCore) {
          await _interactions.applySpeed();
        }
        if (mounted && !_closed && ticket == _generation) {
          setState(() {
            _loading = false;
          });
          _danmaku.setPlan(plan);
          _syncDanmaku();
          _menuRevision.value++;
          _applyLifecycleVisibility();
        }
      });
    } catch (error) {
      if (!_closed && mounted && ticket == _generation) {
        if (prepared != null && identical(_plan, prepared)) {
          _acceptErrors = true;
          _queueRecovery();
        } else {
          if (prepared != null) {
            await widget.repository.release(prepared.session);
          }
          if (mounted && !_closed && ticket == _generation) {
            final fallbackPage = _lastPageUrl.isNotEmpty
                ? _lastPageUrl
                : (prepared != null && looksLikeWebPage(prepared.url)
                      ? prepared.url
                      : '');
            final needsSniffFallback =
                !_sniffFallbackTried &&
                warmed == null &&
                fallbackPage.isNotEmpty;
            setState(() {
              _loading = false;
              _localFailure =
                  (error is AppFailure && error.code == 'local_media') ||
                  (widget.localOnly && !_forceOnline);
              _error = error is AppFailure
                  ? error.message
                  : '无法播放这一集，请重试或换一集。（$error）';
            });
            if (needsSniffFallback) {
              _sniffFallbackTried = true;
              _sniffRungConsumed = true;
              _lastPageUrl = fallbackPage;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && !_closed && _deepSniffer) _openSniffer();
              });
            }
            // 取流失败（无 plan 可恢复）：终态错误，非本地且不走嗅探
            // 兜底时通知调用方换线（女优链先试别的站）；链耗尽时
            // 错误屏留着，用户再点重试重探。
            if (!_localFailure && !needsSniffFallback) {
              _notifyPlaybackExhausted();
            }
          }
        }
      } else if (prepared != null && !installed) {
        await widget.repository.release(prepared.session);
      }
    } finally {
      if (warmed != null && !installed) {
        await widget.repository.release(warmed.session);
      }
      if (retained != null) {
        await widget.repository.release(retained!.session);
      }
    }
  }

  Future<void> _switchOnline() async {
    _forceOnline = true;
    await _retry();
  }

  Future<void> _retry({int? quality}) async {
    final position = _currentPosition;
    if (quality != null) {
      _requestedQuality = quality;
    }
    await _play(
      _index,
      position: position,
      playWhenReady: quality == null || _error != null || _enginePlaying,
    );
  }

  /// 报错屏“重试播放”：先让调用方重探换线（女优链 resetForRetry
  /// 再探），重探无果再原地重播同一集。
  Future<void> _onErrorRetry() async {
    final probe = widget.onRetryProbe;
    if (probe != null && await probe(context)) return;
    _retry();
  }

  Future<void> _openCoreDialog() async {
    final next = await showPlayerCoreDialog(
      context,
      _effectiveCore,
      exoAvailable: Platform.isAndroid,
      ijkAvailable: Platform.isAndroid,
    );
    if (next == null || next == _effectiveCore || _closed) return;
    await _switchCore(next);
  }

  Future<void> _switchCore(PlayerCore next) async {
    if (_closed) return;
    _discardSeamlessStandby();
    final previous = _core;
    final position = _currentPosition;
    final playing = _playIntent && _enginePlaying;
    try {
      await PlayerCoreStorage.write(widget.store.preferences, next);
      if (_closed) return;
      setState(() {
        _core = next;
        _loading = true;
      });
      await _play(_index, position: position, playWhenReady: playing);
    } catch (_) {
      if (mounted && !_closed) {
        setState(() => _core = previous);
        _notice('切换播放器失败，已恢复原播放器');
      }
    }
  }

  Future<void> _selectRoute(int route) async {
    if (_closed || _plan == null || _plan!.local) return;
    if (route < 0 || route >= _routeCount || route == _currentRoute) return;
    final previous = _routeIndex;
    final position = _currentPosition;
    final playing = _playIntent && _enginePlaying;
    try {
      await _saveProgress();
      setState(() => _routeIndex = route);
      await _play(
        _index,
        position: position,
        routeSelection: route,
        playWhenReady: playing,
      );
    } catch (_) {
      if (mounted && !_closed && _routeIndex == route) {
        setState(() => _routeIndex = previous);
      }
      if (mounted && !_closed) _notice('切换线路失败，已恢复原线路');
      return;
    }
    if (_closed || !mounted || _plan?.routeIndex == route) return;
    if (_routeIndex == route) setState(() => _routeIndex = previous);
  }

  bool get _showFullscreen {
    if (_television || _fullscreen || _pageFullscreen || _windowFullscreen) {
      return true;
    }
    if (!_mobile || _automaticFullscreenSuppressed) return false;
    final orientation = MediaQuery.orientationOf(context);
    return switch (_orientationMode) {
      PlaybackOrientationMode.portrait => orientation == Orientation.portrait,
      PlaybackOrientationMode.landscape => orientation == Orientation.landscape,
      PlaybackOrientationMode.auto =>
        (_orientationAspectRatio >= 1 &&
                orientation == Orientation.landscape) ||
            (_orientationAspectRatio < 1 &&
                orientation == Orientation.portrait),
    };
  }

  Future<void> _rotate() async {
    if (widget.embedded || _rotating || _television) {
      return;
    }
    final windows = Platform.isWindows;
    final fullscreen = windows ? !_windowFullscreen : !_showFullscreen;
    final previous = _fullscreen;
    final previousPageFullscreen = _pageFullscreen;
    final previousWindowFullscreen = _windowFullscreen;
    final previousSuppressed = _automaticFullscreenSuppressed;
    _interactions.cancel();
    _rotating = true;
    setState(() {
      if (windows) {
        _windowFullscreen = fullscreen;
      } else {
        _fullscreen = fullscreen;
        _automaticFullscreenSuppressed = !fullscreen;
      }
    });
    try {
      if (windows) {
        await windowManager.setFullScreen(fullscreen);
      } else if (_mobile) {
        await (_orientationController?.setPlayback(
                  this,
                  fullscreen: fullscreen,
                  aspectRatio: _orientationAspectRatio,
                  mode: _orientationMode,
                ) ??
                SystemChrome.setPreferredOrientations(
                  AppOrientationController.orientations(
                    television: _television,
                    fullscreen: fullscreen,
                    aspectRatio: _orientationAspectRatio,
                    mode: _orientationMode,
                  ),
                ))
            .timeout(const Duration(seconds: 2));
      }
    } catch (_) {
      if (mounted && !_closed) {
        setState(() {
          _fullscreen = previous;
          _pageFullscreen = previousPageFullscreen;
          _windowFullscreen = previousWindowFullscreen;
          _automaticFullscreenSuppressed = previousSuppressed;
        });
        _notice('无法切换全屏，请重试');
      }
    } finally {
      _rotating = false;
      if (_backPending) {
        _backPending = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_closed) _backToList();
        });
      }
      if (mounted && !_closed) _scheduleSystemUi();
      if (!fullscreen && mounted && !_closed) {
        _scrollEpisodeStripToCurrent();
      }
    }
  }

  /// 播过留帧：进页时列出已缓存的帧键，选集卡按集合成员
  /// 关系决定显不显示帧图。缓存读失败时当作没有帧。
  Future<void> _loadFrameKeys() async {
    try {
      final keys = await EpisodeFrameCache.instance.warmUp();
      if (mounted && !_closed) {
        setState(() => _frameKeys = keys);
      }
    } catch (_) {
      // 帧缓存不可用时卡片回落剧照/海报，不影响播放。
    }
  }

  /// 播过留帧：当前集播到 3 秒后截一帧存缓存，每集每会话
  /// 只试一次。只在 media_kit 渲染时截——Tvbox/Exo 原生句柄
  /// 与 IJK 内核都不走 _player，截了也是空的。
  void _maybeCaptureEpisodeFrame(Duration position) {
    if (_closed || !mounted) return;
    if (_useNativeHandle || _useIjkCore) return;
    if (position < const Duration(seconds: 3)) return;
    if (_openedIndex != _index) return;
    if (!_player.state.playing) return;
    final episodes = widget.detail.episodes;
    if (_index < 0 || _index >= episodes.length) return;
    final drama = widget.detail.drama;
    final key = EpisodeFrameCache.frameKey(
      source: drama.source,
      dramaId: drama.id,
      episodeNumber: episodes[_index].number,
    );
    if (_frameKeys.contains(key) || _frameCaptureAttempted.contains(key)) {
      return;
    }
    _frameCaptureAttempted.add(key);
    unawaited(_captureAndSaveFrame(key));
  }

  Future<void> _captureAndSaveFrame(String key) async {
    try {
      final bytes = await _player.screenshot(format: 'image/jpeg');
      if (bytes == null || bytes.isEmpty) return;
      final saved = await EpisodeFrameCache.instance.saveFrame(key, bytes);
      if (saved && mounted && !_closed) {
        setState(() => _frameKeys = {..._frameKeys, key});
      }
    } catch (_) {
      // 截帧失败静默跳过：卡片继续显示剧照/海报。
    }
  }

  /// 退出全屏后把选集横排滚回当前集（每张预览卡按
  /// episodePreviewCardWidth 宽 + 8px 间距估宽，精确位置由
  /// ListView 的可视钳制兜底）。
  void _scrollEpisodeStripToCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closed || !_episodeStripController.hasClients) return;
      final displayIndex = _episodesReversed
          ? widget.detail.episodes.length - 1 - _index
          : _index;
      final target = (displayIndex * (episodePreviewCardWidth + 8)).clamp(
        0.0,
        _episodeStripController.position.maxScrollExtent,
      );
      _episodeStripController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  void _notifyEmbeddedFullscreen() {
    widget.onEmbeddedFullscreen?.call();
  }

  void _handleEmbeddedBack() {
    if (widget.embeddedFullscreen) {
      widget.onEmbeddedFullscreen?.call();
    } else {
      widget.onEmbeddedClose?.call();
    }
  }

  Future<void> _applyOrientation() async {
    if (widget.embedded || _television || !_mobile || _closed) return;
    final fullscreen = _orientationMode != PlaybackOrientationMode.auto
        ? true
        : _showFullscreen;
    try {
      await (_orientationController?.setPlayback(
            this,
            fullscreen: fullscreen,
            aspectRatio: _orientationAspectRatio,
            mode: _orientationMode,
          ) ??
          SystemChrome.setPreferredOrientations(
            AppOrientationController.orientations(
              television: _television,
              fullscreen: fullscreen,
              aspectRatio: _orientationAspectRatio,
              mode: _orientationMode,
            ),
          ));
    } catch (_) {}
    if (mounted && !_closed) _scheduleSystemUi();
  }

  /// 内嵌播放器的方向同步：详情页翻转 embeddedFullscreen 时方向要跟
  /// 着走（与独立路由的 _rotate 同款语义）。_rotate 与 _applyOrientation
  /// 都对 embedded 提前返回，内嵌这条只能靠这里；退出全屏时释放方
  /// 向主人，方向回到不约束。
  Future<void> _syncEmbeddedOrientation() async {
    if (!widget.embedded || _television || !_mobile || _closed) return;
    try {
      if (widget.embeddedFullscreen) {
        await (_orientationController?.setPlayback(
              this,
              fullscreen: true,
              aspectRatio: _orientationAspectRatio,
              mode: _orientationMode,
            ) ??
            SystemChrome.setPreferredOrientations(
              AppOrientationController.orientations(
                television: _television,
                fullscreen: true,
                aspectRatio: _orientationAspectRatio,
                mode: _orientationMode,
              ),
            ));
      } else {
        await (_orientationController?.releasePlayback(this) ??
            SystemChrome.setPreferredOrientations(
              AppOrientationController.orientations(television: _television),
            ));
      }
    } catch (_) {}
  }

  Future<void> _loadParseSelection() async {
    try {
      final selected = await ParseInterfaceStore.loadSelected();
      if (!_closed && mounted) _selectedParse = selected;
    } catch (_) {}
  }

  Future<void> _loadDeepSniffer() async {
    try {
      final settings = await ViewingExperienceSettings.load();
      if (mounted) setState(() => _deepSniffer = settings.deepSniffer);
    } catch (_) {}
  }

  /// 选集预览图用的 TMDB 元数据：与详情页同一条路（标题 + 年份 +
  /// 类型提示），进页取一次存 state；拉不到只影响预览图。
  Future<void> _loadTmdb(Drama drama) async {
    final config = await TmdbConfig.load();
    if (!mounted || _closed) return;
    // 不再以“填了 key”设门：没 key 时刮削链直接走不要 key 的公开源。
    setState(() => _tmdbConfig = config);
    try {
      final meta = await TmdbService.instance.fetchMetadata(
        title: drama.title,
        year: yearFromText(drama.onlineDate),
        typeHint: tmdbMediaTypeHint(drama.category, drama.title),
        config: config,
      );
      if (!mounted || _closed) return;
      setState(() => _tmdb = meta);
    } catch (_) {
      // TMDB 拉不到只影响选集预览图，播放页照常显示站源内容。
    }
  }

  Future<PlaybackPlan?> _tryYoutubeDirect(PlaybackPlan current) async {
    final direct = await JarYoutubeTakeover.tryResolveWatchUrl(current.url);
    if (direct == null) return null;
    if (current.session.isNotEmpty) {
      await widget.repository.release(current.session);
    }
    return direct;
  }

  void _openSniffer() {
    final pageUrl = _lastPageUrl;
    if (pageUrl.isEmpty || !mounted || _closed || _sniffEmbedded) return;
    setState(() {
      _sniffPreviousError = _error;
      _sniffEmbedded = true;
      _error = null;
      _loading = false;
    });
  }

  void _closeSniffer() {
    if (!_sniffEmbedded) return;
    setState(() {
      _sniffEmbedded = false;
      _error = _sniffPreviousError;
      _sniffPreviousError = null;
    });
  }

  Future<void> _onSniffedMedia(String url) async {
    if (url.isEmpty || _closed || !mounted) return;
    setState(() => _sniffEmbedded = false);
    await _play(
      _index,
      preparedPlan: PlaybackPlan(url: url, headers: _plan?.headers ?? const {}),
    );
  }

  /// 嗅探页本身加载失败（如 HTTP 404）：关掉嗅探页，不再把服务器
  /// 的错误页挂在播放区；走与恢复耗尽同一条路——留错误界面，
  /// 有换线回调时下一帧通知调用方换下一条线，链耗尽才停在错误
  /// 界面。嗅探页只报一次失败，这里不重复通知。
  void _onSniffLoadFailed(String message) {
    if (!_sniffEmbedded || _closed || !mounted) return;
    final onExhausted = widget.onPlaybackExhausted;
    setState(() {
      _sniffEmbedded = false;
      _sniffPreviousError = null;
      _loading = false;
      _error = onExhausted == null
          ? '网页加载失败（$message），请重试或换一集。'
          : '网页加载失败（$message）。';
    });
    if (onExhausted != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) onExhausted(context);
      });
    }
  }

  /// 嗅探超时仍没拿到验活的地址：关嗅探、留「无法获取播放链接」
  /// 错误态，如实收口；有换线回调时与加载失败同路通知调用方。
  void _onSniffTimeout() {
    if (!_sniffEmbedded || _closed || !mounted) return;
    final onExhausted = widget.onPlaybackExhausted;
    setState(() {
      _sniffEmbedded = false;
      _sniffPreviousError = null;
      _loading = false;
      // 文案避开「超时/网络」等词：错误屏会按关键词归类，
      // 带「取流失败」归到站源问题，不误导成网络故障。
      _error = onExhausted == null
          ? '无法获取播放链接：嗅探未找到可播放地址（取流失败），请重试或换一集。'
          : '无法获取播放链接：嗅探未找到可播放地址（取流失败）。';
    });
    if (onExhausted != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) onExhausted(context);
      });
    }
  }

  String _queueSwipe(int direction) {
    final queue = widget.queue;
    if (queue == null || queue.isEmpty) {
      return direction > 0 ? '已经是最后一集' : '已经是第一集';
    }
    final target = queue.neighbor(direction);
    if (target == null) {
      _notice(direction > 0 ? '已经是列表最后一部' : '已经是列表第一部');
      return '';
    }
    unawaited(_openQueueDrama(queue, direction, target));
    return target.title;
  }

  Future<void> _openQueueDrama(
    PlaybackQueue queue,
    int direction,
    Drama target,
  ) async {
    if (_closed || !mounted || widget.embedded) return;
    try {
      final detail = await widget.repository.detail(target);
      if (_closed || !mounted) return;
      if (detail.episodes.isEmpty) {
        _notice('《${target.title}》暂时没有可播放的集数');
        return;
      }
      final watched = widget.store.watched(detail.drama.id);
      final index = resumeEpisodeIndex(detail.episodes, watched);
      final position =
          watched?.episode == detail.episodes[index].number &&
              watched?.finished == false
          ? watched!.position
          : 0.0;
      await Navigator.of(context).pushReplacement(
        playerRoute(
          PlayerScreen(
            detail: detail,
            initialIndex: index,
            initialPosition: position,
            repository: widget.repository,
            store: widget.store,
            queue: queue.moved(direction),
          ),
        ),
      );
    } catch (_) {
      if (mounted && !_closed) _notice('切换失败，请重试');
    }
  }

  Future<void> _setOrientationMode(PlaybackOrientationMode mode) async {
    if (mode == _orientationMode || _closed) return;
    try {
      await _setPreferences(_preferences.copyWith(orientationMode: mode));
    } catch (_) {
      _notice('方向偏好未能保存，请重试');
    }
  }

  void _notice(String message) {
    if (!mounted || _closed) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _sendLocalDanmaku() async {
    if (_closed) return;
    final input = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('发送本地弹幕'),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: const InputDecoration(hintText: '弹幕内容，只存在本机'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(input.text),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    input.dispose();
    if (_closed || text == null || text.trim().isEmpty) return;
    await _danmaku.sendLocal(text);
    if (mounted && !_closed) _notice('已发送本地弹幕');
  }

  Future<void> _setPreferences(PlaybackPreferences preferences) async {
    if (_closed || widget.store.profileEpoch != _profileEpoch) {
      if (mounted && !_closed) _notice('当前用户已变更，请重试');
      return;
    }
    try {
      await _setPreferencesInner(preferences);
    } catch (_) {
      if (mounted && !_closed) _notice('设置保存失败，请重试');
    }
  }

  Future<void> _setPreferencesInner(PlaybackPreferences preferences) async {
    _interactions.cancel();
    final adBlockChanged = preferences.adBlock != _adBlock;
    final nextPreferences = preferences.copyWith(
      autoAdvance: true,
      preload: true,
    );
    await widget.store.setPlaybackPreferences(nextPreferences);
    if (!mounted || _closed || widget.store.profileEpoch != _profileEpoch)
      return;
    final qualityChanged = nextPreferences.quality != _requestedQuality;
    final decoderChanged =
        nextPreferences.televisionDecoder != _televisionDecoder;
    final orientationChanged =
        nextPreferences.orientationMode != _orientationMode;
    _enhancement.setPreferences(nextPreferences.enhancement);
    unawaited(_pictureQuality.apply(nextPreferences.pictureQuality));
    setState(() {
      _speed = nextPreferences.speed;
      _requestedQuality = nextPreferences.quality;
      _autoAdvance = true;
      _danmakuEnabled = nextPreferences.danmaku;
      _adBlock = nextPreferences.adBlock;
      _preloadEnabled = true;
      _seamlessEnabled = nextPreferences.seamless;
      _televisionDecoder = nextPreferences.televisionDecoder;
      _orientationMode = nextPreferences.orientationMode;
    });
    if (orientationChanged) unawaited(_applyOrientation());
    _danmaku.setEnabled(_danmakuEnabled);
    _syncDanmaku();
    if (qualityChanged || adBlockChanged) {
      _preloader.clear();
      _discardSeamlessStandby();
    }
    if (!nextPreferences.seamless) {
      _discardSeamlessStandby();
    }
    _syncPreload();
    _menuRevision.value++;
    await _interactions.applySpeed();
    if (_useNativeHandle) unawaited(_tvboxHandle.setSpeed(_speed));
    if (_useIjkCore) unawaited(_ijkHandle.setSpeed(_speed));
    if (qualityChanged && _plan?.local != true) {
      await _retry(quality: nextPreferences.quality);
    } else if (adBlockChanged && _plan?.local != true) {
      // 去广告开关按会话生效：重建播放会话让核心按新标志清洗或放行原画。
      await _retry();
    } else if (decoderChanged && _televisionDecoderApplies) {
      await _retry();
    }
  }

  Future<void> _toggleFavorite() async {
    try {
      await widget.store.toggleFavorite(widget.detail.drama);
      if (mounted && !_closed) setState(() {});
    } catch (_) {
      _notice('追剧记录未能保存，请检查存储空间后重试');
    }
  }

  Future<void> _toggleDanmaku() async {
    if (widget.detail.drama.source != 'hongguo') return;
    try {
      await _setPreferences(_preferences.copyWith(danmaku: !_danmakuEnabled));
    } catch (_) {
      _notice('弹幕偏好未能保存，请重试');
    }
  }

  Future<void> _retryDanmakuFromControls() async {
    try {
      _danmaku.retry();
      _menuRevision.value++;
    } catch (_) {
      _notice('弹幕重试失败，请稍后再试');
    }
  }

  /// MPV 开播后挂默认外挂字幕：规则见 [chooseDefaultSubtitle]
  /// （中文语言优先、否则第一条）。挂载失败不挡播放，菜单里可手动再选。
  Future<void> _loadDefaultExternalSubtitle(PlaybackPlan plan) async {
    if (plan.subs.isEmpty) return;
    final index = chooseDefaultSubtitle(plan.subs);
    if (index < 0) return;
    final sub = plan.subs[index];
    try {
      await _player.setSubtitleTrack(
        SubtitleTrack.uri(sub.url, title: sub.name, language: sub.lang),
      );
      _externalSubUrl = sub.url;
    } catch (_) {}
  }

  List<TrackMenuEntry> _buildAudioTrackEntries() {
    _audioTrackById.clear();
    final choices = <TrackChoice>[];
    for (final track in _player.state.tracks.audio) {
      if (track.id == 'auto' || track.id == 'no') continue;
      _audioTrackById[track.id] = track;
      choices.add(
        TrackChoice(
          id: track.id,
          title: track.title ?? '',
          language: track.language ?? '',
        ),
      );
    }
    return buildAudioTrackEntries(
      choices,
      selectedId: _player.state.track.audio.id,
    );
  }

  List<TrackMenuEntry> _buildSubtitleTrackEntries() {
    _subtitleTrackById.clear();
    final choices = <TrackChoice>[];
    for (final track in _player.state.tracks.subtitle) {
      if (track.id == 'auto' || track.id == 'no') continue;
      // 已挂上的外挂字幕会以 uri 形态出现在轨道列表里，它由
      // plan.subs 那组条目承载，内嵌组里跳过避免重复。
      if (track.uri == true) continue;
      _subtitleTrackById[track.id] = track;
      choices.add(
        TrackChoice(
          id: track.id,
          title: track.title ?? '',
          language: track.language ?? '',
        ),
      );
    }
    return buildSubtitleTrackEntries(
      choices,
      external: _plan?.subs ?? const [],
      selectedEmbeddedId: _player.state.track.subtitle.id,
      selectedExternalUrl: _externalSubUrl,
      subtitlesOff:
          _subtitlesOff || _player.state.track.subtitle.id == 'no',
    );
  }

  Future<void> _onTrackEntry(TrackMenuEntry entry) async {
    try {
      switch (entry.kind) {
        case TrackMenuEntryKind.audio:
          final track = _audioTrackById[entry.id];
          if (track != null) await _player.setAudioTrack(track);
        case TrackMenuEntryKind.subtitleOff:
          await _player.setSubtitleTrack(SubtitleTrack.no());
          _externalSubUrl = null;
          _subtitlesOff = true;
        case TrackMenuEntryKind.subtitleEmbedded:
          final track = _subtitleTrackById[entry.id];
          if (track != null) {
            await _player.setSubtitleTrack(track);
            _externalSubUrl = null;
            _subtitlesOff = false;
          }
        case TrackMenuEntryKind.subtitleExternal:
          final url = entry.externalUrl;
          final sub = (_plan?.subs ?? const <SubtitleSource>[])
              .where((item) => item.url == url)
              .firstOrNull;
          if (sub != null) {
            await _player.setSubtitleTrack(
              SubtitleTrack.uri(sub.url, title: sub.name, language: sub.lang),
            );
            _externalSubUrl = sub.url;
            _subtitlesOff = false;
          }
      }
    } catch (_) {
      if (mounted && !_closed) _notice('轨道切换失败，请重试');
    }
    _menuRevision.value++;
  }

  Future<void> _openPanel(PlayerMenuSection section) async {
    if (_panelOpen || _closed) return;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    final menuTheme = _showFullscreen ? AppTheme.dark : Theme.of(context);
    try {
      final index = await showDialog<int>(
        context: context,
        builder: (menuContext) => AnimatedBuilder(
          animation: Listenable.merge([
            _menuRevision,
            widget.store,
            _danmaku,
            _preloader,
          ]),
          builder: (_, _) => Theme(
            data: menuTheme,
            child: PlayerMenu(
              section: section,
              episodes: widget.detail.episodes,
              currentIndex: _index,
              preferences: _preferences,
              qualities: _plan?.qualities ?? [],
              actualQuality: _plan?.quality ?? 0,
              local: _plan?.local == true,
              favorite: widget.store.isFavorite(widget.detail.drama.id),
              mobile: _mobile,
              routeIndex: _currentRoute,
              routeCount: _routeCount,
              onRoute: (route) => Navigator.pop(menuContext, route),
              onEpisode: (index) => Navigator.pop(menuContext, index),
              onPreferences: _setPreferences,
              showDanmaku: widget.detail.drama.source == 'hongguo',
              danmakuStatus: _danmaku.status,
              onRetryDanmaku: _danmaku.canRetry ? _danmaku.retry : null,
              onSendLocalDanmaku: _danmaku.canSendLocal
                  ? _sendLocalDanmaku
                  : null,
              preloadStatus: _preloader.status,
              enhancement: _enhancementForUi,
              onCompareEnhancement: () {
                unawaited(_enhancement.toggleCompare());
                Navigator.pop(menuContext);
              },
              onFavorite: () =>
                  widget.store.toggleFavorite(widget.detail.drama),
              audioTrackEntries: _useNativeHandle || _useIjkCore
                  ? const []
                  : _buildAudioTrackEntries(),
              subtitleTrackEntries: _useNativeHandle || _useIjkCore
                  ? const []
                  : _buildSubtitleTrackEntries(),
              onTrackEntry: _onTrackEntry,
              introOutro: _introOutroSettings,
              introOutroEnabled: widget.store.introOutroSkipEnabled,
              onIntroOutroChanged: (next) => widget.store.setIntroOutroFor(
                widget.detail.drama.source,
                widget.detail.drama.id,
                next,
              ),
            ),
          ),
        ),
      );
      if (!mounted || _closed || index == null) return;
      try {
        if (section == PlayerMenuSection.route) {
          await _selectRoute(index);
        } else if (index != _index) {
          await _play(index, showControlsOnReady: false);
        }
      } catch (_) {
        if (mounted && !_closed) _notice('切换失败，请重试');
      }
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
  }

  Future<void> _seekTo(Duration target) async {
    if (_closed || _loading || _error != null) return;
    final ticket = ++_seekSequence;
    final generation = _generation;
    _danmaku.beginSeek();
    _enhancement.ignorePerformance();
    var succeeded = false;
    try {
      if (_useNativeHandle) {
        await _tvboxHandle.seek(target);
      } else if (_useIjkCore) {
        await _ijkHandle.seek(target);
      } else {
        await _player.seek(target);
      }
      succeeded = true;
    } catch (_) {
      _notice('跳转失败，请重试');
    } finally {
      if (!_closed && ticket == _seekSequence && generation == _generation) {
        _danmaku.endSeek(succeeded ? target : _seekFallbackPosition);
      }
    }
    // 拖进度成功后把实时字幕锚点重钉到新位置，免得旧锚点的行
    // 还留在画面上；服务没起时 reanchor 是空操作。
    if (succeeded) _liveSubtitle?.reanchor(target);
  }

  void _seek(int seconds) {
    final desired = _enginePosition + Duration(seconds: seconds);
    final maxDuration = _engineDuration;
    final target = desired < Duration.zero
        ? Duration.zero
        : maxDuration > Duration.zero && desired > maxDuration
        ? maxDuration
        : desired;
    unawaited(_seekTo(target));
  }

  bool get _androidBrightness =>
      defaultTargetPlatform == TargetPlatform.android;

  double? _currentBrightness() {
    return _cachedBrightness;
  }

  Future<void> _setScreenBrightness(double value) async {
    if (_closed) return;
    _cachedBrightness = value;
    _brightnessAdjusted = true;
    try {
      await AppDevice.channel.invokeMethod<void>('setScreenBrightness', {
        'value': value,
      });
    } on PlatformException {
      _notice('亮度调整失败');
    } on MissingPluginException {
      _notice('亮度调整失败');
    }
  }

  Future<void> _resetScreenBrightness() async {
    if (!_brightnessAdjusted) return;
    _brightnessAdjusted = false;
    _cachedBrightness = null;
    try {
      await AppDevice.channel.invokeMethod<void>('resetScreenBrightness');
    } on PlatformException {
      // 恢复失败不打扰用户：窗口亮度覆盖只在本 Activity 存续，返回即失效。
    } on MissingPluginException {
      // 同上。
    }
  }

  Future<void> _readSystemBrightness() async {
    if (!_androidBrightness || _brightnessAdjusted) return;
    try {
      final value = await AppDevice.channel.invokeMethod<double>(
        'screenBrightness',
      );
      _cachedBrightness = value;
    } on PlatformException {
      _cachedBrightness = null;
    } on MissingPluginException {
      _cachedBrightness = null;
    }
  }

  Future<void> _televisionEpisodes(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    int? index;
    try {
      index = await showDialog<int>(
        context: context,
        builder: (_) => Theme(
          data: televisionTheme(AppTheme.dark),
          child: TelevisionEpisodeDialog(
            episodes: widget.detail.episodes,
            currentIndex: _index,
          ),
        ),
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (index != null && mounted && !_closed && index != _index) {
      await _play(index, showControlsOnReady: false);
    }
  }

  Future<void> _televisionSettings(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    TelevisionPlaybackSetting? selection;
    try {
      final compatibleRendering = _televisionDecoderApplies
          ? await AppDevice.compatibleRendering()
          : null;
      if (!mounted || _closed) return;
      selection = await showDialog<TelevisionPlaybackSetting>(
        context: context,
        builder: (menuContext) => AnimatedBuilder(
          animation: Listenable.merge([_danmaku, _preloader]),
          builder: (_, _) => Theme(
            data: televisionTheme(AppTheme.dark),
            child: TelevisionSettingsDialog(
              speed: _speed,
              quality: _requestedQuality,
              qualities: _plan?.qualities ?? [],
              favorite: widget.store.isFavorite(widget.detail.drama.id),
              onFavorite: _toggleFavorite,
              autoAdvance: _autoAdvance,
              danmaku: _danmakuEnabled,
              showDanmaku: widget.detail.drama.source == 'hongguo',
              danmakuStatus: _danmaku.status,
              onRetryDanmaku: _danmaku.canRetry ? _danmaku.retry : null,
              preload: _preloadEnabled,
              preloadStatus: _preloader.status,
              seamless: _seamlessEnabled,
              enhancement: _enhancementForUi,
              onCompareEnhancement: () {
                unawaited(_enhancement.toggleCompare());
                Navigator.pop(menuContext);
              },
              route: _currentRoute,
              routeCount: _routeCount,
              decoder: _televisionDecoderApplies ? _televisionDecoder : null,
              compatibleRendering: compatibleRendering,
            ),
          ),
        ),
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (selection == null || !mounted || _closed) return;
    if (selection.compatibleRendering != null) {
      await _switchCompatibleRendering(selection.compatibleRendering!);
      return;
    }
    if (selection.route != null && selection.route != _currentRoute) {
      await _selectRoute(selection.route!);
      return;
    }
    try {
      await _setPreferences(
        _preferences.copyWith(
          speed: selection.speed,
          quality: selection.quality,
          autoAdvance: true,
          danmaku: selection.danmaku,
          preload: true,
          seamless: selection.seamless,
          enhancement: selection.enhancement,
          televisionDecoder: selection.decoder,
        ),
      );
    } catch (_) {
      _notice('播放偏好未能保存，请重试');
    }
  }

  Future<void> _switchCompatibleRendering(bool enabled) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Theme(
        data: televisionTheme(AppTheme.dark),
        child: AlertDialog(
          title: Text(enabled ? '开启兼容渲染模式？' : '关闭兼容渲染模式？'),
          content: const Text('需要重启应用才能生效。'),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('立即重启'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true) {
      await AppDevice.setCompatibleRendering(enabled);
    }
  }

  void _backToList() {
    if (_closed) return;
    if (_audioMode && _playIntent && !widget.embedded) {
      _showAudioMiniBar();
      Navigator.of(context).push(
        appPageRoute<void>(
          builder: (_) =>
              HomeScreen(repository: widget.repository, store: widget.store),
        ),
      );
      return;
    }
    if (widget.embedded) {
      _handleEmbeddedBack();
      return;
    }
    if (_episodePanelVisible && !_mobile) {
      _toggleEpisodePanel();
      return;
    }
    final action = resolvePlayerBackAction(
      panelOpen: _panelOpen,
      pageFullscreen: _pageFullscreen,
      fullscreen: _showFullscreen,
      television: _television,
      isFirstRoute: ModalRoute.of(context)?.isFirst ?? false,
    );
    switch (action) {
      case PlayerBackAction.closePanel:
        Navigator.of(context).pop();
      case PlayerBackAction.backOnce:
        Navigator.of(context).pop();
      case PlayerBackAction.exitPageFullscreen:
        _togglePageFullscreen();
      case PlayerBackAction.exitFullscreen:
        if (_rotating) {
          _backPending = true;
          return;
        }
        unawaited(_rotate());
      case PlayerBackAction.backToList:
        Navigator.of(context).popUntil(isBackToListStop);
      case PlayerBackAction.toHome:
        Navigator.of(context).pushReplacement(
          appPageRoute<void>(
            builder: (_) =>
                HomeScreen(repository: widget.repository, store: widget.store),
          ),
        );
    }
  }

  void _togglePageFullscreen() {
    if (_television || _closed) return;
    _interactions.cancel();
    setState(() => _pageFullscreen = !_pageFullscreen);
    _scheduleSystemUi();
  }

  void _toggleEpisodePanel() {
    if (_closed || _showFullscreen || _mobile) return;
    _interactions.cancel();
    setState(() => _episodePanelVisible = !_episodePanelVisible);
  }

  @override
  void dispose() {
    _closed = true;
    _removeAudioMiniBar();
    _releaseExternalAudio();
    unawaited(_stopLiveSubtitle());
    if (_playbackServiceHeld) {
      _playbackServiceHeld = false;
      unawaited(PlaybackForeground.release());
    }
    unawaited(_resetScreenBrightness());
    final enhancementClosed = _enhancement.close();
    widget.store.removeListener(_accessChanged);
    _danmaku.dispose();
    _preloader.dispose();
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _healthTimer?.cancel();
    _speedTracker.dispose();
    _errorTimer?.cancel();
    _pictureInPictureExitTimer?.cancel();
    if (_pictureInPictureHandlerInstalled) {
      AppDevice.channel.setMethodCallHandler(null);
    }
    _interactions.dispose();
    _playerFocus.dispose();
    _episodeStripController.dispose();
    _menuRevision.dispose();
    unawaited(_saveProgress());
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    for (final subscription in _engineSubscriptions) {
      subscription.cancel();
    }
    _engineSubscriptions.clear();
    unawaited(widget.repository.release(_session));
    unawaited(_loader.close().catchError((Object _) {}));
    unawaited(
      _operations
          .catchError((Object _) {})
          .timeout(const Duration(seconds: 1), onTimeout: () {})
          .then((_) async {
            await _interactions.pendingRates.catchError((Object _) {});
            await enhancementClosed.catchError((Object _) {});
            await _pictureQuality.dispose().catchError((Object _) {});
            await _player.dispose();
            final standby = _standbyMpvRig;
            if (standby != null) {
              await standby.player.dispose().catchError((Object _) {});
            }
          }),
    );
    if (Platform.isWindows) {
      unawaited(windowManager.setFullScreen(false));
    } else if (_mobile || _television && Platform.isAndroid) {
      unawaited(
        (_orientationController?.releasePlayback(this) ??
                SystemChrome.setPreferredOrientations(
                  AppOrientationController.orientations(
                    television: _television,
                  ),
                ))
            .catchError((Object _) {}),
      );
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  Widget _nonVideoPane() {
    final content = _nonVideo!;
    final title = widget.detail.drama.title;
    final episode = widget.detail.episodes[_index];
    final label = content.isNovel ? '正在阅读' : '正在浏览图片';
    final body = content.isNovel
        ? NovelReaderView(content: content, title: title)
        : PicsViewerView(content: content, title: title);
    final audioEpisode = content.isNovel ? _audioEpisodeFor(_index) : null;
    return Container(
      color: Colors.black,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                body,
                if (audioEpisode != null)
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: Opacity(
                      opacity: 0.85,
                      child: Material(
                        color: Colors.black54,
                        shape: const CircleBorder(),
                        child: IconButton(
                          tooltip: '听书',
                          onPressed: () => _playAudio(_index),
                          icon: const Icon(
                            Icons.headphones,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            color: Colors.black,
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: Row(
              children: [
                IconButton(
                  tooltip: '上一集',
                  onPressed: _index > 0
                      ? () => _play(_index - 1, showControlsOnReady: false)
                      : null,
                  icon: const Icon(Icons.skip_previous, color: Colors.white),
                ),
                Expanded(
                  child: Text(
                    '$label · 第 ${episode.number} 集'
                    '${content.isPics ? '（${content.urls.length} 张）' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                IconButton(
                  tooltip: '下一集',
                  onPressed: _index + 1 < widget.detail.episodes.length
                      ? () => _play(_index + 1, showControlsOnReady: false)
                      : null,
                  icon: const Icon(Icons.skip_next, color: Colors.white),
                ),
                if (!widget.embedded)
                  IconButton(
                    tooltip: '返回',
                    onPressed: _backToList,
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_audioMiniBar != null && ModalRoute.of(context)?.isCurrent == true) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _removeAudioMiniBar(),
      );
    }
    final inherited = Theme.of(context);
    final theme = _television ? televisionTheme(inherited) : inherited;
    if (widget.embedded) {
      return Theme(
        data: theme,
        child: Focus(
          focusNode: _playerFocus,
          child: _nonVideo != null ? _nonVideoPane() : _videoPane(context),
        ),
      );
    }
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          final fullscreen = _showFullscreen;
          final overlayBrightness = fullscreen
              ? Brightness.dark
              : Theme.of(context).brightness;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: AppTheme.systemBars(overlayBrightness),
            child: _buildPlayer(context),
          );
        },
      ),
    );
  }

  Widget _buildPlayer(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.detail.drama.title;
    if (_nonVideo != null) {
      return PopScope(
        canPop: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          body: SafeArea(top: false, child: _nonVideoPane()),
        ),
      );
    }
    final fullscreen = _showFullscreen;
    final pictureInPicture = _pictureInPictureVisible;
    return PopScope(
      canPop: _television,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_television) {
          _backToList();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _backToList,
          const SingleActivator(LogicalKeyboardKey.goBack): _backToList,
        },
        child: Focus(
          focusNode: _playerFocus,
          onKeyEvent: (_, event) {
            if (_television ||
                _panelOpen ||
                !_playerFocus.hasPrimaryFocus ||
                !(ModalRoute.of(context)?.isCurrent ?? true)) {
              return KeyEventResult.ignored;
            }
            return _interactions.key(event);
          },
          autofocus: !_television,
          canRequestFocus: !_television,
          skipTraversal: _television,
          child: Scaffold(
            backgroundColor: fullscreen || pictureInPicture
                ? Colors.black
                : theme.scaffoldBackgroundColor,
            appBar: pictureInPicture || fullscreen || _mobile
                ? null
                : AppBar(
                    title: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    actions: [
                      PlayerCoreBadge(
                        core: _effectiveCore,
                        onTap: _openCoreDialog,
                      ),
                      IconButton(
                        tooltip: '旋转与全屏',
                        onPressed: _rotate,
                        icon: const Icon(Icons.screen_rotation_alt_rounded),
                      ),
                    ],
                  ),
            // 画中画也走同一条链：以前画中画时 body 直接挂 _videoPane，
            // 进出系统画中画等于把播放区从 Stack 里的 Positioned 挪到
            // Scaffold body 直下，父级一变原生画面重挂。改成全程
            // SafeArea → LayoutBuilder → Stack → Positioned，只改
            // 四条边与面板显隐（画中画里视频占满、面板全藏）。
            body: SafeArea(
              top: !_television && (fullscreen || _mobile),
              bottom: !fullscreen,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final desktop = constraints.maxWidth >= 840;
                  final wide =
                      desktop ||
                      constraints.maxWidth > constraints.maxHeight * 1.3;
                  // 画面层绝不换父级：全屏/非全屏/画中画都挂在同一条
                  // Stack → Positioned 链上，只改四条边。
                  // 短剧走的是原生画面层（AndroidView），早先全屏时
                  // 把 _videoPane 从 SizedBox/Row 里搬到 LayoutBuilder
                  // 直下，平台视图被重建 → 解码器照旧出声、画面全黑
                  // （v45 修的是观看房那台播放器，这条路径没吃到）。
                  // 改成尺寸变化后，Element 不搬，表面也不重建。
                  // 画中画同理：以前画中画时 body 直接挂 _videoPane，
                  // 进出画中画也换了父级，一并收进同一条链（视频占满、
                  // 面板全藏）。
                  final panelSide =
                      !fullscreen &&
                      !pictureInPicture &&
                      wide &&
                      _episodePanelVisible;
                  final sideWidth = panelSide
                      ? (desktop ? 312.0 : 210.0)
                      : 0.0;
                  double videoHeight = 0; // 0 = 视频占满剩余高度
                  if (!fullscreen && !pictureInPicture && !wide) {
                    final maxRatio = _mobile ? .56 : .64;
                    videoHeight = (constraints.maxWidth / _aspectRatio)
                        .clamp(0.0, constraints.maxHeight * maxRatio);
                  }
                  final filler = videoHeight > 0
                      ? (constraints.maxHeight - videoHeight).clamp(
                          0.0,
                          constraints.maxHeight,
                        )
                      : 0.0;
                  return Stack(
                    children: [
                      Positioned(
                        left: 0,
                        top: 0,
                        right: sideWidth,
                        bottom: filler,
                        child: _videoPane(context),
                      ),
                      if (!fullscreen && !wide && !pictureInPicture)
                        Positioned(
                          left: 0,
                          right: 0,
                          // 面板顶边就是视频底边：filler 是视频底边到
                          // Stack 底的距离（maxHeight - videoHeight），
                          // 不是视频高度；以前用 filler 当顶边，视频
                          // 16:9 时面板被顶下去 filler - videoHeight，
                          // 中间露出一大段底色空白。
                          top: videoHeight,
                          bottom: 0,
                          child: _mobilePlaybackPanel(),
                        ),
                      if (panelSide)
                        Positioned(
                          top: 0,
                          right: 0,
                          bottom: 0,
                          width: sideWidth,
                          child: _episodePanel(
                            onClose: _toggleEpisodePanel,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _backdropUrl() {
    final drama = widget.detail.drama;
    var url = widget.detail.backdrop;
    if (url.isEmpty) {
      for (final still in widget.detail.stills) {
        if (still.isNotEmpty) {
          url = still;
          break;
        }
      }
    }
    if (url.isEmpty) url = drama.cover;
    return url;
  }

  Widget _audioPosterOverlay() {
    final drama = widget.detail.drama;
    final episode = widget.detail.episodes[_index];
    final chapterTitle =
        episode.title.isEmpty || episodeTitleLooksLikeUrl(episode.title)
        ? '第 ${episode.number} 集'
        : episode.title;
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _videoBackdrop(),
          Container(color: Colors.black.withValues(alpha: .35)),
          // 顶边距只留一份：上层 body SafeArea（全屏/手机）或 AppBar
          // （桌面）已占，覆盖层不再重复加顶；底边距只在全屏时由
          // 覆盖层占（非全屏时 body 已占），滑杆不被手势条压住。
          SafeArea(
            top: false,
            bottom: _showFullscreen,
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: '返回',
                      onPressed: _backToList,
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => _playText(_index),
                      icon: const Icon(Icons.menu_book, color: Colors.white),
                      label: const Text(
                        '看文字',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _openPanel(PlayerMenuSection.episodes),
                      icon: const Icon(Icons.list, color: Colors.white),
                      label: const Text(
                        '选集',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 180,
                        height: 240,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: DramaCover(
                            drama: drama,
                            repository: widget.repository,
                            radius: 16,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          drama.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          chapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                StreamBuilder<Duration>(
                  stream: _player.stream.position,
                  initialData: _player.state.position,
                  builder: (context, snapshot) {
                    final position = snapshot.data ?? _player.state.position;
                    return StreamBuilder<Duration>(
                      stream: _player.stream.duration,
                      initialData: _player.state.duration,
                      builder: (context, durationSnapshot) {
                        final duration =
                            durationSnapshot.data ?? _player.state.duration;
                        final total = duration.inMilliseconds.toDouble();
                        final value = total > 0
                            ? position.inMilliseconds.toDouble().clamp(
                                0.0,
                                total,
                              )
                            : 0.0;
                        String fmt(Duration d) {
                          final m = d.inMinutes;
                          final s = d.inSeconds % 60;
                          return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
                        }

                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Column(
                            children: [
                              Slider(
                                value: value,
                                max: total > 0 ? total : 1,
                                onChanged: total > 0
                                    ? (v) => unawaited(
                                        _seekTo(
                                          Duration(milliseconds: v.toInt()),
                                        ),
                                      )
                                    : null,
                              ),
                              Row(
                                children: [
                                  Text(
                                    fmt(position),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    fmt(duration),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: '上一集',
                        onPressed: _index > 0
                            ? () => _playAudio(_index - 1)
                            : null,
                        icon: const Icon(
                          Icons.skip_previous,
                          color: Colors.white,
                          size: 36,
                        ),
                      ),
                      const SizedBox(width: 16),
                      StreamBuilder<bool>(
                        stream: _player.stream.playing,
                        initialData: _player.state.playing,
                        builder: (context, snapshot) {
                          final playing =
                              snapshot.data ?? _player.state.playing;
                          return IconButton(
                            tooltip: playing ? '暂停' : '播放',
                            onPressed: _togglePlayback,
                            icon: Icon(
                              playing
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_filled,
                              color: Colors.white,
                              size: 56,
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        tooltip: '下一集',
                        onPressed: _index + 1 < widget.detail.episodes.length
                            ? () => _playAudio(_index + 1)
                            : null,
                        icon: const Icon(
                          Icons.skip_next,
                          color: Colors.white,
                          size: 36,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _videoBackdrop() {
    final drama = widget.detail.drama;
    final url = _backdropUrl();
    if (url.isEmpty) return const SizedBox.shrink();
    final backdropDrama = Drama(
      id: '${drama.id}#player-backdrop',
      source: drama.source,
      title: drama.title,
      cover: url,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        AtmosphereBackground(
          url: url,
          repository: widget.repository,
          drama: backdropDrama,
        ),
        // 背景图清晰显示、不模糊（用户令）：前景文字可读性靠各调用
        // 点的渐变罩/暗色覆盖保证，这里不再加任何 blur 滤镜。
        DramaCover(
          drama: backdropDrama,
          repository: widget.repository,
          radius: 0,
        ),
      ],
    );
  }

  Widget _videoPane(BuildContext context) {
    final videoTheme = _television
        ? televisionTheme(AppTheme.dark)
        : AppTheme.dark;
    final title =
        '${widget.detail.drama.title} · 第 ${widget.detail.episodes[_index].number} 集${_audioMode ? ' · 听书' : ''}${_plan?.local == true ? ' · 本地' : ''}${widget.detail.episodes[_index].vip ? ' · VIP 试看' : ''}${(_plan?.routeIndex ?? 0) > 0 ? ' · 线路 ${_plan!.routeIndex + 1}' : ''}';
    final hideOverlayForPictureInPicture = _pictureInPictureVisible;
    final errorKind = _error == null ? null : classifyPlaybackError(_error!);
    // 左上角返回箭头只留一个：常驻返回渲染时，控制层顶栏不再画
    // 第二个箭头；加载/失败全屏时的退出全屏行同理。两者都走
    // _backToList，藏掉哪一个都不改变返回行为。嗅探态同理：左上角
    // 只留关嗅探的 X，常驻返回藏掉（X 盖在它下层，留着点不到），
    // 关掉嗅探后常驻返回随状态恢复；系统返回仍走 _backToList。
    final permanentBackVisible =
        _mobile &&
        !_television &&
        !_useNativeHandle &&
        !_useIjkCore &&
        !_sniffEmbedded &&
        !hideOverlayForPictureInPicture &&
        !((_loading || _error != null) && _showFullscreen);
    final loadingFullscreenExitVisible =
        (_loading || _error != null) &&
        !hideOverlayForPictureInPicture &&
        _showFullscreen &&
        !_television;
    final Widget controls = hideOverlayForPictureInPicture
        ? const SizedBox.shrink()
        : _television
        ? TelevisionControls(
            key: ValueKey('television-controls-rig-${_activeMpvRig.id}'),
            player: _player,
            title: title,
            enabled: !_loading && _error == null,
            showOnPlaybackReady: _showControlsOnPlaybackReady,
            enhancement: _enhancementForUi,
            onTogglePlayback: _togglePlayback,
            onSeek: _seek,
            onPrevious: _index > 0
                ? () => _audioMode
                      ? _playAudio(_index - 1)
                      : _play(_index - 1, showControlsOnReady: false)
                : null,
            onNext: _index + 1 < widget.detail.episodes.length
                ? () => _audioMode
                      ? _playAudio(_index + 1)
                      : _play(_index + 1, showControlsOnReady: false)
                : null,
            onEpisodes: () => _televisionEpisodes(context),
            onSettings: () => _televisionSettings(context),
            onBack: _backToList,
          )
        : PlayerControls(
            key: ValueKey('player-controls-rig-${_activeMpvRig.id}'),
            player: _player,
            interactions: _interactions,
            enabled: !_loading && _error == null,
            enhancement: _enhancementForUi,
            panelOpen: _panelOpen,
            fullscreen: widget.embedded
                ? widget.embeddedFullscreen
                : _showFullscreen,
            pageFullscreen: _pageFullscreen,
            windowFullscreen: _windowFullscreen,
            showOnPlaybackReady: _showControlsOnPlaybackReady,
            title: title,
            onTogglePlayback: _togglePlayback,
            swipeEnabled: _mobile,
            onFullscreen: widget.embedded ? _notifyEmbeddedFullscreen : _rotate,
            onPageFullscreen: Platform.isWindows ? _togglePageFullscreen : null,
            onExitFullscreen: _backToList,
            onBack: _backToList,
            showTopBarBackButton:
                !permanentBackVisible && !loadingFullscreenExitVisible,
            onFocusSurface: _playerFocus.requestFocus,
            onSeek: _seekTo,
            speed: _speed,
            networkSpeed: _speedTracker.speedText,
            qualityLabel: _qualityLabel,
            routeLabel: _routeLabel,
            routeCount: _routeCount,
            onRoute: () => _openPanel(PlayerMenuSection.route),
            showDanmaku: widget.detail.drama.source == 'hongguo',
            danmakuEnabled: _danmakuEnabled,
            danmakuStatus: _danmaku.status,
            onEpisodes: () async {
              if (!_mobile && !_showFullscreen) {
                _toggleEpisodePanel();
              } else {
                await _openPanel(PlayerMenuSection.episodes);
              }
            },
            onSpeed: () => _openPanel(PlayerMenuSection.speed),
            onQuality: () => _openPanel(PlayerMenuSection.quality),
            onSettings: () => _openPanel(PlayerMenuSection.settings),
            onDanmaku: widget.detail.drama.source == 'hongguo'
                ? _toggleDanmaku
                : null,
            onRetryDanmaku: _danmaku.canRetry
                ? _retryDanmakuFromControls
                : null,
            // 控制层显隐变化时抬/落字幕：字幕是 media_kit 的 Flutter 层
            // SubtitleView，默认底边只留 24px，正好被控制行与进度条盖
            // 住；可见时抬到 96px（控制行+进度条之上），隐藏时落回
            // 默认 24px。非 Video 路径下 _videoState 为 null，空操作。
            onControlsVisibilityChanged: (visible) =>
                _videoState?.setSubtitleViewPadding(
                  EdgeInsets.fromLTRB(16, 0, 16, visible ? 96 : 24),
                ),
            onPictureInPicture: _canUsePictureInPicture
                ? _enterPictureInPicture
                : null,
            onPrevious: _index > 0
                ? () => _audioMode
                      ? _playAudio(_index - 1)
                      : _play(_index - 1, showControlsOnReady: false)
                : widget.detail.episodes.length <= 1 &&
                      widget.queue?.neighbor(-1) != null
                ? () => _queueSwipe(-1)
                : null,
            onNext: _index + 1 < widget.detail.episodes.length
                ? () => _audioMode
                      ? _playAudio(_index + 1)
                      : _play(_index + 1, showControlsOnReady: false)
                : widget.detail.episodes.length <= 1 &&
                      widget.queue?.neighbor(1) != null
                ? () => _queueSwipe(1)
                : null,
            orientationMode: _orientationMode,
            onOrientationMode: _mobile ? _setOrientationMode : null,
            core: _effectiveCore,
            onCoreTap: _openCoreDialog,
          );
    final layeredControls = Stack(
      fit: StackFit.expand,
      children: [
        if (!hideOverlayForPictureInPicture)
          DanmakuOverlay(controller: _danmaku, aspectRatio: _aspectRatio),
        controls,
      ],
    );
    return Theme(
      data: videoTheme,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final ratio = MediaQuery.devicePixelRatioOf(context);
          final pixels = Size(
            constraints.maxWidth * ratio,
            constraints.maxHeight * ratio,
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_closed) {
              _enhancement.setViewport(pixels, television: _television);
            }
          });
          return Stack(
            key: _videoPaneKey,
            fit: StackFit.expand,
            children: [
              if (_sniffEmbedded)
                SniffWebViewPage(
                  key: ValueKey('embedded-sniffer-$_lastPageUrl'),
                  pageUrl: _lastPageUrl,
                  headers: _plan?.headers ?? const {},
                  embedded: true,
                  onMediaFound: _onSniffedMedia,
                  onLoadFailed: _onSniffLoadFailed,
                  validateCandidate: sniffCandidateValidator(
                    headers: _plan?.headers ?? const {},
                  ),
                  sniffTimeout: sniffFallbackTimeout,
                  onSniffTimeout: _onSniffTimeout,
                ),
              if (_sniffEmbedded && !hideOverlayForPictureInPicture)
                Positioned(
                  top: 8,
                  left: 8,
                  child: Material(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      key: const ValueKey('player-sniff-close'),
                      borderRadius: BorderRadius.circular(20),
                      onTap: _closeSniffer,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
              // EXO 待命面：盖在正式面下层，只出画面（待命模式），
              // 首帧备好后等对调。key 按装置编号钉死，对调时元素
              // 不重建、平台视图不重挂，首帧不丢。
              if (!_sniffEmbedded &&
                  _useNativeHandle &&
                  _standbyTvboxRig.standbyPlan != null)
                TvboxVideoPane(
                  key: ValueKey('tvbox-rig-${1 - _activeTvboxRigIndex}'),
                  viewType: TvboxPlayerController.viewType,
                  plan: _standbyTvboxRig.standbyPlan,
                  startPosition: 0,
                  autoplay: false,
                  decoderMode: _televisionDecoder,
                  handle: _standbyTvboxRig.handle,
                  onCompleted: () {},
                  onError: _onStandbyExoError,
                  headless: true,
                  onFirstFrame: _onStandbyExoFirstFrame,
                ),
              // MPV 待命画面：同理盖在正式画面下层，不带控制层。
              if (!_sniffEmbedded &&
                  !_useNativeHandle &&
                  !_useIjkCore &&
                  _standbyMpvRig?.video != null)
                Video(
                  key: ValueKey('mpv-rig-${_standbyMpvRig!.id}'),
                  controller: _standbyMpvRig!.video!,
                  fit: BoxFit.contain,
                  subtitleViewConfiguration: const SubtitleViewConfiguration(
                    visible: false,
                  ),
                  controls: (_) => const SizedBox.shrink(),
                ),
              if (!_sniffEmbedded && widget.videoBuilder != null)
                widget.videoBuilder!(layeredControls)
              else if (!_sniffEmbedded && _useNativeHandle)
                TvboxVideoPane(
                  key: ValueKey('tvbox-rig-$_activeTvboxRigIndex'),
                  viewType: TvboxPlayerController.viewType,
                  plan: _activeTvboxRig.plan,
                  startPosition: _activeTvboxRig.startPosition,
                  autoplay: _activeTvboxRig.autoplay,
                  decoderMode: _televisionDecoder,
                  handle: _tvboxHandle,
                  onCompleted: _onTvboxCompleted,
                  onError: _onTvboxError,
                  onBack: _television ? null : _backToList,
                  onFullscreen: _television
                      ? null
                      : widget.embedded
                      ? _notifyEmbeddedFullscreen
                      : _rotate,
                  isFullscreen: widget.embedded
                      ? widget.embeddedFullscreen
                      : _showFullscreen,
                )
              else if (!_sniffEmbedded && _useIjkCore)
                IjkVideoPane(
                  plan: _ijkPlan,
                  startPosition: _ijkStartPosition,
                  autoplay: _ijkAutoplay,
                  handle: _ijkHandle,
                  onCompleted: _onIjkCompleted,
                  onError: _onIjkError,
                  onBack: _backToList,
                  onFullscreen: widget.embedded
                      ? _notifyEmbeddedFullscreen
                      : _rotate,
                  isFullscreen: widget.embedded
                      ? widget.embeddedFullscreen
                      : _showFullscreen,
                )
              else if (!_sniffEmbedded)
                Video(
                  key: ValueKey('mpv-rig-${_activeMpvRig.id}'),
                  controller: _video!,
                  fit: BoxFit.contain,
                  // 实时字幕行在播时，media_kit 自带的内嵌字幕层先藏
                  // 起来，只画实时行，不两层叠画；没实时行时照常
                  // 显示内嵌字幕。
                  subtitleViewConfiguration: SubtitleViewConfiguration(
                    visible: _liveLines.isEmpty,
                  ),
                  controls: (videoState) {
                    _videoState = videoState;
                    return layeredControls;
                  },
                ),
              // 实时字幕（MPV 核）：画在视频层之上、控制层之下，
              // 底边距 72 逻辑像素盖过底部控制条；画中画时不画。
              if (!_sniffEmbedded &&
                  !_useNativeHandle &&
                  !_useIjkCore &&
                  !hideOverlayForPictureInPicture &&
                  _liveLines.isNotEmpty)
                Positioned.fill(
                  child: ExoSubtitleOverlay(lines: _liveLines),
                ),
              if (_audioMode && !hideOverlayForPictureInPicture)
                Positioned.fill(child: _audioPosterOverlay()),
              if ((_useExoCore || _useIjkCore) &&
                  !hideOverlayForPictureInPicture)
                Positioned(
                  top: 8,
                  right: 8,
                  child: PlayerCoreBadge(
                    core: _effectiveCore,
                    onTap: _openCoreDialog,
                  ),
                ),
              if (_audioMode && !hideOverlayForPictureInPicture)
                Positioned(
                  top: 8,
                  left: 8,
                  child: Opacity(
                    opacity: 0.85,
                    child: Material(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => _playText(_index),
                        child: const Padding(
                          padding: EdgeInsets.fromLTRB(12, 8, 12, 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.menu_book,
                                color: Colors.white,
                                size: 18,
                              ),
                              SizedBox(width: 6),
                              Text(
                                '看文字',
                                style: TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if ((_loading || _error != null) &&
                  !hideOverlayForPictureInPicture)
                _videoBackdrop(),
              if (_loading && !hideOverlayForPictureInPicture)
                ColoredBox(
                  color: Colors.black.withValues(alpha: .55),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(_loadingMessage),
                      ],
                    ),
                  ),
                ),
              if (_error != null && !hideOverlayForPictureInPicture)
                ColoredBox(
                  color: Colors.black.withValues(alpha: .55),
                  child: Column(
                    children: [
                      Expanded(
                        child: StatusPanel(
                          title:
                              errorKind == null ||
                                  errorKind == PlaybackErrorKind.other
                              ? '暂时无法播放'
                              : '暂时无法播放 · ${errorKind.label}',
                          message: errorKind?.suggestion ?? '',
                          detail: _error!,
                          onRetry: _onErrorRetry,
                          action: _localFailure ? '重试本地播放' : '重试播放',
                          secondaryAction:
                              _localFailure && widget.allowOnlineFallback
                              ? TextButton.icon(
                                  onPressed: _switchOnline,
                                  icon: const Icon(Icons.cloud_outlined),
                                  label: const Text('改为在线播放'),
                                )
                              : !_localFailure &&
                                    !widget.localOnly &&
                                    widget.repository.supportsSourceManagement
                              ? SourceDiagnosticsButton(
                                  repository: widget.repository,
                                  store: widget.store,
                                  drama: widget.detail.drama,
                                )
                              : null,
                          icon: Icons.play_disabled_rounded,
                        ),
                      ),
                      if (errorKind != null &&
                          errorKind.suggestRoute &&
                          _routeCount > 1)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: TextButton.icon(
                            onPressed: () =>
                                _openPanel(PlayerMenuSection.route),
                            icon: const Icon(Icons.route_outlined),
                            label: const Text('换线路'),
                          ),
                        ),
                      if (_lastPageUrl.isNotEmpty && !_localFailure)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 24),
                          child: TextButton.icon(
                            onPressed: _openSniffer,
                            icon: const Icon(Icons.radar_rounded),
                            label: const Text('网页内嵌播放'),
                          ),
                        ),
                    ],
                  ),
                ),
              if (loadingFullscreenExitVisible)
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '退出全屏',
                          onPressed: _rotate,
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () =>
                              _openPanel(PlayerMenuSection.episodes),
                          child: const Text('选集'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_saveWarning != null && !hideOverlayForPictureInPicture)
                Positioned(
                  top: 52,
                  left: 12,
                  right: 12,
                  child: SafeArea(
                    bottom: false,
                    child: Material(
                      color: const Color(0xE6322424),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              _saveWarning!,
                              style: const TextStyle(fontSize: 12),
                            ),
                            TextButton(
                              onPressed: _saveProgress,
                              child: const Text('重试保存'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (permanentBackVisible)
                Positioned(
                  top: 0,
                  left: 0,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .36),
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: IconButton(
                          key: const ValueKey('player-permanent-back'),
                          tooltip: '返回',
                          constraints: const BoxConstraints.tightFor(
                            width: 42,
                            height: 42,
                          ),
                          padding: EdgeInsets.zero,
                          onPressed: _backToList,
                          icon: const Icon(
                            Icons.arrow_back_rounded,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 竖屏合一页（照 FongMi 手机版骨架）：播放器固定在上方，
  /// 下方单列滚动——片名→备注→站源→年份·类型→线路（同名跨站）→
  /// 选集横排→简介（3 行折叠）→相关推荐（站内 + 同名跨站双轨）。
  /// 选集永远在简介之前。
  Widget _mobilePlaybackPanel() {
    final darkScrim = _backdropUrl().isNotEmpty;
    final content = SafeArea(
      top: false,
      child: SingleChildScrollView(
        key: const ValueKey('player-info-scroll'),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _playerInfoHeader(darkScrim: darkScrim),
            _playerSourceRoutes(darkScrim: darkScrim),
            _playerRouteQualityRow(),
            _playerEpisodeSection(darkScrim: darkScrim),
            _playerSynopsisSection(darkScrim: darkScrim),
            _playerRelatedSection(darkScrim: darkScrim),
          ],
        ),
      ),
    );
    if (!darkScrim) {
      return ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: content,
      );
    }
    return Stack(
      children: [
        Positioned.fill(child: _videoBackdrop()),
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black45, Colors.black87],
              ),
            ),
          ),
        ),
        content,
      ],
    );
  }

  Widget _playerInfoHeader({required bool darkScrim}) {
    final drama = widget.detail.drama;
    final colors = Theme.of(context).colorScheme;
    final soft = darkScrim
        ? Colors.white.withValues(alpha: .82)
        : colors.onSurfaceVariant;
    final remark = [
      if (drama.releaseStatus.isNotEmpty && drama.releaseStatus != 'unknown')
        drama.releaseLabel,
      if (drama.episodes > 0) '共 ${drama.episodes} 集',
      '当前第 ${widget.detail.episodes[_index].number} 集',
    ].join(' · ');
    final meta = [
      if (drama.onlineDate.isNotEmpty) drama.onlineDate,
      if (drama.category.isNotEmpty) drama.category,
      if (drama.heat.isNotEmpty) heatDisplayText(drama.heat),
      if (drama.views.isNotEmpty) '播放 ${drama.views}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          drama.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: darkScrim ? Colors.white : null,
          ),
        ),
        const SizedBox(height: 4),
        Text(remark, style: TextStyle(color: soft)),
        const SizedBox(height: 2),
        Text(
          '站源：${SourceSite.byId(drama.source).name}',
          style: TextStyle(color: soft),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(meta.join(' · '), style: TextStyle(color: soft)),
        ],
        const SizedBox(height: 10),
        _mobileFollowControl(drama),
        if (drama.tags.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in drama.tags.take(12))
                Chip(label: Text(tag), visualDensity: VisualDensity.compact),
            ],
          ),
        ],
      ],
    );
  }

  /// 线路区：同名跨站副本即换源 chips（有多站时才出现），
  /// 点一条在本页换到那个站的同片续播（集数对齐）。
  Widget _playerSourceRoutes({required bool darkScrim}) {
    final drama = widget.detail.drama;
    if (drama.peers.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '换源',
            style: TextStyle(
              color: darkScrim ? Colors.white : colors.primary,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final peer in drama.peers)
                ActionChip(
                  key: ValueKey('player-peer-${peer.source}'),
                  avatar: const Icon(Icons.play_arrow_rounded, size: 16),
                  label: Text(
                    peer.episodes > 0
                        ? '${SourceSite.byId(peer.source).name} · ${peer.episodes} 集'
                        : SourceSite.byId(peer.source).name,
                  ),
                  onPressed: () =>
                      _openDramaInPlayer(peer, episodeIndex: _index),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _playerRouteQualityRow() {
    final routeCount = _routeCount;
    final qualities = _plan?.qualities ?? const <int>[];
    if (routeCount <= 1 && qualities.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (routeCount > 1)
            ActionChip(
              key: const ValueKey('player-info-route'),
              avatar: const Icon(Icons.alt_route_rounded, size: 16),
              label: Text(_routeLabel),
              onPressed: () => _openPanel(PlayerMenuSection.route),
            ),
          if (qualities.isNotEmpty)
            ActionChip(
              key: const ValueKey('player-info-quality'),
              avatar: const Icon(Icons.high_quality_rounded, size: 16),
              label: Text(_qualityLabel),
              onPressed: () => _openPanel(PlayerMenuSection.quality),
            ),
        ],
      ),
    );
  }

  Widget _playerEpisodeSection({required bool darkScrim}) {
    final episodes = widget.detail.episodes;
    final colors = Theme.of(context).colorScheme;
    // 全集列表上匹配一次、按真实集号下标取，倒序显示不重算、不错位。
    final previews = episodePreviewData(
      titles: [
        for (final episode in episodes)
          displayEpisodeTitle(episode.title, episode.number),
      ],
      tmdbEpisodes: _tmdb?.episodes ?? const [],
      config: _tmdbConfig,
      tmdbPosterUrl: _tmdb?.posterUrl(_tmdbConfig) ?? '',
      dramaCover: widget.detail.drama.cover,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '选集',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: darkScrim ? Colors.white : null,
                ),
              ),
              const Spacer(),
              IconButton(
                key: const ValueKey('episode-reverse'),
                tooltip: _episodesReversed ? '正序' : '倒序',
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    setState(() => _episodesReversed = !_episodesReversed),
                icon: Icon(
                  _episodesReversed
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded,
                  size: 18,
                  color: darkScrim ? Colors.white : null,
                ),
              ),
              if (episodes.length >= 10)
                TextButton(
                  key: const ValueKey('episode-more'),
                  style: darkScrim
                      ? TextButton.styleFrom(foregroundColor: Colors.white)
                      : null,
                  onPressed: _showEpisodeGridSheet,
                  child: const Text('更多'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: episodePreviewCardExtent(context, episodePreviewCardWidth),
            child: ListView.separated(
              controller: _episodeStripController,
              scrollDirection: Axis.horizontal,
              itemCount: episodes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final realIndex = _episodesReversed
                    ? episodes.length - 1 - i
                    : i;
                final episode = episodes[realIndex];
                final preview = previews[realIndex];
                final selected = realIndex == _index;
                final frameKey = EpisodeFrameCache.frameKey(
                  source: widget.detail.drama.source,
                  dramaId: widget.detail.drama.id,
                  episodeNumber: episode.number,
                );
                final framePath = _frameKeys.contains(frameKey)
                    ? EpisodeFrameCache.instance.pathForKey(frameKey)
                    : null;
                return SizedBox(
                  width: episodePreviewCardWidth,
                  child: EpisodePreviewCard(
                    // key 沿用 chip 时代的名字，widget 测试与外部定位不改。
                    key: ValueKey('episode-chip-$realIndex'),
                    episode: episode,
                    tmdb: preview.tmdb,
                    stillUrl: preview.stillUrl,
                    posterUrl: preview.posterUrl,
                    current: selected,
                    framePath: framePath,
                    onPressed: () {
                      if (selected) {
                        // 再点当前集 = 进全屏（FongMi 语义）
                        unawaited(_rotate());
                      } else {
                        _play(realIndex, showControlsOnReady: false);
                      }
                    },
                  ),
                );
              },
            ),
          ),
          if (episodes[_index].vip)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '当前集为 VIP 试看',
                style: TextStyle(color: colors.error, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  void _showEpisodeGridSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.of(sheetContext).size.height * 0.7,
        child: PlayerEpisodeGrid(
          episodes: widget.detail.episodes,
          currentIndex: _index,
          compact: true,
          title: '全部选集',
          onSelected: (index) {
            Navigator.of(sheetContext).pop();
            _play(index, showControlsOnReady: false);
          },
        ),
      ),
    );
  }

  Widget _playerSynopsisSection({required bool darkScrim}) {
    final drama = widget.detail.drama;
    final colors = Theme.of(context).colorScheme;
    final body = drama.description.trim().isEmpty
        ? '暂无简介'
        : drama.description.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '简介',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: darkScrim ? Colors.white : null,
            ),
          ),
          const SizedBox(height: 6),
          GestureDetector(
            key: const ValueKey('player-synopsis'),
            onTap: () => setState(() => _synopsisExpanded = !_synopsisExpanded),
            child: Text(
              body,
              maxLines: _synopsisExpanded ? null : 3,
              overflow: _synopsisExpanded ? null : TextOverflow.ellipsis,
              style: TextStyle(
                height: 1.55,
                color: darkScrim ? Colors.white : null,
              ),
            ),
          ),
          if (widget.detail.warning.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(widget.detail.warning, style: TextStyle(color: colors.error)),
          ],
        ],
      ),
    );
  }

  /// 相关区双轨：站内 related 图片卡打底 + 同名跨站卡片网格；
  /// 两轨都为空时整区不渲染。
  Widget _playerRelatedSection({required bool darkScrim}) {
    final related = widget.detail.related;
    final peers = widget.detail.drama.peers;
    if (related.isEmpty && peers.isEmpty) return const SizedBox.shrink();
    Widget grid(List<Drama> items, String keyPrefix, int episodeIndex) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final columns = (constraints.maxWidth / 150).floor().clamp(2, 6);
          final tileWidth =
              (constraints.maxWidth - (columns - 1) * 10) / columns;
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              mainAxisExtent: DramaTile.extentFor(context, tileWidth),
            ),
            itemCount: items.length,
            itemBuilder: (context, index) => DramaTile(
              key: ValueKey('$keyPrefix-${items[index].id}'),
              drama: items[index],
              repository: widget.repository,
              onTap: () =>
                  _openDramaInPlayer(items[index], episodeIndex: episodeIndex),
            ),
          );
        },
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (related.isNotEmpty) ...[
            Text(
              '相关推荐',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: darkScrim ? Colors.white : null,
              ),
            ),
            const SizedBox(height: 10),
            grid(related, 'player-related', 0),
          ],
          if (peers.isNotEmpty) ...[
            if (related.isNotEmpty) const SizedBox(height: 18),
            Text(
              '同名跨站',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: darkScrim ? Colors.white : null,
              ),
            ),
            const SizedBox(height: 10),
            grid(peers, 'player-peer-card', _index),
          ],
        ],
      ),
    );
  }

  /// 在本页换片：取目标详情后以新 PlayerScreen 替换当前路由，
  /// 播放器位置不变（同 FongMi selectSource / 点 quick 的体感）。
  Future<void> _openDramaInPlayer(
    Drama target, {
    required int episodeIndex,
  }) async {
    if (_closed || widget.embedded) return;
    try {
      final detail = await widget.repository.detail(target);
      if (!mounted || _closed) return;
      final index = detail.episodes.isEmpty
          ? 0
          : episodeIndex.clamp(0, detail.episodes.length - 1);
      await Navigator.of(context).pushReplacement(
        appPageRoute<void>(
          // 与 playerRoute 同名：返回的 popUntil 靠名字认出播放页，
          // 无名路由会让 popUntil 停在播放页自己身上、返回失灵。
          settings: const RouteSettings(name: 'player'),
          builder: (_) => PlayerScreen(
            detail: detail,
            initialIndex: index,
            repository: widget.repository,
            store: widget.store,
            playerFactory: widget.playerFactory,
            videoBuilder: widget.videoBuilder,
          ),
        ),
      );
    } on AppFailure catch (error) {
      if (mounted && !_closed) _notice(error.message);
    } catch (_) {
      if (mounted && !_closed) _notice('打开失败，请重试');
    }
  }

  Widget _mobileFollowControl(Drama drama) {
    final state = widget.store.following(drama.id);
    return PopupMenuButton<String>(
      key: const ValueKey('player-follow-status'),
      tooltip: '追剧与观看状态',
      onSelected: (value) async {
        if (_profileEpoch != widget.store.profileEpoch) return;
        if (value == 'remove') {
          await saveUserChange(
            context,
            () => widget.store.toggleFavorite(drama),
          );
        } else {
          final status = FollowStatus.values.firstWhere(
            (status) => status.name == value,
          );
          await saveUserChange(
            context,
            () => widget.store.setFollowStatus(drama, status),
          );
        }
        if (mounted && !_closed) setState(() {});
      },
      itemBuilder: (_) => [
        for (final status in FollowStatus.values)
          CheckedPopupMenuItem(
            value: status.name,
            checked: state?.status == status,
            child: Text(status.label),
          ),
        if (state != null)
          const CheckedPopupMenuItem(value: 'remove', child: Text('取消追剧')),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: state == null
              ? Theme.of(context).colorScheme.surfaceContainerHighest
              : Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              state == null
                  ? Icons.bookmark_add_outlined
                  : Icons.bookmark_rounded,
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(state?.label ?? '加入追剧'),
            const SizedBox(width: 2),
            const Icon(Icons.expand_more_rounded, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _episodePanel({bool compact = false, VoidCallback? onClose}) {
    final panel = ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: PlayerEpisodeGrid(
        episodes: widget.detail.episodes,
        currentIndex: _index,
        compact: compact,
        title: compact ? '剧集' : '选集',
        onSelected: (index) => _play(index, showControlsOnReady: false),
      ),
    );
    if (compact || onClose == null) return panel;
    return Stack(
      fit: StackFit.expand,
      children: [
        panel,
        Positioned(
          top: 2,
          right: 4,
          child: IconButton(
            tooltip: '关闭选集',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
          ),
        ),
      ],
    );
  }
}
