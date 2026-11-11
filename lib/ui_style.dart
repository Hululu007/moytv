import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// 当前选中的视觉风格（对应设置里「外观主题」的 id，例如 neon / deep / candy）。
///
/// 主题样式由 LocalStore 持久化，MaterialApp 构建时会把它同步到这里，
/// 让深层组件（抽屉、内容区背景）也能判断要不要走霓虹视觉。
final themeStyleNotifier = ValueNotifier<String>('');

/// 霓虹暗夜风格是否生效。
bool get neonStyleActive => themeStyleNotifier.value == 'neon';
