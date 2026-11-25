import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core_bridge.dart' show AppFailure;
import '../idj_plugin_store.dart';

/// 小程序内「插件」tab（设计 §4）：已安装 / 安装入口 / 订阅 / 更新检查
/// 四区。只作 tab 内容，不独立导航、不注册路由。
///
/// 只经 [IdjPluginStore] 调数据，不直接写盘、不直接调 Go。
/// 安装/卸载/启用/停用后调 `IdjPluginRegistry.onRegistryChanged`
///（主入口已接到 `LocalStore.refreshSiteRegistry`）让片库立即刷新，
/// 再刷新 tab 本页。
///
/// 分区文案一律按 store 给出的 section 走（`IdjPluginRegistry` 的
/// `shortDramaPluginIds` / `adultDisplayPluginIds`），不要自己再按
/// `manifest.adult` 判：4 个真包的 adult 全是 true，只按它推会把
/// 橙果/爱果也判进午夜组。

/// 插件类型展示名。
String idjTypeLabel(String type) => switch (type) {
  'shortdrama' => '短剧',
  'video' => '视频',
  'comic' => '漫画',
  'live' => '直播',
  _ => type,
};

/// 已安装行的显示名：注册进片库用的那个名（含 🔞 前缀规则）。
String idjDisplayName(IdjInstalledPlugin item) {
  final manifest = item.manifest;
  if (manifest != null) {
    return IdjPluginRegistry.siteForPlugin(
      manifest: manifest,
      siteKey: item.entry.siteKey,
    ).name;
  }
  if (IdjPluginRegistry.adultDisplayPluginIds.contains(item.entry.pluginId)) {
    return '🔞${item.entry.name}';
  }
  return item.entry.name;
}

/// 装完结果提示里的分区文案（原设计 §4.3 给安装确认 sheet 用，
/// 2026-11-25 免确认后改挂在装完的提示里，用户 2026-11-24 定）：
/// 按分区（section）写，不按 adult 字段写。
/// 短剧分区写短剧区文案；视频分区且带 🔞 前缀写午夜组文案；
/// 视频分区无 🔞 前缀不加提示行（回 null）。
String? idjSectionNoteForManifest(IdjPluginManifest manifest) {
  final isDrama =
      IdjPluginRegistry.shortDramaPluginIds.contains(manifest.id) ||
      manifest.type == 'shortdrama';
  if (isDrama) return '短剧插件：装好后进短剧区，可在片库短剧区找到';
  if (IdjPluginRegistry.adultDisplayPluginIds.contains(manifest.id)) {
    return '成人插件：装好后进午夜组，默认不对新用户显示';
  }
  return null;
}

Future<void> _showIdjError(BuildContext context, String message) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('安装失败'),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

Future<void> _showIdjMessage(
  BuildContext context,
  String title,
  String message,
) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

/// 三个安装入口 + 右上角「+」菜单共用的安装器入口（设计 §4.2.1/§4.6）：
/// 只写一套逻辑，tab 里的按钮与「+」菜单都调这里。
/// 成功装上东西回 true（调用方切到「插件」tab / 刷新列表），
/// 取消或失败回 false。
class IdjPluginActions {
  IdjPluginActions._();

