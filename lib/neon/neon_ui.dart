import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_theme_config.dart';

/// 霓虹（Neon / 赛博）视觉系统：深紫黑底 + 紫粉青渐变 + 发光描边。
///
/// 这一套是纯展示层，只提供配色与装饰组件，不持有任何业务状态。
/// 首页（潮影式主推流）与频道页（左侧分类 + 媒体墙）共用，
/// 保证两页的颜色、圆角、描边、字重完全一致。
abstract final class Neon {
  // 背景（对参考图取样：顶部蓝紫、左中洋红、右侧青色、底部偏冷中性）
  static const bg = Color(0xFF120B20);
  static const bgDeep = Color(0xFF0B0617);
  static const surface = Color(0xFF191029);
  static const surfaceHigh = Color(0xFF22143A);
  static const surfaceGlass = Color(0xFF1B1030);

  // 主色
  static const purple = Color(0xFFB14BFF);
  static const violet = Color(0xFF7B4BFF);
  static const pink = Color(0xFFFF4FA3);
  static const magenta = Color(0xFFA021A8);
  static const cyan = Color(0xFF33E1FF);
  static const blue = Color(0xFF5B8CFF);

  /// 参考图里右侧那种偏深的青蓝（不是纯亮青）。
  static const teal = Color(0xFF10A9CD);

  // 文字
  static const text = Color(0xFFFFFFFF);
  static const textDim = Color(0xFFB4A5CE);
  static const textFaint = Color(0xFF7E6E9C);

  // 渐变
  static const edgeGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [purple, cyan],
  );
  static const hotGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFFFF5FC8), Color(0xFF8A5BFF)],
  );
  static const cyanGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF39F0FF), Color(0xFF3E8BFF)],
  );
  static const pageGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0, .45, 1],
    colors: [Color(0xFF1B0F32), Color(0xFF100A1E), Color(0xFF141622)],
  );

  static Color glow(Color color, double alpha) =>
      color.withValues(alpha: alpha);

  static BoxShadow bloom(Color color, {double blur = 22, double spread = 0}) =>
      BoxShadow(
        color: glow(color, .45),
        blurRadius: blur,
        spreadRadius: spread,
      );

  static const titleStyle = TextStyle(
    color: text,
    fontSize: 15,
    fontWeight: FontWeight.w900,
    height: 1.1,
    letterSpacing: .2,
  );

  static const brandStyle = TextStyle(
    color: text,
    fontSize: 21,
    fontWeight: FontWeight.w900,
    height: 1.0,
    letterSpacing: 1.4,
  );
}

/// 整页背景：深紫底 + 多光源氛围（左中洋红、右侧青蓝、顶部蓝紫）。
///
/// 光晕位置与浓度按参考截图取样还原：左侧亮度峰值在屏幕高度 40% 附近，
/// 右侧青蓝在 30%~60% 区间，顶部正中偏蓝紫。
class NeonBackdrop extends StatelessWidget {
  const NeonBackdrop({
    super.key,
    this.child,
    this.intensity = 1,
    this.magentaY = .40,
    this.tealY = .40,
    this.topGlow = .26,
    this.rightGlowColor = Neon.teal,
    this.rightGlowAlpha = 1,
  });

  /// 全 App 统一的氛围光背景：抽屉与点播区 / 内容区共用这一份定义。
  ///
  /// 参数取点播区那套（.52/.46/.42/.2）；改这里一处，两处一起变，
  /// 不要在各处再写一份硬编码参数。
  const NeonBackdrop.app({super.key, this.child})
    : intensity = .52,
      magentaY = .46,
      tealY = .42,
      topGlow = .2,
      rightGlowColor = Neon.teal,
      rightGlowAlpha = 1;

  final Widget? child;

  /// 光晕浓度倍率，1 = 首页参考图浓度。
  final double intensity;

  /// 左中洋红主光的垂直中心（屏幕高度占比）。
  final double magentaY;

  /// 右侧青蓝光的垂直中心。
  final double tealY;

  /// 顶部蓝紫光的浓度。
  final double topGlow;

