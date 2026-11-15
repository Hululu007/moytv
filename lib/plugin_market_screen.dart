import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'core_bridge.dart';
import 'import_center.dart';
import 'import_file_store.dart';
import 'imported_site_record.dart';
import 'jar_import.dart';
import 'local_store.dart';
import 'neon_glass_kit.dart';
import 'plugin_icons.dart';
import 'plugin_manager.dart';
import 'py_bridge.dart';
import 'zip_install.dart';
import 'zip_pick_screen.dart';

/// 插件管理 + 插件市场：本地（从文件安装 + 已安装管理）与远程（索引拉取）两区。
class PluginMarketScreen extends StatefulWidget {
  const PluginMarketScreen({
    super.key,
    required this.store,
    required this.repository,
  });

  final LocalStore store;
  final AppRepository repository;

  @override
  State<PluginMarketScreen> createState() => _PluginMarketScreenState();
}

class _PluginMarketScreenState extends State<PluginMarketScreen> {
  late final ImportEngine _engine = ImportEngine(
    store: widget.store,
    repository: widget.repository,
  );
  final _urlController = TextEditingController();
  Set<String> _uninstalled = {};
  var _busy = false;
  var _marketState = 'idle'; // idle | loading | ready | empty | error
  var _marketError = '';
  var _marketItems = const <RemotePluginItem>[];
  var _installingKey = '';

