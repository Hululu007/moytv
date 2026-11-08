import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

enum _DragMode { none, seek, brightness }

class PlayerInteractions extends ChangeNotifier {
  static const double boostRate = 2;

  PlayerInteractions({
    required this.player,
    required this.available,
    required this.baseSpeed,
    required this.onTogglePlayback,
    required this.onFullscreen,
    required this.onEpisode,
    this.onSeek,
    this.onBrightness,
    this.currentBrightness,
  }) {
    _playing = player.stream.playing.listen((playing) {
      if (!playing) cancel();
    });
  }

  final Player player;
  final bool Function() available;
  final double Function() baseSpeed;
  final VoidCallback onTogglePlayback;
  final VoidCallback onFullscreen;
  final String Function(int direction) onEpisode;
  final Future<void> Function(Duration)? onSeek;
  final Future<void> Function(double value)? onBrightness;
  final double? Function()? currentBrightness;
  late final StreamSubscription<bool> _playing;
  Timer? _holdTimer;
  Timer? _hintTimer;
  Future<void> _rates = Future<void>.value();
  final Set<int> _pointers = {};
  int? _pointer;
  Offset? _origin;
  Offset? _lastPosition;
  Duration _started = Duration.zero;
  double _swipeThreshold = 70;
  bool _swipeEnabled = false;
  bool _dragEnabled = false;
  bool _moved = false;
  bool _held = false;
  bool _boosting = false;
  bool _keyboardHold = false;
  bool _cancelUntilRelease = false;
  bool _disposed = false;
  double _unmutedVolume = 100;
  String _feedback = '';
  bool _feedbackRevealsControls = false;
  DateTime _ignoreTapUntil = DateTime(2000);
  double _paneWidth = 0;
  double _paneHeight = 0;
  bool _originOnLeft = false;
  _DragMode _dragMode = _DragMode.none;
  Duration _seekAnchor = Duration.zero;
  Duration? _seekPreview;
  double _brightnessAnchor = .5;

  String get feedback => _feedback;
  bool get feedbackRevealsControls => _feedbackRevealsControls;
  bool get boosting => _boosting;
  bool get suppressTap => DateTime.now().isBefore(_ignoreTapUntil);
  Future<void> get pendingRates => _rates;

  void hint(
    String message, {
    bool persistent = false,
    bool revealControls = true,
  }) {
    if (_disposed) return;
    _hintTimer?.cancel();
    _feedbackRevealsControls = revealControls;
    if (_feedback != message) {
      _feedback = message;
      notifyListeners();
    }
    if (!persistent && message.isNotEmpty) {
      _hintTimer = Timer(const Duration(milliseconds: 1200), () {
        hint('', persistent: true);
      });
    }
  }

  Future<void> applySpeed() => _setRate(baseSpeed());

  Future<void> _setRate(double value) {
    _rates = _rates
        .catchError((Object _) {})
        .then((_) => player.setRate(value));
    unawaited(
      _rates.catchError((Object _) {
        hint('倍速调整失败，请重试');
      }),
    );
    return _rates;
  }

  void _beginHold({bool keyboard = false}) {
    if (!available() || _holdTimer != null || _boosting) return;
    _keyboardHold = keyboard;
    _holdTimer = Timer(const Duration(milliseconds: 350), () {
      _holdTimer = null;
      if (_disposed ||
          !available() ||
          !player.state.playing ||
          player.state.completed) {
        return;
      }
      _boosting = true;
      _held = true;
      unawaited(_setRate(boostRate));
      hint('');
      notifyListeners();
    });
  }

  void _endHold({bool tap = false}) {
    final wasKeyboard = _keyboardHold;
    final boosted = _boosting;
    _holdTimer?.cancel();
    _holdTimer = null;
    _keyboardHold = false;
    _boosting = false;
    if (boosted) {
      unawaited(_setRate(baseSpeed()));
      notifyListeners();
    } else if (tap && wasKeyboard) {
      seek(5);
    }
  }

