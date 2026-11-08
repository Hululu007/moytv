import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'crack_config_section.dart';
import 'import_center.dart';
import 'import_file_store.dart';
import 'imported_site_record.dart';
import 'local_store.dart';
import 'm3u_subscriptions.dart';
import 'py_bridge.dart';

const _maxImportBytes = 32 * 1024 * 1024;

class _PendingFile {
  const _PendingFile({
    required this.name,
    required this.size,
    required this.loadBytes,
  });

  final String name;
  final int size;
  final Future<List<int>> Function() loadBytes;

  String get sizeLabel {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class ImportCenterSection extends StatefulWidget {
  const ImportCenterSection({
    super.key,
    required this.repository,
    required this.store,
  });

  final AppRepository repository;
  final LocalStore store;

  @override
  State<ImportCenterSection> createState() => _ImportCenterSectionState();
}

class _ImportCenterSectionState extends State<ImportCenterSection> {
  bool _busy = false;
  String _busyLabel = '';

  ImportEngine get _engine =>
      ImportEngine(store: widget.store, repository: widget.repository);

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _runBusy(String label, Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyLabel = label;
    });
    try {
      await action();
    } catch (error) {
      _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanFolder() => _runBusy('扫描文件夹中…', () async {
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择要扫描的文件夹',
    );
    if (directory == null || !mounted) return;
    final pending = <_PendingFile>[];
    try {
      await for (final entity in Directory(
        directory,
      ).list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        final dot = name.lastIndexOf('.');
        if (dot < 0) continue;
        final extension = name.substring(dot + 1).toLowerCase();
        if (!ImportEngine.supportedExtensions.contains(extension)) continue;
        final size = await entity.length();
        final path = entity.path;
        pending.add(
          _PendingFile(
            name: name,
            size: size,
            loadBytes: () => File(path).readAsBytes(),
          ),
        );
      }
    } catch (error) {
      _showMessage('扫描失败：$error');
      return;
    }
    if (!mounted) return;
    if (pending.isEmpty) {
      _showMessage('该文件夹（含子目录）没有找到 .py/.js/.json/.jar/.zip 文件');
      return;
    }
    pending.sort((a, b) => a.name.compareTo(b.name));
    await _previewAndImport(pending, title: '扫描结果（${pending.length} 个文件）');
  });

  Future<void> _pickMultiple() => _runBusy('读取文件中…', () async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['py', 'js', 'json', 'jar', 'zip'],
    );
    if (files.isEmpty || !mounted) return;
    final pending = <_PendingFile>[];
    for (final file in files) {
      pending.add(
        _PendingFile(
          name: file.name,
          size: await file.length() ?? 0,
          loadBytes: () => file.readAsBytes(),
        ),
      );
    }
    await _previewAndImport(pending, title: '待导入文件（${pending.length} 个）');
  });

  Future<void> _pickSinglePy() => _runBusy('导入中…', () async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['py'],
    );
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    final report = await _engine.importAll([
      ImportCandidate(name: file.name, bytes: bytes),
    ]);
    if (mounted) await _showReport(report);
  });

  Future<void> _pickSingleJar() => _runBusy('导入中…', () async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['jar', 'zip'],
    );
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    final report = await _engine.importAll([
      ImportCandidate(name: file.name, bytes: bytes),
    ]);
    if (mounted) await _showReport(report);
  });

  Future<void> _previewAndImport(
    List<_PendingFile> pending, {
    required String title,
  }) async {
    final selection = await showDialog<_ImportSelection>(
      context: context,
      builder: (_) => _ImportPreviewDialog(title: title, files: pending),
    );
    if (selection == null || selection.indices.isEmpty || !mounted) return;
    final candidates = <ImportCandidate>[];
    for (final index in selection.indices) {
      final file = pending[index];
      if (file.size > _maxImportBytes) {
        candidates.add(ImportCandidate(name: file.name, bytes: const []));
        continue;
      }
      final isPy = file.name.toLowerCase().endsWith('.py');
      candidates.add(
        ImportCandidate(
          name: file.name,
          bytes: await file.loadBytes(),
          ext: isPy ? selection.ext : '',
        ),
      );
    }
    final report = await _engine.importAll(candidates);
    if (mounted) await _showReport(report);
  }

  Future<void> _showReport(ImportReport report) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入报告'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(report.summary),
                const SizedBox(height: 12),
                for (final outcome in report.outcomes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          switch (outcome.status) {
                            ImportOutcomeStatus.success =>
                              Icons.check_circle_rounded,
                            ImportOutcomeStatus.duplicate => Icons.copy_rounded,
                            ImportOutcomeStatus.failed => Icons.error_rounded,
                          },
                          size: 20,
                          color: switch (outcome.status) {
                            ImportOutcomeStatus.success => Theme.of(
                              context,
                            ).colorScheme.primary,
                            ImportOutcomeStatus.duplicate => Colors.orange,
                            ImportOutcomeStatus.failed => Theme.of(
                              context,
                            ).colorScheme.error,
                          },
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                outcome.fileName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                outcome.reason,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleImported(ImportedSiteRecord record, bool enabled) async {
    final records = [
      for (final item in widget.store.importedSiteRecords)
        if (item.id == record.id) item.copyWith(enabled: enabled) else item,
    ];
    await widget.store.syncImportedSites(records);
  }

  Future<void> _removeImported(ImportedSiteRecord record) async {
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
    if (record.type == ImportedSiteRecord.typePy) {
      unawaited(
        ImportFileStore.pathOf(
          record.fileName,
        ).then((path) => PyBridge.dispose(path)),
      );
    }
    await ImportFileStore.delete(record.fileName);
    await widget.store.syncImportedSites([
      for (final item in widget.store.importedSiteRecords)
        if (item.id != record.id) item,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final records = widget.store.importedSiteRecords;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Text('导入中心', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          '批量扫描文件夹或多选文件导入 py / js / json / jar / zip：py 经 Python 桥成站，'
          'XBPQ 规则 JSON 进核心规则通道，自定义源 JSON 进自定义源通道，'
          'TVBox 配置与 jar 转交 jar 桥（未接入时明确失败），js 先注册占位。'
          'jar + 配置 JSON 的 zip 包会拆开导入，包里的站点配置自动带上 ext 与站名；'
          '没有配置的 jar 站点会在报告里明确提醒。'
          '导入按内容哈希去重，并逐个给出结果报告。',
        ),
        const SizedBox(height: 8),
        FutureBuilder<PyRuntimeStatus>(
          future: PyBridge.status(),
          builder: (context, snapshot) {
            final status = snapshot.data;
            if (status == null) return const SizedBox.shrink();
            return Text(
              status.available
                  ? 'Python 运行时：可用（${status.python}）'
                  : 'Python 运行时：未就绪（py 站可见但打开会明确报错）',
              style: TextStyle(
                color: status.available ? colors.primary : colors.error,
                fontSize: 12,
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const ValueKey('import-scan-folder'),
              onPressed: _busy ? null : () => unawaited(_scanFolder()),
              icon: const Icon(Icons.folder_open_rounded, size: 20),
              label: const Text('扫描文件夹批量导入'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('import-pick-multiple'),
              onPressed: _busy ? null : () => unawaited(_pickMultiple()),
              icon: const Icon(Icons.library_add_rounded, size: 20),
              label: const Text('多选文件批量导入'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('import-pick-py'),
              onPressed: _busy ? null : () => unawaited(_pickSinglePy()),
              icon: const Icon(Icons.code_rounded, size: 20),
              label: const Text('导入单个 py'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('import-pick-jar'),
              onPressed: _busy ? null : () => unawaited(_pickSingleJar()),
              icon: const Icon(Icons.archive_rounded, size: 20),
              label: const Text('导入单个 jar / zip 包'),
            ),
          ],
        ),
        if (_busy)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(_busyLabel),
              ],
            ),
          ),
        if (records.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('已导入站（${records.length}）'),
          const SizedBox(height: 8),
          for (final record in records)
            Card(
              key: ValueKey('imported-${record.id}'),
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(
                  record.type == ImportedSiteRecord.typePy
                      ? Icons.code_rounded
                      : Icons.javascript_rounded,
                ),
                title: Text(record.name),
                subtitle: Text(
                  '${record.type == ImportedSiteRecord.typePy ? 'Python 蜘蛛' : 'JS 蜘蛛'}'
                  ' · 哈希 ${record.contentHash.substring(0, 8)}'
                  '${record.enabled ? '' : ' · 已停用'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: record.enabled,
                      onChanged: (value) =>
                          unawaited(_toggleImported(record, value)),
                    ),
                    IconButton(
                      tooltip: '删除',
                      onPressed: () => unawaited(_removeImported(record)),
                      icon: Icon(Icons.delete_outline, color: colors.error),
                    ),
                  ],
                ),
              ),
            ),
        ],
        M3uImportSection(store: widget.store),
        CrackConfigSection(repository: widget.repository),
      ],
    );
  }
}

