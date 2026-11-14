import 'package:flutter/material.dart';

import 'app_build.dart';
import 'app_theme_config.dart';
import 'neon/neon_ui.dart';
import 'neon_glass_kit.dart';
import 'ui_style.dart';

enum HomeZone { library, live, audio, novel }

enum AppDrawerTool {
  sources,
  settings,
  player,
  appUpdate,
  importCenter,
  contentSources,
  parse,
  clearance,
  proxyKernel,
  lanSync,
  ruleEditor,
  miniApp,
  viewingExperience,
  torrent,
  themeSettings,
}

/// 抽屉头部横向切换的内容板块。
enum DrawerShelf { video, reading, miniApp }

extension DrawerShelfLabel on DrawerShelf {
  String get label => switch (this) {
    DrawerShelf.video => '影视',
    DrawerShelf.reading => '阅读',
    DrawerShelf.miniApp => '小程序',
  };
}

class SiteSourceBox extends StatelessWidget {
  const SiteSourceBox({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: config.unselectedBg,
          border: Border.all(color: config.dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.expand_more_rounded, size: 16),
          ],
        ),
      ),
    );
  }
}

/// 单个图标 + 主标题 + 小字描述 + 右侧箭头的行项。
class _DrawerRow extends StatelessWidget {
  const _DrawerRow({
    required this.icon,
    required this.label,
    required this.selected,
    this.description,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? description;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final config = AppThemeConfig.of(context);
    final tile = ListTile(
      contentPadding: const EdgeInsets.fromLTRB(12, 0, 10, 0),
      minLeadingWidth: 32,
      horizontalTitleGap: 12,
      leading: selected
          ? NeonIconTile(icon: icon, size: 32, iconSize: 18, radius: 9)
          : Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: config.unselectedBg,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 18, color: config.textSecondary),
            ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
          color: selected ? config.primaryColor : config.textPrimary,
        ),
      ),
      subtitle: description == null
          ? null
          : Text(
              description!,
              style: TextStyle(fontSize: 11, color: config.textSecondary),
            ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 18,
        color: config.textSecondary.withValues(alpha: 0.7),
      ),
      selected: selected,
      onTap: onTap,
    );
    return tile;
  }
}

/// 分组标题 + 圆角卡片容器包裹的一组行项。
class _DrawerSection extends StatelessWidget {
  const _DrawerSection({
    required this.title,
    required this.children,
    this.hint,
  });

  final String title;
  final String? hint;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NeonSectionTitle(
            title,
            hint: hint,
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          ),
          NeonRowGroup(children: children),
        ],
      ),
    );
  }
}

class AppDrawer extends StatefulWidget {
  const AppDrawer({
    super.key,
    required this.zone,
    required this.currentVersion,
    required this.onZoneSelected,
    required this.onWatchRoom,
    required this.onTool,
    required this.onMinorProtectionChanged,
    this.appTheme = AppThemeMode.purpleNeon,
  });

  final HomeZone zone;
  final String currentVersion;
  final ValueChanged<HomeZone> onZoneSelected;
  final VoidCallback onWatchRoom;
  final ValueChanged<AppDrawerTool> onTool;
  final ValueChanged<bool> onMinorProtectionChanged;

  /// 当前全局主题：只用于主题切换行的“当前：X”显示，
  /// 调用方（首页）从 LocalStore 传入真实值。
  final AppThemeMode appTheme;

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  late DrawerShelf _shelf;

  @override
  void initState() {
    super.initState();
    // 分区键选中态与当前内容区一致：打开抽屉时就选中对的分区。
    _shelf = _shelfForZone(widget.zone);
  }

  static DrawerShelf _shelfForZone(HomeZone zone) => switch (zone) {
    HomeZone.library || HomeZone.live => DrawerShelf.video,
    HomeZone.audio || HomeZone.novel => DrawerShelf.reading,
  };

  String get _versionText => widget.currentVersion.isEmpty
      ? 'v—'
      : 'v${widget.currentVersion} ($appBuild)';

  bool get _videoZone =>
      widget.zone == HomeZone.library || widget.zone == HomeZone.live;

  void _selectShelf(DrawerShelf shelf) {
    if (_shelf == shelf) return;
    setState(() => _shelf = shelf);
    // 分区键与内容区联动：点选立即切换到底层内容区（回调里有关抽屉），
    // 不只换抽屉内部的分组列表。
    switch (shelf) {
      case DrawerShelf.video:
        widget.onZoneSelected(HomeZone.library);
      case DrawerShelf.reading:
        widget.onZoneSelected(HomeZone.novel);
      case DrawerShelf.miniApp:
        widget.onTool(AppDrawerTool.miniApp);
    }
  }

