import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 灵动岛胶囊通道：原生悬浮窗服务。
///
/// 服务在前台时先拉起（悬浮窗本体先藏着），切后台且在播时才显示胶囊，
/// 这样不依赖后台拉起服务（后台拉服务在新安卓上会被拦）。
/// 权限拿不到、服务拉不起、调用失败时一律返回 false，调用方降级为
/// 只留通知栏控制。悬浮窗在鸿蒙 NEXT + 卓易通容器里能不能显示，
/// 树里验不了，标未验、等手机实测。
class AudioCapsule {
  static const MethodChannel _channel = MethodChannel('moyi/audio_capsule');

  static Future<bool> isPermissionGranted() async {
    try {
      return await _channel.invokeMethod<bool>('isPermissionGranted') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 拉起胶囊服务（本体先藏着，不显示）。
  static Future<bool> ensureService() async {
    try {
      return await _channel.invokeMethod<bool>('ensureService') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 显示胶囊（书名 · 章节 + 播放状态点）。点胶囊回应用听书页。
  static Future<bool> show({
    required String title,
    required String chapter,
    required bool playing,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('show', {
            'title': title,
            'chapter': chapter,
            'playing': playing,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 藏起胶囊（服务还在，下次显示不用重拉）。
  static Future<bool> hide() async {
    try {
      return await _channel.invokeMethod<bool>('hide') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 停掉胶囊服务。
  static Future<bool> stop() async {
    try {
      return await _channel.invokeMethod<bool>('stop') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isShowing() async {
    try {
      return await _channel.invokeMethod<bool>('isShowing') ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// 悬浮窗授权“只主动跳一次”的持久标记。
///
/// 首次听书切后台且在播、权限未给时，控制器跳一次系统授权页并记下；
/// 之后无论用户给没给，都不再主动跳（拒绝后静默降级，只留通知栏控制）。
/// 用户事后在设置里手动点的“听书胶囊悬浮窗”入口不受此标记限制。
class AudioCapsulePermissionPrompt {
  static const _key = 'audio_capsule_overlay_prompted';

  static Future<bool> hasPrompted() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      return preferences.getBool(_key) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> markPrompted() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(_key, true);
    } catch (_) {}
  }
}
