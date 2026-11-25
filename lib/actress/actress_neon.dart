import 'package:flutter/material.dart';

import '../neon/neon_ui.dart';

export '../neon/neon_ui.dart' show Neon;

/// 女优库模块霓虹样式（2026-11-21 用户令：照 whos-tv 霓虹版 HTML +
/// Neon 系统改，不另发明）。
///
/// 配色一律取 [Neon] 常量（底 #120B20、卡面 #191029、紫 #B14BFF、
/// 紫罗兰 #7B4BFF、粉 #FF4FA3、青 #33E1FF、字白、次字 #B4A5CE）。
/// NeonPill / NeonPoster / NeonCapsuleBar 等现成组件的颜色取当前
/// 主题 AppThemeConfig，换非霓虹主题时会变色、保不住令里给定的
/// 色值，所以这里直接取 Neon 常量、只复用它们的形制：选中态紫→
/// 青渐变 + 辉光（霓虹版 HTML .navbtn/.chip），卡片紫描边 + 外发
/// 光（.acard/.vcard），底部栏胶囊形制照 NeonCapsuleBar 的尺寸
/// （高 62、左右 14、安全区下 10、圆角 31）。
///
/// 只给女优库模块的新增/改动部分用（顶栏、导航钮、分类 chips、
/// 演员卡、视频卡、底部栏），不碰其它页。

/// 霓虹药丸钮（导航钮 / 分类 chips 同款）：未选中卡面底 + 紫罗兰
/// 描边 + 次字色；选中紫→青 135° 渐变 + 白字 + 紫青双辉光。
class ActressNeonPill extends StatelessWidget {
  const ActressNeonPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: compact ? 6 : 7,
        ),
        decoration: BoxDecoration(
          gradient: selected ? Neon.edgeGradient : null,
          color: selected ? null : Neon.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? Colors.transparent
                : Neon.violet.withValues(alpha: .8),
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Neon.purple.withValues(alpha: .45),
                    blurRadius: 18,
                    offset: const Offset(0, 5),
                  ),
                  BoxShadow(
                    color: Neon.cyan.withValues(alpha: .30),
                    blurRadius: 16,
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: compact ? 12.5 : 13.5,
            height: 1.0,
            fontWeight: FontWeight.w600,
            color: selected ? Neon.text : Neon.textDim,
          ),
        ),
      ),
    );
  }
}

/// 霓虹卡片描边（演员卡 / 视频卡同款）：卡面底 + 紫描边 + 外发光。
BoxDecoration actressNeonCardDecoration({double radius = 15}) {
  return BoxDecoration(
    color: Neon.surface,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: Neon.violet.withValues(alpha: .55)),
    boxShadow: [
      BoxShadow(
        color: Neon.purple.withValues(alpha: .18),
        blurRadius: 18,
      ),
    ],
  );
}

/// 霓虹顶栏（女优库模块三页同款）：深紫底 + 底边紫线 + 紫辉光。
AppBar actressNeonAppBar({
  required Widget? title,
  List<Widget>? actions,
  double? toolbarHeight,
}) {
  return AppBar(
    toolbarHeight: toolbarHeight,
    title: title,
    actions: actions,
    backgroundColor: Neon.bg,
    foregroundColor: Neon.text,
    surfaceTintColor: Colors.transparent,
    elevation: 4,
    shadowColor: Neon.purple.withValues(alpha: .22),
    shape: Border(
      bottom: BorderSide(color: Neon.purple.withValues(alpha: .45)),
    ),
  );
}

/// 女优库模块底部胶囊导航（模板 TABS：排行榜 / 帧探索 / 专题 /
/// 演员库 / 影片库）。形制照 NeonCapsuleBar（高 62、左右 14、圆
/// 角 31、安全区下 10），里面 5 个霓虹药丸钮；选中态紫→青渐变 +
/// 辉光。没有中间圆钮——模块里没有全屏流入口，不硬塞一个。
class ActressModuleTabBar extends StatelessWidget {
  const ActressModuleTabBar({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
  });

  /// 模板 TABS 的顺序与 key（与 whos-tv 模板 TABS 一一对应）。
  static const entries = <({String key, String label, IconData icon})>[
    (key: 'ranking', label: '排行榜', icon: Icons.emoji_events_outlined),
    (key: 'frames', label: '帧探索', icon: Icons.photo_library_outlined),
    (key: 'topics', label: '专题', icon: Icons.collections_outlined),
    (key: 'actresses', label: '演员库', icon: Icons.people_outline),
    (key: 'videos', label: '影片库', icon: Icons.movie_outlined),
  ];

  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: SafeArea(
        top: false,
        bottom: true,
        minimum: const EdgeInsets.only(bottom: 10),
        child: Container(
          height: 62,
          decoration: BoxDecoration(
            color: Neon.surface.withValues(alpha: .94),
            borderRadius: BorderRadius.circular(31),
            border: Border.all(color: Neon.violet.withValues(alpha: .5)),
            boxShadow: [
              BoxShadow(
                color: Neon.purple.withValues(alpha: .22),
                blurRadius: 26,
                spreadRadius: -6,
              ),
            ],
          ),
          child: Row(
            children: [
              for (var i = 0; i < entries.length; i++)
                Expanded(
                  child: _ModuleTabItem(
                    entry: entries[i],
                    selected: i == selectedIndex,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModuleTabItem extends StatelessWidget {
  const _ModuleTabItem({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final ({String key, String label, IconData icon}) entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: ValueKey('actress-module-tab-${entry.key}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (selected)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                gradient: Neon.edgeGradient,
                borderRadius: BorderRadius.circular(999),
                boxShadow: [
                  BoxShadow(
                    color: Neon.purple.withValues(alpha: .45),
                    blurRadius: 14,
                  ),
                  BoxShadow(
                    color: Neon.cyan.withValues(alpha: .28),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(entry.icon, size: 15, color: Neon.text),
                  const SizedBox(width: 3),
                  Text(
                    entry.label,
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.0,
                      fontWeight: FontWeight.w700,
                      color: Neon.text,
                    ),
                  ),
                ],
              ),
            )
          else
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(entry.icon, size: 19, color: Neon.textDim),
                const SizedBox(height: 3),
                Text(
                  entry.label,
                  style: const TextStyle(
                    fontSize: 9.5,
                    height: 1.0,
                    fontWeight: FontWeight.w500,
                    color: Neon.textDim,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 海报中央透明播放键（2026-11-25 女优库详情页/卡片墙修复）：
/// 与详情页 `_hero` 的 playButton 同款——半透明黑圆底 + 白圈 +
/// 白三角；纯装饰、不接手势，点按由外层海报/卡片的 InkWell 或
/// GestureDetector 接管（点海报/点卡即播，行为与原来一字不差）。
/// 大海报用 72/44（与 `_hero` 同尺寸），卡片墙用默认 48/30。
class ActressPosterPlayKey extends StatelessWidget {
  const ActressPosterPlayKey({
    super.key,
    this.diameter = 48,
    this.iconSize = 30,
  });

  final double diameter;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black.withValues(alpha: 0.3),
        border: Border.all(color: Colors.white70, width: 1.5),
      ),
      child: Icon(
        Icons.play_arrow_rounded,
        color: Colors.white,
        size: iconSize,
      ),
    );
  }
}
