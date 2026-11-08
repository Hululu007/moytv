import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'import_center.dart';
import 'import_file_store.dart';
import 'imported_site_record.dart';
import 'local_store.dart';
import 'py_bridge.dart';
import 'tvbox_config.dart';
import 'zoo_builtin_seed.dart';

List<ImportedSiteRecord> pySiteRecords(Iterable<ImportedSiteRecord> records) =>
    records
        .where((record) => record.type == ImportedSiteRecord.typePy)
        .toList();

class ContentConfigGroup {
  const ContentConfigGroup({
    required this.configId,
    required this.name,
    required this.sites,
  });

  final String configId;
  final String name;
  final List<TvBoxSiteRecord> sites;
}

List<ContentConfigGroup> configSiteGroups(
  Iterable<TvBoxConfigRecord> configs,
) => configs
    .map(
      (config) => ContentConfigGroup(
        configId: config.configId,
        name: config.name,
        sites: config.sites,
      ),
    )
    .toList();

enum ContentSourceView { py, config }

class ContentSourceScreen extends StatefulWidget {
  const ContentSourceScreen({
    super.key,
    required this.repository,
    required this.store,
  });

  final AppRepository repository;
  final LocalStore store;

  @override
  State<ContentSourceScreen> createState() => _ContentSourceScreenState();
}

class _ContentSourceScreenState extends State<ContentSourceScreen> {
  List<TvBoxConfigRecord> _configs = [];
  List<ImportedSiteRecord> _records = [];
  ContentSourceView _view = ContentSourceView.py;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _configs = TvBoxConfigStore.configs;
      _records = widget.store.importedSiteRecords;
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addInterface() async {
    final result = await showDialog<_InterfaceInput>(
      context: context,
      builder: (_) => const _AddInterfaceDialog(),
    );
    if (result == null || !mounted) return;
    await _run(() async {
      final importer = TvBoxImporter(widget.repository);
      final TvBoxImportReport report;
      if (result.filePath != null) {
        final file = File(result.filePath!);
        final bytes = await file.readAsBytes();
        final text = utf8.decode(bytes);
        report = await importer.importFromText(
          text,
          sourceIdentity: 'file:${result.fileName}:${bytes.length}',
          displayName: result.name,
        );
      } else if (result.address.isNotEmpty) {
        report = await importer.importFromUrl(
          result.address,
          displayName: result.name,
        );
      } else {
        _showMessage('请填写接口地址或选择本地文件');
        return;
      }
      if (mounted) {
        _showMessage('已导入「${report.name}」');
        _refresh();
      }
    });
  }

