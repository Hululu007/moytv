import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'app_theme_config.dart';
import 'liquid_glass.dart';

/// 底部 Tab 导航栏（6 个 Tab：片库/直播/听书/阅读/我的/多媒体）。
///
/// 只借 LwLive 底部栏的结构（图标 + 文字 + 选中着色 + 小圆点指示），
/// 配色一律取当前主题的 AppThemeConfig，图标用树内已有的 Lucide 图标。
/// 玻璃平台（手机）走 LiquidGlass 毛玻璃 + 半透明主题面色；非玻璃平台
/// （Windows 桌面）走纯色面色，不用 BackdropFilter 模糊。
class MoyiBottomTabBar extends StatelessWidget {
  const MoyiBottomTabBar({
    super.key,
    required this.index,
    required this.onSelect,
  });

  /// 当前选中下标：0 片库、1 直播、2 听书、3 阅读、4 我的、5 多媒体。
  final int index;

  final ValueChanged<int> onSelect;

  static const _labels = ['片库', '直播', '听书', '阅读', '我的', '多媒体'];

  static const _icons = [
    LucideIcons.clapperboard,
    LucideIcons.tv,
    LucideIcons.headphones,
    LucideIcons.bookOpen,
    LucideIcons.user,
    LucideIcons.hardDrive,
  ];

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    final bar = Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: config.dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              for (var i = 0; i < _labels.length; i++)
                Expanded(child: _tab(context, config, i)),
            ],
          ),
        ),
      ),
    );
    if (!glassDesign(context)) {
      return Container(color: config.surfaceColor, child: bar);
    }
    return LiquidGlass(
      borderRadius: BorderRadius.zero,
      tint: config.surfaceColor.withValues(alpha: 0.82),
      elevated: false,
      child: bar,
    );
  }

  Widget _tab(BuildContext context, AppThemeConfig config, int tabIndex) {
    final selected = tabIndex == index;
    final foreground = selected ? config.selectedText : config.textSecondary;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(_icons[tabIndex], size: 22, color: foreground),
        const SizedBox(height: 2),
        Text(
          _labels[tabIndex],
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            color: foreground,
          ),
        ),
      ],
    );
    return InkWell(
      key: ValueKey('moyi-bottom-tab-$tabIndex'),
      onTap: () => onSelect(tabIndex),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (selected)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: config.selectedBg,
                borderRadius: BorderRadius.circular(999),
              ),
              child: content,
            )
          else
            content,
          const SizedBox(height: 3),
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? config.primaryColor : Colors.transparent,
            ),
          ),
        ],
      ),
    );
  }
}
