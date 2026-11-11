import 'package:flutter/material.dart';

import 'app_page_route.dart';

import 'app_drawer.dart';
import 'content_source_screen.dart';
import 'core_bridge.dart';
import 'local_store.dart';
import 'parse_settings_screen.dart';
import 'player_picker.dart';
import 'settings_screen.dart';
import 'xigua/playback_settings_screen.dart';

class ZoneSettingsScreen extends StatelessWidget {
  const ZoneSettingsScreen({
    super.key,
    required this.repository,
    required this.store,
    required this.zone,
    this.onHideAdult,
  });

  final AppRepository repository;
  final LocalStore store;
  final HomeZone zone;
  final VoidCallback? onHideAdult;

  String get title => switch (zone) {
    HomeZone.drama => '短剧设置',
    HomeZone.vod => '点播设置',
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
      case HomeZone.drama:
      case HomeZone.vod:
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
    if (zone == HomeZone.drama ||
        zone == HomeZone.vod ||
        zone == HomeZone.live) {
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
    if (zone == HomeZone.vod) {
      entries.add(
        _entry(
          icon: Icons.link_rounded,
          label: '解析接口',
          subtitle: '播放解析接口列表与默认选中',
          onTap: () => _push(context, const ParseSettingsScreen()),
        ),
      );
    }
    if (zone == HomeZone.vod) {
      entries.add(
        _entry(
          icon: Icons.dns_rounded,
          label: '内容源管理',
          subtitle: 'TVBox 远程配置与 py 互斥切换',
          onTap: () => _push(
            context,
            ContentSourceScreen(repository: repository, store: store),
          ),
        ),
      );
    }
    // 点播区是合并后的唯一视频区，未成年保护开关跟到点播区设置里，
    // 语义与火蚁TV午夜区设置里的一致：一次性离开视频区、回到短剧区。
    if (zone == HomeZone.vod && onHideAdult != null) {
      entries.add(
        SwitchListTile(
          secondary: const Icon(Icons.shield_rounded),
          title: const Text('未成年保护'),
          subtitle: const Text('开启后隐藏成人站并回到短剧区'),
          value: false,
          onChanged: (value) {
            if (value) {
              onHideAdult!();
              Navigator.pop(context);
            }
          },
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
