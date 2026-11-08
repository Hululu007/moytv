import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'mini_app_host_page.dart';
import 'mini_app_manifest.dart';
import 'mini_app_runtime.dart';
import 'mini_app_settings.dart';
import 'mini_app_settings_screen.dart';
import 'mini_app_store.dart';

class MiniAppHomePage extends StatefulWidget {
  const MiniAppHomePage({super.key});

  @override
  State<MiniAppHomePage> createState() => _MiniAppHomePageState();
}

class _MiniAppHomePageState extends State<MiniAppHomePage>
    with SingleTickerProviderStateMixin {
  MiniAppSettings? _settings;
  MiniAppRuntime? _runtime;
  List<MiniAppManifest> _installed = const [];
  List<MiniAppMarketItem> _market = const [];
  String _marketState = 'idle';
  String _marketError = '';
  final Set<String> _installing = {};
  bool _busy = false;

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
      final manifest = await runtime.store.installFromZipFile(File(path));
      return manifest;
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

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('小程序'),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: '小程序设置',
              onPressed: _settings == null ? null : _openSettings,
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '已安装'),
              Tab(text: '市场'),
            ],
          ),
        ),
        body: _settings == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _installedTab(),
                  _marketTab(),
                ],
              ),
      ),
    );
  }

  Widget _installedTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _installFromZip,
              icon: const Icon(Icons.archive_outlined),
              label: const Text('导入 zip 包'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _installFromFolder,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('导入文件夹'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _installFromLink,
              icon: const Icon(Icons.link_rounded),
              label: const Text('从链接安装'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_busy) const LinearProgressIndicator(),
        if (_installed.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: Text('还没有安装小程序')),
          )
        else
          for (final manifest in _installed)
            Card(
              child: ListTile(
                leading: const Icon(Icons.apps_rounded),
                title: Text(manifest.name),
                subtitle: Text(
                  '${manifest.appId}${manifest.version.isEmpty ? '' : ' · ${manifest.version}'}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.play_arrow_rounded),
                      tooltip: '打开',
                      onPressed: () => _openApp(manifest),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded),
                      tooltip: '删除',
                      onPressed: () => _deleteApp(manifest),
                    ),
                  ],
                ),
                onTap: () => _openApp(manifest),
              ),
            ),
      ],
    );
  }

  Widget _marketTab() {
    if (_marketState == 'loading') {
      return const Center(child: CircularProgressIndicator());
    }
    if (_marketState == 'error') {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('还没有市场数据'),
              const SizedBox(height: 8),
              Text(
                '市场地址拉取失败：$_marketError',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loadMarket,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_marketState == 'empty') {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('还没有市场数据'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loadMarket,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadMarket,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _market.length,
        itemBuilder: (context, index) {
          final item = _market[index];
          final installed = _installed.any((e) => e.appId == item.appId);
          final installing = _installing.contains(item.appId);
          return Card(
            child: ListTile(
              leading: const Icon(Icons.apps_rounded),
              title: Text(item.name),
              subtitle: Text(
                [
                  if (item.version.isNotEmpty) item.version,
                  if (item.author.isNotEmpty) item.author,
                  if (item.description.isNotEmpty) item.description,
                ].join(' · '),
              ),
              isThreeLine: item.description.isNotEmpty,
              trailing: installed
                  ? FilledButton(
                      onPressed: () {
                        final manifest = _installed
                            .where((e) => e.appId == item.appId)
                            .firstOrNull;
                        if (manifest != null) _openApp(manifest);
                      },
                      child: const Text('打开'),
                    )
                  : FilledButton(
                      onPressed: installing
                          ? null
                          : () => _installMarketItem(item),
                      child: Text(installing ? '安装中…' : '安装'),
                    ),
            ),
          );
        },
      ),
    );
  }
}
