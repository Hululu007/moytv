import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'exo_subtitle.dart';
import 'live_subtitle_engine.dart';
import 'live_subtitle_service.dart';
import 'live_subtitle_settings.dart';
import 'models.dart';
import 'playback_preferences.dart';
import 'tvbox_player_bridge.dart';

class TvboxPlaybackHandle {
  TvboxPlayerController? _controller;
  double speed = 1.0;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  bool completed = false;

  void attach(TvboxPlayerController controller) {
    _controller = controller;
  }

  void detach() {
    _controller = null;
  }

  Future<void> play() => _controller?.play() ?? Future.value();

  Future<void> pause() => _controller?.pause() ?? Future.value();

  Future<void> seek(Duration target) =>
      _controller?.seekTo(target) ?? Future.value();

  Future<void> setSpeed(double value) {
    speed = value;
    return _controller?.setSpeed(value) ?? Future.value();
  }

  double get positionSeconds => position.inMilliseconds / 1000;

  double get durationSeconds => duration.inMilliseconds / 1000;
}

class TvboxVideoPane extends StatefulWidget {
  const TvboxVideoPane({
    super.key,
    required this.plan,
    required this.startPosition,
    required this.autoplay,
    required this.decoderMode,
    required this.handle,
    required this.onCompleted,
    required this.onError,
    this.viewType = TvboxPlayerController.viewType,
    this.onBack,
    this.onFullscreen,
    this.isFullscreen = false,
  });

  final PlaybackPlan? plan;
  final double startPosition;
  final bool autoplay;
  final TelevisionDecoder decoderMode;
  final TvboxPlaybackHandle handle;
  final VoidCallback onCompleted;
  final ValueChanged<String> onError;
  final String viewType;
  final VoidCallback? onBack;
  final VoidCallback? onFullscreen;
  final bool isFullscreen;

  @override
  State<TvboxVideoPane> createState() => _TvboxVideoPaneState();
}

class _TvboxVideoPaneState extends State<TvboxVideoPane> {
  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  TvboxPlayerController? _controller;
  String? _openedSession;
  String? _openedUrl;
  bool _openedAutoplay = true;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _dragging = false;
  double _dragValue = 0;
  bool _buffering = false;
  final _subtitleBuffer = ExoSubtitleBuffer();
  List<String> _subtitleLines = const [];
  // 字幕偏移：树里没有现成的字幕偏移设置项，不虚构；0 即按 CueGroup
  // 时间轴自动对齐，偏移逻辑在 ExoSubtitleBuffer 里，入口待拍板。
  static const _subtitleOffsetMs = 0;

  // 实时字幕：与内嵌字幕共用同一个叠加层，有实时字幕时优先
  // 显示实时字幕，没有时回落到内嵌字幕，不另起一层叠画。
  LiveSubtitleSettings? _liveSettings;
  LiveSubtitleService? _liveSubtitle;
  final List<StreamSubscription<dynamic>> _liveSubscriptions = [];
  String _livePartial = '';

  @override
  void initState() {
    super.initState();
    unawaited(_loadLiveSubtitleSettings());
  }

  Future<void> _loadLiveSubtitleSettings() async {
    final settings = await LiveSubtitleSettings.load();
    if (mounted) setState(() => _liveSettings = settings);
  }