  Widget _row({
    required IconData icon,
    required String label,
    String? description,
    bool selected = false,
    VoidCallback? onTap,
  }) {
    return _DrawerRow(
      icon: icon,
      label: label,
      description: description,
      selected: selected,
      onTap: onTap,
    );
  }

  Widget _zoneRow({
    required IconData icon,
    required String label,
    required String description,
    required HomeZone target,
  }) {
    return _row(
      icon: icon,
      label: label,
      description: description,
      selected: widget.zone == target,
      onTap: () => widget.onZoneSelected(target),
    );
  }

  Widget _toolRow(
    AppDrawerTool tool,
    IconData icon,
    String label,
    String description,
  ) {
    return _row(
      icon: icon,
      label: label,
      description: description,
      onTap: () => widget.onTool(tool),
    );
  }

  Widget _shelfTabs(BuildContext context) {
    return SizedBox(
      height: 34,
      child: SingleChildScrollView(
        key: const ValueKey('drawer-shelf-tabs'),
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final shelf in DrawerShelf.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _shelfChip(shelf),
              ),
          ],
        ),
      ),
    );
  }

  Widget _shelfChip(DrawerShelf shelf) {
    return NeonCapsule(
      label: shelf.label,
      selected: _shelf == shelf,
      onTap: () => _selectShelf(shelf),
    );
  }

  Widget _header(BuildContext context) {
    final config = AppThemeConfig.of(context);
    return Container(
      key: const ValueKey('drawer-header'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 0, 6, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            config.primaryColor.withValues(alpha: 0.30),
            config.secondaryColor.withValues(alpha: 0.12),
            config.surfaceColor.withValues(alpha: 0),
          ],
          stops: const [0, .55, 1],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 18),
            Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: config.surfaceColor,
                    border: Border.all(
                      color: config.primaryColor.withValues(alpha: 0.25),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.asset(
                    'assets/ant_logo.png',
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Icon(
                      Icons.play_circle_fill_rounded,
                      size: 26,
                      color: config.primaryColor,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        appName,
                        key: const ValueKey('drawer-app-name'),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: config.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _versionText,
                        key: const ValueKey('drawer-version'),
                        style: TextStyle(
                          fontSize: 11,
                          color: config.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  iconSize: 20,
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _shelfTabs(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _shelfSections() {
    switch (_shelf) {
      case DrawerShelf.video:
        return [
          _DrawerSection(
            title: '影视模块',
            hint: _videoZone ? '当前所在板块' : null,
            children: [
              _zoneRow(
                icon: Icons.video_library_rounded,
                label: '片库',
                description: '短剧与点播站源 · 切站看',
                target: HomeZone.library,
              ),
              _zoneRow(
                icon: Icons.live_tv_rounded,
                label: '直播',
                description: 'IPTV / 直播源频道',
                target: HomeZone.live,
              ),
              _row(
                icon: Icons.meeting_room_rounded,
                label: '一起看房间',
                description: '多人同步观影房间',
                onTap: widget.onWatchRoom,
              ),
            ],
          ),
        ];
      case DrawerShelf.reading:
        return [
          _DrawerSection(
            title: '阅读模块',
            hint: '小说 · 漫画 · 听书',
            children: [
              _zoneRow(
                icon: Icons.menu_book_rounded,
                label: '小说',
                description: '长篇 / 短篇 · 书源聚合阅读',
                target: HomeZone.novel,
              ),
              _row(
                icon: Icons.auto_stories_rounded,
                label: '漫画区',
                description: '打开阅读区 · sourceType=2 的源即漫画源',
                selected: widget.zone == HomeZone.novel,
                onTap: () => widget.onZoneSelected(HomeZone.novel),
              ),
              _zoneRow(
                icon: Icons.headphones_rounded,
                label: '听书',
                description: '有声书 / 播客 · 音频源',
                target: HomeZone.audio,
              ),
              _row(
                icon: Icons.collections_bookmark_rounded,
                label: '小说源',
                description: '导入 Legado / 蜘蛛书源',
                onTap: () => widget.onTool(AppDrawerTool.contentSources),
              ),
              _row(
                icon: Icons.image_rounded,
                label: '漫画源',
                description: '导入 Legado / 漫画源包',
                onTap: () => widget.onTool(AppDrawerTool.contentSources),
              ),
              _row(
                icon: Icons.folder_open_rounded,
                label: '书源文件',
                description: '本地 txt / epub / 书源包',
                onTap: () => widget.onTool(AppDrawerTool.importCenter),
              ),
            ],
          ),
        ];
      case DrawerShelf.miniApp:
        return [
          _DrawerSection(
            title: '小程序模块',
            hint: '内置小程序容器',
            children: [
              _row(
                icon: Icons.apps_rounded,
                label: '小程序面板',
                description: '运行内置小程序与网页应用',
                onTap: () => widget.onTool(AppDrawerTool.miniApp),
              ),
              _row(
                icon: Icons.inventory_2_rounded,
                label: '小程序包',
                description: '导入 zip 小程序包',
                onTap: () => widget.onTool(AppDrawerTool.importCenter),
              ),
            ],
          ),
        ];
    }
  }

  Widget _appToolSection() {
    // 设置项统一收进「设置」页（分类口径对齐参考实现），抽屉只留常用快捷入口。
    return _DrawerSection(
      title: '应用工具',
      hint: '常用入口 · 完整设置见「设置」',
      children: [
        _toolRow(
          AppDrawerTool.sources,
          Icons.list_rounded,
          '站点区',
          '统一站点区 · 全部站源呈现与管理',
        ),
        _toolRow(
          AppDrawerTool.contentSources,
          Icons.dns_rounded,
          '内容源管理',
          '导入远程配置 / py 站 / 蜘蛛源',
        ),
        _toolRow(
          AppDrawerTool.player,
          Icons.play_circle_rounded,
          '播放器选择',
          '切换解码内核',
        ),
        _row(
          icon: Icons.library_add_outlined,
          label: '导入中心',
          description: '本地文件 / 书源 / 配置包',
          onTap: () => widget.onTool(AppDrawerTool.importCenter),
        ),
        _row(
          icon: Icons.system_update_rounded,
          label: '软件更新',
          description: _versionText,
          onTap: () => widget.onTool(AppDrawerTool.appUpdate),
        ),
        _toolRow(
          AppDrawerTool.themeSettings,
          Icons.palette_outlined,
          '主题切换',
          '当前：${AppThemeConfig.forTheme(widget.appTheme).themeName} · 8 套主题',
        ),
        _row(
          icon: Icons.settings_outlined,
          label: '设置',
          description: '播放 / 外观 / 网络 / 存储 / 关于',
          onTap: () => widget.onTool(AppDrawerTool.settings),
        ),
      ],
    );
  }

  Widget _guardianSection() {
    final config = AppThemeConfig.of(context);
    return _DrawerSection(
      title: '青少年保护',
      hint: '开启后隐藏成人站并切回短剧站',
      children: [
        SwitchListTile.adaptive(
          contentPadding: const EdgeInsets.fromLTRB(12, 0, 10, 0),
          secondary: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: config.unselectedBg,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              Icons.shield_rounded,
              size: 18,
              color: config.textSecondary,
            ),
          ),
          title: Text(
            '未成年保护',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: config.textPrimary,
            ),
          ),
          subtitle: Text(
            '开启后隐藏成人站并切回短剧站',
            style: TextStyle(fontSize: 11, color: config.textSecondary),
          ),
          value: false,
          onChanged: (value) {
            if (value) widget.onMinorProtectionChanged(true);
          },
        ),
      ],
    );
  }

  Widget _footer() {
    final colors = Theme.of(context).colorScheme;
    final muted = colors.onSurfaceVariant.withValues(alpha: 0.75);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 26),
      child: Column(
        children: [
          Text(
            '$appName · $_versionText',
            key: const ValueKey('drawer-footer'),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: muted,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '© ${DateTime.now().year} $appName 保留所有权利',
            style: TextStyle(fontSize: 10, color: muted),
          ),
          const SizedBox(height: 3),
          Text(
            '仅供个人学习与研究使用',
            style: TextStyle(
              fontSize: 10,
              color: colors.onSurfaceVariant.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = ListView(
      padding: EdgeInsets.zero,
      children: [
        _header(context),
        ..._shelfSections(),
        _appToolSection(),
        _guardianSection(),
        _footer(),
      ],
    );
    if (!neonStyleActive) {
      // 非霓虹风格：抽屉底与片库区（Scaffold 背景）用同一个主题背景色。
      return Drawer(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        child: content,
      );
    }
    // 霓虹风格：抽屉跟片库区 / 内容区同一套氛围光（NeonBackdrop.app），
    // 不再是一块单独的纯色板，也不再是自己一份参数。
    return Drawer(
      key: const ValueKey('drawer-neon'),
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(24)),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(24)),
        child: NeonBackdrop.app(child: content),
      ),
    );
  }
}
