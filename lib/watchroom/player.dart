import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core_bridge.dart';
import '../local_store.dart';
import '../models.dart';
import '../playback_loader.dart';
import '../playback_preferences.dart';
import '../tvbox_video_pane.dart';
import '../widgets.dart';

class RoomPlayerHandle extends ChangeNotifier {
  Player? _player;
  VideoController? _videoController;
  final TvboxPlaybackHandle _tvboxHandle = TvboxPlaybackHandle();
  PlaybackLoader? _loader;
  PlaybackPlan? _plan;
  AppRepository? _repository;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final StreamController<double> _positionController =
      StreamController<double>.broadcast();
  Timer? _tvboxPollTimer;
  bool _subscribed = false;

  bool useTvbox = false;
  bool loading = false;
  String? error;
  String videoKey = '';
  double tvboxStartPosition = 0;
  VoidCallback? onCompleted;

  Stream<double> get positionStream => _positionController.stream;

  VideoController? get videoController => _videoController;

  TvboxPlaybackHandle get tvboxHandle => _tvboxHandle;

  PlaybackPlan? get plan => _plan;

  bool get playing =>
      useTvbox ? _tvboxHandle.playing : _player?.state.playing ?? false;

  double get position => useTvbox
      ? _tvboxHandle.positionSeconds
      : (_player?.state.position.inMilliseconds ?? 0) / 1000;

  double get duration => useTvbox
      ? _tvboxHandle.durationSeconds
      : (_player?.state.duration.inMilliseconds ?? 0) / 1000;

  bool get hasVideo => _plan != null && error == null;

  void _subscribePlayerStreams() {
    if (_subscribed || _player == null) return;
    _subscribed = true;
    final player = _player!;
    _subscriptions.addAll([
      player.stream.playing.listen((_) => notifyListeners()),
      player.stream.position.listen((value) {
        _positionController.add(value.inMilliseconds / 1000);
      }),
      player.stream.duration.listen((_) => notifyListeners()),
      player.stream.completed.listen((completed) {
        if (completed) onCompleted?.call();
      }),
      player.stream.error.listen((message) {
        error = message;
        notifyListeners();
      }),
    ]);
  }

  void _startTvboxPoll() {
    _tvboxPollTimer?.cancel();
    _tvboxPollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_positionController.isClosed) {
        _positionController.add(_tvboxHandle.positionSeconds);
      }
      notifyListeners();
    });
  }

  Future<void> open({
    required DramaDetail detail,
    required int episodeIndex,
    required double startPosition,
    required AppRepository repository,
    required LocalStore store,
    PlaybackPlan? preloadedPlan,
  }) async {
    await _closeCurrent();
    if (episodeIndex < 0 || episodeIndex >= detail.episodes.length) {
      error = '选集超出范围';
      notifyListeners();
      return;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      PlaybackPlan? plan = preloadedPlan;
      if (plan == null || plan.url.isEmpty) {
        final loader = PlaybackLoader(repository);
        _loader = loader;
        plan = await loader.load(
          detail.drama,
          detail.episodes[episodeIndex],
        );
      }
      if (plan == null || plan.url.isEmpty) {
        throw AppFailure('站源未返回播放地址，请重试');
      }
      _plan = plan;
      _repository = repository;
      final tvbox =
          Platform.isAndroid &&
          (store.player == 'tvbox') &&
          plan.decryptionKey.isEmpty;
      if (tvbox) {
        useTvbox = true;
        tvboxStartPosition = startPosition;
        _startTvboxPoll();
      } else {
        useTvbox = false;
        _player ??= Player(
          configuration: const PlayerConfiguration(
            bufferSize: 32 * 1024 * 1024,
            logLevel: MPVLogLevel.error,
          ),
        );
        _videoController ??= VideoController(
          _player!,
          configuration: const VideoControllerConfiguration(
            enableHardwareAcceleration: true,
          ),
        );
        _subscribePlayerStreams();
        final platform = _player!.platform;
        if (Platform.isAndroid &&
            platform is NativePlayer &&
            plan.decryptionKey.isNotEmpty) {
          await platform.setProperty(
            'demuxer-lavf-o',
            [
              'seg_max_retry=3',
              'strict=experimental',
              'allowed_extensions=ALL',
              'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
              'decryption_key=${plan.decryptionKey}',
            ].join(','),
          );
          await platform.setProperty('network-timeout', '20');
        }
        await _player!.open(
          Media(
            plan.url,
            httpHeaders: plan.headers,
            start: startPosition > 0
                ? Duration(milliseconds: (startPosition * 1000).round())
                : null,
          ),
          play: true,
        );
      }
      videoKey = '${detail.drama.id}|$episodeIndex';
      loading = false;
      notifyListeners();
    } catch (error) {
      this.error = error.toString();
      loading = false;
      notifyListeners();
    }
  }

  Future<void> play() async {
    if (useTvbox) {
      await _tvboxHandle.play();
    } else {
      await _player?.play();
    }
  }

  Future<void> pause() async {
    if (useTvbox) {
      await _tvboxHandle.pause();
    } else {
      await _player?.pause();
    }
  }

  Future<void> seek(double seconds) async {
    final target = Duration(milliseconds: (seconds * 1000).round());
    if (useTvbox) {
      await _tvboxHandle.seek(target);
    } else {
      await _player?.seek(target);
    }
  }

  Future<void> _closeCurrent() async {
    _tvboxPollTimer?.cancel();
    _tvboxPollTimer = null;
    final loader = _loader;
    _loader = null;
    final plan = _plan;
    _plan = null;
    try {
      await loader?.close();
    } catch (_) {}
    if (plan != null && plan.session.isNotEmpty) {
      try {
        await _repository?.release(plan.session);
      } catch (_) {}
    }
    try {
      await _player?.stop();
    } catch (_) {}
  }

  Future<void> close() async {
    await _closeCurrent();
    videoKey = '';
    loading = false;
    error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_closeCurrent());
    _tvboxPollTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    unawaited(_positionController.close());
    unawaited(_player?.dispose());
    _player = null;
    _videoController = null;
    super.dispose();
  }
}

