import 'dart:async';

import 'app_page_route.dart';

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';

import 'core_bridge.dart';
import 'app_update.dart';
import 'cloud_drive/cloud_drive_screen.dart';
import 'lan_web/lan_settings_screen.dart';
import 'app_update_screen.dart';
import 'audio_capsule.dart';
import 'floating_window.dart';
import 'clearance_bridge.dart';
import 'crack_config_section.dart';
import 'custom_headers_screen.dart';
import 'jar_bridge.dart';
import 'py_bridge.dart';
import 'import_center_screen.dart';
import 'parse_settings_screen.dart';
import 'liquid_glass.dart';
import 'neon_glass_kit.dart';
import 'app_theme_config.dart';
import 'local_store.dart';
import 'profiles_screen.dart';
import 'remote_widgets.dart';
import 'site_check_screen.dart';
import 'sources_screen.dart';
import 'content_source_screen.dart';
import 'widgets.dart';
import 'resource_settings_screen.dart';
import 'lan_screen.dart';
import 'miniapp/mini_app_home_page.dart';
import 'viewing_experience_screen.dart';
import 'torrent/torrent_home_screen.dart';
import 'proxy_kernel_screen.dart';
import 'rule_editor_screen.dart';
import 'theme_settings_screen.dart';
import 'hongguo_device_screen.dart';
import 'hongguo_login_page.dart';
import 'app_layout.dart';
import 'models.dart';
import 'playback_launch_screen.dart';
import 'player_picker.dart';
import 'saved_library.dart';
import 'detail_screen.dart';
import 'vod_detail_route.dart';

