import 'package:flutter/material.dart';

import 'app_build.dart';

enum HomeZone { drama, vod, midnight, live, audio, novel }

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
}

/// 抽屉头部横向切换的内容板块。
enum DrawerShelf { video, music, reading, comic, miniApp }

extension DrawerShelfLabel on DrawerShelf {
  String get label => switch (this) {
    DrawerShelf.video => '影视',
    DrawerShelf.music => '音乐',
    DrawerShelf.reading => '阅读',
    DrawerShelf.comic => '漫画',
    DrawerShelf.miniApp => '小程序',
  };
}

class SiteSourceBox extends StatelessWidget {
  const SiteSourceBox({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
    this.onDoubleTap,
  });

  final IconData icon;
  final String label;
  final String? description;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = selected ? colors.primary : colors.onSurfaceVariant;
    final tile = ListTile(
      contentPadding: const EdgeInsets.fromLTRB(12, 0, 10, 0),
      minLeadingWidth: 32,
      horizontalTitleGap: 12,
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: selected
              ? colors.primary.withValues(alpha: 0.14)
              : colors.surface.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(icon, size: 18, color: foreground),
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
          color: selected ? colors.primary : colors.onSurface,
        ),
      ),
      subtitle: description == null
          ? null
          : Text(
              description!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 18,
        color: colors.onSurfaceVariant.withValues(alpha: 0.7),
      ),
      selected: selected,
      onTap: onDoubleTap == null ? onTap : null,
    );
    if (onDoubleTap == null) return tile;
    return InkWell(onTap: onTap, onDoubleTap: onDoubleTap, child: tile);
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
    final colors = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: 56,
            endIndent: 12,
            color: colors.outlineVariant.withValues(alpha: 0.35),
          ),
        );
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (hint != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      hint!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Material(
            color: colors.surfaceContainerHighest.withValues(alpha: 0.4),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: colors.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: rows),
          ),
        ],
      ),
    );
  }
}

class AppDrawer extends StatefulWidget {
  const AppDrawer({
    super.key,
    required this.zone,
    required this.midnightActivated,
    required this.currentVersion,
    required this.onZoneSelected,
    required this.onWatchRoom,
    required this.onTool,
    required this.onMinorProtectionChanged,
    required this.onVersionDoubleTap,
  });

  final HomeZone zone;
  final bool midnightActivated;
  final String currentVersion;
  final ValueChanged<HomeZone> onZoneSelected;
  final VoidCallback onWatchRoom;
  final ValueChanged<AppDrawerTool> onTool;
  final ValueChanged<bool> onMinorProtectionChanged;
  final VoidCallback onVersionDoubleTap;

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  DrawerShelf _shelf = DrawerShelf.video;

  String get _versionText => widget.currentVersion.isEmpty
      ? 'v—'
      : 'v${widget.currentVersion} ($appBuild)';

  bool get _videoZone =>
      widget.zone == HomeZone.drama ||
      widget.zone == HomeZone.vod ||
      widget.zone == HomeZone.midnight ||
      widget.zone == HomeZone.live;

  void _selectShelf(DrawerShelf shelf) {
    if (_shelf == shelf) return;
    setState(() => _shelf = shelf);
  }

