import 'package:flutter/material.dart';

/// AvPlay 式浅色样式（2026-11-26 用户发四张真机截图 + 反编
/// 译源码规格表 UI_SPEC.md 定版）：白底、近黑字、红色点缀、
/// 圆角卡。演员库模块的作品列表 / 演员列表 / 女优详情 / 作
/// 品详情照这套走。要点：选中页签红粗体 + 底部红线；选中胶
/// 囊浅粉底红字；作品卡番号红色、徽标（有资源绿字 / 字幕橙
/// 字 / 高清蓝字）、日期灰字；演员卡方形圆角照片 + 名字居
/// 中加粗。主色取规格表证实的 highlightRed 基色 #D81B60
/// （AvPlay 是动态取色，此为其红色高亮基色）；绿/蓝同理取
/// highlightGreen/highlightBlue 基色。间距梯队照规格表：
/// 页边距 16、区块距 20、条目间距 10；圆角梯队 4/8/12/16。
abstract final class AvStyle {
  static const bg = Color(0xFFFFFFFF);
  static const softBg = Color(0xFFF7F7F8);
  static const fieldFill = Color(0xFFF1F1F3);
  static const text = Color(0xFF191919);
  static const dim = Color(0xFF8E8E93);
  static const warm = Color(0xFF7A6A5C);
  static const accent = Color(0xFFD81B60);
  static const accentSoft = Color(0xFFFCE4EF);
  static const border = Color(0xFFE7E7EA);
  static const green = Color(0xFF55B16C);
  static const orange = Color(0xFFF08C00);
  static const blue = Color(0xFF2B91AF);
}

/// 浅色胶囊（源切换 / 分类 / 标签共用）：选中 = 浅粉底 +
/// 酒红字，未选 = 白底浅边 + 深灰字。
class AvPill extends StatelessWidget {
  const AvPill({
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: compact ? 4 : 7,
        ),
        decoration: BoxDecoration(
          color: selected ? AvStyle.accentSoft : AvStyle.bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? AvStyle.accentSoft : AvStyle.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AvStyle.accent : AvStyle.text,
            fontSize: compact ? 12 : 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// 页签式文字（演员列表分类行，照 AvPlay 页签）：选中 =
/// 酒红粗体 + 底部 2px 红线，未选 = 灰字。
class AvTabText extends StatelessWidget {
  const AvTabText({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(2, 6, 2, 5),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? AvStyle.accent : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AvStyle.accent : AvStyle.dim,
            fontSize: 14.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// 作品卡（三屏共用，照 AvPlay 列表项摆法）：竖版封面圆角
/// 在上，其下标题一行截断、番号酒红 + 徽标行、日期灰字。
/// 评分我们没有数据，不编。徽标只在数据支持时传：
/// [hasResource] = 库里有地址（绿字「有资源」），
/// [hasSubtitle] = 分类/标签带字幕（橙字「字幕」）。
class AvWorkCard extends StatelessWidget {
  const AvWorkCard({
    super.key,
    required this.cover,
    required this.title,
    required this.code,
    required this.date,
    required this.onTap,
    this.hasResource = false,
    this.hasSubtitle = false,
    this.hasHd = false,
    this.duration = '',
    this.busy = false,
    this.topRight,
  });

  final String cover;
  final String title;
  final String code;
  final String date;
  final VoidCallback onTap;
  final bool hasResource;
  final bool hasSubtitle;

  /// 高清徽标（规格表证实 AvPlay 徽标文案有「高清」，数据来
  /// 自 hd 字段；我们按分类/标签含高清口径映射）。
  final bool hasHd;

  /// 时长徽标（压在封面右下，在线源用）。
  final String duration;

  /// 取流中遮罩（在线源点卡后）。
  final bool busy;

  /// 封面右上角小控件（本地卡的收藏星）。
  final Widget? topRight;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 3 / 4,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    color: AvStyle.softBg,
                    child: cover.isEmpty
                        ? Center(
                            child: Text(
                              code.isEmpty ? 'NV' : code,
                              style: const TextStyle(
                                color: AvStyle.dim,
                                fontSize: 11,
                              ),
                            ),
                          )
                        : Image.network(
                            cover,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const SizedBox.shrink(),
                          ),
                  ),
                  if (duration.isNotEmpty)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xB3000000),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          duration,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                  if (topRight != null)
                    Positioned(right: 2, top: 2, child: topRight!),
                  if (busy)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Color(0x66000000),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AvStyle.text,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Flexible(
                child: Text(
                  code,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AvStyle.accent,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (hasResource) ...[
                const SizedBox(width: 6),
                const Text(
                  '有资源',
                  style: TextStyle(color: AvStyle.green, fontSize: 11),
                ),
              ],
              if (hasSubtitle) ...[
                const SizedBox(width: 6),
                const Text(
                  '字幕',
                  style: TextStyle(color: AvStyle.orange, fontSize: 11),
                ),
              ],
              if (hasHd) ...[
                const SizedBox(width: 6),
                const Text(
                  '高清',
                  style: TextStyle(color: AvStyle.blue, fontSize: 11),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(
            date,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AvStyle.dim, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// 作品网格布局（三屏共用）：三列竖版卡。格比按实测留
/// 余量（390 宽下格高比内容高多约 6px，防字体度量差溢出）。
const avWorkGridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 140,
  mainAxisSpacing: 10,
  crossAxisSpacing: 10,
  childAspectRatio: 0.53,
);