String storageSize(int bytes) {
  if (bytes < 0) return '暂不可用';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.repository,
    required this.store,
    this.embedded = false,
  });
  final AppRepository repository;
  final LocalStore store;

  /// 作为底部导航「设置」tab 嵌入时不自带 Scaffold/AppBar。
  final bool embedded;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  String _appUpdateSummary = '检查整包新版本';
  bool _capsuleGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ensureTelevisionFocus(context);
    _loadAppUpdateSummary();
    _loadCapsuleState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadCapsuleState();
  }

  /// 听书胶囊悬浮窗权限状态：从系统授权页回来时刷新，显示以实测为准。
  Future<void> _loadCapsuleState() async {
    if (!Platform.isAndroid) return;
    try {
      final granted = await AudioCapsule.isPermissionGranted();
      if (mounted) setState(() => _capsuleGranted = granted);
    } catch (_) {}
  }

  /// 手动再开悬浮窗授权：不受“只主动跳一次”标记限制，点一次跳一次。
  Future<void> _requestCapsulePermission() async {
    try {
      await FloatingWindow.requestPermission();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('打开授权页失败')));
      }
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _loadCapsuleState();
  }

  Future<void> _loadAppUpdateSummary() async {
    try {
      final current = await AppUpdateChecker.currentVersion();
      final latest = await AppUpdateChecker.cachedLatestVersion();
      if (!mounted) return;
      setState(() {
        _appUpdateSummary = latest.isEmpty
            ? '当前版本 $current'
            : '当前版本 $current · 最新 $latest';
      });
    } catch (_) {}
  }

  String _displayModeLabel(String mode) => switch (mode) {
    'television' => '电视 / 遥控器',
    'standard' => '手机 / 电脑',
    _ => '自动识别设备',
  };

  Future<void> _chooseDisplayMode() async {
    final selection = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('界面模式'),
        children: [
          RadioGroup<String>(
            groupValue: widget.store.displayMode,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in const {
                  'auto': '自动识别设备',
                  'television': '电视 / 遥控器',
                  'standard': '手机 / 电脑',
                }.entries)
                  RadioListTile<String>(
                    value: mode.key,
                    autofocus: mode.key == widget.store.displayMode,
                    title: Text(mode.value),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selection != null && mounted) {
      await saveUserChange(
        context,
        () => widget.store.setDisplayMode(selection),
      );
    }
  }

  /// 导航样式：改的是当前主题绑定的显示方案，切主题后随新主题的方案走。
  Future<void> _chooseNavStyle() async {
    final store = widget.store;
    final current = store.displayScheme(store.appTheme).navStyle;
    final selection = await showDialog<NavStyle>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('导航样式'),
        children: [
          RadioGroup<NavStyle>(
            groupValue: current,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final style in NavStyle.values)
                  RadioListTile<NavStyle>(
                    value: style,
                    autofocus: style == current,
                    title: Text(style.label),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selection != null && mounted) {
      final scheme = store.displayScheme(store.appTheme);
      await saveUserChange(
        context,
        () => store.setDisplayScheme(
          store.appTheme,
          scheme.copyWith(navStyle: selection),
        ),
      );
    }
  }

  void _openSavedDrama(Drama drama, {bool resume = false}) {
    if (vodOpenAction(
          isVodZone: isVodZoneSource(SourceSite.byId(drama.source)),
          resume: resume,
        ) ==
        VodOpenAction.detail) {
      Navigator.of(context).push(
        appPageRoute<void>(
          settings: const RouteSettings(name: 'detail'),
          builder: (_) => DetailScreen(
            drama: drama,
            repository: widget.repository,
            store: widget.store,
          ),
        ),
      );
      return;
    }
    unawaited(
      openPlaybackDirectly(
        context,
        drama: drama,
        repository: widget.repository,
        store: widget.store,
      ),
    );
  }

  void _openSavedLibrary({required bool history}) {
    Navigator.push<void>(
      context,
      appPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(history ? '最近观看' : '追剧')),
          body: SavedLibrary(
            repository: widget.repository,
            store: widget.store,
            history: history,
            onOpen: _openSavedDrama,
            onContinue: (drama) => _openSavedDrama(drama, resume: true),
          ),
        ),
      ),
    );
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: appName,
      applicationVersion: AppLayout.versionOf(context),
      applicationIcon: Icon(
        glassDesign(context)
            ? LucideIcons.circlePlay
            : Icons.play_circle_filled_rounded,
        size: 48,
        color: AppThemeConfig.of(context).primaryColor,
      ),
      children: [const Text('独立运行，打开即可浏览和播放。观看记录与追剧收藏保存在当前设备。')],
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (_, _) {
      final body = glassDesign(context) ? _glassBody() : _materialBody();
      if (widget.embedded) return body;
      return Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: body,
      );
    },
  );

  /// 设置分组：分类口径对齐参考实现的设置页体系
  /// （播放 / 外观界面 / 网络 / 缓存存储 / 源与规则 / 小程序 / 媒体库 / 设备 / 关于）。
  List<_SettingsGroup> _settingGroups() {
    final store = widget.store;
    final admin = store.profile.admin;
    return [
      _SettingsGroup('播放与画面', [
        _SettingsItem(
          keyName: 'player-entry',
          icon: Icons.play_circle_outline_rounded,
          lucide: LucideIcons.circlePlay,
          title: '播放器选择',
          detail: '解码内核与播放优先级',
          onTap: () => _push(PlayerPickerScreen(store: store)),
        ),
        _SettingsItem(
          keyName: 'viewing-experience-entry',
          icon: Icons.visibility_outlined,
          lucide: LucideIcons.sparkles,
          title: '观看体验',
          detail: '沉浸式详情 · TMDB 海报 · 弹幕与手势',
          onTap: () => _push(ViewingExperienceScreen(store: store)),
        ),
        _SettingsItem(
          keyName: 'parse-settings-entry',
          icon: Icons.alt_route_rounded,
          lucide: LucideIcons.route,
          title: '解析接口',
          detail: '播放解析接口列表与默认选中',
          onTap: () => _push(const ParseSettingsScreen()),
        ),
        if (Platform.isAndroid)
          _SettingsItem(
            keyName: 'audio-capsule-entry',
            icon: Icons.picture_in_picture_alt_rounded,
            lucide: LucideIcons.pictureInPicture2,
            title: '听书胶囊悬浮窗',
            detail: _capsuleGranted
                ? '已开启 · 切后台听书时显示胶囊'
                : '未开启 · 点此打开系统授权页',
            onTap: _requestCapsulePermission,
          ),
      ]),
      _SettingsGroup('外观与界面', [
        _SettingsItem(
          keyName: 'theme-settings-entry',
          icon: Icons.palette_outlined,
          lucide: LucideIcons.palette,
          title: '外观主题',
          detail:
              '当前：${AppThemeConfig.forTheme(store.appTheme).themeName} · 8 套主题',
          onTap: () => _push(
            ThemeSettingsScreen(
              store: store,
              repository: widget.repository,
              sourceId: store.source,
            ),
          ),
        ),
        _SettingsItem(
          keyName: 'nav-style-entry',
          icon: Icons.view_day_outlined,
          lucide: LucideIcons.panelBottom,
          title: '导航样式',
          detail:
              '当前：${store.displayScheme(store.appTheme).navStyle.label} · 随当前主题',
          onTap: _chooseNavStyle,
        ),
        _SettingsItem(
          keyName: 'display-mode-entry',
          icon: Icons.display_settings_outlined,
          lucide: LucideIcons.monitor,
          title: '界面模式',
          detail: _displayModeLabel(store.displayMode),
          onTap: _chooseDisplayMode,
        ),
      ]),
      _SettingsGroup('网络与连接', [
        if (admin)
          _SettingsItem(
            keyName: 'network-resource-entry',
            icon: Icons.settings_ethernet_rounded,
            lucide: LucideIcons.network,
            title: '网络与资源',
            detail: '代理、请求间隔与站源目录',
            onTap: () => _push(
              ResourceSettingsScreen(
                repository: widget.repository,
                store: store,
              ),
            ),
          ),
        _SettingsItem(
          keyName: 'proxy-kernel-entry',
          icon: Icons.shield_outlined,
          lucide: LucideIcons.shield,
          title: '代理内核',
          detail: 'mihomo 本地代理 · 订阅与选节点',
          onTap: () => _push(ProxyKernelScreen(repository: widget.repository)),
        ),
        _SettingsItem(
          keyName: 'clearance-entry',
          icon: Icons.verified_user_outlined,
          lucide: LucideIcons.shieldCheck,
          title: '站点验证',
          detail: '为被拦截的站点完成浏览器验证',
          onTap: () => openClearanceFlow(context, widget.repository),
        ),
        _SettingsItem(
          keyName: 'lan-web-entry',
          icon: Icons.wifi_outlined,
          lucide: LucideIcons.wifi,
          title: '局域网服务',
          detail: '局域网浏览器看片 · 流媒体网关',
          onTap: () => _push(LanWebSettingsScreen(store: store)),
        ),
      ]),
      _SettingsGroup('源与规则', [
        if (widget.repository.supportsSourceManagement)
          _SettingsItem(
            keyName: 'sources-entry',
            icon: Icons.dns_outlined,
            lucide: LucideIcons.server,
            title: '站点区',
            detail: '统一站点区 · 独立更新、连接与播放检测',
            onTap: () => _push(
              SourcesScreen(repository: widget.repository, store: store),
            ),
          ),
        _SettingsItem(
          keyName: 'cloud-drive-entry',
          icon: Icons.cloud_outlined,
          lucide: LucideIcons.cloud,
          title: '网盘登录',
          detail: '115 · 夸克 · 阿里云盘 · 百度网盘',
          onTap: () => _push(CloudDriveScreen(store: store)),
        ),
        _SettingsItem(
          keyName: 'content-sources-entry',
          icon: Icons.layers_outlined,
          lucide: LucideIcons.libraryBig,
          title: '内容源管理',
          detail: '远程配置 / py 站 / 蜘蛛源 / 书源',
          onTap: () => _push(
            ContentSourceScreen(repository: widget.repository, store: store),
          ),
        ),
        _SettingsItem(
          keyName: 'site-check-entry',
          icon: Icons.fact_check_outlined,
          lucide: LucideIcons.listChecks,
          title: '站点检查',
          detail: '逐站测活，失效站自动隐藏',
          onTap: () => _push(
            SiteCheckScreen(repository: widget.repository, store: store),
          ),
        ),
        _SettingsItem(
          keyName: 'rule-editor-entry',
          icon: Icons.code_rounded,
          lucide: LucideIcons.code,
          title: '蜘蛛规则编辑器',
          detail: '编辑、校验与本地试跑 XBPQ 规则',
          onTap: () => _push(RuleEditorScreen(repository: widget.repository)),
        ),
        _SettingsItem(
          keyName: 'crack-config-entry',
          icon: Icons.security_rounded,
          lucide: LucideIcons.fingerprint,
          title: '过盾、指纹与请求头',
          detail: '指纹过盾开关 · 自定义请求头 · VIP 配置',
          onTap: () => _push(
            _AntiBotScreen(repository: widget.repository, store: store),
          ),
        ),
      ]),
      _SettingsGroup('存储与缓存', [
        _SettingsItem(
          keyName: 'storage-entry',
          icon: Icons.sd_storage_outlined,
          lucide: LucideIcons.arrowDownToLine,
          title: '存储空间',
          detail: '下载目录、占用与迁移',
          onTap: () =>
              _push(StorageScreen(repository: widget.repository, store: store)),
        ),
        _SettingsItem(
          keyName: 'import-center-entry',
          icon: Icons.library_add_outlined,
          lucide: LucideIcons.download,
          title: '导入中心',
          detail: 'TVBox 远程配置与 jar 直导入',
          onTap: () => _push(
            ImportCenterScreen(repository: widget.repository, store: store),
          ),
        ),
        _SettingsItem(
          keyName: 'torrent-entry',
          icon: Icons.download_outlined,
          lucide: LucideIcons.download,
          title: '种子',
          detail: '磁力解析、文件导入与播放',
          onTap: () => _push(
            TorrentHomePage(repository: widget.repository, store: widget.store),
          ),
        ),
      ]),
      _SettingsGroup('小程序', [
        _SettingsItem(
          keyName: 'miniapp-entry',
          icon: Icons.widgets_outlined,
          lucide: LucideIcons.layoutGrid,
          title: '小程序',
          detail: '已安装、市场与小程序设置',
          onTap: () => _push(const MiniAppHomePage()),
        ),
      ]),
      _SettingsGroup('媒体库', [
        _SettingsItem(
          keyName: 'saved-drama-entry',
          icon: Icons.bookmark_outline_rounded,
          lucide: LucideIcons.bookmark,
          title: '追剧',
          detail: '收藏的剧集与更新',
          onTap: () => _openSavedLibrary(history: false),
        ),
        _SettingsItem(
          keyName: 'saved-history-entry',
          icon: Icons.history_rounded,
          lucide: LucideIcons.history,
          title: '最近观看',
          detail: '本机观看记录与续播',
          onTap: () => _openSavedLibrary(history: true),
        ),
      ]),
      _SettingsGroup('设备', [
        _SettingsItem(
          keyName: 'lan-settings',
          icon: Icons.devices_rounded,
          lucide: LucideIcons.monitorSmartphone,
          title: '设备互联',
          detail: '局域网同步追剧与推送播放',
          onTap: () => openLanSync(context),
        ),
        _SettingsItem(
          keyName: 'hongguo-device-entry',
          icon: Icons.badge_outlined,
          lucide: LucideIcons.badge,
          title: '设备注册档案',
          detail: '设备身份与注册状态',
          onTap: () =>
              _push(HongguoDeviceScreen(repository: widget.repository)),
        ),
        _SettingsItem(
          keyName: 'hongguo-account-entry',
          icon: Icons.account_circle_outlined,
          lucide: LucideIcons.user,
          title: '红果账号',
          detail: '手机号 / 扫码登录、账号收藏与云端记录',
          onTap: () => _push(
            HongguoAccountPage(repository: widget.repository, store: store),
          ),
        ),
      ]),
      _SettingsGroup('关于与更新', [
        _SettingsItem(
          keyName: 'profiles-entry',
          icon: Icons.people_outline_rounded,
          lucide: LucideIcons.users,
          title: '用户管理',
          detail: '当前：${store.profile.name}',
          onTap: () => _push(ProfilesScreen(store: store)),
        ),
        _SettingsItem(
          keyName: 'app-update-entry',
          icon: Icons.system_update_outlined,
          lucide: LucideIcons.arrowDownToLine,
          title: '软件更新',
          detail: _appUpdateSummary,
          onTap: () => _push(const AppUpdateScreen()),
        ),
        _SettingsItem(
          keyName: 'about-entry',
          icon: Icons.info_outlined,
          lucide: LucideIcons.info,
          title: '关于$appName',
          detail: '版本与许可',
          onTap: _showAbout,
        ),
      ]),
    ];
  }

  Widget _materialBody() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          key: const ValueKey('settings-list'),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
          children: [
            for (final group in _settingGroups())
              if (group.items.isNotEmpty) ...[
                NeonSectionTitle(group.title),
                NeonRowGroup(
                  children: [
                    for (final item in group.items)
                      NeonRow(
                        key: ValueKey(item.keyName),
                        icon: item.icon,
                        title: item.title,
                        detail: item.detail.isEmpty ? null : item.detail,
                        onTap: item.onTap,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
          ],
        ),
      ),
    );
  }

  Future<void> _push(Widget page) =>
      Navigator.push(context, appPageRoute<void>(builder: (_) => page));
  Widget _glassIcon(IconData icon) =>
      NeonIconTile(icon: icon, size: 30, iconSize: 18, radius: 8);

  Widget _glassSection(
    String? header,
    List<Widget> children, {
    String? footer,
  }) {
    final config = AppThemeConfig.of(context);
    final caption = TextStyle(
      fontSize: 12,
      letterSpacing: 0,
      color: config.textSecondary,
    );
    if (iosDesign(context)) {
      return CupertinoListSection.insetGrouped(
        backgroundColor: Colors.transparent,
        decoration: BoxDecoration(
          color: config.surfaceColor,
          borderRadius: BorderRadius.circular(18),
        ),
        separatorColor: config.dividerColor,
        header: header == null ? null : Text(header, style: caption),
        footer: footer == null ? null : Text(footer, style: caption),
        children: children,
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header != null) NeonSectionTitle(header),
          NeonRowGroup(children: children),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(footer, style: caption),
            ),
        ],
      ),
    );
  }

  Widget _glassRow({
    Key? key,
    required IconData icon,
    required String title,
    String? detail,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    if (!iosDesign(context)) {
      return NeonRow(
        key: key,
        icon: icon,
        title: title,
        detail: detail,
        trailing: trailing,
        onTap: onTap,
      );
    }
    return CupertinoListTile.notched(
      key: key,
      leading: _glassIcon(icon),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          letterSpacing: 0,
          color: onTap == null && trailing == null
              ? colors.onSurface.withValues(alpha: .4)
              : colors.onSurface,
        ),
      ),
      subtitle: detail == null
          ? null
          : Text(
              detail,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
      trailing:
          trailing ?? (onTap == null ? null : const CupertinoListTileChevron()),
      backgroundColorActivated: colors.surfaceContainerHigh,
      onTap: onTap,
    );
  }

  Widget _glassBody() {
    return ListView(
      key: const ValueKey('settings-list'),
      padding: EdgeInsets.fromLTRB(
        0,
        4,
        0,
        32 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        for (final group in _settingGroups())
          if (group.items.isNotEmpty)
            _glassSection(group.title, [
              for (final item in group.items)
                _glassRow(
                  key: ValueKey(item.keyName),
                  icon: item.lucide,
                  title: item.title,
                  detail: item.detail.isEmpty ? null : item.detail,
                  onTap: item.onTap,
                ),
            ]),
      ],
    );
  }
}