  @override
  void initState() {
    super.initState();
    _refreshLocal();
    _loadMarketUrl();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _refreshLocal() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _uninstalled =
          preferences.getStringList(PluginManager.uninstalledPrefsKey)?.toSet() ??
          {};
    });
  }

  Future<void> _loadMarketUrl() async {
    _urlController.text = await PluginManager.loadMarketUrl();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm(String title, String content) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
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
    );
    return confirmed == true;
  }

  /// 登记表变化后：通知全部站点列表立即刷新（设置列表、站点切换、
  /// 跨站探活池都挂在 store 上），再刷新本页的安装状态。
  Future<void> _afterRegistryChange() async {
    widget.store.refreshSiteRegistry();
    await _refreshLocal();
  }

  Future<void> _installBuiltin(BuiltinPluginInfo plugin) async {
    setState(() => _busy = true);
    final ok = await PluginManager.installBuiltinPlugin(plugin.id);
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(ok ? '已安装「${plugin.name}」' : '安装失败，请重试');
    await _afterRegistryChange();
  }

  Future<void> _uninstallBuiltin(BuiltinPluginInfo plugin) async {
    final confirmed = await _confirm(
      '卸载插件',
      '确定卸载「${plugin.name}」吗？它注册的 ${plugin.siteCount} 个站点将一并撤掉，可随时重装。',
    );
    if (!confirmed) return;
    setState(() => _busy = true);
    await PluginManager.uninstallBuiltinPlugin(plugin.id);
    if (!mounted) return;
    setState(() => _busy = false);
    _toast('已卸载「${plugin.name}」');
    await _afterRegistryChange();
  }

  Future<void> _uninstallImportedJar(ImportedJarGroup group) async {
    final confirmed = await _confirm(
      '卸载插件',
      '确定卸载「${group.displayName}」吗？它注册的 ${group.siteCount} 个站点将一并撤掉，jar 文件副本一并删除。',
    );
    if (!confirmed) return;
    setState(() => _busy = true);
    await JarImport.removeImportedJar(group.jarId);
    if (!mounted) return;
    setState(() => _busy = false);
    _toast('已卸载「${group.displayName}」');
    await _afterRegistryChange();
  }

  Future<void> _uninstallImportedPy(ImportedSiteRecord record) async {
    final confirmed = await _confirm(
      '卸载插件',
      '确定卸载「${record.name}」吗？导入的蜘蛛文件副本将一并删除。',
    );
    if (!confirmed) return;
    unawaited(
      ImportFileStore.pathOf(
        record.fileName,
      ).then((path) => PyBridge.dispose(path)),
    );
    await ImportFileStore.delete(record.fileName);
    await widget.store.syncImportedSites([
      for (final item in widget.store.importedSiteRecords)
        if (item.id != record.id) item,
    ]);
    if (!mounted) return;
    _toast('已卸载「${record.name}」');
    await _afterRegistryChange();
  }

  Future<void> _pickAndInstallFile() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['jar', 'zip', 'py'],
    );
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    final lower = file.name.toLowerCase();
    if (lower.endsWith('.zip')) {
      await _installZipFile(file.name, bytes);
      return;
    }
    if (lower.endsWith('.jar')) {
      // 市场内单 jar 安装：同款（同一 md5）已安装则跳过并提示，
      // 不重复注册（导入中心原有的重装语义不动）。
      final group = JarImport.groupForJarMd5(md5.convert(bytes).toString());
      if (group != null) {
        _toast('「${group.displayName}」已安装，跳过，不重复注册');
        return;
      }
    }
    setState(() => _busy = true);
    try {
      final report = await _engine.importAll([
        ImportCandidate(name: file.name, bytes: bytes),
      ]);
      if (!mounted) return;
      _showReport(report);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _afterRegistryChange();
  }

  /// zip 选择安装：先开选择器列出识别到的影视源 / 直播列表 / 组件，
  /// 用户勾选后再装；与文件管理器点 zip 选魔蚁走同一个选择器。
  /// 安装结果弹窗由选择器自己出，这里只在装上东西后刷新登记表。
  Future<void> _installZipFile(String fileName, List<int> bytes) async {
    final changed = await openZipPicker(
      context: context,
      zipName: fileName,
      zipBytes: bytes,
      installer: ZipPickInstaller.forApp(
        store: widget.store,
        repository: widget.repository,
      ),
    );
    if (!mounted) return;
    if (changed) await _afterRegistryChange();
  }

  void _showReport(ImportReport report) {
    final firstFailure = report.outcomes
        .where((item) => !item.ok)
        .map((item) => '${item.fileName}：${item.reason}')
        .join('\n');
    _toast(
      '成功 ${report.successCount} · 重复 ${report.duplicateCount} · '
      '失败 ${report.failedCount}'
      '${firstFailure.isEmpty ? '' : '\n$firstFailure'}',
    );
  }

  Future<void> _saveMarketUrl() async {
    await PluginManager.saveMarketUrl(_urlController.text);
    _toast('远程索引地址已保存');
    await _loadMarket();
  }

  Future<void> _loadMarket() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _marketState = 'idle';
        _marketItems = const [];
        _marketError = '';
      });
      return;
    }
    setState(() {
      _marketState = 'loading';
      _marketError = '';
    });
    try {
      final items = await fetchPluginMarket(url);
      if (!mounted) return;
      setState(() {
        _marketItems = items;
        _marketState = items.isEmpty ? 'empty' : 'ready';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _marketItems = const [];
        _marketState = 'error';
        _marketError = error.toString();
      });
    }
  }

  Future<void> _installRemote(RemotePluginItem item) async {
    setState(() => _installingKey = item.key);
    try {
      final response = await http
          .get(Uri.parse(item.url))
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final bytes = response.bodyBytes;
      final expectedMd5 = item.md5;
      if (expectedMd5 != null && expectedMd5.isNotEmpty) {
        final actual = md5.convert(bytes).toString();
        if (actual != expectedMd5) {
          throw const FormatException('下载文件 md5 与索引不一致，已拒绝安装');
        }
      }
      if (item.type == 'jar') {
        final group = JarImport.groupForJarMd5(md5.convert(bytes).toString());
        if (group != null) {
          if (mounted) _toast('「${group.displayName}」已安装，跳过，不重复注册');
          return;
        }
      }
      final fileName = '${item.key}.${item.type}';
      final report = await _engine.importAll([
        ImportCandidate(name: fileName, bytes: bytes),
      ]);
      if (!mounted) return;
      _showReport(report);
    } catch (error) {
      if (mounted) _toast('安装失败：$error');
    } finally {
      if (mounted) setState(() => _installingKey = '');
    }
    await _afterRegistryChange();
  }

  @override
  Widget build(BuildContext context) {
    final builtin = PluginManager.builtinPlugins();
    final jarGroups = JarImport.importedJarGroups();
    final importedPy = widget.store.importedSiteRecords
        .where((record) => record.type == ImportedSiteRecord.typePy)
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('插件市场')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          const Text(
            '本地插件',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const ValueKey('plugin-install-from-file'),
            onPressed: _busy ? null : () => unawaited(_pickAndInstallFile()),
            icon: const Icon(Icons.file_upload_outlined),
            label: const Text('从文件安装（jar / zip / py）'),
          ),
          const SizedBox(height: 4),
          const Text(
            '选 zip 包会先列出里面的影视源、直播列表与组件，勾选后再安装。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          const Text('内置插件', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          NeonGlassCard(
            child: Column(
              children: [
                for (var i = 0; i < builtin.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _builtinRow(builtin[i]),
                ],
              ],
            ),
          ),
          if (jarGroups.isNotEmpty || importedPy.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              '已导入插件',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            NeonGlassCard(
              child: Column(
                children: [
                  for (var i = 0; i < jarGroups.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _importedJarRow(jarGroups[i]),
                  ],
                  for (var i = 0; i < importedPy.length; i++) ...[
                    if (jarGroups.isNotEmpty || i > 0) const Divider(height: 1),
                    _importedPyRow(importedPy[i]),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          const Text(
            '远程插件',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('plugin-market-url'),
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: '远程插件索引地址',
              hintText: 'https://…/plugins.json',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton(
                onPressed: _busy ? null : () => unawaited(_saveMarketUrl()),
                child: const Text('保存地址并刷新'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _marketState == 'loading'
                    ? null
                    : () => unawaited(_loadMarket()),
                child: const Text('刷新'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _remoteBody(),
        ],
      ),
    );
  }

  Widget _builtinRow(BuiltinPluginInfo plugin) {
    final installed = !_uninstalled.contains(plugin.id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(
        children: [
          NeonIconTile(
            icon: Icons.extension_outlined,
            child: PluginTypeIcon(kind: plugin.kind, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plugin.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${plugin.detail} · ${plugin.siteCount} 个站点'
                  '${installed ? '' : ' · 未安装'}',
                  style: const TextStyle(fontSize: 11.5),
                ),
              ],
            ),
          ),
          if (installed)
            OutlinedButton(
              onPressed: _busy ? null : () => unawaited(_uninstallBuiltin(plugin)),
              child: const Text('卸载'),
            )
          else
            FilledButton(
              onPressed: _busy ? null : () => unawaited(_installBuiltin(plugin)),
              child: const Text('安装'),
            ),
        ],
      ),
    );
  }

  Widget _importedJarRow(ImportedJarGroup group) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(
        children: [
          const NeonIconTile(
            icon: Icons.extension_outlined,
            child: PluginTypeIcon(kind: PluginIconKind.jar, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.displayName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '导入的 jar 插件 · ${group.siteCount} 个站点',
                  style: const TextStyle(fontSize: 11.5),
                ),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: _busy ? null : () => unawaited(_uninstallImportedJar(group)),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
  }

  Widget _importedPyRow(ImportedSiteRecord record) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(
        children: [
          const NeonIconTile(
            icon: Icons.extension_outlined,
            child: PluginTypeIcon(kind: PluginIconKind.py, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '导入的 py 插件 · ${record.fileName}',
                  style: const TextStyle(fontSize: 11.5),
                ),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: _busy ? null : () => unawaited(_uninstallImportedPy(record)),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
  }

  Widget _remoteBody() {
    switch (_marketState) {
      case 'loading':
        return const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        );
      case 'error':
        return Padding(
          padding: const EdgeInsets.all(8),
          child: Text('拉取失败：$_marketError'),
        );
      case 'empty':
        return const Padding(
          padding: EdgeInsets.all(8),
          child: Text('远程索引为空，没有可安装的插件。'),
        );
      case 'ready':
        return NeonGlassCard(
          child: Column(
            children: [
              for (var i = 0; i < _marketItems.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _remoteRow(_marketItems[i]),
              ],
            ],
          ),
        );
      case 'idle':
      default:
        return const Padding(
          padding: EdgeInsets.all(8),
          child: Text('未设置远程地址。填入插件索引 JSON 地址并保存，即可浏览远程插件。'),
        );
    }
  }

  Widget _remoteRow(RemotePluginItem item) {
    final installing = _installingKey == item.key;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(
        children: [
          NeonIconTile(
            icon: Icons.extension_outlined,
            child: item.icon.isEmpty
                ? PluginTypeIcon(kind: item.kind, size: 20)
                : ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(
                      item.icon,
                      width: 20,
                      height: 20,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          PluginTypeIcon(kind: item.kind, size: 20),
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (item.version.isNotEmpty) 'v${item.version}',
                    item.type,
                    if (item.description.isNotEmpty) item.description,
                  ].join(' · '),
                  style: const TextStyle(fontSize: 11.5),
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: installing ? null : () => unawaited(_installRemote(item)),
            child: installing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('安装'),
          ),
        ],
      ),
    );
  }
}
