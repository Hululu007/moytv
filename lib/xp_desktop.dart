import 'package:flutter/material.dart';

import 'win7_desktop.dart';

/// XP 主题的桌面外壳：绿色山丘墙纸 + 左侧图标列 + Luna 蓝任务栏
/// + XP 式开始菜单 + 蓝渐变窗口标题栏。
///
/// 外观与 Win7 严格区分（用户 2026-11-16 令“win7是win7，xp系统你
/// 应该知道”）：Win7 是深蓝玻璃墙纸 + 深灰任务栏，XP 是用户发的绿色
/// 山丘墙纸图（assets/xp_wallpaper.jpg）+ Luna 蓝任务栏 + 绿色开始钮 + 浅色开始菜单。只有操作
/// 方式与 Win7 一样（桌面无导航、点图标开窗口、窗口内导航、右上角
/// 最小化/关闭、任务栏切窗、最小化保状态关闭丢状态），窗口管理器
/// 状态机复用 home_screen 里同一套（_win7Windows 等），本文件只
/// 负责 XP 外观的纯展示组件；窗口种类与开始菜单树节点类型也复用
/// Win7 的定义（Win7WindowKind / Win7TreeNode），不另立一套。

/// XP Luna 配色（经典蓝任务栏 + 绿开始钮 + 浅色菜单）。
abstract final class XpTheme {
  static const Color taskBarTop = Color(0xFF3168D5);
  static const Color taskBarMid = Color(0xFF4993E6);
  static const Color taskBarBottom = Color(0xFF2157D6);
  static const Color startGreenTop = Color(0xFF5EAC56);
  static const Color startGreenBottom = Color(0xFF3C873C);
  static const Color titleLeft = Color(0xFF0058E6);
  static const Color titleMid = Color(0xFF3A93FF);
  static const Color titleRight = Color(0xFF127DFF);
  static const Color closeOrange = Color(0xFFD45500);
  static const Color menuHeaderTop = Color(0xFF3A93FF);
  static const Color menuHeaderBottom = Color(0xFF0058E6);
  static const Color menuBody = Colors.white;
  static const Color menuText = Color(0xFF1A1A1A);
  static const Color entryBg = Color(0xFF3F8CF3);
  static const Color entryActiveBg = Color(0xFF1C4FB8);
}

/// 桌面：绿色山丘墙纸 + 左侧图标区（竖排，满一列换一列）。桌面本身没有任何导航。
class XpDesktop extends StatelessWidget {
  const XpDesktop({super.key, required this.onIconTap});

  final ValueChanged<Win7WindowKind> onIconTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('xp-desktop'),
      color: const Color(0xFF3D7DD8),
      child: Stack(
        children: [
          Positioned.fill(
            child: Image.asset('assets/xp_wallpaper.jpg', fit: BoxFit.cover),
          ),
          Positioned(
            top: 40,
            left: 16,
            // bottom 必须给：不给时 Stack 给图标列的高度约束是
            // 无限，满列换列算不出每列个数、图标会一直往下排
            // 进任务栏（与 Win7 同一问题，见 win7_desktop.dart）。
            bottom: 0,
            child: DesktopIconColumn(
              keyPrefix: 'xp-desktop-icon',
              onIconTap: onIconTap,
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
        ],
      ),
    );
  }
}