  @override
  void didUpdateWidget(TvboxVideoPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final plan = widget.plan;
    if (plan != null &&
        (plan.session != _openedSession ||
            plan.url != oldWidget.plan?.url) &&
        _controller != null) {
      _openedSession = plan.session;
      _openedUrl = plan.url;
      _openedAutoplay = widget.autoplay;
      unawaited(_open(plan, widget.startPosition));
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    unawaited(_stopLiveSubtitle());
    widget.handle.detach();
    unawaited(_controller?.release());
    _controller = null;
    super.dispose();
  }

  void _onViewCreated(int viewId) {
    final controller = TvboxPlayerController.attach(
      viewId,
      viewType: widget.viewType,
    );
    _controller = controller;
    widget.handle.attach(controller);
    _subscriptions.addAll([
      controller.positionStream.listen((position) {
        if (!mounted) return;
        widget.handle.position = position;
        _updateSubtitleLines();
        if (!_dragging) setState(() {});
      }),
      controller.durationStream.listen((duration) {
        if (!mounted) return;
        widget.handle.duration = duration;
        setState(() {});
      }),
      controller.playingStream.listen((playing) {
        if (!mounted) return;
        widget.handle.playing = playing;
        setState(() {});
      }),
      controller.bufferingStream.listen((buffering) {
        if (!mounted) return;
        _buffering = buffering;
        setState(() {});
      }),
      controller.completedStream.listen((_) {
        if (!mounted) return;
        widget.handle.completed = true;
        widget.onCompleted();
      }),
      controller.errorStream.listen((message) {
        if (!mounted) return;
        widget.onError(message);
      }),
      controller.cueGroupStream.listen((group) {
        if (!mounted) return;
        _subtitleBuffer.push(group);
        if (_updateSubtitleLines()) setState(() {});
      }),
    ]);
    final plan = widget.plan;
    if (plan != null) {
      final recreated =
          _openedSession == plan.session && _openedUrl == plan.url;
      final startPosition = recreated
          ? widget.handle.positionSeconds
          : widget.startPosition;
      _openedSession = plan.session;
      _openedUrl = plan.url;
      _openedAutoplay = recreated ? widget.handle.playing : widget.autoplay;
      unawaited(_open(plan, startPosition));
    }
  }

  Future<void> _open(PlaybackPlan plan, double startPosition) async {
    final controller = _controller;
    if (controller == null) return;
    widget.handle.completed = false;
    _subtitleBuffer.clear();
    _subtitleLines = const [];
    await _stopLiveSubtitle();
    await controller.open(
      url: plan.url,
      headers: plan.headers,
      positionMs: (startPosition * 1000).round(),
      decoderMode: widget.decoderMode.name,
    );
    await controller.setSpeed(widget.handle.speed);
    if (!_openedAutoplay) {
      await controller.pause();
    }
    await _startLiveSubtitle(plan, startPosition);
  }

  /// 实时字幕：只在总开关开着、平台支持、源不是播放器侧内存
  /// 密钥解密时才启动（内存密钥解密的源后台取不到音轨）。
  Future<void> _startLiveSubtitle(PlaybackPlan plan, double startPosition) async {
    final settings = _liveSettings;
    if (settings == null || !settings.enabled) return;
    if (!liveSubtitleEngineSupported) return;
    if (plan.decryptionKey.isNotEmpty) return;
    final service = LiveSubtitleService(settings: settings);
    _liveSubtitle = service;
    _liveSubscriptions.add(
      service.cueStream.listen((_) {
        if (mounted) _updateSubtitleLines();
      }),
    );
    _liveSubscriptions.add(
      service.partialStream.listen((partial) {
        if (!mounted) return;
        _livePartial = partial;
        _updateSubtitleLines();
      }),
    );
    await service.start(
      url: plan.url,
      headers: plan.headers,
      startPosition: Duration(milliseconds: (startPosition * 1000).round()),
    );
  }

  Future<void> _stopLiveSubtitle() async {
    for (final subscription in _liveSubscriptions) {
      await subscription.cancel();
    }
    _liveSubscriptions.clear();
    final service = _liveSubtitle;
    _liveSubtitle = null;
    if (service != null) await service.dispose();
    _livePartial = '';
  }

  /// 取当前播放进度对应的实时字幕行；没有则返回空，回落内嵌字幕。
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

  /// 按当前位置刷新应显示的字幕行；行内容变化时返回 true。
  /// 位置 tick 与 cue 到达两路都走这里，偏移只影响取组不影响 tick。
  /// 有实时字幕时优先显示实时行，否则回落到内嵌字幕。
  bool _updateSubtitleLines() {
    final liveLines = _liveLinesAt(widget.handle.position);
    final lines = liveLines.isNotEmpty
        ? liveLines
        : layoutExoSubtitleLines(
            _subtitleBuffer.activeCuesAt(
              widget.handle.position.inMilliseconds,
              offsetMs: _subtitleOffsetMs,
            ),
          );
    if (lines.length == _subtitleLines.length) {
      var same = true;
      for (var i = 0; i < lines.length; i++) {
        if (lines[i] != _subtitleLines[i]) {
          same = false;
          break;
        }
      }
      if (same) return false;
    }
    _subtitleLines = lines;
    return true;
  }

  String _formatTime(Duration value) {
    final total = value.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      return const ColoredBox(color: Colors.black);
    }
    final position = widget.handle.position;
    final duration = widget.handle.duration;
    final maxMs = duration.inMilliseconds.toDouble();
    final sliderValue = maxMs > 0
        ? (_dragging
              ? _dragValue
              : position.inMilliseconds.toDouble().clamp(0, maxMs).toDouble())
        : 0.0;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: AndroidView(
            viewType: widget.viewType,
            onPlatformViewCreated: _onViewCreated,
          ),
        ),
        // Exo 字幕只画这一层：原生 SubtitleView 已在 Kotlin 侧隐藏。
        // 放控制条之下，底边距盖过控制条，字幕不被控制条遮住。
        Positioned.fill(
          child: ExoSubtitleOverlay(lines: _subtitleLines),
        ),
        if (_buffering)
          const Center(
            child: SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black54, Colors.transparent],
              ),
            ),
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: Row(
              children: [
                if (widget.onBack != null)
                  IconButton(
                    key: const ValueKey('tvbox-back'),
                    tooltip: '返回',
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      color: Colors.white,
                    ),
                    onPressed: widget.onBack,
                  ),
                IconButton(
                  icon: Icon(
                    widget.handle.playing ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    if (widget.handle.playing) {
                      unawaited(widget.handle.pause());
                    } else {
                      unawaited(widget.handle.play());
                    }
                  },
                ),
                Text(
                  _formatTime(position),
                  style: const TextStyle(color: Colors.white),
                ),
                Expanded(
                  child: Slider(
                    value: sliderValue,
                    max: maxMs > 0 ? maxMs : 1,
                    onChangeStart: (_) => setState(() => _dragging = true),
                    onChanged: (value) => setState(() => _dragValue = value),
                    onChangeEnd: (value) {
                      setState(() => _dragging = false);
                      unawaited(
                        widget.handle.seek(
                          Duration(milliseconds: value.round()),
                        ),
                      );
                      // 拖进度条后重新锚一次实时字幕时间轴。
                      _liveSubtitle?.reanchor(
                        Duration(milliseconds: value.round()),
                      );
                    },
                  ),
                ),
                Text(
                  _formatTime(duration),
                  style: const TextStyle(color: Colors.white),
                ),
                PopupMenuButton<double>(
                  icon: Text(
                    '${widget.handle.speed}x',
                    style: const TextStyle(color: Colors.white),
                  ),
                  onSelected: (speed) {
                    setState(() {});
                    unawaited(widget.handle.setSpeed(speed));
                  },
                  itemBuilder: (context) => _speeds
                      .map(
                        (speed) => PopupMenuItem<double>(
                          value: speed,
                          child: Text('${speed}x'),
                        ),
                      )
                      .toList(),
                ),
                if (widget.onFullscreen != null)
                  IconButton(
                    key: const ValueKey('tvbox-fullscreen'),
                    tooltip: widget.isFullscreen ? '退出全屏' : '全屏',
                    icon: Icon(
                      widget.isFullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      color: Colors.white,
                    ),
                    onPressed: widget.onFullscreen,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
