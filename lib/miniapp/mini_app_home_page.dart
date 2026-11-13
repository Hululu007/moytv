import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'mini_app_builtin.dart';
import 'mini_app_host_page.dart';
import 'mini_app_manifest.dart';
import 'mini_app_runtime.dart';
import 'mini_app_settings.dart';
import 'mini_app_settings_screen.dart';
import 'mini_app_store.dart';
import 'haikuo/haikuo_home_page.dart';

/// 小程序首页。
///
/// 结构对齐参考实现：顶栏（标题 + 新建 / 视图切换 / 设置）+「已安装 / 市场 / 海阔」
/// 三标签 + 四列图标网格。图标用名称首字 + 按 appId 取色的圆角方块，
/// 与参考实现的视觉一致，也不依赖小程序包内提供图标资源。
/// 海阔小程序有自己的独立标签（海阔规则列表与导入入口都在那页里），
/// 不再以固定卡片挂在「已安装」列表顶部。
class MiniAppHomePage extends StatefulWidget {
  const MiniAppHomePage({super.key});

  @override
  State<MiniAppHomePage> createState() => _MiniAppHomePageState();
}

enum MiniAppViewMode { grid, list }

class _MiniAppHomePageState extends State<MiniAppHomePage> {
  MiniAppSettings? _settings;
  MiniAppRuntime? _runtime;
  List<MiniAppManifest> _installed = const [];
  List<MiniAppMarketItem> _market = const [];
  String _marketState = 'idle';
  String _marketError = '';
  final Set<String> _installing = {};
  bool _busy = false;
  MiniAppViewMode _viewMode = MiniAppViewMode.grid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    unawaited(_runtime?.stopAll());
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await MiniAppSettings.load();
    final runtime = MiniAppRuntime(
      store: MiniAppStore(),
      settings: settings,
    );
    // 内置小程序首次播种（火蚁TV 同款 17 个）：失败不拦页面。
    await MiniAppBuiltin.ensureSeeded(runtime.store);
    final installed = await runtime.store.listInstalled();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _runtime = runtime;
      _installed = installed;
    });
    await _loadMarket();
  }

  Future<void> _refreshInstalled() async {
    final runtime = _runtime;
    if (runtime == null) return;
    final installed = await runtime.store.listInstalled();
    if (mounted) setState(() => _installed = installed);
  }

  Future<void> _loadMarket() async {
    final settings = _settings;
    if (settings == null) return;
    setState(() {
      _marketState = 'loading';
      _marketError = '';
    });
    try {
      final response = await http
          .get(Uri.parse(settings.marketUrl))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final items = parseMiniAppMarketJson(
        utf8.decode(response.bodyBytes),
      );
      if (!mounted) return;
      setState(() {
        _market = items;
        _marketState = items.isEmpty ? 'empty' : 'ready';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _market = const [];
        _marketState = 'error';
        _marketError = error.toString();
      });
    }
  }

  Future<void> _openSettings() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => const MiniAppSettingsScreen(),
      ),
    );
    final settings = await MiniAppSettings.load();
    final runtime = _runtime;
    if (runtime != null) runtime.settings = settings;
    if (!mounted) return;
    setState(() => _settings = settings);
    await _loadMarket();
  }

  Future<void> _openApp(MiniAppManifest manifest) async {
    final runtime = _runtime;
    final settings = _settings;
    if (runtime == null || settings == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => MiniAppHostPage(
          manifest: manifest,
          runtime: runtime,
          settings: settings,
        ),
      ),
    );
    await _refreshInstalled();
  }

  Future<void> _deleteApp(MiniAppManifest manifest) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除小程序'),
        content: Text('确定删除「${manifest.name}」吗？'),
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
    final runtime = _runtime;
    if (runtime == null) return;
    await runtime.stop(manifest.appId);
    await runtime.store.deleteApp(manifest.appId);
    await _refreshInstalled();
    if (mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('已删除')));
    }
  }

  Future<void> _showInstalledActions(MiniAppManifest manifest) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                manifest.name,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('打开'),
              onTap: () {
                Navigator.pop(sheetContext);
                _openApp(manifest);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('卸载'),
              onTap: () {
                Navigator.pop(sheetContext);
                _deleteApp(manifest);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('详情'),
              onTap: () {
                Navigator.pop(sheetContext);
                _showAppInfo(manifest);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAppInfo(MiniAppManifest manifest) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(manifest.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('应用 ID：${manifest.appId}'),
            const SizedBox(height: 6),
            Text('版本：${manifest.version.isEmpty ? '未标注' : manifest.version}'),
            const SizedBox(height: 6),
            Text('渲染方式：${manifest.renderer}'),
            if (manifest.description.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(manifest.description),
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

  Future<void> _showCreateMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('从 zip 包安装'),
              onTap: () {
                Navigator.pop(sheetContext);
                _installFromZip();
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('从文件夹安装'),
              onTap: () {
                Navigator.pop(sheetContext);
                _installFromFolder();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_rounded),
              title: const Text('从链接安装'),
              onTap: () {
                Navigator.pop(sheetContext);
                _installFromLink();
              },
            ),
            ListTile(
              leading: const Icon(Icons.extension_rounded),
              title: const Text('海阔小程序'),
              subtitle: const Text('导入海阔 JSON 文件或粘贴口令'),
              onTap: () {
                Navigator.pop(sheetContext);
                _openHaikuo();
              },
            ),
            ListTile(
              leading: const Icon(Icons.refresh_rounded),
              title: const Text('刷新市场'),
              onTap: () {
                Navigator.pop(sheetContext);
                _loadMarket();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openHaikuo() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const HaikuoHomePage()),
    );
  }

  Future<void> _installFromZip() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (files.isEmpty) return;
    final path = files.first.path;
    if (path == null) return;
    await _runInstall(() async {
      final runtime = _runtime!;
      return runtime.store.installFromZipFile(File(path));
    });
  }

  Future<void> _installFromFolder() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择小程序文件夹',
    );
    if (path == null) return;
    await _runInstall(() async {
      final runtime = _runtime!;
      return runtime.store.installFromDirectory(Directory(path));
    });
  }

  Future<void> _installFromLink() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从链接安装'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入 zip 包地址',
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
    if (url == null || url.isEmpty) return;
    await _runInstall(() async {
      final runtime = _runtime!;
      return runtime.store.installFromUrl(url);
    });
  }

  Future<void> _runInstall(
    Future<MiniAppManifest> Function() install,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final manifest = await install();
      await _refreshInstalled();
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('已安装「${manifest.name}」')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('安装失败：$error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _installMarketItem(MiniAppMarketItem item) async {
    if (_installing.contains(item.appId)) return;
    setState(() => _installing.add(item.appId));
    try {
      final runtime = _runtime!;
      await runtime.store.installFromUrl(
        item.url,
        expectedMd5: item.md5,
        expectedSize: item.size,
      );
      await _refreshInstalled();
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('已安装「${item.name}」')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('安装失败：$error')),
        );
      }
    } finally {
      if (mounted) setState(() => _installing.remove(item.appId));
    }
  }

  MiniAppManifest? _installedById(String appId) {
    for (final manifest in _installed) {
      if (manifest.appId == appId) return manifest;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('小程序'),
          titleSpacing: 4,
          actions: [
            IconButton(
              icon: const Icon(Icons.add_rounded),
              tooltip: '安装小程序',
              onPressed: _busy ? null : _showCreateMenu,
            ),
            IconButton(
              icon: Icon(
                _viewMode == MiniAppViewMode.grid
                    ? Icons.view_list_rounded
                    : Icons.grid_view_rounded,
              ),
              tooltip: _viewMode == MiniAppViewMode.grid ? '切换为列表' : '切换为网格',
              onPressed: () => setState(
                () => _viewMode = _viewMode == MiniAppViewMode.grid
                    ? MiniAppViewMode.list
                    : MiniAppViewMode.grid,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: '小程序设置',
              onPressed: _settings == null ? null : _openSettings,
            ),
            const SizedBox(width: 4),
          ],
          bottom: TabBar(
            indicatorSize: TabBarIndicatorSize.label,
            indicatorWeight: 3,
            indicatorColor: colors.primary,
            labelStyle: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
            tabs: const [
              Tab(text: '已安装'),
              Tab(text: '市场'),
              Tab(text: '海阔'),
            ],
          ),
        ),
        body: _settings == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  Builder(builder: _installedTab),
                  _marketTab(),
                  // 海阔小程序独立界面：规则列表与导入入口都在这页里。
                  const HaikuoHomePage(embedded: true),
                ],
              ),
      ),
    );
  }

  Widget _installedTab(BuildContext tabContext) {
    return _installedBody(tabContext);
  }

  Widget _installedBody(BuildContext tabContext) {
    if (_busy && _installed.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_installed.isEmpty) {
      return _EmptyState(
        icon: Icons.widgets_outlined,
        title: '还没有安装小程序',
        description: '右上角「+」可从 zip 包、文件夹或链接安装，也可以去「市场」挑一个',
        actionLabel: '去市场看看',
        onAction: () => DefaultTabController.of(tabContext).animateTo(1),
      );
    }
    if (_viewMode == MiniAppViewMode.list) {
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: _installed.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (context, index) {
          final manifest = _installed[index];
          return _MiniAppListRow(
            name: manifest.name,
            subtitle: [
              manifest.appId,
              if (manifest.version.isNotEmpty) manifest.version,
            ].join(' · '),
            seed: manifest.appId,
            onTap: () => _openApp(manifest),
            onLongPress: () => _showInstalledActions(manifest),
          );
        },
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 28),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 18,
        crossAxisSpacing: 8,
        childAspectRatio: 0.74,
      ),
      itemCount: _installed.length,
      itemBuilder: (context, index) {
        final manifest = _installed[index];
        return _MiniAppTile(
          name: manifest.name,
          seed: manifest.appId,
          onTap: () => _openApp(manifest),
          onLongPress: () => _showInstalledActions(manifest),
        );
      },
    );
  }

  Widget _marketTab() {
    if (_marketState == 'loading') {
      return const Center(child: CircularProgressIndicator());
    }
    if (_marketState == 'error') {
      return _EmptyState(
        icon: Icons.cloud_off_rounded,
        title: '市场拉取失败',
        description: _marketError,
        actionLabel: '重试',
        onAction: _loadMarket,
      );
    }
    if (_marketState == 'empty' || _market.isEmpty) {
      return _EmptyState(
        icon: Icons.storefront_outlined,
        title: '市场暂时是空的',
        description: '可以在「小程序设置」里换一个市场地址',
        actionLabel: '重新拉取',
        onAction: _loadMarket,
      );
    }
    if (_viewMode == MiniAppViewMode.list) {
      return RefreshIndicator(
        onRefresh: _loadMarket,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          itemCount: _market.length,
          separatorBuilder: (_, _) => const SizedBox(height: 6),
          itemBuilder: (context, index) {
            final item = _market[index];
            final installed = _installedById(item.appId) != null;
            final installing = _installing.contains(item.appId);
            return _MiniAppListRow(
              name: item.name,
              subtitle: [
                if (item.version.isNotEmpty) item.version,
                if (item.author.isNotEmpty) item.author,
                if (item.description.isNotEmpty) item.description,
              ].join(' · '),
              seed: item.appId,
              trailing: _marketAction(item, installed, installing),
              onTap: () => _onMarketTap(item, installed, installing),
            );
          },
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadMarket,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 18, 12, 28),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 18,
          crossAxisSpacing: 8,
          childAspectRatio: 0.74,
        ),
        itemCount: _market.length,
        itemBuilder: (context, index) {
          final item = _market[index];
          final installed = _installedById(item.appId) != null;
          final installing = _installing.contains(item.appId);
          return _MiniAppTile(
            name: item.name,
            seed: item.appId,
            badge: installing
                ? '…'
                : installed
                ? '✓'
                : null,
            onTap: () => _onMarketTap(item, installed, installing),
            onLongPress: () => _showMarketInfo(item),
          );
        },
      ),
    );
  }

  void _onMarketTap(
    MiniAppMarketItem item,
    bool installed,
    bool installing,
  ) {
    if (installed) {
      final manifest = _installedById(item.appId);
      if (manifest != null) _openApp(manifest);
      return;
    }
    if (installing) return;
    _installMarketItem(item);
  }

  Widget _marketAction(
    MiniAppMarketItem item,
    bool installed,
    bool installing,
  ) {
    return FilledButton(
      onPressed: installing
          ? null
          : () => _onMarketTap(item, installed, installing),
      child: Text(
        installed
            ? '打开'
            : installing
            ? '安装中…'
            : '安装',
      ),
    );
  }

  void _showMarketInfo(MiniAppMarketItem item) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('应用 ID：${item.appId}'),
            if (item.version.isNotEmpty) Text('版本：${item.version}'),
            if (item.author.isNotEmpty) Text('作者：${item.author}'),
            if (item.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(item.description),
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
}

