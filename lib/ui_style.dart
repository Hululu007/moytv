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
