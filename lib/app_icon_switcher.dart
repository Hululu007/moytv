import 'dart:io';

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
  Future<bool> setIcon(String id) async {
    if (!appIconOptions.any((o) => o.id == id)) return false;
    if (!supported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('setIcon', {'id': id});
      if (ok != true) return false;
    } on PlatformException {
      return false;
    }
    final prefs = await _preferences();
    await prefs.setString(appIconSelectionKey, id);
    return true;
  }
}