  Future<void> _importPy() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['py'],
    );
    if (files.isEmpty || !mounted) return;
    await _run(() async {
      final candidates = <ImportCandidate>[];
      for (final file in files) {
        candidates.add(
          ImportCandidate(name: file.name, bytes: await file.readAsBytes()),
        );
      }
      final engine = ImportEngine(
        store: widget.store,
        repository: widget.repository,
      );
      final report = await engine.importAll(candidates);
      if (mounted) {
        _showMessage(report.summary);
        _refresh();
      }
    });
  }

  Future<void> _removePy(ImportedSiteRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除导入站'),
        content: Text('确定删除「${record.name}」吗？导入的蜘蛛文件副本将一并删除。'),
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
    await _run(() async {
      if (record.type == ImportedSiteRecord.typePy) {
        unawaited(
          ImportFileStore.pathOf(record.fileName)
              .then((path) => PyBridge.dispose(path)),
        );
      }
      await ImportFileStore.delete(record.fileName);
      await widget.store.syncImportedSites([
        for (final item in widget.store.importedSiteRecords)
          if (item.id != record.id) item,
      ]);
      if (mounted) _refresh();
    });
  }

  Future<void> _removeConfig(TvBoxConfigRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除配置'),
        content: Text('确定删除配置「${record.name}」吗？该组站点将一并移除。'),
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
    await _run(() async {
      if (ZooBuiltinSeeder.isBuiltinConfig(record.configId)) {
        await ZooBuiltinSeeder.deleteConfig(widget.repository, record.configId);
      } else {
        await TvBoxImporter(widget.repository).removeConfig(record.configId);
      }
      if (mounted) _refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final pyRecords = pySiteRecords(_records);
    final groups = configSiteGroups(_configs);
    final totalSites = _configs.fold<int>(
      0,
      (sum, config) => sum + config.sites.length,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('内容源管理')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Text('接口配置', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),

              IconButton(
                tooltip: '添加 TVBox 远程配置',
                onPressed: _busy ? null : () => unawaited(_addInterface()),
                icon: const Icon(Icons.add_rounded),
              ),
              IconButton(
                tooltip: '导入 py',
                onPressed: _busy ? null : () => unawaited(_importPy()),
                icon: const Icon(Icons.upload_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              title: const Text('本地自定义配置'),
              subtitle: Text(
                '本机已保存 ${_configs.length} 个 TVBox 配置 · $totalSites 个站点',
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '历史配置（${_configs.length}）',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (_configs.isEmpty)
            const Text('还没有导入的配置')
          else
            for (final config in _configs)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(config.name),
                  subtitle: Text(config.summaryLine),
                  trailing: IconButton(
                    tooltip: '删除配置',
                    onPressed: _busy
                        ? null
                        : () => unawaited(_removeConfig(config)),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ),
              ),
          const Divider(height: 32),
          SegmentedButton<ContentSourceView>(
            segments: const [
              ButtonSegment(value: ContentSourceView.py, label: Text('py 站点')),
              ButtonSegment(
                value: ContentSourceView.config,
                label: Text('远程配置'),
              ),
            ],
            selected: {_view},
            onSelectionChanged: (selected) {
              setState(() => _view = selected.first);
            },
          ),
          const SizedBox(height: 12),
          if (_view == ContentSourceView.py) ...[
            if (pyRecords.isEmpty)
              const Text('还没有导入的 py 站点')
            else
              for (final record in pyRecords)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Text(record.name),
                    subtitle: Text(record.fileName),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '删除',
                          onPressed: _busy
                              ? null
                              : () => unawaited(_removePy(record)),
                          icon: const Icon(Icons.delete_outline_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
          ] else ...[
            if (groups.isEmpty)
              const Text('还没有导入的远程配置')
            else ...[
              for (final group in groups) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(
                    group.name,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                for (final site in group.sites)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text(site.name),
                      subtitle: Text(
                        site.kind == 'py'
                            ? 'py 站'
                            : site.kind == 'jar'
                            ? 'jar 站'
                            : '接口',
                      ),
                    ),
                  ),
              ],
            ],
          ],
        ],
      ),
    );
  }
}

class _InterfaceInput {
  const _InterfaceInput({
    required this.name,
    required this.address,
    this.filePath,
    this.fileName = '',
  });

  final String name;
  final String address;
  final String? filePath;
  final String fileName;
}

class _AddInterfaceDialog extends StatefulWidget {
  const _AddInterfaceDialog();

  @override
  State<_AddInterfaceDialog> createState() => _AddInterfaceDialogState();
}

class _AddInterfaceDialogState extends State<_AddInterfaceDialog> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  String? _filePath;
  String _fileName = '';

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null || file.path == null) return;
    setState(() {
      _filePath = file.path;
      _fileName = file.name;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加接口'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '配置名称',
                hintText: '可选，方便识别',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _address,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '接口地址',
                hintText: '在线配置 URL 或本地文件',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => unawaited(_pickFile()),
              icon: const Icon(Icons.folder_open_outlined),
              label: Text(_filePath == null ? '选择本地文件' : _fileName),
            ),
            const SizedBox(height: 8),
            const Text('支持在线配置链接或本地 JSON 文件'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _InterfaceInput(
              name: _name.text.trim(),
              address: _address.text.trim(),
              filePath: _filePath,
              fileName: _fileName,
            ),
          ),
          child: const Text('添加'),
        ),
      ],
    );
  }
}
