import 'dart:async';
import 'dart:math' show Random;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'site_icon.dart';

/// Win7 主题的桌面外壳：墙纸 + 左侧图标列 + 底部任务栏 + 开始菜单
/// + 窗口标题栏。数值全部取用户 2026-11-16 发来的桌面设计稿精确值
/// （第二份文件）；窗口标题栏是用户 12:10 纠正后新增的，设计稿里
/// 没有，按 Win7 玻璃蓝标题栏做。
///
/// 本文件只负责桌面外壳的纯展示组件；窗口的开关/最小化/状态保留
/// 由 home_screen 里的窗口管理器管（见 _win7Windows）。

/// Win7 窗口种类：一种区一个窗口位（同种区只开一个窗口，再点
/// 只是切到前台，不重复开）。听书与阅读已并为一个“听读”窗口
/// （用户 2026-11-18 令）：窗口内听书/阅读胶囊切换子区，不再
/// 各开一个窗口；旧版分开的 audio/novel 两个种类已取消，存下来
/// 的旧顺序名字由 [resolveDesktopIconOrder] 映射到听读。
enum Win7WindowKind {
  library,
  drama,
  live,
  listenRead,
  miniApp,
  multimedia,
  mine,
  actress,
  // 游戏区（用户 2026-11-19 令新增）：独立区、两张游戏卡；只走
  // 底部标签与开始菜单单叶，不进桌面图标表（桌面图标还是两个
  // 游戏各自的，不动）。
  gameZone,
  game,
  kof;

  /// 窗口标题栏与任务栏条目上显示的区名（取桌面图标叫法）。
  String get title => switch (this) {
    Win7WindowKind.library => '片库',
    Win7WindowKind.drama => '短剧',
    Win7WindowKind.live => '直播',
    Win7WindowKind.listenRead => '听读',
    Win7WindowKind.miniApp => '小程序',
    Win7WindowKind.multimedia => '网盘',
    Win7WindowKind.mine => '我的电脑',
    Win7WindowKind.actress => '演员库',
    Win7WindowKind.gameZone => '游戏区',
    Win7WindowKind.game => '红警2',
    Win7WindowKind.kof => '拳皇97',
  };

  IconData get icon => switch (this) {
    Win7WindowKind.library => Icons.video_library,
    Win7WindowKind.drama => Icons.play_circle,
    Win7WindowKind.live => Icons.live_tv,
    // 与底部“听读”标签同一字形（书 + 耳机）。
    Win7WindowKind.listenRead => LucideIcons.bookHeadphones,
    Win7WindowKind.miniApp => Icons.apps,
    Win7WindowKind.multimedia => Icons.storage,
    Win7WindowKind.mine => Icons.desktop_windows,
    Win7WindowKind.actress => Icons.people_alt_outlined,
    Win7WindowKind.gameZone => Icons.sports_esports,
    Win7WindowKind.game => Icons.sports_esports,
    Win7WindowKind.kof => Icons.sports_esports,
  };

  /// 桌面图标底块的渐变色（一深一浅，左上到右下）：成套彩色，
  /// Win7/XP 桌面共用同一套；任务栏与标题栏的小图标仍用白色，
  /// 不走这套配色。mine（我的电脑）与 multimedia（网盘）图标
  /// 与配色刻意区分：mine 是显示器 + XP 蓝，multimedia 是硬盘
  /// + slate 灰，桌面与任务栏上能分清。
  List<Color> get iconGradient => switch (this) {
    Win7WindowKind.library => const [Color(0xFF6366F1), Color(0xFF4338CA)],
    Win7WindowKind.drama => const [Color(0xFFA855F7), Color(0xFF7E22CE)],
    Win7WindowKind.live => const [Color(0xFFF25022), Color(0xFFC2410C)],
    // 听读：听书琥珀到阅读绿的渐变，两边各取一头，合并不丢色。
    Win7WindowKind.listenRead => const [Color(0xFFF59E0B), Color(0xFF15803D)],
    Win7WindowKind.miniApp => const [Color(0xFF06B6D4), Color(0xFF0284C7)],
    Win7WindowKind.multimedia => const [Color(0xFF64748B), Color(0xFF475569)],
    Win7WindowKind.mine => const [Color(0xFF3A93FF), Color(0xFF0058E6)],
    Win7WindowKind.actress => const [Color(0xFFEC4899), Color(0xFFDB2777)],
    // 游戏区：金色，与其余 10 对渐变均不撞（kof 测试钉全员互异）。
    Win7WindowKind.gameZone => const [Color(0xFFEAB308), Color(0xFFA16207)],
    Win7WindowKind.game => const [Color(0xFFB91C1C), Color(0xFF7F1D1D)],
    Win7WindowKind.kof => const [Color(0xFF14B8A6), Color(0xFF0F766E)],
  };
}

/// 桌面图标底块（Win7/XP 共用）：圆角渐变色块 + 白色字形 +
/// 浅边与投影，亮墙纸（XP 山丘）与深墙纸（Win7 蓝渐变）上都
/// 清晰可读。只负责图标本体，标题文字由调用方画在底块下面。
class DesktopIconBadge extends StatelessWidget {
  const DesktopIconBadge({super.key, required this.kind, this.size = 48});

