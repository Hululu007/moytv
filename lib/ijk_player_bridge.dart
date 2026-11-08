import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class IjkPlayerController {
  IjkPlayerController._(this._channel);

  static const String viewType = 'moyi/ijkplayer';
  static bool get supported => Platform.isAndroid;

  final MethodChannel _channel;
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _completedController = StreamController<void>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  bool _released = false;

  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration> get durationStream => _durationController.stream;
  Stream<bool> get playingStream => _playingController.stream;
  Stream<bool> get bufferingStream => _bufferingController.stream;
  Stream<void> get completedStream => _completedController.stream;
  Stream<String> get errorStream => _errorController.stream;

  static IjkPlayerController attach(int viewId) {
    final channel = MethodChannel('$viewType/$viewId');
    final controller = IjkPlayerController._(channel);
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
    }
  }

  Future<void> open({
    required String url,
    Map<String, String> headers = const {},
    int positionMs = 0,
  }) {
    if (_released) return Future.value();
    return _channel.invokeMethod('open', {
      'url': url,
      'headers': headers,
      'positionMs': positionMs,
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
  }
}
