import 'package:flutter/material.dart';

import 'app_theme_config.dart';

/// 霓虹玻璃共用件：设置页、站点区、导入中心、抽屉、频道筛选胶囊共用
/// 同一套视觉语言——玻璃卡片、渐变选中态、发光描边、胶囊徽章。
///
/// 颜色一律取自当前主题的 [AppThemeConfig]，不在这里写死任何色值，
/// 切主题后所有用它的界面一起变色。浅色主题同样可读：渐变上的文字
/// 永远用各主题自带的 [AppThemeConfig.selectedText]。
Gradient neonSelectedGradient(AppThemeConfig config) =>
    config.selectedGradient ??
    LinearGradient(colors: [config.primaryColor, config.secondaryColor]);

/// 选中态外发光：主题主色柔光，不抢内容。
BoxShadow neonGlow(AppThemeConfig config, {double blur = 16}) =>
    BoxShadow(
      color: config.primaryColor.withValues(alpha: config.isDark ? 0.38 : 0.22),
      blurRadius: blur,
      spreadRadius: -3,
    );

/// 分组玻璃卡片：主题面色 + 细描边 + 柔和投影。
class NeonGlassCard extends StatelessWidget {
  const NeonGlassCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius = 20,
    this.glow = false,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: config.surfaceColor,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: config.isDark
              ? config.primaryColor.withValues(alpha: 0.28)
              : config.dividerColor,
        ),
        boxShadow: [
          if (glow)
            neonGlow(config)
          else
            BoxShadow(
              color: config.isDark
                  ? config.primaryColor.withValues(alpha: 0.10)
                  : config.textPrimary.withValues(alpha: 0.06),
              blurRadius: 14,
              spreadRadius: -4,
              offset: const Offset(0, 4),
            ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      // 内层透明 Material：卡片里的 ListTile/InkWell 需要一个在装饰背景
      // 之上的 Material 祖先，否则水波纹会被卡片背景盖住（调试断言）。
      child: Material(color: Colors.transparent, child: child),
    );
  }
}

/// 分组标题：渐变竖条 + 标题 + 可选副标，文字完整显示不截断。
class NeonSectionTitle extends StatelessWidget {
  const NeonSectionTitle(
    this.title, {
    super.key,
    this.hint,
    this.padding = const EdgeInsets.fromLTRB(4, 8, 4, 8),
  });

  final String title;
  final String? hint;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 3,
            height: 15,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              gradient: neonSelectedGradient(config),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: config.textPrimary,
                  ),
                ),
                if (hint != null && hint!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    hint!,
                    style: TextStyle(
                      fontSize: 11,
                      color: config.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 渐变图标方块：选中渐变底 + 主题选中文字色图标。
class NeonIconTile extends StatelessWidget {
  const NeonIconTile({
    super.key,
    required this.icon,
    this.size = 34,
    this.iconSize = 18,
    this.radius = 10,
  });

  final IconData icon;
  final double size;
  final double iconSize;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: neonSelectedGradient(config),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [neonGlow(config, blur: 10)],
      ),
      child: Icon(icon, size: iconSize, color: config.selectedText),
    );
  }
}

/// 一行：渐变图标 + 标题 + 副文 + 右侧件。标题与副文完整换行显示，
/// 不截断、不省略号。
class NeonRow extends StatelessWidget {
  const NeonRow({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.trailing,
    this.onTap,
    this.showChevron = true,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    final enabled = onTap != null || trailing != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
          child: Row(
            children: [
              NeonIconTile(icon: icon),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: enabled
                            ? config.textPrimary
                            : config.textPrimary.withValues(alpha: 0.4),
                      ),
                    ),
                    if (detail != null && detail!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        detail!,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: config.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null)
                trailing!
              else if (showChevron && onTap != null)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: config.textSecondary.withValues(alpha: 0.7),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一组行 + 行间分隔线，包在同一张玻璃卡片里。
class NeonRowGroup extends StatelessWidget {
  const NeonRowGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: 60,
            endIndent: 12,
            color: config.dividerColor.withValues(alpha: 0.6),
          ),
        );
      }
      rows.add(children[i]);
    }
    return NeonGlassCard(
      child: Column(mainAxisSize: MainAxisSize.min, children: rows),
    );
  }
}

/// 筛选/切换胶囊：选中渐变实心 + 发光，未选中玻璃底 + 描边。
/// 标签有多宽就多宽，不截断。
class NeonCapsule extends StatelessWidget {
  const NeonCapsule({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.iconSize = 11,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          gradient: selected ? neonSelectedGradient(config) : null,
          color: selected ? null : config.unselectedBg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? Colors.transparent
                : config.dividerColor,
          ),
          boxShadow: selected ? [neonGlow(config)] : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: iconSize,
                color: selected
                    ? config.selectedText
                    : config.textSecondary,
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                height: 1.0,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected
                    ? config.selectedText
                    : config.unselectedText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 小徽章：当前使用 / 已启用 / 导入配置这类状态标记，渐变底。
class NeonBadge extends StatelessWidget {
  const NeonBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        gradient: neonSelectedGradient(config),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          height: 1.1,
          fontWeight: FontWeight.w700,
          color: config.selectedText,
        ),
      ),
    );
  }
}

/// 主题开关：轨道用主题主色，拇指用选中文字色。
class NeonSwitch extends StatelessWidget {
  const NeonSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    return Switch.adaptive(
      value: value,
      onChanged: onChanged,
      activeColor: config.selectedText,
      activeTrackColor: config.primaryColor,
      inactiveThumbColor: config.textSecondary,
      inactiveTrackColor: config.unselectedBg,
      trackOutlineColor: WidgetStatePropertyAll(config.dividerColor),
    );
  }
}