  /// 「从文件安装（.idjplugin）」：系统文件选择器（安卓侧即 SAF
  /// `ACTION_OPEN_DOCUMENT`），只认 `.idjplugin` 后缀；
  /// 按选择器返回的 URI 读字节（`PlatformFile.readAsBytes()`，
  /// 底层走内容 URI / XFile），绝不 `File(path)` 猜路径、
  /// 不自造应用内文件浏览；用户在选择器里点取消什么都不发生。
  static Future<bool> installFromFile(
    BuildContext context,
    IdjPluginStore store,
  ) async {
    // 选择器调用原来在 try 外面：选择器本身打不开/抛错会漏出到
    // 调用方（与统一导入入口 9395cf3 修的是同款毛病）。现包进
    // try/catch：取消（返回空列表）静默返回 false，抛错弹明确提示。
    final List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['idjplugin'],
      );
    } catch (error) {
      if (!context.mounted) return false;
      await _showIdjError(context, '打开文件选择器失败：$error');
      return false;
    }
    if (files.isEmpty) return false;
    final picked = files.single;
    if (!picked.name.toLowerCase().endsWith('.idjplugin')) {
      await _showIdjError(context, '请选择 .idjplugin 文件');
      return false;
    }
    late final List<int> bytes;
    try {
      bytes = await picked.readAsBytes();
    } catch (_) {
      if (!context.mounted) return false;
      await _showIdjError(context, '未能读取文件内容，请重试');
      return false;
    }
    if (!context.mounted) return false;
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      await _showIdjError(context, '不是合法的 .idjplugin（缺少 manifest 或入口脚本）');
      return false;
    }
    final installed = await installBundleText(
      context,
      store,
      text,
      sourceLabel: '文件',
    );
    return installed != null;
  }

  /// 「从网址安装」：先弹文本框输地址，再走 [installFromUrlString]。
  static Future<bool> installFromUrlDialog(
    BuildContext context,
    IdjPluginStore store,
  ) async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从网址安装'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入插件包或订阅地址（https）',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('安装'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return false;
    return installFromUrlString(context, store, url);
  }

  /// 网址安装本体：`interpret` 分流后按种类处理。
  /// 订阅地址直接加进订阅列表（先拉取一次成功才保存，见 store）；
  /// 插件包直接装（免确认）；M3U / TVBox / 非法输入只提示，不装。
  static Future<bool> installFromUrlString(
    BuildContext context,
    IdjPluginStore store,
    String url,
  ) async {
    late final IdjInterpretResult interpreted;
    try {
      interpreted = await store.interpret(url.trim());
    } on AppFailure catch (error) {
      await _showIdjError(context, error.message);
      return false;
    } catch (error) {
      await _showIdjError(context, '下载失败：$error');
      return false;
    }
    return _handleInterpreted(context, store, interpreted, url: url.trim());
  }

  /// 「粘贴插件/订阅」：文本框对话框 → `interpret` 分流。
  static Future<bool> installFromPasteDialog(
    BuildContext context,
    IdjPluginStore store,
  ) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('粘贴插件/订阅'),
        content: TextField(
          controller: controller,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: '粘贴 .idjplugin 包内容、订阅 JSON 或地址',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('解析'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return false;
    return installFromPastedText(context, store, text);
  }

  /// 粘贴安装本体：与网址安装同一条 `interpret` 分流。
  static Future<bool> installFromPastedText(
    BuildContext context,
    IdjPluginStore store,
    String text,
  ) async {
    late final IdjInterpretResult interpreted;
    try {
      interpreted = await store.interpretText(text);
    } on AppFailure catch (error) {
      await _showIdjError(context, error.message);
      return false;
    }
    return _handleInterpreted(context, store, interpreted);
  }

  static Future<bool> _handleInterpreted(
    BuildContext context,
    IdjPluginStore store,
    IdjInterpretResult interpreted, {
    String? url,
  }) async {
    switch (interpreted.kind) {
      case IdjInterpretKind.bundle:
        final installed = await installBundleText(
          context,
          store,
          interpreted.bundleText!,
          sourceLabel: url == null ? '粘贴' : '网址',
        );
        return installed != null;
      case IdjInterpretKind.subscription:
        // 网址来的订阅：按地址加进订阅列表；粘贴来的订阅 JSON 没有地址，
        // 只展示内容、不自动装（插件逐个点安装要走订阅地址拉取）。
        if (url != null) {
          try {
            await store.addSubscription(url);
          } on AppFailure catch (error) {
            await _showIdjError(context, error.message);
            return false;
          }
          return true;
        }
        await _showSubscriptionPreview(
          context,
          interpreted.subscription!,
        );
        return false;
      case IdjInterpretKind.m3u:
      case IdjInterpretKind.tvbox:
      case IdjInterpretKind.unsupported:
        await _showIdjMessage(context, '装不了这个', interpreted.message);
        return false;
    }
  }

  static Future<void> _showSubscriptionPreview(
    BuildContext context,
    IdjSubscription subscription,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(subscription.name.isEmpty ? '订阅' : subscription.name),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('订阅里的插件不会自动安装，只展示、逐个点安装。'),
                const SizedBox(height: 8),
                const Text(
                  '粘贴的订阅 JSON 没有地址，装插件要走「添加订阅地址」粘贴订阅地址。',
                ),
                const SizedBox(height: 12),
                for (final plugin in subscription.plugins) ...[
                  Text(
                    '${plugin.name} v${plugin.version}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (plugin.description.isNotEmpty)
                    Text(
                      plugin.description,
                      style: const TextStyle(fontSize: 12),
                    ),
                  const SizedBox(height: 6),
                ],
                for (final cms in subscription.cms) ...[
                  Text('CMS：${cms.name}'),
                  Text(
                    cms.api,
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 插件包安装本体：解析 → 直接走安装链（probe → 写盘 + 索引 → 注册）。
  /// 免确认口径（用户 2026-11-25 令）：点安装就装到底，不弹确认 sheet；
  /// 更新时新版本多申请了域名，只在装完的结果提示里顺带一句。
  /// 失败在对话框里给看得懂的中文报错，不闪退、不留半成品。
  static Future<IdjInstalledPlugin?> installBundleText(
    BuildContext context,
    IdjPluginStore store,
    String text, {
    String sourceLabel = '文件',
  }) async {
    late final IdjPluginBundle bundle;
    try {
      bundle = IdjPluginStore.parseBundleText(text, sourceLabel: sourceLabel);
    } on AppFailure catch (error) {
      await _showIdjError(context, error.message);
      return null;
    }
    final oldManifest = await store.readInstalledManifest(bundle.manifest.id);
    try {
      final installed = await store.installBundleText(
        text,
        sourceLabel: sourceLabel,
      );
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              _installResultMessage(
                bundle.manifest,
                oldManifest,
                installed.entry.version,
              ),
            ),
          ),
        );
      }
      return installed;
    } on AppFailure catch (error) {
      await _showIdjError(context, error.message);
      return null;
    }
  }

  /// 装完后的结果提示文案：新装说「已安装」，更新说「已更新到 vX」；
  /// 更新且权限有扩大时顺带一句差异（只报域名数等概要，不拦路）。
  static String _installResultMessage(
    IdjPluginManifest manifest,
    IdjPluginManifest? oldManifest,
    String installedVersion,
  ) {
    if (oldManifest == null) {
      final note = idjSectionNoteForManifest(manifest);
      return '已安装「${manifest.name}」${note == null ? '' : '。$note'}';
    }
    final diff = IdjPluginStore.permissionDiff(oldManifest, manifest);
    final buffer = StringBuffer('已更新「${manifest.name}」到 v$installedVersion');
    if (!diff.isEmpty) {
      buffer.write('（${diff.describe().join('；')}）');
    }
    return buffer.toString();
  }

  /// 订阅里装一个插件：按 `manifestUrl` 下载正文再分流，
  /// 拿到包后直接装（免确认，更新有权限扩大也只在结果提示里带一句）。
  static Future<IdjInstalledPlugin?> installSubscriptionPlugin(
    BuildContext context,
    IdjPluginStore store,
    IdjSubscriptionPlugin plugin,
  ) async {
    if (plugin.manifestUrl.isEmpty) {
      await _showIdjError(context, '该订阅条目没有插件地址，无法安装');
      return null;
    }
    final uri = Uri.tryParse(plugin.manifestUrl);
    if (uri == null) {
      await _showIdjError(context, '该订阅条目没有合法的插件地址，无法安装');
      return null;
    }
    late final String text;
    try {
      text = await store.downloadText(uri, maxBytes: 2 * 1024 * 1024);
    } on AppFailure catch (error) {
      await _showIdjError(context, error.message);
      return null;
    }
    late final IdjInterpretResult interpreted;
    try {
      interpreted = await store.interpretText(text, baseUri: uri);
    } on AppFailure catch (error) {
      await _showIdjError(context, error.message);
      return null;
    }
    if (interpreted.kind != IdjInterpretKind.bundle ||
        interpreted.bundleText == null) {
      await _showIdjError(context, interpreted.message);
      return null;
    }
    return installBundleText(context, store, interpreted.bundleText!);
  }
}

