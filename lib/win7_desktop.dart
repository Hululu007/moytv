import 'package:flutter/material.dart';

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
  multimedia;

  /// 窗口标题栏与任务栏条目上显示的区名（取桌面图标叫法）。
  String get title => switch (this) {
    Win7WindowKind.library => '片库',
    Win7WindowKind.drama => '短剧',
    Win7WindowKind.live => '直播',
    Win7WindowKind.audio => '听书',
    Win7WindowKind.novel => '阅读',
    Win7WindowKind.miniApp => '小程序',
    Win7WindowKind.multimedia => '我的电脑',
  };

  IconData get icon => switch (this) {
    Win7WindowKind.library => Icons.video_library,
    Win7WindowKind.drama => Icons.play_circle,
    Win7WindowKind.live => Icons.live_tv,
    Win7WindowKind.audio => Icons.headphones,
    Win7WindowKind.novel => Icons.menu_book,
    Win7WindowKind.miniApp => Icons.apps,
    Win7WindowKind.multimedia => Icons.computer,
  };
}

/// 桌面图标顺序与内容（设计稿固定 6 个，直播没有桌面图标、只在
/// 开始菜单树里）。
/// 桌面图标：短剧不在此列（桌面有片库即够用）；短剧窗只走开始菜单。
const List<Win7WindowKind> win7DesktopIcons = [
  Win7WindowKind.audio,
  Win7WindowKind.novel,
  Win7WindowKind.library,
  Win7WindowKind.miniApp,
  Win7WindowKind.multimedia,
];

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

/// 桌面：蓝渐变墙纸 + 左侧竖排 6 图标。桌面本身没有任何导航。
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (final kind in win7DesktopIcons)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: InkWell(
                      key: ValueKey('win7-desktop-icon-${kind.name}'),
                      onTap: () => onIconTap(kind),
                      child: Column(
                        children: [
                          Icon(kind.icon, size: 42, color: Colors.white),
                          const SizedBox(height: 4),
                          Text(
                            kind.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 任务栏：56 高半透明条，左起 Windows 开始钮，后跟已开窗口条目。
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
      height: 56,
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
            margin: const EdgeInsets.only(bottom: 64),
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
          height: 40,
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
                  child: const Icon(
                    Icons.close,
                    size: 16,
                    color: Colors.white,
                  ),
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
