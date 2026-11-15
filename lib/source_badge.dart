import 'package:flutter/material.dart';

import 'models.dart';
import 'plugin_manager.dart';

/// 「在看 / 追剧」卡片右上角的源（服务器）徽标：源名称 + 类型图标。
///
/// 数据来源：[Drama.source]（站点 id）→ [SourceSite.byId] 取显示名；
/// 图标复用插件机制 [PluginManager.pluginIconForSource]：jar 站咖啡杯、
/// py 站爬虫。站点模型今天没有自有图标字段，无图标数据的源只显示
/// 文字徽标，不编假图标；将来模型有了自有图标、走同一个复用口，
/// 徽标会自动跟上。
///
/// 落位见 [topOffset] / [rightOffset]：卡片右上角已有“更多”按钮
/// （高 40，top 2），徽标挂在它下方 6px；左上角是 VIP / 置顶标，
/// 左下角是集数标、底部是整条状态条，都不在这一侧，不重叠。
/// 未知来源（未注册的 id）不显示徽标，不借用其它站名。
class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.sourceId, this.maxWidth = 132});

  final String sourceId;
  final double maxWidth;

  /// 徽标在卡片 Stack 里的上边距：刚好躲开右上角的“更多”按钮。
  static const double topOffset = 48;

  /// 徽标在卡片 Stack 里的右边距：与卡片内其它角标对齐。
  static const double rightOffset = 6;

  /// [sourceId] 对应的显示名；空 id 或未注册的 id 返回 null（不显示）。
  static String? displayNameFor(String sourceId) {
    if (sourceId.isEmpty || !SourceSite.isKnown(sourceId)) return null;
    final name = SourceSite.byId(sourceId).name.trim();
    return name.isEmpty ? null : name;
  }

  @override
  Widget build(BuildContext context) {
    final name = displayNameFor(sourceId);
    if (name == null) return const SizedBox.shrink();
    final icon = PluginManager.pluginIconForSource(
      SourceSite.byId(sourceId),
      size: 12,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .64),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              IconTheme(
                data: const IconThemeData(color: Colors.white),
                child: icon,
              ),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