/// 「插件」tab 本体：已安装 / 安装入口 / 订阅 / 更新检查四区。
class IdjPluginTab extends StatefulWidget {
  const IdjPluginTab({
    super.key,
    required this.store,
    this.initialSubscriptions,
    this.initialUpdateCandidates,
  });

  final IdjPluginStore store;

  /// 测试/预览注入：传了就直接用，不走网络拉订阅。
  final List<IdjSubscription>? initialSubscriptions;

  /// 测试/预览注入：传了就直接当作已查到的更新候选展示。
  final List<IdjUpdateCandidate>? initialUpdateCandidates;

  @override
  State<IdjPluginTab> createState() => IdjPluginTabState();
}

class IdjPluginTabState extends State<IdjPluginTab> {
  List<IdjInstalledPlugin> _installed = const [];
  List<IdjSubscription> _subscriptions = const [];
  List<IdjUpdateCandidate> _updates = const [];
  bool _updatesChecked = false;
  int _subscriptionNewerCount = 0;
  bool _loading = true;
  bool _busyInstalling = false;
  bool _checkingUpdates = false;
  final Set<String> _installingIds = {};
  // 内置远程仓库默认展开：打开市场直接看到远程插件列表，不用再点一下。
  final Set<String> _expandedSubs = {idjBuiltInSubscriptionUrl};
  // 已安装区折叠：默认展开；状态记偏好，下次进 tab 保持上次的样子。
  static const _installedCollapsedPrefKey = 'idj_installed_collapsed';
  bool _installedCollapsed = false;