/// 参考实现里的图标方块：圆角正方形 + 名称首字 + 名称两行。
class _MiniAppTile extends StatelessWidget {
  const _MiniAppTile({
    required this.name,
    required this.seed,
    required this.onTap,
    this.onLongPress,
    this.badge,
  });

  final String name;
  final String seed;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = miniAppIconColor(seed);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [color, Color.lerp(color, Colors.black, 0.28)!],
                  ),
                  borderRadius: BorderRadius.circular(15),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.28),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: Text(
                  miniAppIconGlyph(name),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (badge != null)
                Positioned(
                  right: -4,
                  top: -4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: color.withValues(alpha: 0.55),
                      ),
                    ),
                    child: Text(
                      badge!,
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.25,
              fontWeight: FontWeight.w500,
              color: colors.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniAppListRow extends StatelessWidget {
  const _MiniAppListRow({
    required this.name,
    required this.subtitle,
    required this.seed,
    required this.onTap,
    this.onLongPress,
    this.trailing,
  });

  final String name;
  final String subtitle;
  final String seed;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = miniAppIconColor(seed);
    return Material(
      color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        contentPadding: const EdgeInsets.fromLTRB(10, 2, 12, 2),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Text(
            miniAppIconGlyph(name),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        ),
        subtitle: subtitle.isEmpty
            ? null
            : Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: colors.onSurfaceVariant,
                ),
              ),
        trailing: trailing,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String description;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 40,
              color: colors.onSurfaceVariant.withValues(alpha: 0.75),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              description,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}

const List<Color> _kMiniAppIconPalette = [
  Color(0xFFFF8A3D),
  Color(0xFF3B82F6),
  Color(0xFFA855F7),
  Color(0xFF22C55E),
  Color(0xFFEF4444),
  Color(0xFF14B8A6),
  Color(0xFFF59E0B),
  Color(0xFF6366F1),
];

/// 按种子串稳定取色，同一个应用每次进入颜色不变。
Color miniAppIconColor(String seed) {
  if (seed.isEmpty) return _kMiniAppIconPalette.first;
  var hash = 0;
  for (final unit in seed.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return _kMiniAppIconPalette[hash % _kMiniAppIconPalette.length];
}

/// 取名称第一个字符作为图标字形。
String miniAppIconGlyph(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '小';
  final first = String.fromCharCode(trimmed.runes.first);
  return first;
}
