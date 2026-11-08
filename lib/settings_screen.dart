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
import 'app_update_screen.dart';
import 'clearance_bridge.dart';
import 'crack_config_section.dart';
import 'custom_headers_screen.dart';
import 'jar_bridge.dart';
import 'import_center_screen.dart';
import 'parse_settings_screen.dart';
import 'app_theme.dart';
import 'liquid_glass.dart';
import 'local_store.dart';
import 'py_bridge.dart';
import 'profiles_screen.dart';
import 'remote_widgets.dart';
import 'site_check_screen.dart';
import 'sources_screen.dart';
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
import 'app_layout.dart';
import 'models.dart';
import 'playback_launch_screen.dart';
import 'player_picker.dart';
import 'saved_library.dart';

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

class _SettingsScreenState extends State<SettingsScreen> {
  String _appUpdateSummary = '检查整包新版本';

  @override
  void initState() {
    super.initState();
    ensureTelevisionFocus(context);
    _loadAppUpdateSummary();
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

  void _openSavedDrama(Drama drama) {
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
            onContinue: _openSavedDrama,
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
        color: const Color(0xFFFF765F),
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
        appBar: AppBar(title: const Text('设置与备份')),
        body: body,
      );
    },
  );

  Widget _materialBody() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ListView(
        key: const ValueKey('settings-list'),
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            key: const ValueKey('lan-settings'),
            leading: const Icon(Icons.devices_rounded),
            title: const Text('设备互联'),
            subtitle: const Text('局域网自动同步追剧与推送播放'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => openLanSync(context),
          ),
          ListTile(
            key: const ValueKey('theme-settings-entry'),
            leading: const Icon(Icons.palette_outlined),
            title: const Text('主题设置'),
            subtitle: const Text('模式、风格、主题色与背景'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => ThemeSettingsScreen(store: widget.store),
              ),
            ),
          ),
          ListTile(
            key: const ValueKey('hongguo-device-entry'),
            leading: const Icon(Icons.badge_outlined),
            title: const Text('设备注册档案'),
            subtitle: const Text('红果设备身份与注册状态'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) =>
                    HongguoDeviceScreen(repository: widget.repository),
              ),
            ),
          ),
          if (widget.repository.supportsSourceManagement)
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('站源管理'),
              subtitle: const Text('独立更新、连接与播放检测'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.push(
                context,
                appPageRoute<void>(
                  builder: (_) => SourcesScreen(
                    repository: widget.repository,
                    store: widget.store,
                  ),
                ),
              ),
            ),
          ListTile(
            key: const ValueKey('site-check-entry'),
            leading: const Icon(Icons.fact_check_outlined),
            title: const Text('站点检查'),
            subtitle: const Text('逐站测活，失效站自动隐藏'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => SiteCheckScreen(
                  repository: widget.repository,
                  store: widget.store,
                ),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.code_rounded),
            title: const Text('蜘蛛规则编辑器'),
            subtitle: const Text('编辑、校验与本地试跑 XBPQ 规则'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => RuleEditorScreen(repository: widget.repository),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.video_settings_outlined),
            title: const Text('播放器选择'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => PlayerPickerScreen(store: widget.store),
              ),
            ),
          ),
          ListTile(
            key: const ValueKey('app-update-entry'),
            leading: const Icon(Icons.system_update_outlined),
            title: const Text('软件更新'),
            subtitle: Text(_appUpdateSummary),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(builder: (_) => const AppUpdateScreen()),
            ),
          ),
          ListTile(
            key: const ValueKey('proxy-kernel-entry'),
            leading: const Icon(Icons.shield_outlined),
            title: const Text('代理内核'),
            subtitle: const Text('mihomo 本地代理：内置核、更新内核、订阅、选节点、测速、自启'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) =>
                    ProxyKernelScreen(repository: widget.repository),
              ),
            ),
          ),
          ListTile(
            key: const ValueKey('miniapp-entry'),
            leading: const Icon(Icons.apps_outlined),
            title: const Text('小程序'),
            subtitle: const Text('已安装小程序、市场与小程序设置'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(builder: (_) => const MiniAppHomePage()),
            ),
          ),
          ListTile(
            key: const ValueKey('viewing-experience-entry'),
            leading: const Icon(Icons.visibility_outlined),
            title: const Text('观看体验'),
            subtitle: const Text('沉浸式详情 · TMDB 海报'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => ViewingExperienceScreen(store: widget.store),
              ),
            ),
          ),
          ListTile(
            key: const ValueKey('torrent-entry'),
            leading: const Icon(Icons.download_outlined),
            title: const Text('种子'),
            subtitle: const Text('磁力链接解析与保存 · 引擎未接入'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(builder: (_) => const TorrentHomePage()),
            ),
          ),
          ListTile(
            key: const ValueKey('import-center-entry'),
            leading: const Icon(Icons.library_add_outlined),
            title: const Text('导入中心'),
            subtitle: const Text('TVBox 远程配置与 jar 直导入，分组共存'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => ImportCenterScreen(
                  repository: widget.repository,
                  store: widget.store,
                ),
              ),
            ),
          ),
          ListTile(
            key: const ValueKey('parse-settings-entry'),
            leading: const Icon(Icons.alt_route_rounded),
            title: const Text('解析接口'),
            subtitle: const Text('播放解析接口列表与默认选中'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(builder: (_) => const ParseSettingsScreen()),
            ),
          ),
          ListTile(
            key: const ValueKey('clearance-entry'),
            leading: const Icon(Icons.verified_user_outlined),
            title: const Text('站点验证'),
            subtitle: const Text('为被拦截的站点完成浏览器验证'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => openClearanceFlow(context, widget.repository),
          ),
          ListTile(
            key: const ValueKey('crack-config-entry'),
            leading: const Icon(Icons.shield_outlined),
            title: const Text('过盾与 VIP 配置'),
            subtitle: const Text('导入导出各站过盾与 VIP 配置'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('过盾与 VIP 配置')),
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: CrackConfigSection(repository: widget.repository),
                  ),
                ),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.display_settings_outlined),
            title: const Text('界面模式'),
            subtitle: Text(_displayModeLabel(widget.store.displayMode)),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _chooseDisplayMode,
          ),
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: const Text('用户管理'),
            subtitle: Text('当前：${widget.store.profile.name}'),
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => ProfilesScreen(store: widget.store),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outlined),
            title: Text('关于$appName'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _showAbout,
          ),
          ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: const Text('追剧'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _openSavedLibrary(history: false),
          ),
          ListTile(
            leading: const Icon(Icons.history_outlined),
            title: const Text('最近观看'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _openSavedLibrary(history: true),
          ),
          if (widget.store.profile.admin) ...[
            ListTile(
              leading: const Icon(Icons.settings_ethernet_rounded),
              title: const Text('网络与资源'),
              subtitle: const Text('代理、目录请求间隔与站源目录'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.push(
                context,
                appPageRoute<void>(
                  builder: (_) => ResourceSettingsScreen(
                    repository: widget.repository,
                    store: widget.store,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Future<void> _push(Widget page) =>
      Navigator.push(context, appPageRoute<void>(builder: (_) => page));

  Widget _glassIcon(IconData icon, Color color) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(8),
    ),
    child: SizedBox.square(
      dimension: 30,
      child: Icon(icon, size: 18, color: Colors.white),
    ),
  );

  Widget _glassSection(
    String? header,
    List<Widget> children, {
    String? footer,
  }) {
    final colors = Theme.of(context).colorScheme;
    final caption = TextStyle(
      fontSize: 12,
      letterSpacing: 0,
      color: colors.onSurfaceVariant,
    );
    if (iosDesign(context)) {
      return CupertinoListSection.insetGrouped(
        backgroundColor: Colors.transparent,
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(18),
        ),
        separatorColor: colors.outlineVariant,
        header: header == null ? null : Text(header, style: caption),
        footer: footer == null ? null : Text(footer, style: caption),
        children: children,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(header, style: caption),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Column(children: children),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(footer, style: caption),
            ),
        ],
      ),
    );
  }

  Widget _glassRow({
    Key? key,
    required IconData icon,
    required Color color,
    required String title,
    String? detail,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    if (!iosDesign(context)) {
      return GlassTapTarget(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.zero,
        child: SizedBox(
          height: 62,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                _glassIcon(icon, color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: onTap == null && trailing == null
                              ? colors.onSurface.withValues(alpha: .4)
                              : colors.onSurface,
                        ),
                      ),
                      if (detail != null)
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                ?trailing,
                if (trailing == null && onTap != null)
                  Icon(
                    LucideIcons.chevronRight,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return CupertinoListTile.notched(
      key: key,
      leading: _glassIcon(icon, color),
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
      additionalInfo: detail == null
          ? null
          : ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
      trailing:
          trailing ?? (onTap == null ? null : const CupertinoListTileChevron()),
      backgroundColorActivated: colors.surfaceContainerHigh,
      onTap: onTap,
    );
  }

  Widget _glassBody() {
    final store = widget.store;
    return ListView(
      key: const ValueKey('settings-list'),
      padding: EdgeInsets.fromLTRB(
        0,
        4,
        0,
        32 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        _glassSection('通用', [
          _glassRow(
            key: const ValueKey('lan-settings'),
            icon: LucideIcons.monitorSmartphone,
            color: const Color(0xFF0A84FF),
            title: '设备互联',
            detail: '同步与推送',
            onTap: () => openLanSync(context),
          ),
          if (widget.repository.supportsSourceManagement)
            _glassRow(
              icon: LucideIcons.server,
              color: const Color(0xFF30B0C7),
              title: '站源管理',
              onTap: () => _push(
                SourcesScreen(repository: widget.repository, store: store),
              ),
            ),
          _glassRow(
            key: const ValueKey('site-check-entry'),
            icon: LucideIcons.listChecks,
            color: const Color(0xFF30B0C7),
            title: '站点检查',
            detail: '逐站测活 · 失效自动隐藏',
            onTap: () => _push(
              SiteCheckScreen(repository: widget.repository, store: store),
            ),
          ),
          _glassRow(
            icon: LucideIcons.code,
            color: const Color(0xFFBF5AF2),
            title: '蜘蛛规则编辑器',
            onTap: () => _push(RuleEditorScreen(repository: widget.repository)),
          ),
          _glassRow(
            icon: LucideIcons.clapperboard,
            color: const Color(0xFF64D2FF),
            title: '播放器选择',
            onTap: () => _push(PlayerPickerScreen(store: store)),
          ),
          _glassRow(
            key: const ValueKey('app-update-entry'),
            icon: LucideIcons.arrowDownToLine,
            color: const Color(0xFF0A84FF),
            title: '软件更新',
            detail: _appUpdateSummary,
            onTap: () => _push(const AppUpdateScreen()),
          ),
          _glassRow(
            key: const ValueKey('import-center-entry'),
            icon: LucideIcons.libraryBig,
            color: const Color(0xFF64D2FF),
            title: '导入中心',
            detail: 'TVBox 配置 / jar',
            onTap: () => _push(
              ImportCenterScreen(repository: widget.repository, store: store),
            ),
          ),
          _glassRow(
            key: const ValueKey('parse-settings-entry'),
            icon: LucideIcons.route,
            color: const Color(0xFFFF6482),
            title: '解析接口',
            detail: '默认选中',
            onTap: () => _push(const ParseSettingsScreen()),
          ),
          _glassRow(
            key: const ValueKey('clearance-entry'),
            icon: LucideIcons.shieldCheck,
            color: const Color(0xFF64D2FF),
            title: '站点验证',
            detail: '浏览器过盾回填',
            onTap: () => openClearanceFlow(context, widget.repository),
          ),
          _glassRow(
            key: const ValueKey('python-cf-disguise-entry'),
            icon: LucideIcons.fingerprint,
            color: const Color(0xFF30D158),
            title: 'Python 指纹过盾',
            detail: store.pythonCfDisguise
                ? '已开启 · 按蜘蛛 UA 匹配浏览器'
                : '已关闭 · 只用普通请求',
            trailing: Switch.adaptive(
              value: store.pythonCfDisguise,
              onChanged: (value) async {
                try {
                  await store.setPythonCfDisguise(value);
                  await PyBridge.setCfDisguise(value);
                } catch (error) {
                  if (mounted) {
                    ScaffoldMessenger.maybeOf(
                      context,
                    )?.showSnackBar(SnackBar(content: Text('切换失败：$error')));
                  }
                }
                if (mounted) setState(() {});
              },
            ),
          ),
          _glassRow(
            key: const ValueKey('jar-fingerprint-entry'),
            icon: LucideIcons.fingerprint,
            color: const Color(0xFF30D158),
            title: 'Jar 指纹过盾',
            detail: store.jarFingerprintEnabled
                ? '已开启 · 按蜘蛛 UA 匹配浏览器'
                : '已关闭 · 只用普通请求',
            trailing: Switch.adaptive(
              value: store.jarFingerprintEnabled,
              onChanged: (value) async {
                try {
                  await store.setJarFingerprintEnabled(value);
                  await JarBridge.setJarFingerprint(value);
                } catch (error) {
                  if (mounted) {
                    ScaffoldMessenger.maybeOf(
                      context,
                    )?.showSnackBar(SnackBar(content: Text('切换失败：$error')));
                  }
                }
                if (mounted) setState(() {});
              },
            ),
          ),
          _glassRow(
            key: const ValueKey('custom-headers-entry'),
            icon: LucideIcons.slidersHorizontal,
            color: const Color(0xFF0A84FF),
            title: '自定义请求头',
            detail: store.customHeadersEnabled
                ? '已开启 · ${store.customHeaderRules.length} 条规则'
                : '已关闭',
            onTap: () => _push(CustomHeadersScreen(store: store)),
            trailing: Switch.adaptive(
              value: store.customHeadersEnabled,
              onChanged: (value) async {
                try {
                  await store.setCustomHeadersEnabled(value);
                } catch (error) {
                  if (mounted) {
                    ScaffoldMessenger.maybeOf(
                      context,
                    )?.showSnackBar(SnackBar(content: Text('切换失败：$error')));
                  }
                }
                if (mounted) setState(() {});
              },
            ),
          ),
          _glassRow(
            key: const ValueKey('proxy-kernel-entry'),
            icon: LucideIcons.shield,
            color: const Color(0xFF5E5CE6),
            title: '代理内核',
            detail: 'mihomo 本地代理',
            onTap: () =>
                _push(ProxyKernelScreen(repository: widget.repository)),
          ),
          _glassRow(
            key: const ValueKey('miniapp-entry'),
            icon: LucideIcons.layoutGrid,
            color: const Color(0xFF30B0C7),
            title: '小程序',
            detail: '已安装与市场',
            onTap: () => _push(const MiniAppHomePage()),
          ),
          _glassRow(
            key: const ValueKey('viewing-experience-entry'),
            icon: LucideIcons.sparkles,
            color: const Color(0xFFFF9F0A),
            title: '观看体验',
            detail: '沉浸式 · TMDB 海报',
            onTap: () => _push(ViewingExperienceScreen(store: widget.store)),
          ),
          _glassRow(
            key: const ValueKey('torrent-entry'),
            icon: LucideIcons.download,
            color: const Color(0xFF30D158),
            title: '种子',
            detail: '磁力链接 · 引擎未接入',
            onTap: () => _push(const TorrentHomePage()),
          ),
          _glassRow(
            key: const ValueKey('theme-setting'),
            icon: LucideIcons.palette,
            color: const Color(0xFFAF52DE),
            title: '外观主题',
            detail: AppTheme.label(store.themeMode),
            onTap: () => _push(ThemeSettingsScreen(store: widget.store)),
          ),
          _glassRow(
            key: const ValueKey('hongguo-device-entry'),
            icon: LucideIcons.badge,
            color: const Color(0xFFFF765F),
            title: '设备注册档案',
            detail: '红果设备身份与注册状态',
            onTap: () =>
                _push(HongguoDeviceScreen(repository: widget.repository)),
          ),
          _glassRow(
            icon: LucideIcons.monitor,
            color: const Color(0xFF5E5CE6),
            title: '界面模式',
            detail: _displayModeLabel(store.displayMode),
            onTap: _chooseDisplayMode,
          ),
          _glassRow(
            icon: LucideIcons.users,
            color: const Color(0xFF34C759),
            title: '用户管理',
            detail: store.profile.name,
            onTap: () => _push(ProfilesScreen(store: store)),
          ),
          _glassRow(
            icon: LucideIcons.info,
            color: const Color(0xFF8E8E93),
            title: '关于$appName',
            onTap: _showAbout,
          ),
        ]),
        _glassSection('内容', [
          _glassRow(
            icon: LucideIcons.bookmark,
            color: const Color(0xFFFF9F0A),
            title: '追剧',
            onTap: () => _openSavedLibrary(history: false),
          ),
          _glassRow(
            icon: LucideIcons.history,
            color: const Color(0xFF30B0C7),
            title: '最近观看',
            onTap: () => _openSavedLibrary(history: true),
          ),
        ]),
        if (store.profile.admin) ...[
          _glassSection('管理', [
            _glassRow(
              icon: LucideIcons.network,
              color: const Color(0xFF5E5CE6),
              title: '网络与资源',
              detail: '代理与并发',
              onTap: () => _push(
                ResourceSettingsScreen(
                  repository: widget.repository,
                  store: store,
                ),
              ),
            ),
          ]),
        ],
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
