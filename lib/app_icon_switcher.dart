import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内置备选应用图标（豆包生成的机械蚂蚁图，水印已裁，只留画面与“魔蚁XPTV”字样）。
class AppIconOption {
  const AppIconOption({
    required this.id,
    required this.name,
    required this.previewAsset,
    required this.aliasSuffix,
  });

  /// 图标 id：'default' 为安装自带的默认图标，其余对应一个 activity-alias。
  final String id;

  /// 显示名。
  final String name;

  /// 设置页预览图（assets 内图片）。
  final String previewAsset;

  /// AndroidManifest 里别名的类名后缀；默认图标为空（走主 Activity）。
  final String aliasSuffix;
}

const String appIconSelectionKey = 'app_icon_selection_v1';

/// 系统拒绝换图标的记忆标志。用户手机是鸿蒙 NEXT、应用跑卓易通容器，
/// 该容器已实证拒掉组件状态变更；拒绝记下来后，选择页改显横条、停掉
/// 反复点选（降级），而不是每次都让用户点一个注定失败的按钮。
const String appIconSwitchDeniedKey = 'app_icon_switch_denied_v1';

/// 切换失败的原因：桥侧把原生异常类名原样带回，按类名归类。
enum AppIconSwitchFailure {
  /// 系统拒绝了切换（SecurityException / 回读校验未通过）：桌面或
  /// 容器不允许改组件状态。
  denied,

  /// 当前桌面不支持固定快捷方式（pinShortcut 桥返回 false）。
  unsupported,

  /// 图标组件未找到（IllegalArgumentException）。
  missing,

  /// 其他原因（通道不可用、非法 id、桥返回非 true 等）。
  unknown,
}

/// 一次切换的结果：成功只认桥侧回读校验通过；失败带原因与原生详情
/// （异常类名，供界面提示与诊断）。
class AppIconSwitchResult {
  const AppIconSwitchResult({required this.ok, this.failure, this.detail});

  final bool ok;
  final AppIconSwitchFailure? failure;
  final String? detail;
}

const List<AppIconOption> appIconOptions = [
  AppIconOption(
    id: 'default',
    name: '默认',
    previewAsset: 'assets/ant_logo.png',
    aliasSuffix: '',
  ),
  AppIconOption(
    id: 'ant_flame',
    name: '烈焰',
    previewAsset: 'assets/app_icons/ant_flame.png',
    aliasSuffix: '.IconAntFlame',
  ),
  AppIconOption(
    id: 'ant_lens',
    name: '镜头',
    previewAsset: 'assets/app_icons/ant_lens.png',
    aliasSuffix: '.IconAntLens',
  ),
  AppIconOption(
    id: 'ant_win12',
    name: '蓝窗',
    previewAsset: 'assets/app_icons/ant_win12.png',
    aliasSuffix: '.IconAntWin12',
  ),
  AppIconOption(
    id: 'ant_storm',
    name: '风暴',
    previewAsset: 'assets/app_icons/ant_storm.png',
    aliasSuffix: '.IconAntStorm',
  ),
  AppIconOption(
    id: 'ant_meadow',
    name: '草原',
    previewAsset: 'assets/app_icons/ant_meadow.png',
    aliasSuffix: '.IconAntMeadow',
  ),
];

/// 应用图标切换：安卓走 moyi/icon_switch 通道（activity-alias 机制），
/// 其它平台不支持。当前选择同时记一份 SharedPreferences，供界面在通
/// 道不可用时显示上次选择；通道返回值才是系统侧的真实状态。
class AppIconSwitcher {
  const AppIconSwitcher({
    MethodChannel? channel,
    this.prefs,
    this.supportedOverride,
  }) : _channel = channel ?? const MethodChannel('moyi/icon_switch');

  final MethodChannel _channel;
  final SharedPreferences? prefs;
  final bool? supportedOverride;

  bool get supported => supportedOverride ?? Platform.isAndroid;

  Future<SharedPreferences> _preferences() async {
    final injected = prefs;
    if (injected != null) return injected;
    return SharedPreferences.getInstance();
  }

  Future<String> currentIconId() async {
    if (!supported) {
      final prefs = await _preferences();
      return prefs.getString(appIconSelectionKey) ?? 'default';
    }
    try {
      final id = await _channel.invokeMethod<String>('currentIcon');
      if (id != null && appIconOptions.any((o) => o.id == id)) return id;
    } on PlatformException {
      // 通道不可用时回落到存档，不谎报。
    }
    final prefs = await _preferences();
    return prefs.getString(appIconSelectionKey) ?? 'default';
  }