  /// 右侧光晕颜色/浓度（首页是青色，频道页是弱蓝紫）。
  final Color rightGlowColor;
  final double rightGlowAlpha;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final w = size.width;
    final h = size.height;
    final magentaSize = w * 1.75;
    final tealSize = w * 1.60;
    final blueSize = w * 1.10;
    final purpleSize = w * .85;
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: Neon.pageGradient),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: -w * .875,
            top: h * magentaY - magentaSize / 2,
            child: _Halo(
              color: Neon.magenta,
              size: magentaSize,
              alpha: 1 * intensity,
            ),
          ),
          Positioned(
            right: -w * .80,
            top: h * tealY - tealSize / 2,
            child: _Halo(
              color: rightGlowColor,
              size: tealSize,
              alpha: rightGlowAlpha * intensity,
            ),
          ),
          Positioned(
            left: w * .05,
            top: -h * .26,
            child: _Halo(
              color: Neon.blue,
              size: blueSize,
              alpha: topGlow * intensity,
            ),
          ),
          Positioned(
            left: w * .34,
            top: -h * .32,
            child: _Halo(
              color: Neon.purple,
              size: purpleSize,
              alpha: .24 * intensity,
            ),
          ),
          if (child != null) child!,
        ],
      ),
    );
  }
}

class _Halo extends StatelessWidget {
  const _Halo({required this.color, required this.size, this.alpha = .30});

  final Color color;
  final double size;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            stops: const [0, .45, 1],
            colors: [
              color.withValues(alpha: alpha),
              color.withValues(alpha: alpha * .55),
              color.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

/// 渐变发光描边容器。内层保持纯色/图片，外层用渐变描边 + 外发光。
class NeonFrame extends StatelessWidget {
  const NeonFrame({
    super.key,
    required this.child,
    this.radius = 20,
    this.thickness = 1.4,
    this.gradient = Neon.edgeGradient,
    this.glow = true,
    this.color,
  });

  final Widget child;
  final double radius;
  final double thickness;
  final Gradient gradient;
  final bool glow;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final br = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: br,
        gradient: gradient,
        boxShadow: glow
            ? [
                BoxShadow(
                  color: (color ?? Neon.purple).withValues(alpha: .35),
                  blurRadius: 18,
                  spreadRadius: -2,
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: EdgeInsets.all(thickness),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius - thickness),
          child: child,
        ),
      ),
    );
  }
}

/// 玻璃卡片（分组容器）。
class NeonGlass extends StatelessWidget {
  const NeonGlass({
    super.key,
    required this.child,
    this.radius = 22,
    this.padding = const EdgeInsets.all(14),
    this.borderColor,
  });

  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Neon.surfaceGlass.withValues(alpha: .78),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: (borderColor ?? Neon.purple).withValues(alpha: .35),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: (borderColor ?? Neon.purple).withValues(alpha: .14),
            blurRadius: 24,
            spreadRadius: -6,
          ),
        ],
      ),
      child: child,
    );
  }
}

/// 胶囊标签（筛选/分类通用）。选中态：青色渐变实心 + 深色字。
class NeonPill extends StatelessWidget {
  const NeonPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.dense = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(dense ? 9 : 18);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 9 : 14,
          vertical: dense ? 4 : 7,
        ),
        decoration: BoxDecoration(
          gradient: selected ? Neon.cyanGradient : null,
          color: selected ? null : Neon.surfaceHigh.withValues(alpha: .85),
          borderRadius: radius,
          border: Border.all(
            color: selected
                ? Colors.transparent
                : Colors.white.withValues(alpha: .10),
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Neon.cyan.withValues(alpha: .40),
                    blurRadius: 16,
                    spreadRadius: -3,
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[icon!, SizedBox(width: dense ? 4 : 6)],
            Text(
              label,
              style: TextStyle(
                fontSize: dense ? 10.5 : 12,
                height: 1.0,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected ? const Color(0xFF04141C) : Neon.textDim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 主行动按钮：粉紫渐变胶囊 + 外发光（参考图里的「马上看」）。
class NeonActionButton extends StatelessWidget {
  const NeonActionButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon = LucideIcons.play,
    this.height = 40,
  });

  final String label;
  final VoidCallback onTap;
  final IconData icon;
  final double height;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          gradient: Neon.hotGradient,
          borderRadius: BorderRadius.circular(height / 2),
          boxShadow: [
            BoxShadow(
              color: Neon.pink.withValues(alpha: .45),
              blurRadius: 20,
              spreadRadius: -2,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: Colors.white),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                height: 1.0,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: .5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分组标题（左粗体标题 + 可选右侧「更多」）。
class NeonSectionHeader extends StatelessWidget {
  const NeonSectionHeader({
    super.key,
    required this.title,
    this.action,
    this.onAction,
  });

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 14, 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 15,
            decoration: BoxDecoration(
              gradient: Neon.edgeGradient,
              borderRadius: BorderRadius.circular(2),
              boxShadow: [Neon.bloom(Neon.purple, blur: 10)],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: Neon.titleStyle.copyWith(color: config.textPrimary),
          ),
          const Spacer(),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              child: Row(
                children: [
                  Text(
                    action!,
                    style: TextStyle(fontSize: 11, color: config.textSecondary),
                  ),
                  Icon(
                    LucideIcons.chevronRight,
                    size: 14,
                    color: config.textSecondary,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 角标：HD / NEW 等，右上角。
class NeonBadge extends StatelessWidget {
  const NeonBadge({super.key, required this.label, this.color = Neon.cyan});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: .55),
            blurRadius: 10,
            spreadRadius: -2,
          ),
        ],
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 9,
          height: 1.0,
          fontWeight: FontWeight.w900,
          color: Color(0xFF04141C),
          letterSpacing: .4,
        ),
      ),
    );
  }
}

/// 顶部品牌栏：品牌名 + 右侧圆形图标按钮。
class NeonTopBar extends StatelessWidget {
  const NeonTopBar({
    super.key,
    required this.brand,
    required this.actions,
    this.subtitle,
    this.leading,
  });

  final String brand;
  final String? subtitle;
  final List<Widget> actions;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 12, 2),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 10)],
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ShaderMask(
                shaderCallback: (rect) => LinearGradient(
                  colors: [config.textPrimary, config.secondaryColor],
                ).createShader(rect),
                child: Text(
                  brand,
                  style: Neon.brandStyle.copyWith(color: config.textPrimary),
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  style: TextStyle(fontSize: 10, color: config.textSecondary),
                ),
              ],
            ],
          ),
          const Spacer(),
          for (final action in actions) ...[action, const SizedBox(width: 8)],
        ],
      ),
    );
  }
}