  final Win7WindowKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = kind.iconGradient;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        borderRadius: BorderRadius.circular(size * 0.25),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.55),
          width: 1,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Icon(kind.icon, size: size * 0.58, color: Colors.white),
    );
  }
}

/// 桌面图标默认顺序与内容：9 个。短剧没有桌面图标、只在开始
/// 菜单树里；网盘有桌面图标（排末尾），窗口标题叫“网盘”，
/// 不再与桌面顶上的“我的电脑”图标撞名。顺序口径（用户
/// 2026-11-18 令）：我的电脑置顶排第一位，其余按听读、片库、
/// 直播、小程序、女优库、游戏、网盘的相对顺序往下排（听书与
/// 阅读已并为一个“听读”图标，占原来听书的位置）。用户长按拖拽
/// 换过顺序后，以存下来的顺序为准（见 [loadDesktopIconOrder]），
/// 这份默认顺序只作没存过时的回落；以前拖过的手机保留自己拖的
/// 顺序，不自动改（可长按再拖回来），旧顺序里的听书/阅读两键由
/// [resolveDesktopIconOrder] 并成一个听读、占先出现者的位置。
const List<Win7WindowKind> win7DesktopIcons = [
  Win7WindowKind.mine,
  Win7WindowKind.listenRead,
  Win7WindowKind.library,
  Win7WindowKind.live,
  Win7WindowKind.miniApp,
  Win7WindowKind.actress,
  Win7WindowKind.game,
  Win7WindowKind.multimedia,
  Win7WindowKind.kof,
];

/// 桌面图标顺序存 SharedPreferences 的键（Win7/XP 共用同一份顺序）。
const String desktopIconOrderKey = 'moyi_desktop_icon_order';

/// 把存下来的名字表解析成图标顺序：未知名字、重复名字、已不在
/// 桌面列表里的种类一律丢弃；默认列表里有但存表里没有的种类
/// （新加的图标）按默认相对顺序追加到末尾。空/没存过时回默认顺序。
/// 旧版两个图标名字的迁移：存表里的 'audio'（听书）与 'novel'
/// （阅读）都映射成听读图标，先出现的那处占位、另一处去重丢弃，
/// 其余图标的相对顺序一律不动，不重置用户拖过的顺序。
List<Win7WindowKind> resolveDesktopIconOrder(List<String>? stored) {
  final resolved = <Win7WindowKind>[];
  if (stored != null) {
    for (final name in stored) {
      Win7WindowKind? match;
      if (name == 'audio' || name == 'novel') {
        match = Win7WindowKind.listenRead;
      } else {
        for (final kind in Win7WindowKind.values) {
          if (kind.name == name) {
            match = kind;
            break;
          }
        }
      }
      if (match == null) continue;
      if (!win7DesktopIcons.contains(match)) continue;
      if (resolved.contains(match)) continue;
      resolved.add(match);
    }
  }
  for (final kind in win7DesktopIcons) {
    if (!resolved.contains(kind)) resolved.add(kind);
  }
  return resolved;
}

/// 读存下来的桌面图标顺序；读不到/读失败时回默认顺序。
Future<List<Win7WindowKind>> loadDesktopIconOrder() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return resolveDesktopIconOrder(prefs.getStringList(desktopIconOrderKey));
  } catch (_) {
    return List.of(win7DesktopIcons);
  }
}

/// 存桌面图标顺序；存失败静默忽略（下次打开回默认顺序）。
Future<void> saveDesktopIconOrder(List<Win7WindowKind> order) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      desktopIconOrderKey,
      order.map((kind) => kind.name).toList(),
    );
  } catch (_) {}
}