class StorageScreen extends StatefulWidget {
  const StorageScreen({
    super.key,
    required this.repository,
    required this.store,
  });
  final AppRepository repository;
  final LocalStore store;
  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  Map<String, dynamic>? _info;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final info = await widget.repository.storage();
      if (mounted) {
        setState(() {
          _info = info;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _move() async {
    String? parent;
    if (Platform.isAndroid || Platform.isIOS) {
      final support = await getApplicationSupportDirectory();
      final directories = <String, String>{support.path: '应用内部存储'};
      if (Platform.isAndroid) {
        final external = await getExternalStorageDirectories() ?? [];
        for (var i = 0; i < external.length; i++) {
          directories[external[i].path] = i == 0
              ? '设备共享存储（应用目录）'
              : 'SD 卡 ${i + 1}（应用目录）';
        }
      } else {
        final documents = await getApplicationDocumentsDirectory();
        directories[documents.path] = '文件 App 可见目录';
      }
      if (!mounted) return;
      parent = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('选择下载位置'),
          children: [
            for (final entry in directories.entries)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, entry.key),
                child: Text(entry.value),
              ),
          ],
        ),
      );
    } else {
      parent = await FilePicker.getDirectoryPath(dialogTitle: '选择下载保存位置');
    }
    if (parent == null || !mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('迁移已下载内容？'),
        content: Text(
          '将视频、合并成品及导出内容迁移到：\n$parent\n\n下载会先暂停，复制成功后清理旧目录。请保证目标有足够空间，并在完成后继续下载。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('迁移'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.moveDownloads(parent);
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('下载目录与空间')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (_info != null) ...[
                Text(
                  '已使用 ${storageSize((_info!['bytes'] as num?)?.toInt() ?? 0)}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  '剩余 ${storageSize((_info!['free'] as num?)?.toInt() ?? -1)} · ${_info!['files'] ?? 0} 个文件',
                ),
                const SizedBox(height: 24),
                const Text('当前下载目录'),
                const SizedBox(height: 8),
                SelectableText(_info!['directory'] as String? ?? ''),
                TextButton.icon(
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: _info!['directory'] as String? ?? ''),
                  ),
                  icon: const Icon(Icons.copy),
                  label: const Text('复制路径'),
                ),
                const SizedBox(height: 20),
                const Text('在下载页删除不需要的分集，可释放空间。'),
              ],
              if (_busy || (_info == null && _error == null))
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: LinearProgressIndicator(),
                ),
              if (_busy) const Text('正在迁移，请保持应用运行…'),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(_error!),
                ),
              if (widget.store.profile.admin)
                FilledButton.icon(
                  onPressed: _busy ? null : _move,
                  icon: const Icon(Icons.drive_file_move_outline),
                  label: const Text('更改并迁移目录'),
                ),
              TextButton(
                onPressed: _busy ? null : _refresh,
                child: const Text('刷新用量'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 设置页分组与条目：只做展示层描述，实际页面在 [_SettingsScreenState] 里绑定。
class _SettingsGroup {
  const _SettingsGroup(this.title, this.items);

  final String title;
  final List<_SettingsItem> items;
}

class _SettingsItem {
  const _SettingsItem({
    required this.keyName,
    required this.icon,
    required this.lucide,
    required this.title,
    required this.onTap,
    this.detail = '',
  });

  final String keyName;
  final IconData icon;
  final IconData lucide;
  final String title;
  final String detail;
  final VoidCallback onTap;
}

/// 过盾、指纹与请求头：把原先散在设置平铺列表里的三项收进一个页面。
///
/// 参考实现的同类项集中在「网络 / 反爬」一处，这里同样只做归拢，
/// 底层开关与存储字段一个不动（pythonCfDisguise / jarFingerprintEnabled /
/// customHeaderRules），所以升级后原配置继续生效。
class _AntiBotScreen extends StatefulWidget {
  const _AntiBotScreen({required this.repository, required this.store});

  final AppRepository repository;
  final LocalStore store;

  @override
  State<_AntiBotScreen> createState() => _AntiBotScreenState();
}

class _AntiBotScreenState extends State<_AntiBotScreen> {
  Future<void> _toggle(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('切换失败：$error')));
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return Scaffold(
      appBar: AppBar(title: const Text('过盾、指纹与请求头')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          NeonRowGroup(
            children: [
              NeonRow(
                key: const ValueKey('python-cf-disguise-entry'),
                icon: LucideIcons.fingerprint,
                title: 'Python 指纹过盾',
                detail: store.pythonCfDisguise
                    ? '已开启 · 按蜘蛛 UA 匹配浏览器'
                    : '已关闭 · 只用普通请求',
                onTap: () => _toggle(() async {
                  final next = !store.pythonCfDisguise;
                  await store.setPythonCfDisguise(next);
                  await PyBridge.setCfDisguise(next);
                }),
                trailing: NeonSwitch(
                  value: store.pythonCfDisguise,
                  onChanged: (value) => _toggle(() async {
                    await store.setPythonCfDisguise(value);
                    await PyBridge.setCfDisguise(value);
                  }),
                ),
              ),
              NeonRow(
                key: const ValueKey('jar-fingerprint-entry'),
                icon: LucideIcons.fingerprint,
                title: 'Jar 指纹过盾',
                detail: store.jarFingerprintEnabled
                    ? '已开启 · 按蜘蛛 UA 匹配浏览器'
                    : '已关闭 · 只用普通请求',
                onTap: () => _toggle(() async {
                  final next = !store.jarFingerprintEnabled;
                  await store.setJarFingerprintEnabled(next);
                  await JarBridge.setJarFingerprint(next);
                }),
                trailing: NeonSwitch(
                  value: store.jarFingerprintEnabled,
                  onChanged: (value) => _toggle(() async {
                    await store.setJarFingerprintEnabled(value);
                    await JarBridge.setJarFingerprint(value);
                  }),
                ),
              ),
              NeonRow(
                key: const ValueKey('custom-headers-entry'),
                icon: LucideIcons.slidersHorizontal,
                title: '自定义请求头',
                detail: store.customHeadersEnabled
                    ? '已开启 · ${store.customHeaderRules.length} 条规则'
                    : '已关闭',
                onTap: () => Navigator.push(
                  context,
                  appPageRoute<void>(
                    builder: (_) => CustomHeadersScreen(store: store),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          CrackConfigSection(repository: widget.repository),
        ],
      ),
    );
  }
}
