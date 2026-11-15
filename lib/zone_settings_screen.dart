import 'package:flutter/material.dart';

import 'app_page_route.dart';

import 'app_drawer.dart';
import 'core_bridge.dart';
import 'local_store.dart';
import 'player_picker.dart';
import 'settings_screen.dart';
import 'xigua/playback_settings_screen.dart';

class ZoneSettingsScreen extends StatelessWidget {
  const ZoneSettingsScreen({
    super.key,
    required this.repository,
    required this.store,
    required this.zone,
  });

  final AppRepository repository;
  final LocalStore store;
  final HomeZone zone;

  // 片库设置页已废弃（2026-11-14）：片库区直接进通用设置，不再打开本页；
  // library 分支仅为 switch 穷举保留，实际不可达。
  String get title => switch (zone) {
    HomeZone.library => '通用设置',
    HomeZone.live => '直播设置',
    HomeZone.audio => '听书设置',
    HomeZone.novel => '阅读设置',
  };

  Future<void> _push(BuildContext context, Widget page) =>
      Navigator.push(context, appPageRoute<void>(builder: (_) => page));

  Widget _entry({
    required IconData icon,
    required String label,
    required String subtitle,
    required VoidCallback onTap,
  }) => ListTile(
    leading: Icon(icon),
    title: Text(label),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: onTap,
  );

  Widget _generalEntry(BuildContext context) => _entry(
    icon: Icons.settings_outlined,
    label: '通用设置',
    subtitle: '外观、备份与全部设置项',
    onTap: () =>
        _push(context, SettingsScreen(repository: repository, store: store)),
  );

  @override
  Widget build(BuildContext context) {
    final entries = <Widget>[];
    switch (zone) {
      case HomeZone.library:
        break;
      case HomeZone.live:
        entries.add(
          _entry(
            icon: Icons.live_tv_rounded,
            label: '直播源',
            subtitle: '在直播区内切换',
            onTap: () => Navigator.pop(context),
          ),
        );
      case HomeZone.audio:
      case HomeZone.novel:
        break;
    }
    if (zone == HomeZone.live) {
      entries.add(
        _entry(
          icon: Icons.play_circle_rounded,
          label: '播放设置',
          subtitle: '倍速、弹幕、自动连播与画质偏好',
          onTap: () => _push(context, PlaybackSettingsScreen(store: store)),
        ),
      );
      entries.add(
        _entry(
          icon: Icons.smart_display_rounded,
          label: '播放器选择',
          subtitle: '切换播放器后端',
          onTap: () => _push(context, PlayerPickerScreen(store: store)),
        ),
      );
    }
    entries.add(_generalEntry(context));
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(children: entries),
    );
  }
}
