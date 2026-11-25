import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'home_zone.dart';
import 'neon_glass_kit.dart';

/// 听读页：底部“听读”标签的目的地，一页里能听又能看。
///
/// 顶部是听书/阅读/音乐三个子切换，下面只挂当前子区的屏（另一
/// 子区不建不取数）；听书播放是应用级单例，子区切换卸载区屏不
/// 影响正在播的书。内部区键（audio/novel）与数据一律不动，只合
/// 并显示与导航。
class ListenReadPage extends StatelessWidget {
  const ListenReadPage({
    super.key,
    required this.zone,
    required this.onZoneSelected,
    required this.zoneBuilder,
  });

  /// 当前子区：[HomeZone.audio] 听书或 [HomeZone.novel] 阅读。
  final HomeZone zone;

  /// 点子切换时回调，调用方切区（与底部标签同一条切区路径）。
  final ValueChanged<HomeZone> onZoneSelected;

  /// 按子区建屏：只建当前子区的屏。
  final Widget Function(HomeZone zone) zoneBuilder;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              NeonCapsule(
                key: const ValueKey('listenread-audio'),
                label: '听书',
                icon: LucideIcons.headphones,
                selected: zone == HomeZone.audio,
                onTap: () => onZoneSelected(HomeZone.audio),
              ),
              const SizedBox(width: 8),
              NeonCapsule(
                key: const ValueKey('listenread-novel'),
                label: '阅读',
                icon: LucideIcons.bookOpen,
                selected: zone == HomeZone.novel,
                onTap: () => onZoneSelected(HomeZone.novel),
              ),
              const SizedBox(width: 8),
              NeonCapsule(
                key: const ValueKey('listenread-music'),
                label: '音乐',
                icon: LucideIcons.music,
                selected: zone == HomeZone.music,
                onTap: () => onZoneSelected(HomeZone.music),
              ),
            ],
          ),
        ),
        Expanded(child: zoneBuilder(zone)),
      ],
    );
  }
}
