import 'package:flutter/services.dart';

import 'audio_background.dart';

/// 锁屏媒体会话通道：把听书六项（书名/章节/封面/播放暂停/上下章/进度）
/// 交给原生侧 MediaSession + 媒体样式通知显示，并接回锁屏上的按键。
///
/// 原生侧不存在或调用失败时一律返回 false，调用方按“无锁屏控制”降级，
/// 播放本身不受影响。
class AudioMediaSession {
  static const MethodChannel _channel = MethodChannel('moyi/audio_media');
  static void Function(String action)? _actionHandler;
  static bool _handlerInstalled = false;

  /// 接锁屏按键：action 只会是 play / pause / previous / next。
  /// 传 null 表示不再接（详情页销毁时调用）。
  static void setActionHandler(void Function(String action)? handler) {
    _actionHandler = handler;
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler(_onCall);
  }

  static Future<void> _onCall(MethodCall call) async {
    if (call.method != 'mediaAction') return;
    final args = call.arguments;
    final action = args is Map ? args['action'] : null;
    if (action is String) _actionHandler?.call(action);
  }

  /// 发布/刷新锁屏界面（元数据 + 播放态 + 进度）。
  static Future<bool> publish(AudioLockscreenInfo info) async {
    try {
      return await _channel.invokeMethod<bool>(
            'publish',
            info.toChannelPayload(),
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 只刷新播放态与进度（元数据不变时用，省一次封面处理）。
  static Future<bool> updateState({
    required bool playing,
    required int positionMs,
    required int durationMs,
    required double rate,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('updateState', {
            'playing': playing,
            'positionMs': positionMs < 0 ? 0 : positionMs,
            'durationMs': durationMs < 0 ? 0 : durationMs,
            'rate': rate.isFinite ? rate.clamp(0.25, 4.0) : 1.0,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 撤掉锁屏界面与媒体会话。
  static Future<bool> release() async {
    try {
      return await _channel.invokeMethod<bool>('release') ?? false;
    } catch (_) {
      return false;
    }
  }
}