/// 单个桌面图标项的高度：图标 48 + 图标与标题间距 4 + 标题行高
/// + 底部留白 20。标题行高用 TextPainter 按真实标题的样式实测：
/// ambient DefaultTextStyle 与 13 号字合并（与图标标题的 Text
/// 同一字体、同一字号），再按当前文字缩放算；只按裸 13 号字测
/// 会低估行高（实测 13，真机渲染 19），一列个数算多、末尾图标
/// 压进任务栏。行高不低于字号本身：字体未就绪的首帧实测会偏
/// 小，下限挡住这种低估，避免首帧多排一项溢出（真机字体行高
/// 本就大于字号，下限不生效）。
double desktopIconItemHeight(BuildContext context) {
  final style = DefaultTextStyle.of(context).style.merge(
    const TextStyle(fontSize: 13),
  );
  final painter = TextPainter(
    text: TextSpan(text: '标题', style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final titleHeight = painter.height < 13 ? 13.0 : painter.height;
  return 48 + 4 + titleHeight + 20;
}

/// 一列能放几个图标：可用高度除以单项高度，向下取整，至少 1 个。
/// 可用高度无约束（无限）时返回 [count]，即全部放一列。
int desktopItemsPerColumn(
  double availableHeight,
  double itemHeight,
  int count,
) {
  if (!availableHeight.isFinite || itemHeight <= 0) return count;
  final per = (availableHeight / itemHeight).floor();
  return per < 1 ? 1 : per;
}

/// 把线性图标顺序按每列 [perColumn] 个切成列块（列优先：第一列
/// 排满再排第二列，和真电脑桌面一样）。[perColumn] 小于 1 时按
/// 1 算；顺序为空时返回空表。
List<List<Win7WindowKind>> splitDesktopIconsIntoColumns(
  List<Win7WindowKind> order,
  int perColumn,
) {
  if (order.isEmpty) return const [];
  final per = perColumn < 1 ? 1 : perColumn;
  final columns = <List<Win7WindowKind>>[];
  for (var i = 0; i < order.length; i += per) {
    final end = i + per > order.length ? order.length : i + per;
    columns.add(order.sublist(i, end));
  }
  return columns;
}

/// 开始菜单树节点：组节点只有 [label] 与 [children]，叶子节点带
/// 目标窗口种类 [kind] 与站点 id [siteId]（点叶子开对应窗口并选站）。
/// 节点名全部由调用方取注册表填，本文件不写死任何站点名。
class Win7TreeNode {
  const Win7TreeNode({
    required this.label,
    this.children = const [],
    this.kind,
    this.siteId,
  });

  final String label;
  final List<Win7TreeNode> children;
  final Win7WindowKind? kind;
  final String? siteId;

  bool get isLeaf => children.isEmpty;
}

/// 开始菜单右列固定站点：存 SharedPreferences 的有序 siteId 列表
/// （Win7/XP 共用同一份）。解析只认树里找得到的叶子，找不到或
/// 已隐藏（不在树里）的 id 静默跳过。用户用长按菜单增删；首次
/// 打开（从没存过）时随机抽几个存下来，之后只读存下来的那份。
const String startMenuPinnedSitesKey = 'moyi_start_menu_pinned_sites';

/// 首次打开开始菜单时随机抽的固定站点数（从没存过时只抽一次）。
const int startMenuPinnedInitialDrawCount = 6;

/// 从树里所有可见站点叶子中随机抽 [count] 个不重复的叶子（kind
/// 与 siteId 都齐的叶子；“暂无可用站点”占位叶与无站点的单叶如
/// 女优库不在内；同一 id 只取树里第一次出现的那处）。叶子不够
/// 时全取。站名一律取树节点，不写死任何站点。
List<Win7TreeNode> drawRandomPinnedSites(
  List<Win7TreeNode> groups,
  int count,
  Random random,
) {
  final leaves = <Win7TreeNode>[];
  final seen = <String>{};
  void walk(Win7TreeNode node) {
    if (node.isLeaf) {
      final siteId = node.siteId;
      if (node.kind != null && siteId != null && seen.add(siteId)) {
        leaves.add(node);
      }
      return;
    }
    for (final child in node.children) {
      walk(child);
    }
  }
  for (final group in groups) {
    walk(group);
  }
  leaves.shuffle(random);
  if (leaves.length <= count) return leaves;
  return leaves.sublist(0, count);
}

/// 把存下来的 siteId 列表解析成固定节点：按存序在树里找叶子，
/// kind/siteId/label 都取树节点；找不到、重复、已隐藏（不在树里）
/// 的 id 静默跳过；同一 id 在多组出现时取树里第一次出现的节点。
/// 存表为空时回空列表（不再自动补抽）。
List<Win7TreeNode> resolveStartMenuPinnedSites(
  List<Win7TreeNode> groups,
  List<String> stored,
) {
  final byId = <String, Win7TreeNode>{};
  void walk(Win7TreeNode node) {
    if (node.isLeaf) {
      final siteId = node.siteId;
      if (node.kind != null && siteId != null) {
        byId.putIfAbsent(siteId, () => node);
      }
      return;
    }
    for (final child in node.children) {
      walk(child);
    }
  }
  for (final group in groups) {
    walk(group);
  }
  final resolved = <Win7TreeNode>[];
  final seen = <String>{};
  for (final id in stored) {
    if (!seen.add(id)) continue;
    final node = byId[id];
    if (node != null) resolved.add(node);
  }
  return resolved;
}

/// 存固定列表（有序 siteId）；存失败静默忽略。
Future<void> saveStartMenuPinnedSites(List<String> siteIds) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(startMenuPinnedSitesKey, siteIds);
  } catch (_) {}
}

/// 读固定列表：存过就读存下来的那份（哪怕是空表）；从没存过
/// （key 不存在）时随机抽 [startMenuPinnedInitialDrawCount] 个立即
/// 存下来当固定列表。只有“从没存过”才抽一次——用户把固定全取
/// 消后，存下来的是空表，之后打开不再自动补抽。读失败时回空列表。
Future<List<Win7TreeNode>> loadStartMenuPinnedSites(
  List<Win7TreeNode> groups, {
  Random? random,
}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(startMenuPinnedSitesKey);
    if (stored != null) {
      return resolveStartMenuPinnedSites(groups, stored);
    }
    final drawn = drawRandomPinnedSites(
      groups,
      startMenuPinnedInitialDrawCount,
      random ?? Random(),
    );
    await saveStartMenuPinnedSites(
      drawn.map((node) => node.siteId!).toList(),
    );
    return drawn;
  } catch (_) {
    return const [];
  }
}