  void cancel() {
    if (_disposed) return;
    if (_pointers.isNotEmpty) {
      _cancelUntilRelease = true;
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
    _pointer = null;
    _origin = null;
    _lastPosition = null;
    _dragMode = _DragMode.none;
    _seekPreview = null;
    _endHold();
    hint('');
  }

  void pointerDown(
    PointerDownEvent event, {
    required bool swipeEnabled,
    required double height,
    required double width,
  }) {
    _pointers.add(event.pointer);
    if (_pointers.length != 1 || _cancelUntilRelease) {
      cancel();
      return;
    }
    if (!available() || event.buttons != kPrimaryButton) return;
    _pointer = event.pointer;
    _origin = _lastPosition = event.localPosition;
    _started = event.timeStamp;
    _swipeEnabled = swipeEnabled && event.kind == PointerDeviceKind.touch;
    _dragEnabled =
        _swipeEnabled &&
        height >= 200 &&
        width >= 240 &&
        (onSeek != null || onBrightness != null);
    _paneWidth = width;
    _paneHeight = height;
    _originOnLeft = event.localPosition.dx < width / 2;
    _dragMode = _DragMode.none;
    _seekAnchor = player.state.position;
    _brightnessAnchor = (currentBrightness?.call() ?? .5).clamp(.01, 1.0);
    _swipeThreshold = math.max(56, math.min(100, height * .1));
    _moved = _held = false;
    _beginHold();
  }

  void pointerMove(PointerMoveEvent event) {
    if (_pointer != event.pointer || _origin == null) return;
    _lastPosition = event.localPosition;
    final delta = event.localPosition - _origin!;
    if (delta.distance > 12) {
      _moved = true;
      _endHold();
    }
    if (!_dragEnabled) return;
    if (_dragMode == _DragMode.none) {
      _maybeBeginDrag(delta, event.timeStamp - _started);
    }
    switch (_dragMode) {
      case _DragMode.seek:
        _updateSeekDrag(delta);
      case _DragMode.brightness:
        _updateBrightnessDrag(delta);
      case _DragMode.none:
        break;
    }
  }

  // 手势分层：水平拖动 = 进度快退/快进；左半屏"慢速"垂直拖动 = 系统亮度临时调整。
  // 亮度手势要求按住超过 260 毫秒才激活，快速竖直 flick 仍走原有的上下滑动切集；
  // 右半屏垂直手势完全不改动，保留切集行为。
  void _maybeBeginDrag(Offset delta, Duration elapsed) {
    if (!_moved || _dragMode != _DragMode.none) return;
    final horizontal =
        delta.dx.abs() > 24 && delta.dx.abs() > delta.dy.abs() * 1.2;
    final vertical =
        delta.dy.abs() > 24 && delta.dy.abs() > delta.dx.abs() * 1.2;
    if (horizontal && player.state.duration > Duration.zero) {
      _dragMode = _DragMode.seek;
      _seekAnchor = player.state.position;
      _clearHold();
      return;
    }
    if (vertical &&
        _originOnLeft &&
        onBrightness != null &&
        elapsed > const Duration(milliseconds: 260)) {
      _dragMode = _DragMode.brightness;
      _brightnessAnchor = (currentBrightness?.call() ?? .5).clamp(.01, 1.0);
      _clearHold();
    }
  }

  void _clearHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _keyboardHold = false;
    if (_boosting) {
      _boosting = false;
      unawaited(_setRate(baseSpeed()));
      notifyListeners();
    }
    _held = false;
  }

  // 全屏横向拖完一整屏 ≈ 进度全幅；短剧时长普遍 < 1 小时，按 min(时长, 45 分钟)
  // 缩放，保证小屏手机上能拖到位又不至于太灵敏。
  void _updateSeekDrag(Offset delta) {
    final duration = player.state.duration;
    if (duration <= Duration.zero || _paneWidth <= 0) return;
    final span = duration > const Duration(minutes: 45)
        ? const Duration(minutes: 45)
        : duration;
    final fraction = (delta.dx / _paneWidth).clamp(-1.0, 1.0);
    var target =
        _seekAnchor +
        Duration(microseconds: (span.inMicroseconds * fraction).round());
    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    _seekPreview = target;
    final shift = target - _seekAnchor;
    final sign = shift >= Duration.zero ? '+' : '-';
    hint(
      '${_formatPosition(target)} / ${_formatPosition(duration)}\n'
      '$sign${_formatDuration(shift.abs())}',
      persistent: true,
      revealControls: false,
    );
  }

  void _updateBrightnessDrag(Offset delta) {
    if (_paneHeight <= 0) return;
    final value = (_brightnessAnchor - delta.dy / _paneHeight).clamp(.01, 1.0);
    unawaited(onBrightness?.call(value));
    hint(
      '亮度 ${(value * 100).round()}%',
      persistent: true,
      revealControls: false,
    );
  }

