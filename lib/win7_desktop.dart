import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Win7 主题的桌面外壳：墙纸 + 左侧图标列 + 底部任务栏 + 开始菜单
/// + 窗口标题栏。数值全部取用户 2026-11-16 发来的桌面设计稿精确值
/// （第二份文件）；窗口标题栏是用户 12:10 纠正后新增的，设计稿里
/// 没有，按 Win7 玻璃蓝标题栏做。
///
/// 本文件只负责桌面外壳的纯展示组件；窗口的开关/最小化/状态保留
/// 由 home_screen 里的窗口管理器管（见 _win7Windows）。

/// Win7 窗口种类：一种区一个窗口位（同种区只开一个窗口，再点
/// 只是切到前台，不重复开）。
enum Win7WindowKind {
  library,
  drama,
  live,
  audio,
  novel,
  miniApp,
  multimedia,
  mine,
  actress;

  /// 窗口标题栏与任务栏条目上显示的区名（取桌面图标叫法）。
  String get title => switch (this) {
    Win7WindowKind.library => '片库',
    Win7WindowKind.drama => '短剧',
    Win7WindowKind.live => '直播',
    Win7WindowKind.audio => '听书',
    Win7WindowKind.novel => '阅读',
    Win7WindowKind.miniApp => '小程序',
    Win7WindowKind.multimedia => '我的电脑',
    Win7WindowKind.mine => '我的',
    Win7WindowKind.actress => '女优库',
  };

  IconData get icon => switch (this) {
    Win7WindowKind.library => Icons.video_library,
    Win7WindowKind.drama => Icons.play_circle,
    Win7WindowKind.live => Icons.live_tv,
    Win7WindowKind.audio => Icons.headphones,
    Win7WindowKind.novel => Icons.menu_book,
    Win7WindowKind.miniApp => Icons.apps,
    Win7WindowKind.multimedia => Icons.computer,
    Win7WindowKind.mine => LucideIcons.user,
    Win7WindowKind.actress => Icons.people_alt_outlined,
  };
}

/// 桌面图标默认顺序与内容：7 个。短剧、多媒体（我的电脑）没有
/// 桌面图标、只在开始菜单树里。顺序口径（用户 2026-11-17 令）：
/// 女优库排在“我的”上面；直播图标在片库图标后面（与现有图标同
/// 风格）。用户长按拖拽换过顺序后，以存下来的顺序为准（见
/// [loadDesktopIconOrder]），这份默认顺序只作没存过时的回落。
const List<Win7WindowKind> win7DesktopIcons = [
  Win7WindowKind.audio,
  Win7WindowKind.novel,
  Win7WindowKind.library,
  Win7WindowKind.live,
  Win7WindowKind.miniApp,
  Win7WindowKind.actress,
  Win7WindowKind.mine,
];

/// 桌面图标顺序存 SharedPreferences 的键（Win7/XP 共用同一份顺序）。
const String desktopIconOrderKey = 'moyi_desktop_icon_order';

/// 把存下来的名字表解析成图标顺序：未知名字、重复名字、已不在
/// 桌面列表里的种类一律丢弃；默认列表里有但存表里没有的种类
/// （新加的图标）按默认相对顺序追加到末尾。空/没存过时回默认顺序。
List<Win7WindowKind> resolveDesktopIconOrder(List<String>? stored) {
  final resolved = <Win7WindowKind>[];
  if (stored != null) {
    for (final name in stored) {
      Win7WindowKind? match;
      for (final kind in Win7WindowKind.values) {
        if (kind.name == name) {
          match = kind;
          break;
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

/// 桌面图标列（Win7/XP 共用）：竖排图标，点按开窗口，长按拖拽
/// 换位置；换完的顺序立刻存下来，下次打开还在。图标本体（图标 +
/// 标题两行）由调用方按各自风格提供；拖拽手势、顺序状态与持久化
/// 都收在这里，两边行为一致。
class DesktopIconColumn extends StatefulWidget {
  const DesktopIconColumn({
    super.key,
    required this.keyPrefix,
    required this.onIconTap,
    required this.iconBuilder,
  });

  /// 图标 InkWell 的 key 前缀：Win7 用 'win7-desktop-icon'，XP 用
  /// 'xp-desktop-icon'（旧测试按 key 点图标，前缀不能变）。
  final String keyPrefix;

  final ValueChanged<Win7WindowKind> onIconTap;

  /// 图标本体：图标 + 标题两行（Win7 素色、XP 带阴影，各自画法）。
  final Widget Function(Win7WindowKind kind) iconBuilder;

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

  /// 把 [dragged] 挪到 [target] 所在的位置（目标及之后的图标顺延），
  /// 立刻存盘。拖到自己身上不做事。
  void _move(Win7WindowKind dragged, Win7WindowKind target) {
    if (dragged == target) return;
    final order = List.of(_order);
    final from = order.indexOf(dragged);
    if (from < 0) return;
    order.removeAt(from);
    final to = order.indexOf(target);
    if (to < 0) return;
    order.insert(to, dragged);
    setState(() => _order = order);
    unawaited(saveDesktopIconOrder(order));
  }

  Widget _item(Win7WindowKind kind, {required bool hovered}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Container(
        decoration: hovered
            ? BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        child: InkWell(
          key: ValueKey('${widget.keyPrefix}-${kind.name}'),
          onTap: () => widget.onIconTap(kind),
          child: widget.iconBuilder(kind),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (final kind in _order)
          DragTarget<Win7WindowKind>(
            onWillAcceptWithDetails: (details) => details.data != kind,
            onAcceptWithDetails: (details) => _move(details.data, kind),
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
          ),
      ],
    );
  }
}

/// 桌面：蓝渐变墙纸 + 左侧竖排 7 图标。桌面本身没有任何导航。
class Win7Desktop extends StatelessWidget {
  const Win7Desktop({super.key, required this.onIconTap});

  final ValueChanged<Win7WindowKind> onIconTap;

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
            child: DesktopIconColumn(
              keyPrefix: 'win7-desktop-icon',
              onIconTap: onIconTap,
              iconBuilder: (kind) => Column(
                children: [
                  Icon(kind.icon, size: 42, color: Colors.white),
                  const SizedBox(height: 4),
                  Text(
                    kind.title,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
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

  Widget _renderNode(Win7TreeNode node, String path, double leftPadding) {
    final expanded = _expanded.contains(path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
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
          alignment: Alignment.bottomCenter,
          child: Container(
            height: MediaQuery.of(context).size.height * 0.65,
            width: MediaQuery.of(context).size.width * 0.92,
            margin: const EdgeInsets.only(bottom: 56),
            decoration: BoxDecoration(
              color: Win7Theme.startMenuBg,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
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
          ),
        ),
      ],
    );
  }
}

/// 窗口框：Win7 玻璃蓝标题栏（区名 + 右上角最小化/关闭）+ 内容区。
/// 标题栏按钮是 Win7 风格的半透明小方钮，关闭钮带红底。
class Win7WindowFrame extends StatelessWidget {
  const Win7WindowFrame({
    super.key,
    required this.kind,
    required this.onMinimize,
    required this.onClose,
    required this.child,
  });

  final Win7WindowKind kind;
  final VoidCallback onMinimize;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
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
        Expanded(child: child),
      ],
    );
  }
}