/// 圆形图标按钮（顶栏/频道页头部用）。
class NeonIconButton extends StatelessWidget {
  const NeonIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = 36,
    this.tooltip,
    this.highlight = false,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final String? tooltip;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: highlight ? null : Colors.white.withValues(alpha: .07),
          gradient: highlight ? Neon.hotGradient : null,
          border: Border.all(color: Colors.white.withValues(alpha: .10)),
          boxShadow: highlight
              ? [
                  BoxShadow(
                    color: Neon.pink.withValues(alpha: .40),
                    blurRadius: 16,
                    spreadRadius: -3,
                  ),
                ]
              : null,
        ),
        child: Icon(icon, size: size * .48, color: Colors.white),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// 底部浮动胶囊导航（首页 / 频道 / ＋ / 多媒体 / 我的）。
class NeonBottomBar extends StatelessWidget {
  const NeonBottomBar({
    super.key,
    required this.index,
    required this.onSelect,
    required this.onCenter,
  });

  /// 0=首页 1=频道 2=多媒体 3=我的（中间按钮单独处理）
  final int index;
  final ValueChanged<int> onSelect;
  final VoidCallback onCenter;

  @override
  Widget build(BuildContext context) {
    const entries = <(int, Object, String)>[
      (0, LucideIcons.house, '首页'),
      (1, '🎞️', '频道'),
      (2, LucideIcons.hardDrive, '多媒体'),
      (3, LucideIcons.user, '我的'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: Container(
        height: 62,
        decoration: BoxDecoration(
          color: const Color(0xFF1D1632).withValues(alpha: .94),
          borderRadius: BorderRadius.circular(31),
          border: Border.all(color: Colors.white.withValues(alpha: .08)),
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
            _item(entries[0]),
            _item(entries[1]),
            Expanded(child: _center()),
            _item(entries[2]),
            _item(entries[3]),
          ],
        ),
      ),
    );
  }

  Widget _item((int, Object, String) entry) {
    final selected = index == entry.$1;
    final glyph = entry.$2;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onSelect(entry.$1),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 频道页签用 🎞️ emoji 字符直接显示，其余页签用 Lucide 图标；
            // emoji 自带彩色，选中态只靠下方文字着色与加粗区分。
            if (glyph is String)
              Text(glyph, style: const TextStyle(fontSize: 19, height: 1.0))
            else
              Icon(
                glyph as IconData,
                size: 19,
                color: selected ? Neon.pink : const Color(0xFF8A7AA8),
              ),
            const SizedBox(height: 3),
            Text(
              entry.$3,
              style: TextStyle(
                fontSize: 9.5,
                height: 1.0,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? Neon.pink : const Color(0xFF8A7AA8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _center() {
    return Center(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onCenter,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: Neon.hotGradient,
            boxShadow: [
              BoxShadow(
                color: Neon.pink.withValues(alpha: .55),
                blurRadius: 20,
                spreadRadius: -2,
              ),
              BoxShadow(
                color: Neon.purple.withValues(alpha: .45),
                blurRadius: 28,
                spreadRadius: -6,
              ),
            ],
          ),
          // 中间按钮：播放三角图标，白色与渐变圆钮的霓虹主题一致；
          // 点按行为不变，仍是 onCenter（进全屏推荐流）。
          child: const Icon(LucideIcons.play, size: 24, color: Colors.white),
        ),
      ),
    );
  }
}

/// 图片圆角卡片壳：封面 + 底部渐变字幕条 + 角标。
class NeonPoster extends StatelessWidget {
  const NeonPoster({
    super.key,
    required this.cover,
    required this.title,
    this.radius = 16,
    this.badge,
    this.badgeColor = Neon.cyan,
    this.subtitle,
    this.onTap,
    this.onLongPress,
    this.showTitle = true,
    this.titleSize = 11.5,
  });

