import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme_config.dart';

enum DramaUiStyle {
  ant;

  String get storageValue => 'ant';

  String get label => '蚂蚁';

  static DramaUiStyle fromStorageValue(String? value) => DramaUiStyle.ant;
}

const dramaUiStyleStorageKey = 'dramaUiStyle';

final dramaUiStyleNotifier = ValueNotifier<DramaUiStyle>(DramaUiStyle.ant);

bool _dramaUiStyleLoaded = false;

Future<void> ensureDramaUiStyleLoaded() async {
  if (_dramaUiStyleLoaded) return;
  final preferences = await SharedPreferences.getInstance();
  dramaUiStyleNotifier.value = DramaUiStyle.fromStorageValue(
    preferences.getString(dramaUiStyleStorageKey),
  );
  _dramaUiStyleLoaded = true;
}

/// 当前选中的全局主题（8 套之一）。
///
/// 主题由 LocalStore 持久化，MaterialApp 构建时会把它同步到这里，
/// 让深层组件（抽屉、内容区背景）也能判断要不要走霓虹视觉。
final appThemeNotifier = ValueNotifier<AppThemeMode>(
  AppThemeMode.purpleNeon,
);

/// 霓虹视觉是否生效：当前主题是紫蓝霓虹时生效，其余主题走各自配色。
bool get neonStyleActive =>
    appThemeNotifier.value == AppThemeMode.purpleNeon;
