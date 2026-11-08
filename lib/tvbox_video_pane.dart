import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

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