  final Widget cover;
  final String title;
  final double radius;
  final String? badge;
  final Color badgeColor;
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showTitle;
  final double titleSize;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: NeonFrame(
        radius: radius,
        thickness: 1.2,
        glow: false,
        child: Stack(
          fit: StackFit.expand,
          children: [
            cover,
            if (badge != null)
              Positioned(
                top: 6,
                right: 6,
                child: NeonBadge(label: badge!, color: badgeColor),
              ),
            if (showTitle)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 18, 8, 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: .82),
                      ],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: titleSize,
                          height: 1.1,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 9,
                            height: 1.1,
                            color: Color(0xFFC9B9E6),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 把任意封面 widget 变成「有内容就有图」的壳；无封面时给霓虹占位。
class NeonCoverSlot extends StatelessWidget {
  const NeonCoverSlot({super.key, required this.child, this.radius = 16});

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: child);
  }
}

/// 一条从底部升起的柔光，用于页面顶部/卡片下方提亮。
class NeonGlowLine extends StatelessWidget {
  const NeonGlowLine({super.key, this.color = Neon.purple, this.height = 1.2});

  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: .75),
            color.withValues(alpha: 0),
          ],
        ),
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: .35), blurRadius: 12),
        ],
      ),
    );
  }
}

/// 圆角水平进度/热度条（参考图标签下的细条）。
class NeonMeter extends StatelessWidget {
  const NeonMeter({super.key, required this.value, this.width = 42});

  final double value;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 3,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(2),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: value.clamp(0, 1),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: Neon.edgeGradient,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// 给任意子项加轻微透视倾斜（轮播两侧卡用）。
class NeonTilt extends StatelessWidget {
  const NeonTilt({
    super.key,
    required this.child,
    this.angle = 0,
    this.scale = 1,
  });

  final Widget child;
  final double angle;
  final double scale;

  @override
  Widget build(BuildContext context) {
    if (angle == 0) return child;
    final matrix = Matrix4.identity()
      ..setEntry(3, 2, .0012)
      ..rotateY(angle);
    return Transform(
      alignment: Alignment.center,
      transform: matrix,
      child: Transform.scale(scale: scale, child: child),
    );
  }
}

/// 静态噪声/颗粒叠层，避免大面积纯色发闷（可选）。
class NeonGrain extends StatelessWidget {
  const NeonGrain({super.key, this.opacity = .035});

  final double opacity;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(child: CustomPaint(painter: _GrainPainter(opacity)));
  }
}

class _GrainPainter extends CustomPainter {
  const _GrainPainter(this.opacity);
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: opacity);
    final random = math.Random(7);
    final count = (size.width * size.height / 900).clamp(80, 900).toInt();
    for (var i = 0; i < count; i++) {
      canvas.drawCircle(
        Offset(
          random.nextDouble() * size.width,
          random.nextDouble() * size.height,
        ),
        random.nextDouble() * .8 + .2,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GrainPainter oldDelegate) =>
      oldDelegate.opacity != opacity;
}

/// 参考图里卡片下方的柔光投影（用于轮播中心卡）。
BoxShadow neonDropShadow() => BoxShadow(
  color: Neon.purple.withValues(alpha: .38),
  blurRadius: 28,
  spreadRadius: -4,
  offset: const Offset(0, 10),
);

/// 供外部（主题/抽屉）复用的材质色。
MaterialColor neonSwatch() {
  const colors = <int, Color>{
    50: Color(0xFFF2E6FF),
    100: Color(0xFFE3CCFF),
    200: Color(0xFFCDA3FF),
    300: Color(0xFFB877FF),
    400: Color(0xFFA85CFF),
    500: Neon.purple,
    600: Color(0xFF9929F0),
    700: Color(0xFF7D1CC9),
    800: Color(0xFF5D1495),
    900: Color(0xFF3D0B63),
  };
  return MaterialColor(Neon.purple.toARGB32(), colors);
}

/// 把 0~1 的进度映射成青色→紫色（用于封面占位渐变）。
Gradient neonCoverFallback() => const LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF2A1548), Color(0xFF120A22)],
);

Color neonBorderTint(double t) => Color.lerp(Neon.purple, Neon.cyan, t)!;