  @override
  void initState() {
    super.initState();
    _loadInstalledCollapsed();
    _updates = widget.initialUpdateCandidates ?? const [];
    if (widget.initialSubscriptions != null) {
      _subscriptions = widget.initialSubscriptions!;
    }
    _refreshAll();
  }

  Future<void> _loadInstalledCollapsed() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(
      () => _installedCollapsed =
          prefs.getBool(_installedCollapsedPrefKey) ?? false,
    );
  }

  Future<void> _toggleInstalledCollapsed() async {
    final next = !_installedCollapsed;
    setState(() => _installedCollapsed = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_installedCollapsedPrefKey, next);
  }

  /// 供「+」菜单与 tab 外部调用：装完插件后刷新本页。
  Future<void> refreshAll() => _refreshAll();

  Future<void> _refreshAll() async {
    await _refreshInstalled();
    if (widget.initialSubscriptions == null) {
      await _refreshSubscriptions();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refreshInstalled() async {
    final installed = await widget.store.listInstalled();
    if (mounted) setState(() => _installed = installed);
  }

  Future<void> _refreshSubscriptions() async {
    final subscriptions = await widget.store.loadSubscriptions();
    if (!mounted) return;
    setState(() {
      _subscriptions = subscriptions;
      _subscriptionNewerCount = _countSubscriptionNewer(subscriptions);
    });
  }

  int _countSubscriptionNewer(List<IdjSubscription> subscriptions) {
    final installedById = {
      for (final item in _installed) item.entry.pluginId: item.entry.version,
    };
    var count = 0;
    for (final subscription in subscriptions) {
      for (final plugin in subscription.plugins) {
        final current = installedById[plugin.id];
        if (current != null &&
            IdjPluginManifest.compareVersions(plugin.version, current) > 0) {
          count++;
        }
      }
    }
    return count;
  }

  /// 安装/卸载/启用/停用后：先让片库立即刷新，再刷新 tab 本页。
  Future<void> _afterMutation() async {
    IdjPluginRegistry.onRegistryChanged?.call();
    await _refreshInstalled();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------- 已安装区 ----------

  Future<void> _toggleEnabled(IdjInstalledPlugin item, bool value) async {
    try {
      await widget.store.setEnabled(item.entry.pluginId, value);
      await _afterMutation();
      _snack(value ? '已启用「${item.entry.name}」' : '已停用「${item.entry.name}」');
    } on AppFailure catch (error) {
      _snack(error.message);
    }
  }

  Future<void> _uninstall(IdjInstalledPlugin item) async {
    var clearData = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('卸载插件'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('确定卸载「${idjDisplayName(item)}」吗？'),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('同时清除插件数据'),
                subtitle: const Text('勾选后插件的存储与 Cookie 一并删除'),
                value: clearData,
                onChanged: (value) =>
                    setDialogState(() => clearData = value ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('卸载'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.store.uninstall(item.entry.pluginId, clearData: clearData);
      await _afterMutation();
      _snack('已卸载「${item.entry.name}」');
    } on AppFailure catch (error) {
      _snack(error.message);
    }
  }

  Future<void> _reinstall(IdjInstalledPlugin item) async {
    // 已损坏的条目只给「卸载」「重新安装」：重新安装就是再走一次
    // 本地导入，挑回同名 .idjplugin 文件装进来。
    await _runEntryInstall(
      () => IdjPluginActions.installFromFile(context, widget.store),
    );
  }

  void _showDetails(IdjInstalledPlugin item) {
    final manifest = item.manifest;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(idjDisplayName(item)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('插件 id：${item.entry.pluginId}'),
            const SizedBox(height: 6),
            Text('版本：${item.entry.version}'),
            const SizedBox(height: 6),
            Text(
              '类型：${idjTypeLabel(item.entry.type)} · ${item.entry.type}',
            ),
            const SizedBox(height: 6),
            Text('状态：${item.damaged ? '已损坏（${item.damageReason}）' : item.entry.enabled ? '已启用' : '已停用'}'),
            if (manifest != null) ...[
              const SizedBox(height: 6),
              Text('申请域名：${manifest.httpDomains.length} 个'),
              if (manifest.description.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(manifest.description),
              ],
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _checkOneUpdate(IdjInstalledPlugin item) async {
    final candidates = await _checkUpdates();
    if (!mounted) return;
    final found = candidates
        .where((candidate) => candidate.pluginId == item.entry.pluginId)
        .firstOrNull;
    if (found != null) {
      _snack('「${item.entry.name}」有新版本 ${found.latestVersion}，见下方更新检查区');
    } else {
      _snack('「${item.entry.name}」已是最新');
    }
  }

  // ---------- 更新检查 ----------

  /// 手动触发：查 update.url 插件 + 刷新全部订阅比对版本。
  /// 有更新逐条列出，无更新 Toast“已是最新”。无定时自动刷新。
  Future<List<IdjUpdateCandidate>> _checkUpdates() async {
    if (_checkingUpdates) return _updates;
    setState(() => _checkingUpdates = true);
    try {
      final candidates = await widget.store.checkUpdates();
      if (widget.initialSubscriptions == null) {
        await _refreshSubscriptions();
      } else {
        _subscriptionNewerCount = _countSubscriptionNewer(_subscriptions);
      }
      if (!mounted) return candidates;
      setState(() {
        _updates = candidates;
        _updatesChecked = true;
      });
      if (candidates.isEmpty && _subscriptionNewerCount == 0) {
        _snack('已是最新');
      }
      return candidates;
    } catch (error) {
      _snack('检查更新失败：$error');
      return _updates;
    } finally {
      if (mounted) setState(() => _checkingUpdates = false);
    }
  }

  Future<void> _installUpdate(IdjUpdateCandidate candidate) async {
    if (candidate.manifest.updateUrl.isEmpty) return;
    await _runEntryInstall(
      () => IdjPluginActions.installFromUrlString(
        context,
        widget.store,
        candidate.manifest.updateUrl,
      ),
    );
  }

  // ---------- 安装入口 ----------

  /// 三个安装按钮与「+」菜单共用的包一层：入口按钮置灰 + 转圈
  ///（`_installing` 防重入），装好后刷新 tab。
  Future<bool> _runEntryInstall(
    Future<bool> Function() install,
  ) async {
    if (_busyInstalling) return false;
    setState(() => _busyInstalling = true);
    try {
      final ok = await install();
      if (ok) {
        IdjPluginRegistry.onRegistryChanged?.call();
        await _refreshInstalled();
        if (widget.initialSubscriptions == null) {
          await _refreshSubscriptions();
        }
      }
      return ok;
    } finally {
      if (mounted) setState(() => _busyInstalling = false);
    }
  }

  /// 供 MiniAppHomePage 右上角「+」菜单调用：与 tab 里的按钮调
  /// 同一个安装器入口（[IdjPluginActions]），不写两套逻辑。
  Future<bool> installFromFile() => _runEntryInstall(
    () => IdjPluginActions.installFromFile(context, widget.store),
  );

  Future<bool> installFromPaste() => _runEntryInstall(
    () => IdjPluginActions.installFromPasteDialog(context, widget.store),
  );

  Future<bool> installFromUrl() => _runEntryInstall(
    () => IdjPluginActions.installFromUrlDialog(context, widget.store),
  );

  // ---------- 订阅 ----------

  Future<void> _addSubscription() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加订阅地址'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入订阅地址（https）',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    try {
      // 先拉取一次成功才保存（失败不保存地址）。
      await widget.store.addSubscription(url);
      await _refreshSubscriptions();
      _snack('已添加订阅');
    } on AppFailure catch (error) {
      _snack(error.message);
    }
  }

  Future<void> _removeSubscription(IdjSubscription subscription) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除订阅'),
        content: const Text('只删订阅地址，不卸载已装的插件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.store.removeSubscription(subscription.url);
    await _refreshSubscriptions();
  }

  Future<void> _installSubscriptionPlugin(
    IdjSubscriptionPlugin plugin,
  ) async {
    if (_installingIds.contains(plugin.id)) return;
    setState(() => _installingIds.add(plugin.id));
    try {
      final installed = await IdjPluginActions.installSubscriptionPlugin(
        context,
        widget.store,
        plugin,
      );
      if (installed != null) {
        IdjPluginRegistry.onRegistryChanged?.call();
        await _refreshInstalled();
      }
    } finally {
      if (mounted) setState(() => _installingIds.remove(plugin.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: const ValueKey('idj-installed-collapse'),
            onTap: _toggleInstalledCollapsed,
            child: Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Row(
                children: [
                  Icon(
                    _installedCollapsed
                        ? Icons.chevron_right
                        : Icons.expand_more,
                    size: 20,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    '已安装（${_installed.length}）',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!_installedCollapsed) ...[
            if (_installed.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('还没有安装插件，可用下面的入口安装。'),
              )
            else
              GridView.builder(
                key: const ValueKey('idj-installed-grid'),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 0.70,
                    ),
                itemCount: _installed.length,
                itemBuilder: (context, index) =>
                    _installedCard(_installed[index], colors),
              ),
          ],
          _IdjSectionTitle(title: '安装入口'),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  key: const ValueKey('idj-install-url'),
                  onPressed: _busyInstalling ? null : installFromUrl,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 12,
                    ),
                    // 只改字号，字样沿用主题（测试里是 CJK 字体；
                    // 直接写 TextStyle 会丢掉主题字体，中文变方框）。
                    textStyle: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(fontSize: 13),
                  ),
                  child: const Text('从网址安装'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonal(
                  key: const ValueKey('idj-install-file'),
                  onPressed: _busyInstalling ? null : installFromFile,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 12,
                    ),
                    // 只改字号，字样沿用主题（测试里是 CJK 字体；
                    // 直接写 TextStyle 会丢掉主题字体，中文变方框）。
                    textStyle: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(fontSize: 13),
                  ),
                  child: const Text('从文件安装'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonal(
                  key: const ValueKey('idj-install-paste'),
                  onPressed: _busyInstalling ? null : installFromPaste,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 12,
                    ),
                    // 只改字号，字样沿用主题（测试里是 CJK 字体；
                    // 直接写 TextStyle 会丢掉主题字体，中文变方框）。
                    textStyle: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(fontSize: 13),
                  ),
                  child: const Text('粘贴插件/订阅'),
                ),
              ),
            ],
          ),
          if (_busyInstalling) ...[
            const SizedBox(height: 8),
            const Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('正在安装…'),
              ],
            ),
          ],
          const SizedBox(height: 4),
          const Text(
            '从文件安装只认 .idjplugin，走系统文件选择器挑文件。',
            style: TextStyle(fontSize: 11),
          ),
          _IdjSectionTitle(title: '订阅（${_subscriptions.length}）'),
          if (_subscriptions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('还没有订阅，添加订阅地址后可逐个安装里面的插件。'),
            )
          else
            for (final subscription in _subscriptions)
              _subscriptionCard(subscription, colors),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              key: const ValueKey('idj-add-subscription'),
              onPressed: _addSubscription,
              child: const Text('添加订阅地址'),
            ),
          ),
          _IdjSectionTitle(title: '更新检查'),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              key: const ValueKey('idj-check-updates'),
              onPressed: _checkingUpdates ? null : _checkUpdates,
              child: Text(_checkingUpdates ? '正在检查…' : '检查更新'),
            ),
          ),
          if (_updatesChecked && _updates.isEmpty && _subscriptionNewerCount == 0)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('已是最新'),
            ),
          if (_subscriptionNewerCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('订阅里另有 $_subscriptionNewerCount 个可更新（见订阅区）。'),
            ),
          for (final candidate in _updates) ...[
            const SizedBox(height: 8),
            _updateRow(candidate),
          ],
        ],
      ),
    );
  }

  /// 已安装插件卡片（三列网格）：图标 + 名 + 版本 + 启用状态，
  /// 管理动作（详情/启停/检查更新/卸载/重新安装）收进右上角小菜单。
  Widget _installedCard(IdjInstalledPlugin item, ColorScheme colors) {
    final name = idjDisplayName(item);
    final disabled = !item.entry.enabled;
    final damaged = item.damaged;
    final dimmed = disabled || damaged;
    return Container(
      key: ValueKey('idj-installed-${item.entry.pluginId}'),
      padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
      decoration: BoxDecoration(
        color: dimmed
            ? colors.surfaceContainerHighest.withValues(alpha: 0.45)
            : colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _IdjPluginAvatar(name: name, colors: colors),
              const Spacer(),
              PopupMenuButton<String>(
                key: ValueKey('idj-menu-${item.entry.pluginId}'),
                icon: const Icon(Icons.more_vert, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: '插件操作',
                onSelected: (action) => _installedCardAction(item, action),
                itemBuilder: (context) => [
                  if (!damaged) ...[
                    PopupMenuItem(
                      key: ValueKey('idj-detail-${item.entry.pluginId}'),
                      value: 'detail',
                      child: const Text('详情'),
                    ),
                    PopupMenuItem(
                      key: ValueKey('idj-toggle-${item.entry.pluginId}'),
                      value: 'toggle',
                      child: Text(disabled ? '启用' : '停用'),
                    ),
                    PopupMenuItem(
                      key: ValueKey('idj-check-one-${item.entry.pluginId}'),
                      value: 'check',
                      child: const Text('检查更新'),
                    ),
                  ],
                  if (damaged)
                    PopupMenuItem(
                      key: ValueKey('idj-reinstall-${item.entry.pluginId}'),
                      value: 'reinstall',
                      child: const Text('重新安装'),
                    ),
                  PopupMenuItem(
                    key: ValueKey('idj-uninstall-${item.entry.pluginId}'),
                    value: 'uninstall',
                    child: const Text('卸载'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: dimmed ? colors.onSurfaceVariant : colors.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'v${item.entry.version}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
          ),
          const Spacer(),
          if (damaged)
            _IdjStatusChip(
              key: ValueKey('idj-damaged-${item.entry.pluginId}'),
              label: '已损坏',
              background: colors.errorContainer,
              foreground: colors.onErrorContainer,
            )
          else if (disabled)
            _IdjStatusChip(
              key: ValueKey('idj-disabled-${item.entry.pluginId}'),
              label: '已停用',
              background: colors.errorContainer,
              foreground: colors.onErrorContainer,
            )
          else
            _IdjStatusChip(
              label: '已启用',
              background: colors.surfaceContainerHighest,
              foreground: colors.onSurfaceVariant,
            ),
        ],
      ),
    );
  }

  void _installedCardAction(IdjInstalledPlugin item, String action) {
    switch (action) {
      case 'detail':
        _showDetails(item);
      case 'toggle':
        _toggleEnabled(item, !item.entry.enabled);
      case 'check':
        _checkOneUpdate(item);
      case 'reinstall':
        _reinstall(item);
      case 'uninstall':
        _uninstall(item);
    }
  }

  Widget _subscriptionCard(IdjSubscription subscription, ColorScheme colors) {
    final expanded = _expandedSubs.contains(subscription.url);
    final builtIn = idjIsBuiltInSubscription(subscription.url);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: ValueKey('idj-subscription-${subscription.url}'),
            onTap: () => setState(() {
              if (expanded) {
                _expandedSubs.remove(subscription.url);
              } else {
                _expandedSubs.add(subscription.url);
              }
            }),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              subscription.name.isEmpty
                                  ? '订阅'
                                  : subscription.name,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          if (builtIn)
                            Container(
                              key: const ValueKey('idj-builtin-badge'),
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: colors.primaryContainer,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '内置',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onPrimaryContainer,
                                ),
                              ),
                            ),
                        ],
                      ),
                      Text(
                        subscription.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: ValueKey('idj-sub-refresh-${subscription.url}'),
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: '刷新订阅',
                  onPressed: _refreshSubscriptions,
                ),
                // 内置远程仓库不可删：只给刷新，不给删除按钮。
                if (!builtIn)
                  IconButton(
                    key: ValueKey('idj-sub-delete-${subscription.url}'),
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: '删除订阅',
                    onPressed: () => _removeSubscription(subscription),
                  ),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                ),
              ],
            ),
          ),
          if (subscription.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '刷新失败，留着旧列表：${subscription.error}',
                style: TextStyle(fontSize: 12, color: colors.error),
              ),
            ),
          if (expanded) ...[
            const Divider(height: 20),
            if (subscription.plugins.isNotEmpty) ...[
              GridView.builder(
                key: ValueKey('idj-sub-grid-${subscription.url}'),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 0.58,
                    ),
                itemCount: subscription.plugins.length,
                itemBuilder: (context, index) =>
                    _subscriptionPluginCard(subscription.plugins[index], colors),
              ),
              const SizedBox(height: 8),
            ],
            for (final cms in subscription.cms) ...[
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          cms.name,
                          style: const TextStyle(fontSize: 14),
                        ),
                        Text(
                          cms.api,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (cms.adult)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Text('🔞', style: TextStyle(fontSize: 14)),
                    ),
                  const Text(
                    '只展示',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (subscription.plugins.isEmpty && subscription.cms.isEmpty)
              const Text('这个订阅里没有插件。'),
          ],
        ],
      ),
    );
  }

  /// 订阅插件卡片（三列网格）：图标 + 名 + 版本 + 安装/更新/已安装按钮。
  /// 简介不进卡片（格子放不下），名字过长省略号截断。
  Widget _subscriptionPluginCard(
    IdjSubscriptionPlugin plugin,
    ColorScheme colors,
  ) {
    final installed = _installed
        .where((item) => item.entry.pluginId == plugin.id)
        .firstOrNull;
    final installedVersion = installed?.entry.version;
    final isNewer =
        installedVersion != null &&
        IdjPluginManifest.compareVersions(plugin.version, installedVersion) >
            0;
    final installing = _installingIds.contains(plugin.id);
    final actionLabel = installed == null
        ? '安装'
        : isNewer
        ? '更新'
        : '已安装';
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _IdjPluginAvatar(name: plugin.name, colors: colors),
              if (plugin.adult) ...[
                const Spacer(),
                const Text('🔞', style: TextStyle(fontSize: 13)),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            plugin.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            'v${plugin.version}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              key: ValueKey('idj-sub-install-${plugin.id}'),
              onPressed: installing || installed != null && !isNewer
                  ? null
                  : () => _installSubscriptionPlugin(plugin),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                // 只改字号，字样沿用主题（同安装入口三按钮的注释）。
                textStyle: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontSize: 12),
              ),
              child: Text(installing ? '安装中…' : actionLabel),
            ),
          ),
        ],
      ),
    );
  }

  Widget _updateRow(IdjUpdateCandidate candidate) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  candidate.manifest.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'v${candidate.currentVersion} → v${candidate.latestVersion}',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          FilledButton(
            key: ValueKey('idj-update-${candidate.pluginId}'),
            onPressed: () => _installUpdate(candidate),
            child: const Text('更新'),
          ),
        ],
      ),
    );
  }
}

class _IdjSectionTitle extends StatelessWidget {
  const _IdjSectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// 网格卡片左上角的插件图标：无图标资源时用名字首字占位，
/// 不留空白、不报错（显示名带 🔞 前缀时首字就是 🔞）。
class _IdjPluginAvatar extends StatelessWidget {
  const _IdjPluginAvatar({required this.name, required this.colors});

  final String name;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '插' : String.fromCharCode(name.runes.first),
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: colors.onPrimaryContainer,
        ),
      ),
    );
  }
}

/// 已安装卡片底部的状态小标签（已启用 / 已停用 / 已损坏）。
class _IdjStatusChip extends StatelessWidget {
  const _IdjStatusChip({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: foreground)),
    );
  }
}
