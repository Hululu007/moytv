import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme_config.dart';

double compactChipHeight(BuildContext context) {
  return math.max(22, MediaQuery.textScalerOf(context).scale(10) + 12);
}

double largeCompactChipHeight(BuildContext context) {
  return compactChipHeight(context) + 6;
}

class CompactFilterChip extends StatelessWidget {
  const CompactFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.avatar,
    this.large = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;
  final Widget? avatar;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final config = AppThemeConfig.of(context);
    final height = large
        ? largeCompactChipHeight(context)
        : compactChipHeight(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onSelected,
        child: Container(
          height: height,
          padding: EdgeInsets.symmetric(horizontal: large ? 12 : 10),
          decoration: BoxDecoration(
            // 选中态跟当前主题选中色（原写死浅绿），未选中态跟主题容器色。
            color: selected
                ? config.selectedBg
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (avatar != null) ...[
                avatar!,
                const SizedBox(width: 3),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: large ? 12 : 10,
                  height: 1.0,
                  color: selected ? config.selectedText : scheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