/// 开始菜单上下文菜单（长按弹出，电脑鼠标右键同式，Win7/XP 共用）：
/// 在长按点附近打开，点菜单外任意处关闭（showMenu 自带遮罩）。
/// [entries] 是 (值, 文案) 对；返回选中的值，没选回 null。
Future<T?> showStartMenuContextMenu<T>({
  required BuildContext context,
  required Offset globalPosition,
  required List<({T value, String label})> entries,
  required Color backgroundColor,
  required Color textColor,
}) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromPoints(globalPosition, globalPosition),
      Offset.zero & overlay.size,
    ),
    color: backgroundColor,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    items: [
      for (final entry in entries)
        PopupMenuItem<T>(
          value: entry.value,
          child: Text(
            entry.label,
            style: TextStyle(color: textColor, fontSize: 14),
          ),
        ),
    ],
  );
}

/// 开始菜单右列：固定站点栏（Win7/XP 共用）。每行一个站点图标 +
/// 站名，点按效果与点树里对应叶子一样（走同一个 onLeafTap，调用
/// 方关菜单）；长按一行调 [onRowLongPress]，由调用方弹取消固定菜单。
/// 图标复用 [SiteIcon] 三级解析，与站点选择弹窗同一套，不另起图标
/// 逻辑。列表为空时显示一句提示，教用户长按左侧站点固定到这里。
class StartMenuPinnedColumn extends StatelessWidget {
  const StartMenuPinnedColumn({
    super.key,
    required this.keyPrefix,
    required this.pinned,
    required this.onLeafTap,
    required this.onRowLongPress,
    required this.textColor,
    required this.hoverColor,
  });

  /// 行 key 前缀：Win7 用 'win7-start-menu'，XP 用 'xp-start-menu'。
  final String keyPrefix;
  final List<Win7TreeNode> pinned;
  final void Function(Win7WindowKind kind, String? siteId) onLeafTap;

  /// 长按一行的回调：长按点的全局坐标 + 该行节点，调用方弹菜单。
  final void Function(Offset globalPosition, Win7TreeNode node) onRowLongPress;
  final Color textColor;
  final Color hoverColor;

  Widget _row(Win7TreeNode node) {
    final siteId = node.siteId!;
    return GestureDetector(
      onLongPressStart: (details) =>
          onRowLongPress(details.globalPosition, node),
      child: InkWell(
        key: ValueKey('$keyPrefix-pinned-$siteId'),
        onTap: () {
          final kind = node.kind;
          if (kind != null) onLeafTap(kind, siteId);
        },
        hoverColor: hoverColor,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          width: double.infinity,
          child: Row(
            children: [
              SiteIcon(
                siteId: siteId,
                siteName: node.label,
                size: 30,
                borderRadius: 8,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  node.label,
                  style: TextStyle(color: textColor, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('$keyPrefix-pinned'),
      child: pinned.isEmpty
          ? Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '长按左侧站点，固定到这里',
                  style: TextStyle(
                    color: textColor.withValues(alpha: 0.6),
                    fontSize: 13,
                  ),
                ),
              ),
            )
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final node in pinned) _row(node)],
              ),
            ),
    );
  }
}

/// 设计稿主题色。
abstract final class Win7Theme {
  static const Color taskBarBg = Color(0xCC1C1C1C);
  static const Color startMenuBg = Color(0xE6202020);
  static const Color accentBlue = Color(0xFF0078D4);
  static const Color textColor = Colors.white;
  static const Color hoverBg = Color(0x22FFFFFF);
  static const List<Color> wallpaperGradient = [
    Color(0xFF0F4C81),
    Color(0xFF1E88E5),
    Color(0xFF002147),
  ];
}

/// 桌面图标列（Win7/XP 共用）：按列排图标，点按开窗口；长按进
/// 编辑态（用户 2026-11-27 令，与底部导航同一套编辑语言），编辑
/// 态里拖动图标换位——拖到另一个图标上松手是两者互换格子、拖到
/// 空格子是移过去，落位立刻存盘、重启与切主题都不乱；退出编辑态
/// 由桌面壳的「完成」钮负责（[editing]/[onEnterEdit] 由壳传入）。
/// 非编辑态点按行为不变。一列排满后换下一列继续排（和真电脑
/// 桌面一样）。图标本体（图标 + 标题两行）由调用方按各自风格
/// 提供；拖拽手势、顺序状态与持久化都收在这里，两边行为一致。
class DesktopIconColumn extends StatefulWidget {
  const DesktopIconColumn({
    super.key,
    required this.keyPrefix,
    required this.onIconTap,
    required this.iconBuilder,
    this.editing = false,
    this.onEnterEdit,
  });

  /// 图标 InkWell 的 key 前缀：Win7 用 'win7-desktop-icon'，XP 用
  /// 'xp-desktop-icon'（旧测试按 key 点图标，前缀不能变）。
  final String keyPrefix;

  final ValueChanged<Win7WindowKind> onIconTap;

  /// 图标本体：图标 + 标题两行（Win7 素色、XP 带阴影，各自画法）。
  final Widget Function(Win7WindowKind kind) iconBuilder;

  /// 编辑态：为真时图标可拖动换位、点按不开窗口；为假时长按图标
  /// 走 [onEnterEdit] 进编辑态。
  final bool editing;
  final VoidCallback? onEnterEdit;

  @override
  State<DesktopIconColumn> createState() => _DesktopIconColumnState();
}

