import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'exo_subtitle.dart';
import 'models.dart';

class TvboxPlayerController {
  TvboxPlayerController._(this._channel);

  static const String viewType = 'moyi/tvboxplayer';
  static bool get supported => Platform.isAndroid;

  final MethodChannel _channel;
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _completedController = StreamController<void>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _cueGroupController = StreamController<ExoSubtitleGroup>.broadcast();
  bool _released = false;

  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration> get durationStream => _durationController.stream;
  Stream<bool> get playingStream => _playingController.stream;
  Stream<bool> get bufferingStream => _bufferingController.stream;
  Stream<void> get completedStream => _completedController.stream;
  Stream<String> get errorStream => _errorController.stream;
  Stream<ExoSubtitleGroup> get cueGroupStream => _cueGroupController.stream;

  static TvboxPlayerController attach(
    int viewId, {
    String viewType = viewType,
  }) {
    final channel = MethodChannel('$viewType/$viewId');
    final controller = TvboxPlayerController._(channel);
    channel.setMethodCallHandler(controller._handleEvent);
    return controller;
  }

  Future<void> _handleEvent(MethodCall call) async {
    switch (call.method) {
      case 'onPosition':
        _positionController.add(
          Duration(milliseconds: (call.arguments as num).toInt()),
        );
      case 'onDuration':
        _durationController.add(
          Duration(milliseconds: (call.arguments as num).toInt()),
        );
      case 'onPlaying':
        _playingController.add(call.arguments as bool);
      case 'onBuffering':
        _bufferingController.add(call.arguments as bool);
      case 'onCompleted':
        _completedController.add(null);
      case 'onError':
        _errorController.add(call.arguments as String? ?? '播放失败');
      case 'onCues':
        final group = ExoSubtitleGroup.fromChannelMap(call.arguments);
        if (group != null) _cueGroupController.add(group);
    }
  }

  Future<void> open({
    required String url,
    Map<String, String> headers = const {},
    int positionMs = 0,
    String decoderMode = 'optimized',
    PlaybackDrm? drm,
  }) {
    if (_released) return Future.value();
    return _channel.invokeMethod('open', {
      'url': url,
      'headers': headers,
      'positionMs': positionMs,
      'decoderMode': decoderMode,
      // DRM 信息（可空）：原生侧据此给 MediaItem 配
      // DrmConfiguration / ClearKey 本地会话；null 时与旧行为一致。
      'drm': drm?.toJson(),
    });
  }

  Future<void> play() {
    if (_released) return Future.value();
    return _channel.invokeMethod('play');
  }

  Future<void> pause() {
    if (_released) return Future.value();
    return _channel.invokeMethod('pause');
  }

  Future<void> seekTo(Duration position) {
    if (_released) return Future.value();
    return _channel.invokeMethod('seekTo', {
      'positionMs': position.inMilliseconds,
    });
  }

  Future<void> setSpeed(double speed) {
    if (_released) return Future.value();
    return _channel.invokeMethod('setSpeed', {'speed': speed});
  }

  Future<void> setDecoderMode(String mode) {
    if (_released) return Future.value();
    return _channel.invokeMethod('setDecoderMode', {'decoderMode': mode});
  }

  Future<void> stop() {
    if (_released) return Future.value();
    return _channel.invokeMethod('stop');
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _channel.invokeMethod('release');
    } catch (_) {}
    await _positionController.close();
    await _durationController.close();
    await _playingController.close();
    await _bufferingController.close();
    await _completedController.close();
    await _errorController.close();
    await _cueGroupController.close();
  }
}