  /// 切图标。成功返回 true；平台不支持或桥侧失败返回 false。
  /// 切换失败时拒绝被记下（[appIconSwitchDeniedKey]），选择页据此降级；
  /// 切换成功清掉拒绝记忆。拒绝只记“系统不让换”这一种，其他失败
  /// （组件缺失、通道异常）不记，因为它们可能是临时问题。
  Future<AppIconSwitchResult> switchIcon(String id) async {
    if (!appIconOptions.any((o) => o.id == id)) {
      return const AppIconSwitchResult(
        ok: false,
        failure: AppIconSwitchFailure.unknown,
      );
    }
    if (!supported) {
      return const AppIconSwitchResult(
        ok: false,
        failure: AppIconSwitchFailure.unknown,
      );
    }
    try {
      final ok = await _channel.invokeMethod<bool>('setIcon', {'id': id});
      if (ok != true) {
        return const AppIconSwitchResult(
          ok: false,
          failure: AppIconSwitchFailure.unknown,
        );
      }
    } on PlatformException catch (e) {
      final detail = e.details?.toString();
      final failure = _failureFrom(e.code, detail, e.message);
      if (failure == AppIconSwitchFailure.denied) {
        final prefs = await _preferences();
        await prefs.setBool(appIconSwitchDeniedKey, true);
      }
      debugPrint(
        'AppIconSwitcher: switch $id failed code=${e.code} detail=$detail message=${e.message}',
      );
      return AppIconSwitchResult(
        ok: false,
        failure: failure,
        detail: detail ?? e.message,
      );
    } catch (_) {
      return const AppIconSwitchResult(
        ok: false,
        failure: AppIconSwitchFailure.unknown,
      );
    }
    final prefs = await _preferences();
    await prefs.setString(appIconSelectionKey, id);
    await prefs.remove(appIconSwitchDeniedKey);
    return const AppIconSwitchResult(ok: true);
  }

  /// 兼容旧调用：只关心成败。选择页已改走 [switchIcon]，失败要给
  /// 用户一句准话。
  Future<bool> setIcon(String id) async => (await switchIcon(id)).ok;

  /// 把选中图标以桌面快捷方式放出去：activity-alias 换图标在鸿蒙
  /// NEXT 的卓易通里不生效时的兜底（鸿蒙桌面不跟随容器内 alias 变化，
  /// App 侧逼不了它重读）。成功只表示系统受理了请求、会弹确认框，
  /// 用户点了确认快捷方式才落桌面；桌面不支持固定快捷方式时失败
  /// 原因是 [AppIconSwitchFailure.unsupported]。
  Future<AppIconSwitchResult> pinShortcut(String id) async {
    if (!appIconOptions.any((o) => o.id == id)) {
      return const AppIconSwitchResult(
        ok: false,
        failure: AppIconSwitchFailure.unknown,
      );
    }
    if (!supported) {
      return const AppIconSwitchResult(
        ok: false,
        failure: AppIconSwitchFailure.unknown,
      );
    }
    try {
      final ok = await _channel.invokeMethod<bool>('pinShortcut', {'id': id});
      if (ok != true) {
        return const AppIconSwitchResult(
          ok: false,
          failure: AppIconSwitchFailure.unsupported,
        );
      }
    } on PlatformException catch (e) {
      final detail = e.details?.toString();
      debugPrint(
        'AppIconSwitcher: pin $id failed code=${e.code} detail=$detail message=${e.message}',
      );
      return AppIconSwitchResult(
        ok: false,
        failure: AppIconSwitchFailure.unknown,
        detail: detail ?? e.message,
      );
    } catch (_) {
      return const AppIconSwitchResult(
        ok: false,
        failure: AppIconSwitchFailure.unknown,
      );
    }
    return const AppIconSwitchResult(ok: true);
  }

  /// 之前是否被系统拒绝过（见 [appIconSwitchDeniedKey]）。
  Future<bool> isSwitchDenied() async {
    final prefs = await _preferences();
    return prefs.getBool(appIconSwitchDeniedKey) ?? false;
  }

  /// 清掉拒绝记忆（选择页“再试一次”用；下一次点选会实打实再调桥）。
  Future<void> clearSwitchDenied() async {
    final prefs = await _preferences();
    await prefs.remove(appIconSwitchDeniedKey);
  }

  static AppIconSwitchFailure _failureFrom(
    String code,
    String? detail,
    String? message,
  ) {
    final text = '${detail ?? ''} ${message ?? ''}';
    if (text.contains('SecurityException')) {
      return AppIconSwitchFailure.denied;
    }
    if (text.contains('IllegalArgumentException')) {
      return AppIconSwitchFailure.missing;
    }
    if (text.contains('IllegalStateException') &&
        text.contains('not applied')) {
      // 桥回读校验未通过：系统静默忽略了组件状态变更，等于不让换。
      return AppIconSwitchFailure.denied;
    }
    return AppIconSwitchFailure.unknown;
  }
}