class RoomPlayerView extends StatelessWidget {
  const RoomPlayerView({
    super.key,
    required this.handle,
    required this.viewType,
    required this.onCompleted,
    required this.onError,
    required this.onRetry,
    this.onFullscreen,
    this.isFullscreen = false,
  });

  final RoomPlayerHandle handle;
  final String viewType;
  final VoidCallback onCompleted;
  final ValueChanged<String> onError;
  final VoidCallback onRetry;
  final VoidCallback? onFullscreen;
  final bool isFullscreen;

  @override
  Widget build(BuildContext context) {
    handle.onCompleted = onCompleted;
    return ListenableBuilder(
      listenable: handle,
      builder: (context, _) {
        if (handle.loading) {
          return const ColoredBox(
            color: Colors.black,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (handle.error != null) {
          return ColoredBox(
            color: Colors.black,
            child: Center(
              child: StatusPanel(
                title: '播放失败',
                message: handle.error!,
                onRetry: onRetry,
              ),
            ),
          );
        }
        final plan = handle.plan;
        if (handle.useTvbox && plan != null) {
          return TvboxVideoPane(
            plan: plan,
            startPosition: handle.tvboxStartPosition,
            autoplay: true,
            decoderMode: TelevisionDecoder.optimized,
            handle: handle.tvboxHandle,
            onCompleted: onCompleted,
            onError: onError,
            viewType: viewType,
            onFullscreen: onFullscreen,
            isFullscreen: isFullscreen,
          );
        }
        final controller = handle.videoController;
        if (controller != null) {
          final video = Video(controller: controller, fit: BoxFit.contain);
          if (onFullscreen == null) return video;
          return Stack(
            fit: StackFit.expand,
            children: [
              video,
              Positioned(
                right: 8,
                bottom: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .36),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: IconButton(
                    key: const ValueKey('room-fullscreen'),
                    tooltip: isFullscreen ? '退出全屏' : '全屏',
                    icon: Icon(
                      isFullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      color: Colors.white,
                    ),
                    onPressed: onFullscreen,
                  ),
                ),
              ),
            ],
          );
        }
        return const ColoredBox(
          color: Colors.black,
          child: Center(
            child: Text('等待房主推送视频', style: TextStyle(color: Colors.white70)),
          ),
        );
      },
    );
  }
}