/// 任务栏：48 高 Luna 蓝渐变条，左起绿色“开始”钮（圆角右缘、
/// 四格小窗格代码色块），后跟已开窗口条目。点已在前台的窗口条目
/// 会把它最小化回桌面（与 Win7 同一语义）。
class XpTaskbar extends StatelessWidget {
  const XpTaskbar({
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
      key: const ValueKey('xp-taskbar'),
      height: 48,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            XpTheme.taskBarTop,
            XpTheme.taskBarMid,
            XpTheme.taskBarBottom,
          ],
          stops: [0.0, 0.12, 1.0],
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          InkWell(
            key: const ValueKey('xp-start-button'),
            onTap: onStartTap,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [XpTheme.startGreenTop, XpTheme.startGreenBottom],
                ),
                borderRadius: BorderRadius.only(
                  topRight: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 四格小窗格：代码画的四个色块，不用任何标志图。
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Column(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: Container(
                                  color: const Color(0xFFF65314),
                                ),
                              ),
                              const SizedBox(width: 2),
                              Expanded(
                                child: Container(
                                  color: const Color(0xFF7CBB00),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: Container(
                                  color: const Color(0xFF00A1F1),
                                ),
                              ),
                              const SizedBox(width: 2),
                              Expanded(
                                child: Container(
                                  color: const Color(0xFFFFBB00),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '开始',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      fontStyle: FontStyle.italic,
                      shadows: [Shadow(color: Colors.black38, blurRadius: 2)],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final kind in openWindows) ...[
                    const SizedBox(width: 4),
                    InkWell(
                      key: ValueKey('xp-taskbar-entry-${kind.name}'),
                      onTap: () => onEntryTap(kind),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: foreground == kind
                              ? XpTheme.entryActiveBg
                              : XpTheme.entryBg,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.45),
                            width: 1,
                          ),
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

/// 开始菜单：遮罩 + 底部弹出的 XP 式菜单（蓝头 + 白身 + 站点树）。
/// 点遮罩关闭；点组节点展开/收起，点叶子开对应窗口并选站。
/// 树数据与 Win7 开始菜单同一份（home_screen 的 _win7TreeGroups）。
class XpStartMenu extends StatefulWidget {
  const XpStartMenu({
    super.key,
    required this.groups,
    required this.onLeafTap,
    required this.onDismiss,
  });

  final List<Win7TreeNode> groups;
  final void Function(Win7WindowKind kind, String? siteId) onLeafTap;
  final VoidCallback onDismiss;

  @override
  State<XpStartMenu> createState() => _XpStartMenuState();
}

class _XpStartMenuState extends State<XpStartMenu> {
  /// 已展开的节点路径（下标串，如 "0-2"）；默认全收起。
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
      backgroundColor: XpTheme.menuBody,
      textColor: XpTheme.menuText,
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
      backgroundColor: XpTheme.menuBody,
      textColor: XpTheme.menuText,
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
            key: ValueKey('xp-tree-node-$path'),
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
            hoverColor: const Color(0x223A93FF),
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
                      color: XpTheme.menuText,
                      size: 18,
                    ),
                  const SizedBox(width: 6),
                  // 组行画该区的图标（箭头后、文字前）；叶子行不画。
                  if (!node.isLeaf && node.kind != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        node.kind!.icon,
                        color: XpTheme.menuText,
                        size: 18,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      node.label,
                      style: const TextStyle(
                        color: XpTheme.menuText,
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
      key: const ValueKey('xp-start-menu'),
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: const ValueKey('xp-start-menu-scrim'),
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
              color: XpTheme.menuBody,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: XpTheme.titleLeft, width: 2),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [XpTheme.menuHeaderTop, XpTheme.menuHeaderBottom],
                    ),
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(10),
                      topRight: Radius.circular(10),
                    ),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.account_circle, color: Colors.white, size: 22),
                      SizedBox(width: 8),
                      Text(
                        '开始菜单',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 左列：导航树，展开/收起行为与原来一字不差。
                      Expanded(
                        flex: 3,
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
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
                      const VerticalDivider(
                        key: ValueKey('xp-start-menu-divider'),
                        width: 1,
                        thickness: 1,
                        color: Color(0xFFB9D1F5),
                      ),
                      // 右列：固定站点栏（图标 + 站名），与电脑开始菜单同式。
                      Expanded(
                        flex: 2,
                        child: StartMenuPinnedColumn(
                          keyPrefix: 'xp-start-menu',
                          pinned: _pinned,
                          onLeafTap: widget.onLeafTap,
                          onRowLongPress: _showPinnedMenu,
                          textColor: XpTheme.menuText,
                          hoverColor: Color(0x223A93FF),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 窗口框：XP 蓝渐变标题栏（区名 + 右上角最小化/关闭）+ 内容区。
/// 关闭钮是红橙圆角钮，最小化是半透明蓝方钮——与 Win7 的玻璃蓝
/// 标题栏 + 深红关闭钮外观区分。
class XpWindowFrame extends StatelessWidget {
  const XpWindowFrame({
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
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [XpTheme.titleLeft, XpTheme.titleMid, XpTheme.titleRight],
            stops: [0.0, 0.55, 1.0],
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
                key: const ValueKey('xp-window-title'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  shadows: [Shadow(color: Colors.black38, blurRadius: 2)],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            InkWell(
              key: const ValueKey('xp-window-minimize'),
              onTap: onMinimize,
              child: Container(
                width: 40,
                height: 28,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.25),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
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
              key: const ValueKey('xp-window-close'),
              onTap: onClose,
              child: Container(
                width: 40,
                height: 28,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: XpTheme.closeOrange,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
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