class _DesktopIconColumnState extends State<DesktopIconColumn> {
  List<Win7WindowKind> _order = List.of(win7DesktopIcons);

  @override
  void initState() {
    super.initState();
    _loadOrder();
  }

  Future<void> _loadOrder() async {
    final order = await loadDesktopIconOrder();
    if (!mounted) return;
    setState(() => _order = order);
  }

  /// 编辑态把 [dragged] 与 [target] 两者互换格子（桌面图标调换的
  /// 习惯做法），立刻存盘。拖到自己身上不做事。
  void _swap(Win7WindowKind dragged, Win7WindowKind target) {
    if (dragged == target) return;
    final order = List.of(_order);
    final from = order.indexOf(dragged);
    final to = order.indexOf(target);
    if (from < 0 || to < 0) return;
    order[from] = target;
    order[to] = dragged;
    setState(() => _order = order);
    unawaited(saveDesktopIconOrder(order));
  }

  /// 编辑态把 [dragged] 移到线性位置 [targetIndex]（拖到空格子时
  /// 用：空格子都在最后一列尾部，落点即排到那一带），立刻存盘。
  void _moveToIndex(Win7WindowKind dragged, int targetIndex) {
    final order = List.of(_order);
    final from = order.indexOf(dragged);
    if (from < 0) return;
    order.removeAt(from);
    var to = targetIndex;
    if (to > order.length) to = order.length;
    if (to < 0) to = 0;
    if (to == from) return;
    order.insert(to, dragged);
    setState(() => _order = order);
    unawaited(saveDesktopIconOrder(order));
  }

  Widget _item(Win7WindowKind kind, {required bool hovered}) {
    return Padding(
      // 图标竖排：行距 20，844 高视口 + 底部安全边距里一列放
      // 8 个，第 9 个起换第二列；一列 8 个时第 8 个图标的标题
      // 刚好不被任务栏盖住（24 时标题被盖）。
      padding: const EdgeInsets.only(bottom: 20),
      child: Container(
        decoration: hovered || widget.editing
            ? BoxDecoration(
                color: Colors.white.withValues(
                  alpha: widget.editing ? 0.10 : 0.18,
                ),
                borderRadius: BorderRadius.circular(8),
                border: widget.editing
                    ? Border.all(
                        color: Colors.white.withValues(alpha: 0.35),
                      )
                    : null,
              )
            : null,
        child: InkWell(
          key: ValueKey('${widget.keyPrefix}-${kind.name}'),
          // 编辑态点按不开窗口（防误触）；非编辑态照常打开。
          onTap: widget.editing ? () {} : () => widget.onIconTap(kind),
          // 非编辑态长按进编辑态；编辑态长按由外层拖拽接管。
          onLongPress: widget.editing ? null : widget.onEnterEdit,
          child: widget.iconBuilder(kind),
        ),
      ),
    );
  }