class M3uImportSection extends StatefulWidget {
  const M3uImportSection({super.key, required this.store});

  final LocalStore store;

  @override
  State<M3uImportSection> createState() => _M3uImportSectionState();
}

class _M3uImportSectionState extends State<M3uImportSection> {
  bool _busy = false;

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _askText({
    required String title,
    required String label,
    String initial = '',
    String? secondLabel,
    String secondInitial = '',
  }) async {
    final first = TextEditingController(text: initial);
    final second = TextEditingController(text: secondInitial);
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: first,
                decoration: InputDecoration(labelText: label),
              ),
              if (secondLabel != null) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: second,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: secondLabel),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, [first.text.trim(), second.text.trim()]),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    first.dispose();
    second.dispose();
    if (result == null) return null;
    return result.join('\u0000');
  }

  Future<void> _importFile() async {
    if (_busy) return;
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['m3u', 'm3u8', 'txt'],
    );
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final bytes = await file.readAsBytes();
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!mounted) return;
      final name = await _askText(
        title: '导入 m3u 文件',
        label: '订阅名称',
        initial: file.name.replaceAll(RegExp(r'\.(m3u8?|txt)$'), ''),
      );
      if (name == null || !mounted) return;
      final record = await M3uSubscriptionService.build(
        name: name,
        kind: M3uSubscription.kindFile,
        text: text,
        rawBytes: bytes,
      );
      await widget.store.syncM3uSubscriptions([
        ...widget.store.m3uSubscriptions,
        record,
      ]);
      _showMessage(
        '已导入「${record.name}」：${record.channelCount} 个频道 / ${record.groupCount} 个分类，已进入直播区',
      );
    } catch (error) {
      _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importUrl() async {
    if (_busy) return;
    final input = await _askText(
      title: '订阅 m3u 地址',
      label: '订阅名称',
      secondLabel: 'm3u 地址（http/https）',
    );
    if (input == null || !mounted) return;
    final parts = input.split('\u0000');
    final name = parts.first;
    final url = parts.length > 1 ? parts[1] : '';
    if (url.isEmpty) {
      _showMessage('请填写订阅地址');
      return;
    }
    setState(() => _busy = true);
    try {
      final text = await M3uSubscriptionService.fetchText(url);
      final record = await M3uSubscriptionService.build(
        name: name.isEmpty ? '未命名订阅' : name,
        kind: M3uSubscription.kindUrl,
        text: text,
        rawBytes: utf8.encode(text),
        url: url,
      );
      await widget.store.syncM3uSubscriptions([
        ...widget.store.m3uSubscriptions,
        record,
      ]);
      _showMessage(
        '已订阅「${record.name}」：${record.channelCount} 个频道 / ${record.groupCount} 个分类，已进入直播区',
      );
    } catch (error) {
      _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh(M3uSubscription sub) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final String text;
      if (sub.isUrl) {
        text = await M3uSubscriptionService.fetchText(sub.url);
      } else {
        text = await M3uFileStore.readText(sub.fileName);
      }
      final updated = await M3uSubscriptionService.build(
        name: sub.name,
        kind: sub.kind,
        text: text,
        rawBytes: utf8.encode(text),
        url: sub.url,
        existing: sub.id,
      );
      await widget.store.syncM3uSubscriptions([
        for (final item in widget.store.m3uSubscriptions)
          if (item.id == sub.id) updated else item,
      ]);
      _showMessage('「${sub.name}」已刷新：${updated.channelCount} 个频道');
    } catch (error) {
      _showMessage('刷新失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename(M3uSubscription sub) async {
    final name = await _askText(
      title: '重命名订阅',
      label: '订阅名称',
      initial: sub.name,
    );
    if (name == null || name.isEmpty || !mounted) return;
    await widget.store.syncM3uSubscriptions([
      for (final item in widget.store.m3uSubscriptions)
        if (item.id == sub.id) item.copyWith(name: name) else item,
    ]);
  }

  Future<void> _remove(M3uSubscription sub) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除 m3u 订阅'),
        content: Text('确定删除「${sub.name}」吗？其频道将从直播区移除。'),
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
    await M3uFileStore.delete(sub.fileName);
    await widget.store.syncM3uSubscriptions([
      for (final item in widget.store.m3uSubscriptions)
        if (item.id != sub.id) item,
    ]);
  }

  String _updatedLabel(int ms) {
    if (ms <= 0) return '未更新';
    final time = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.month}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final subscriptions = widget.store.m3uSubscriptions;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Text('m3u 直播订阅', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          '导入本地 m3u 文件或订阅远程地址：#EXTINF 的 group-title 作频道分类、'
          'tvg-logo 作台标，频道进入直播区；订阅可刷新、改名、删除，解析失败会明确报错。',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const ValueKey('m3u-import-file'),
              onPressed: _busy ? null : () => unawaited(_importFile()),
              icon: const Icon(Icons.folder_open_rounded, size: 20),
              label: const Text('导入 m3u 文件'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('m3u-import-url'),
              onPressed: _busy ? null : () => unawaited(_importUrl()),
              icon: const Icon(Icons.link_rounded, size: 20),
              label: const Text('订阅 m3u 地址'),
            ),
          ],
        ),
        if (subscriptions.isNotEmpty) ...[
          const SizedBox(height: 16),
          for (final sub in subscriptions)
            Card(
              key: ValueKey('m3u-${sub.id}'),
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.live_tv_rounded),
                title: Text(sub.name),
                subtitle: Text(
                  '${sub.isUrl ? '远程订阅' : '本地文件'} · ${sub.channelCount} 个频道 / ${sub.groupCount} 个分类'
                  ' · 更新 ${_updatedLabel(sub.updatedAtMs)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '刷新',
                      onPressed: _busy ? null : () => unawaited(_refresh(sub)),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                    IconButton(
                      tooltip: '改名',
                      onPressed: _busy ? null : () => unawaited(_rename(sub)),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: '删除',
                      onPressed: _busy ? null : () => unawaited(_remove(sub)),
                      icon: Icon(Icons.delete_outline, color: colors.error),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _ImportSelection {
  const _ImportSelection(this.indices, this.ext);

  final Set<int> indices;
  final String ext;
}

class _ImportPreviewDialog extends StatefulWidget {
  const _ImportPreviewDialog({required this.title, required this.files});

  final String title;
  final List<_PendingFile> files;

  @override
  State<_ImportPreviewDialog> createState() => _ImportPreviewDialogState();
}

class _ImportPreviewDialogState extends State<_ImportPreviewDialog> {
  late final Set<int> _selected = {
    for (var i = 0; i < widget.files.length; i++)
      if (widget.files[i].size <= _maxImportBytes) i,
  };
  final _extController = TextEditingController();

  @override
  void dispose() {
    _extController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.files.length; i++)
                CheckboxListTile(
                  value: _selected.contains(i),
                  onChanged: widget.files[i].size > _maxImportBytes
                      ? null
                      : (value) => setState(() {
                          if (value == true) {
                            _selected.add(i);
                          } else {
                            _selected.remove(i);
                          }
                        }),
                  title: Text(
                    widget.files[i].name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    widget.files[i].size > _maxImportBytes
                        ? '${widget.files[i].sizeLabel} · 超过 32 MB 上限，不可导入'
                        : widget.files[i].sizeLabel,
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _extController,
                decoration: const InputDecoration(
                  labelText: '扩展参数（仅 py 源，init 用，可空）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  _ImportSelection(_selected, _extController.text.trim()),
                ),
          child: Text('导入所选（${_selected.length}）'),
        ),
      ],
    );
  }
}