  void pointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    if (_cancelUntilRelease) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
      if (_pointers.isEmpty) _cancelUntilRelease = false;
      return;
    }
    if (_pointer != event.pointer || _origin == null) return;
    final delta = (_lastPosition ?? event.localPosition) - _origin!;
    final mode = _dragMode;
    _pointer = null;
    _origin = null;
    _dragMode = _DragMode.none;
    _endHold();
    if (_moved || _held || mode != _DragMode.none) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
    if (mode == _DragMode.seek) {
      final target = _seekPreview;
      _seekPreview = null;
      hint('', persistent: true, revealControls: false);
      if (target != null && available()) {
        unawaited((onSeek ?? player.seek)(target).catchError((Object _) {}));
      }
      return;
    }
    if (mode == _DragMode.brightness) {
      hint('', persistent: true, revealControls: false);
      return;
    }
    final swipe =
        _swipeEnabled &&
        !_held &&
        _moved &&
        delta.dy.abs() >= _swipeThreshold &&
        delta.dy.abs() > delta.dx.abs() * 1.5 &&
        event.timeStamp - _started < const Duration(milliseconds: 1500);
    if (swipe && available()) {
      hint(onEpisode(delta.dy < 0 ? 1 : -1), revealControls: false);
    }
  }

  void pointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    cancel();
    _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    if (_pointers.isEmpty) _cancelUntilRelease = false;
  }

  void seek(int seconds) {
    if (!available() || player.state.duration <= Duration.zero) return;
    _endHold();
    final target = (player.state.position.inMilliseconds + seconds * 1000)
        .clamp(0, player.state.duration.inMilliseconds);
    unawaited((onSeek ?? player.seek)(Duration(milliseconds: target)));
    hint('', persistent: true, revealControls: false);
  }

  void changeVolume(double delta) {
    if (!available()) return;
    final volume = (player.state.volume + delta).clamp(0.0, 100.0);
    unawaited(player.setVolume(volume));
    if (volume > 0) _unmutedVolume = volume;
    hint(volume == 0 ? '已静音' : '音量 ${volume.round()}%');
  }

  void toggleMute() {
    if (!available()) return;
    final current = player.state.volume;
    if (current > 0) _unmutedVolume = current;
    final target = current > 0 ? 0.0 : _unmutedVolume;
    unawaited(player.setVolume(target));
    hint(target == 0 ? '已静音' : '音量 ${target.round()}%');
  }

  KeyEventResult key(KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      if (key == LogicalKeyboardKey.arrowRight && _keyboardHold) {
        _endHold(tap: available());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final hardware = HardwareKeyboard.instance;
    if (hardware.isAltPressed ||
        hardware.isMetaPressed ||
        hardware.isShiftPressed) {
      cancel();
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.f11 || key == LogicalKeyboardKey.keyF) {
      if (event is KeyDownEvent) {
        cancel();
        onFullscreen();
      }
      return KeyEventResult.handled;
    }
    if (hardware.isControlPressed || !available()) {
      return KeyEventResult.ignored;
    }
    if (key != LogicalKeyboardKey.arrowRight) _endHold();
    if (key == LogicalKeyboardKey.arrowRight) {
      if (event is KeyDownEvent) _beginHold(keyboard: true);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      seek(-5);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      changeVolume(5);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      changeVolume(-5);
    } else if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (event is KeyDownEvent) onTogglePlayback();
    } else if (key == LogicalKeyboardKey.keyM) {
      if (event is KeyDownEvent) toggleMute();
    } else if (key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      if (event is KeyDownEvent) {
        hint(
          onEpisode(key == LogicalKeyboardKey.mediaTrackNext ? 1 : -1),
          revealControls: false,
        );
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  static String _formatPosition(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    String two(int v) => v.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }

  static String _formatDuration(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds.remainder(60);
    return minutes > 0 ? '$minutes 分 $seconds 秒' : '$seconds 秒';
  }

  @override
  void dispose() {
    _disposed = true;
    _holdTimer?.cancel();
    _hintTimer?.cancel();
    if (_boosting) unawaited(_setRate(baseSpeed()));
    _boosting = false;
    _playing.cancel();
    _pointers.clear();
    super.dispose();
  }
}