  Widget _dragTarget(Win7WindowKind kind) {
    if (!widget.editing) return _item(kind, hovered: false);
    return DragTarget<Win7WindowKind>(
      onWillAcceptWithDetails: (details) => details.data != kind,
      onAcceptWithDetails: (details) => _swap(details.data, kind),
      builder: (context, candidateData, rejectedData) {
        return LongPressDraggable<Win7WindowKind>(
          data: kind,
          onDragStarted: HapticFeedback.mediumImpact,
          feedback: Material(
            color: Colors.transparent,
            child: Opacity(
              opacity: 0.85,
              child: widget.iconBuilder(kind),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.3,
            child: _item(kind, hovered: false),
          ),
          child: _item(kind, hovered: candidateData.isNotEmpty),
        );
      },
    );
  }

  /// 编辑态最后一列尾部的空格子：淡色描边占位，拖到它上面松手
  /// 即把图标移过去（见 [_moveToIndex]）。
  Widget _emptySlot(int linearIndex, BuildContext context) {
    return DragTarget<Win7WindowKind>(
      onWillAcceptWithDetails: (details) => true,
      onAcceptWithDetails: (details) =>
          _moveToIndex(details.data, linearIndex),
      builder: (context, candidateData, rejectedData) {
        return Container(
          key: ValueKey('${widget.keyPrefix}-empty-$linearIndex'),
          width: 60,
          height: desktopIconItemHeight(context),
          decoration: BoxDecoration(
            color: Colors.white.withValues(
              alpha: candidateData.isNotEmpty ? 0.16 : 0.05,
            ),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 满列换列（和真电脑桌面一样）：用布局实测的可用高度除以
    // 单项高度，算出一列能放几个，排满一列再排下一列。一列能
    // 放下时只有一列，外观与原来一字不差；编辑态的互换/空格
    // 落位逻辑（_swap/_moveToIndex）对列数无感。
    return LayoutBuilder(
      builder: (context, constraints) {
        final perColumn = desktopItemsPerColumn(
          constraints.maxHeight,
          desktopIconItemHeight(context),
          _order.length,
        );
        final columns = splitDesktopIconsIntoColumns(_order, perColumn);
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < columns.length; i++) ...[
              if (i > 0) const SizedBox(width: 20),
              Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (final kind in columns[i]) _dragTarget(kind),
                  // 编辑态：最后一列没排满时补空格子作落点。
                  if (widget.editing && i == columns.length - 1)
                    for (
                      var row = columns[i].length;
                      row < perColumn;
                      row++
                    )
                      _emptySlot(i * perColumn + row, context),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 桌面图标编辑态顶栏（Win7/XP 共用）：一句提示 + 「完成」钮，
/// 挂在桌面右上角；编辑态的视觉标记与退出都收在这里。
class DesktopEditBar extends StatelessWidget {
  const DesktopEditBar({super.key, required this.doneKey, required this.onDone});

  final Key doneKey;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '拖动图标换位',
          style: TextStyle(
            color: Colors.white,
            fontSize: 12,
            shadows: [
              Shadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 1)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Material(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: doneKey,
            borderRadius: BorderRadius.circular(16),
            onTap: onDone,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              child: Text(
                '完成',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 桌面：蓝渐变墙纸 + 左侧图标区（竖排，满一列换一列）。桌面本身没有任何导航。
/// 长按图标进编辑态（本壳自持状态），编辑态顶栏出「完成」钮退出。
class Win7Desktop extends StatefulWidget {
  const Win7Desktop({super.key, required this.onIconTap});

  final ValueChanged<Win7WindowKind> onIconTap;

  @override
  State<Win7Desktop> createState() => _Win7DesktopState();
}

class _Win7DesktopState extends State<Win7Desktop> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('win7-desktop'),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: Win7Theme.wallpaperGradient,
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: 40,
            left: 16,
            // bottom 必须给：不给时 Stack 给图标列的高度约束是
            // 无限，满列换列算不出每列个数、图标会一直往下排
            // 进任务栏（第 9 个图标实测压在任务栏下点不到）。
            bottom: 0,
            child: DesktopIconColumn(
              keyPrefix: 'win7-desktop-icon',
              onIconTap: widget.onIconTap,
              editing: _editing,
              onEnterEdit: () => setState(() => _editing = true),
              iconBuilder: (kind) => Column(
                children: [
                  DesktopIconBadge(kind: kind),
                  const SizedBox(height: 4),
                  Text(
                    kind.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      shadows: [
                        Shadow(
                          color: Colors.black54,
                          blurRadius: 4,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_editing)
            Positioned(
              top: 8,
              right: 12,
              child: DesktopEditBar(
                doneKey: const ValueKey('win7-desktop-edit-done'),
                onDone: () => setState(() => _editing = false),
              ),
            ),
        ],
      ),
    );
  }
}

/// 任务栏：48 高半透明条，左起 Windows 开始钮，后跟已开窗口条目。
/// 点已在前台的窗口条目会把它最小化回桌面（Windows 习惯）。
class Win7Taskbar extends StatelessWidget {
  const Win7Taskbar({
    super.key,
    required this.openWindows,
    required this.foreground,
    required this.onStartTap,
    required this.onEntryTap,
  });

  /// 已开窗口（按打开顺序）。
  final List<Win7WindowKind> openWindows;

  /// 当前前台窗口；null 表示桌面在前台。
  final Win7WindowKind? foreground;

  final VoidCallback onStartTap;
  final ValueChanged<Win7WindowKind> onEntryTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('win7-taskbar'),
      height: 48,
      color: Win7Theme.taskBarBg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: 12),
          InkWell(
            key: const ValueKey('win7-start-button'),
            onTap: onStartTap,
            child: Container(
              padding: const EdgeInsets.all(8),
              child: const Icon(
                Icons.window,
                color: Win7Theme.accentBlue,
                size: 28,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final kind in openWindows) ...[
                    const SizedBox(width: 4),
                    InkWell(
                      key: ValueKey('win7-taskbar-entry-${kind.name}'),
                      onTap: () => onEntryTap(kind),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: foreground == kind
                              ? Win7Theme.accentBlue.withValues(alpha: 0.55)
                              : Win7Theme.hoverBg,
                          borderRadius: BorderRadius.circular(6),
                          border: foreground == kind
                              ? Border.all(
                                  color: Win7Theme.accentBlue,
                                  width: 1,
                                )
                              : null,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(kind.icon, size: 18, color: Colors.white),
                            const SizedBox(width: 5),
                            Text(
                              kind.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 开始菜单：遮罩 + 底部弹出的树形站点菜单。点遮罩关闭；
/// 点组节点展开/收起，点叶子开对应窗口并选站。
class Win7StartMenu extends StatefulWidget {
  const Win7StartMenu({
    super.key,
    required this.groups,
    required this.onLeafTap,
    required this.onDismiss,
  });

  final List<Win7TreeNode> groups;
  final void Function(Win7WindowKind kind, String? siteId) onLeafTap;
  final VoidCallback onDismiss;

  @override
  State<Win7StartMenu> createState() => _Win7StartMenuState();
}

class _Win7StartMenuState extends State<Win7StartMenu> {
  /// 已展开的节点路径（下标串，如 "0-2"）；默认全收起，与设计稿一致。
  final Set<String> _expanded = {};

  /// 右列固定站点：先空着（显示提示语），存表读到后换成解析结果；
  /// 从没存过时读到的是首次随机抽的那份。
  List<Win7TreeNode> _pinned = const [];

  @override
  void initState() {
    super.initState();
    _loadPinned();
  }

  Future<void> _loadPinned() async {
    final pinned = await loadStartMenuPinnedSites(widget.groups);
    if (!mounted) return;
    setState(() => _pinned = pinned);
  }

  /// 把树叶子固定到右列末尾并存盘；已在固定栏里时不重复加。
  Future<void> _pinNode(Win7TreeNode node) async {
    final siteId = node.siteId;
    if (siteId == null || node.kind == null) return;
    if (_pinned.any((pinned) => pinned.siteId == siteId)) return;
    final updated = [..._pinned, node];
    setState(() => _pinned = updated);
    await saveStartMenuPinnedSites(
      updated.map((pinned) => pinned.siteId!).toList(),
    );
  }

  /// 从右列取消固定并存盘；全取消后存下来的是空表，不再自动补抽。
  Future<void> _unpinSite(String siteId) async {
    final updated =
        _pinned.where((pinned) => pinned.siteId != siteId).toList();
    if (updated.length == _pinned.length) return;
    setState(() => _pinned = updated);
    await saveStartMenuPinnedSites(
      updated.map((pinned) => pinned.siteId!).toList(),
    );
  }

  /// 长按树叶子弹出的上下文菜单：只有“固定到快捷方式”一项。
  Future<void> _showLeafMenu(Offset position, Win7TreeNode node) async {
    final action = await showStartMenuContextMenu<String>(
      context: context,
      globalPosition: position,
      entries: const [(value: 'pin', label: '固定到快捷方式')],
      backgroundColor: Win7Theme.startMenuBg,
      textColor: Win7Theme.textColor,
    );
    if (action == 'pin' && mounted) _pinNode(node);
  }

  /// 长按右列固定站点弹出的上下文菜单：只有“取消固定”一项。
  Future<void> _showPinnedMenu(Offset position, Win7TreeNode node) async {
    final siteId = node.siteId;
    if (siteId == null) return;
    final action = await showStartMenuContextMenu<String>(
      context: context,
      globalPosition: position,
      entries: const [(value: 'unpin', label: '取消固定')],
      backgroundColor: Win7Theme.startMenuBg,
      textColor: Win7Theme.textColor,
    );
    if (action == 'unpin' && mounted) _unpinSite(siteId);
  }

  Widget _renderNode(Win7TreeNode node, String path, double leftPadding) {
    final expanded = _expanded.contains(path);
    // 只有可固定的叶子才响应长按（组节点与无站点叶子不弹菜单）；
    // 长按手势与点按/展开互不干扰（手势竞技场裁决）。
    final pinnable = node.isLeaf && node.kind != null && node.siteId != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onLongPressStart: pinnable
              ? (details) => _showLeafMenu(details.globalPosition, node)
              : null,
          child: InkWell(
            key: ValueKey('win7-tree-node-$path'),
            onTap: () {
              if (node.isLeaf) {
                final kind = node.kind;
                if (kind != null) widget.onLeafTap(kind, node.siteId);
                return;
              }
              setState(() {
                if (expanded) {
                  _expanded.remove(path);
                } else {
                  _expanded.add(path);
                }
              });
            },
            hoverColor: Win7Theme.hoverBg,
            child: Container(
              padding: EdgeInsets.only(
                left: leftPadding,
                top: 10,
                bottom: 10,
                right: 12,
              ),
              width: double.infinity,
              child: Row(
                children: [
                  if (!node.isLeaf)
                    Icon(
                      expanded ? Icons.expand_more : Icons.chevron_right,
                      color: Win7Theme.textColor,
                      size: 18,
                    ),
                  const SizedBox(width: 6),
                  // 组行画该区的图标（箭头后、文字前）；叶子行不画。
                  if (!node.isLeaf && node.kind != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        node.kind!.icon,
                        color: Win7Theme.textColor,
                        size: 18,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      node.label,
                      style: const TextStyle(
                        color: Win7Theme.textColor,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (expanded)
          for (var i = 0; i < node.children.length; i++)
            _renderNode(node.children[i], '$path-$i', leftPadding + 22),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      key: const ValueKey('win7-start-menu'),
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey('win7-start-menu-scrim'),
            onTap: widget.onDismiss,
            child: Container(color: Colors.black38),
          ),
        ),
        Align(
          alignment: Alignment.bottomLeft,
          child: Container(
            height: MediaQuery.of(context).size.height * 0.65,
            width: MediaQuery.of(context).size.width * 0.92,
            margin: EdgeInsets.zero,
            decoration: BoxDecoration(
              color: Win7Theme.startMenuBg,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 左列：导航树，展开/收起行为与原来一字不差。
                  Expanded(
                    flex: 3,
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < widget.groups.length; i++)
                            _renderNode(widget.groups[i], '$i', 12),
                        ],
                      ),
                    ),
                  ),
                  const VerticalDivider(
                    key: ValueKey('win7-start-menu-divider'),
                    width: 1,
                    thickness: 1,
                    color: Colors.white24,
                  ),
                  // 右列：固定站点栏（图标 + 站名），与电脑开始菜单同式。
                  Expanded(
                    flex: 2,
                    child: StartMenuPinnedColumn(
                      keyPrefix: 'win7-start-menu',
                      pinned: _pinned,
                      onLeafTap: widget.onLeafTap,
                      onRowLongPress: _showPinnedMenu,
                      textColor: Win7Theme.textColor,
                      hoverColor: Win7Theme.hoverBg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 窗口框：Win7 玻璃蓝标题栏（区名 + 右上角最小化/关闭）+ 内容区。
/// 标题栏按钮是 Win7 风格的半透明小方钮，关闭钮带红底。
/// 桌面窗口标题栏自动隐藏壳（Win7 / XP 两套窗口框共用）。
///
/// 行为（用户 2026-11-18 令）：窗口内 3 秒无操作收起标题栏，内容区
/// 顶到窗口顶边；点一下屏幕标题栏放下来，3 秒无操作再收起；收起时
/// 的点按只放下标题栏、不触发底下内容；任务栏在壳外，不受影响。
///
/// 无操作计时：窗口内的点按、拖动、滚轮都算操作（标题栏自身按钮的
/// 点按也算），任一操作都重新计时。窗口退到后台（[active] 为假）
/// 时停掉计时器，回到前台时标题栏重新放下并重新计时；窗口销毁时
/// 计时器取消，不泄漏。
class WindowTitleBarAutoHide extends StatefulWidget {
  const WindowTitleBarAutoHide({
    super.key,
    required this.titleBar,
    required this.child,
    this.active = true,
    this.hideTitleBar = false,
  });

  /// 标题栏（32px 高那条）；收起时整条从树里拿掉，内容区顶满。
  final Widget titleBar;

  /// 窗口内容体。
  final Widget child;

  /// 窗口是否在前台。后台窗口（Offstage 藏起）不计时。
  final bool active;

  /// 强制藏标题栏（游戏全屏用）：标题栏不渲染、收起遮罩不挡事件，
  /// 内容体直接可点。只改渲染条件、不改树形，内容体 State 不重建。
  final bool hideTitleBar;

  @override
  State<WindowTitleBarAutoHide> createState() => _WindowTitleBarAutoHideState();
}

class _WindowTitleBarAutoHideState extends State<WindowTitleBarAutoHide> {
  /// 无操作多久收起标题栏（用户令：3 秒）。
  static const _hideAfter = Duration(seconds: 3);

  bool _titleVisible = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _restartTimer();
  }

  @override
  void didUpdateWidget(WindowTitleBarAutoHide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      // 回到前台：标题栏放下，重新计时。
      if (!_titleVisible) _titleVisible = true;
      _restartTimer();
    } else {
      _hideTimer?.cancel();
      _hideTimer = null;
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _restartTimer() {
    _hideTimer?.cancel();
    if (!widget.active) {
      _hideTimer = null;
      return;
    }
    _hideTimer = Timer(_hideAfter, () {
      if (!mounted) return;
      setState(() => _titleVisible = false);
    });
  }

  /// 窗口内有操作：标题栏放下（已放下则不动），重新计时。
  void _noteActivity() {
    _restartTimer();
    if (!_titleVisible) setState(() => _titleVisible = true);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      // 点按、拖动、滚轮都算操作：任一活动都重新计时。Listener
      // 不拦手势，底下的按钮/列表照常收到事件。
      onPointerDown: (_) => _noteActivity(),
      onPointerMove: (_) => _noteActivity(),
      onPointerSignal: (_) => _noteActivity(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AbsorbPointer(
            // 标题栏收起时整窗不接事件：收起时的点按只放下标题栏，
            // 绝不点透到底下内容。强制藏栏（游戏全屏）时不吸收，
            // 游戏内容直接可点。
            absorbing: !_titleVisible && !widget.hideTitleBar,
            child: Column(
              children: [
                if (_titleVisible && !widget.hideTitleBar) widget.titleBar,
                Expanded(child: widget.child),
              ],
            ),
          ),
          if (!_titleVisible && !widget.hideTitleBar)
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => _noteActivity(),
                child: const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }
}

class Win7WindowFrame extends StatelessWidget {
  const Win7WindowFrame({
    super.key,
    required this.kind,
    required this.onMinimize,
    required this.onClose,
    required this.child,
    this.active = true,
    this.hideTitleBar = false,
  });

  final Win7WindowKind kind;
  final VoidCallback onMinimize;
  final VoidCallback onClose;
  final Widget child;

  /// 窗口是否在前台（见 [WindowTitleBarAutoHide.active]）。
  final bool active;

  /// 强制藏标题栏（游戏全屏用，见 [WindowTitleBarAutoHide.hideTitleBar]）。
  final bool hideTitleBar;

  @override
  Widget build(BuildContext context) {
    return WindowTitleBarAutoHide(
      active: active,
      hideTitleBar: hideTitleBar,
      titleBar: Container(
        height: 32,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF4A90D9), Color(0xFF1E5AA8)],
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(kind.icon, size: 18, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                kind.title,
                key: const ValueKey('win7-window-title'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            InkWell(
              key: const ValueKey('win7-window-minimize'),
              onTap: onMinimize,
              child: Container(
                width: 40,
                height: 28,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(
                  Icons.minimize,
                  size: 16,
                  color: Colors.white,
                ),
              ),
            ),
            InkWell(
              key: const ValueKey('win7-window-close'),
              onTap: onClose,
              child: Container(
                width: 40,
                height: 28,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFE81123).withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(Icons.close, size: 16, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
      child: child,
    );
  }
}