  Widget _row({
    required IconData icon,
    required String label,
    String? description,
    bool selected = false,
    VoidCallback? onTap,
    VoidCallback? onDoubleTap,
  }) {
    return _DrawerRow(
      icon: icon,
      label: label,
      description: description,
      selected: selected,
      onTap: onTap,
      onDoubleTap: onDoubleTap,
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
    final colors = Theme.of(context).colorScheme;
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
                child: _shelfChip(colors, shelf),
              ),
          ],
        ),
      ),
    );
  }

  Widget _shelfChip(ColorScheme colors, DrawerShelf shelf) {
    final active = _shelf == shelf;
    return InkWell(
      onTap: () => _selectShelf(shelf),
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active
              ? colors.primary
              : colors.surface.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active
                ? colors.primary
                : colors.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        child: Text(
          shelf.label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? colors.onPrimary : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('drawer-header'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 0, 6, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.primaryContainer, colors.surface],
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
                    color: colors.surface,
                    border: Border.all(
                      color: colors.primary.withValues(alpha: 0.25),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.asset(
                    'assets/ant_logo.png',
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Icon(
                      Icons.play_circle_fill_rounded,
                      size: 26,
                      color: colors.primary,
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
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _versionText,
                        key: const ValueKey('drawer-version'),
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
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
                icon: Icons.movie_rounded,
                label: '短剧',
                description: '竖屏短剧 · 按站源聚合',
                target: HomeZone.drama,
              ),
              _zoneRow(
                icon: Icons.movie_filter_rounded,
                label: '点播',
                description: '电影 / 剧集 / 动漫站源',
                target: HomeZone.vod,
              ),
              if (widget.midnightActivated)
                _zoneRow(
                  icon: Icons.nightlight_rounded,
                  label: '午夜区',
                  description: '已解锁 · 开启未成年保护可隐藏',
                  target: HomeZone.midnight,
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
      case DrawerShelf.music:
        return [
          _DrawerSection(
            title: '音乐与音频',
            hint: '音频源来自内容源管理',
            children: [
              _zoneRow(
                icon: Icons.headphones_rounded,
                label: '听书',
                description: '有声书 / 播客 · 音频源',
                target: HomeZone.audio,
              ),
              _row(
                icon: Icons.library_music_rounded,
                label: '音乐源',
                description: '本版未内置音乐板块，导入音频源后在听书区播放',
                onTap: () => widget.onTool(AppDrawerTool.contentSources),
              ),
            ],
          ),
        ];
      case DrawerShelf.reading:
        return [
          _DrawerSection(
            title: '阅读模块',
            hint: '小说与书源',
            children: [
              _zoneRow(
                icon: Icons.menu_book_rounded,
                label: '小说',
                description: '长篇 / 短篇 · 书源聚合阅读',
                target: HomeZone.novel,
              ),
              _row(
                icon: Icons.collections_bookmark_rounded,
                label: '小说源',
                description: '导入 Legado / 蜘蛛书源',
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
      case DrawerShelf.comic:
        return [
          _DrawerSection(
            title: '漫画模块',
            hint: '漫画源在阅读区内识别',
            children: [
              _row(
                icon: Icons.auto_stories_rounded,
                label: '漫画区',
                description: '打开阅读区 · sourceType=2 的源即漫画源',
                selected: widget.zone == HomeZone.novel,
                onTap: () => widget.onZoneSelected(HomeZone.novel),
              ),
              _row(
                icon: Icons.image_rounded,
                label: '漫画源',
                description: '导入 Legado / 漫画源包',
                onTap: () => widget.onTool(AppDrawerTool.contentSources),
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
    return _DrawerSection(
      title: '应用工具',
      hint: '通用配置与管理',
      children: [
        _toolRow(
          AppDrawerTool.sources,
          Icons.list_rounded,
          '站源管理',
          '显示与排序当前站源',
        ),
        _toolRow(
          AppDrawerTool.contentSources,
          Icons.dns_rounded,
          '内容源管理',
          '导入远程配置 / py 站 / 蜘蛛源',
        ),
        _row(
          icon: Icons.system_update_rounded,
          label: '软件更新',
          description: _versionText,
          onTap: () => widget.onTool(AppDrawerTool.appUpdate),
          onDoubleTap: widget.onVersionDoubleTap,
        ),
        _row(
          icon: Icons.download_rounded,
          label: '导入中心',
          description: '本地文件 / 书源 / 配置包',
          onTap: () => widget.onTool(AppDrawerTool.importCenter),
        ),
        _toolRow(
          AppDrawerTool.parse,
          Icons.link_rounded,
          '解析接口',
          '网页解析与直链解析',
        ),
        _toolRow(
          AppDrawerTool.clearance,
          Icons.verified_user_rounded,
          '站点验证',
          'Cloudflare / 人机验证通道',
        ),
        _toolRow(
          AppDrawerTool.proxyKernel,
          Icons.vpn_key_rounded,
          '代理内核',
          '内置代理与线路',
        ),
        _toolRow(
          AppDrawerTool.lanSync,
          Icons.devices_rounded,
          '设备互联',
          '局域网同步与推屏',
        ),
        _toolRow(
          AppDrawerTool.player,
          Icons.play_circle_rounded,
          '播放器选择',
          '切换解码内核',
        ),
        _toolRow(
          AppDrawerTool.ruleEditor,
          Icons.code_rounded,
          '蜘蛛规则编辑器',
          '写 / 调 / 测蜘蛛规则',
        ),
        _toolRow(
          AppDrawerTool.viewingExperience,
          Icons.visibility_outlined,
          '观看体验',
          '弹幕 / 倍速 / 画面比例',
        ),
        _toolRow(
          AppDrawerTool.torrent,
          Icons.download_outlined,
          '种子',
          'BT / 磁力下载',
        ),
        _row(
          icon: Icons.settings_outlined,
          label: '设置',
          description: '账号 / 主题 / 关于',
          onTap: () => widget.onTool(AppDrawerTool.settings),
        ),
      ],
    );
  }

  Widget _guardianSection() {
    final colors = Theme.of(context).colorScheme;
    return _DrawerSection(
      title: '青少年保护',
      hint: '开启后隐藏午夜区',
      children: [
        SwitchListTile.adaptive(
          contentPadding: const EdgeInsets.fromLTRB(12, 0, 10, 0),
          secondary: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: colors.surface.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              Icons.shield_rounded,
              size: 18,
              color: colors.onSurfaceVariant,
            ),
          ),
          title: const Text(
            '未成年保护',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '开启后隐藏午夜区',
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
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
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: muted),
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
    return Drawer(
      backgroundColor: Theme.of(context).colorScheme.surface,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          _header(context),
          ..._shelfSections(),
          _appToolSection(),
          if (widget.midnightActivated) _guardianSection(),
          _footer(),
        ],
      ),
    );
  }
}
