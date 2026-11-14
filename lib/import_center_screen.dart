import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'import_center.dart';
import 'jar_bridge_handoff.dart';
import 'jar_import.dart';
import 'local_store.dart';
import 'neon_glass_kit.dart';
import 'tvbox_config.dart';
import 'widgets.dart';

class ImportCenterScreen extends StatefulWidget {
  const ImportCenterScreen({
    super.key,
    required this.repository,
    required this.store,
  });

  final AppRepository repository;
  final LocalStore store;

  @override
  State<ImportCenterScreen> createState() => _ImportCenterScreenState();
}

class _ImportCenterScreenState extends State<ImportCenterScreen> {
  bool _busy = false;
  late final TvBoxImporter _importer = TvBoxImporter(widget.repository);

  @override
  void initState() {
    super.initState();
    TvBoxImporter.storeSync = widget.store.syncCustomSources;
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

  void _showReport(TvBoxImportReport report) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          (report.apiSites + report.jarSites + report.lives + report.parses) ==
                  0
              ? '未导入任何内容「${report.name}」'
              : '已导入「${report.name}」',
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(report.summary),
                if (report.notes.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final note in report.notes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        note,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
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

  Future<void> _importByUrl() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _ImportUrlDialog(),
    );
    if (url == null || url.isEmpty || !mounted) return;
    await _run(() async {
      final report = await _importer.importFromUrl(url);
      if (mounted) _showReport(report);
    });
  }

  Future<void> _importFromFile() async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null || !mounted) return;
    final filePath = file.path;
    if (filePath == null || filePath.isEmpty) {
      _showMessage('无法读取所选文件');
      return;
    }
    if (file.name.toLowerCase().endsWith('.jar')) {
      await _run(() => _importJarFile(filePath));
      return;
    }
    if (file.name.toLowerCase().endsWith('.zip')) {
      await _run(() => _importZipFile(filePath));
      return;
    }
    if (file.name.toLowerCase().endsWith('.py')) {
      await _run(() async {
        final bytes = await File(filePath).readAsBytes();
        if (bytes.length > 32 * 1024 * 1024) {
          if (mounted) _showMessage('文件过大，无法导入');
          return;
        }
        final report = await ImportEngine(
          store: widget.store,
          repository: widget.repository,
        ).importAll([ImportCandidate(name: file.name, bytes: bytes)]);
        if (mounted) _showMessage(report.summary);
      });
      return;
    }
    final size = await File(filePath).length();
    if (size > 8 * 1024 * 1024) {
      _showMessage('文件过大，无法导入');
      return;
    }
    final String text;
    try {
      text = utf8.decode(await File(filePath).readAsBytes());
    } catch (_) {
      _showMessage('文件不是有效的 UTF-8 文本');
      return;
    }
    var isTvBox = false;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map &&
          (decoded.containsKey('sites') || decoded.containsKey('spider'))) {
        isTvBox = true;
      }
    } catch (_) {}
    if (!isTvBox) {
      _showMessage('该文件不是 TVBox 配置（含 sites/spider）；普通站源清单请到「自定义源」导入');
      return;
    }
    await _run(() async {
      final report = await _importer.importFromText(
        text,
        sourceIdentity: 'file:${file.name}:${text.length}',
      );
      if (mounted) _showReport(report);
    });
  }

  Future<void> _importJarFile(String filePath) async {
    final jarId =
        'jar-${md5.convert(utf8.encode(filePath)).toString().substring(0, 8)}';
    final configs = await JarBridgeHandoff.siblingConfigsForJarFile(filePath);
    final result = await JarImport.scanAndRegister(
      jarId: jarId,
      jarUrl: filePath,
      configs: configs,
      displayName: JarImport.fileBaseName(filePath),
    );
    if (!mounted) return;
    final classes = result.all;
    final usable = result.newly.length;
    final skipped = classes
        .where((info) => !info.instantiable)
        .map((info) => '${info.simpleName}：${info.reason}')
        .toList();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('jar 导入完成'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '识别到 ${classes.length} 个 Spider 类，新增注册 $usable 个站点（进「导入」分组，站名跟文件名，重复导入另注册新站点、同名按序号区分）。',
                ),
                if (result.updated.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('已更新 ${result.updated.length} 个已注册站点的配置。'),
                ],
                if (result.configured.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('已自动带上站点配置：${result.configured.join('、')}。'),
                ],
                if (result.missing.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '提醒：以下站点未找到站点配置，注册后可能跑不起来：'
                    '${result.missing.join('、')}；可在下方条目上手动补填 ext。',
                  ),
                ],
                if (skipped.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  for (final line in skipped)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        line,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
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

  Future<void> _importZipFile(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    if (bytes.length > 32 * 1024 * 1024) {
      if (mounted) _showMessage('文件过大，无法导入');
      return;
    }
    final result = await JarBridgeHandoff.registerZip(
      name: filePath.split(Platform.pathSeparator).last,
      bytes: bytes,
    );
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('zip 包导入完成'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Text(result.summary),
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

  Future<void> _refreshConfig(TvBoxConfigRecord record) async {
    await _run(() async {
      final report = await _importer.refreshConfig(record.configId);
      if (mounted) _showReport(report);
    });
  }

  Future<void> _removeConfig(TvBoxConfigRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这份配置'),
        content: Text('将移除「${record.name}」名下的全部站点及其附带直播/解析，内置站与其他配置不受影响。'),
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
    if (confirmed != true || !mounted) return;
    await _run(() => _importer.removeConfig(record.configId));
  }

  Future<void> _editJarExt(StandaloneJarSite site) async {
    final controller = TextEditingController(text: site.ext);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('「${site.name}」的 ext'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            maxLines: 5,
            minLines: 2,
            autocorrect: false,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '留空表示无参；可填 token、JSON 或参数串',
              helperText: '保存后该站点会以新 ext 重新初始化',
              helperMaxLines: 2,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    await _run(() => JarImport.updateExt(site.siteId, controller.text.trim()));
  }

  Future<void> _removeJarSite(StandaloneJarSite site) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除 jar 站点'),
        content: Text('确定删除「${site.name}」吗？同一 jar 的其它站点不受影响。'),
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
    if (confirmed != true || !mounted) return;
    await _run(() => JarImport.remove(site.siteId));
  }

  @override
  Widget build(BuildContext context) {
    final configs = TvBoxConfigStore.configs;
    final jarSites = JarImport.sites;
    return Scaffold(
      appBar: AppBar(
        title: const Text('导入中心'),
        actions: [
          IconButton(
            key: const ValueKey('import-center-file'),
            tooltip: '从本地文件导入（TVBox 配置 JSON / jar / zip 包）',
            onPressed: _busy ? null : () => unawaited(_importFromFile()),
            icon: const Icon(Icons.folder_open_rounded),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            key: const ValueKey('import-center-url'),
            onPressed: _busy ? null : () => unawaited(_importByUrl()),
            icon: const Icon(Icons.add_rounded, size: 20),
            label: const Text('填配置地址'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              const Text(
                'TVBox 远程配置：填入配置地址或选本地配置文件，站点按配置分组与内置站共存；'
                '接口站走自定义源通道，csp 类 jar 站走本地 jar 桥，附带直播进直播区、解析进解析列表。'
                '单独的 jar 文件可直接导入：枚举其中全部 Spider 类，一类一站进「导入」分组；'
                'jar + 配置 JSON 的 zip 包也可直接导入，包里的站点配置自动带上 ext 与站名，'
                '同目录的站点配置 JSON 也会在导 jar 时自动匹配；没有配置的站点会明确提醒。',
              ),
              const SizedBox(height: 16),
              NeonSectionTitle(
                'TVBox 配置（${configs.length}）',
                padding: const EdgeInsets.only(bottom: 8),
              ),
              if (configs.isEmpty)
                const StatusPanel(
                  title: '还没有导入任何 TVBox 配置',
                  message: '点右上角「填配置地址」粘贴配置 URL，或用文件夹按钮选本地配置 JSON。',
                )
              else
                for (final record in configs) _configCard(record),
              const SizedBox(height: 16),
              NeonSectionTitle(
                'jar 直导入站点（${jarSites.length}）',
                padding: const EdgeInsets.only(bottom: 8),
              ),
              if (jarSites.isEmpty)
                const StatusPanel(
                  title: '还没有 jar 直导入站点',
                  message: '用文件夹按钮选择 .jar 或 .zip 包文件即可枚举注册；zip 包与同目录的站点配置会自动带上 ext 与站名；没有配置的站点会明确提醒，之后可在条目上手动补填 ext。',
                )
              else
                for (final site in jarSites) _jarSiteCard(site),
            ],
          ),
        ),
      ),
    );
  }

  Widget _configCard(TvBoxConfigRecord record) {
    final colors = Theme.of(context).colorScheme;
    return NeonGlassCard(
      key: ValueKey('tvbox-${record.configId}'),
      margin: const EdgeInsets.only(bottom: 12),
      child: NeonRow(
        icon: Icons.settings_input_component_outlined,
        title: record.name,
        detail:
            '${record.summaryLine}'
            '${record.url.isEmpty ? '' : '\n${record.url}'}',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (record.url.isNotEmpty)
              IconButton(
                tooltip: '刷新',
                onPressed: _busy
                    ? null
                    : () => unawaited(_refreshConfig(record)),
                icon: const Icon(Icons.refresh_rounded),
              ),
            IconButton(
              tooltip: '删除整份配置',
              onPressed: _busy ? null : () => unawaited(_removeConfig(record)),
              icon: Icon(Icons.delete_outline, color: colors.error),
            ),
          ],
        ),
      ),
    );
  }

  Widget _jarSiteCard(StandaloneJarSite site) {
    final colors = Theme.of(context).colorScheme;
    return NeonGlassCard(
      key: ValueKey('jar-${site.siteId}'),
      margin: const EdgeInsets.only(bottom: 12),
      child: NeonRow(
        icon: Icons.extension_outlined,
        title: site.name,
        detail:
            '${site.className}\next：${site.ext.isEmpty ? '未填' : site.ext}'
            '${site.missingConfig ? '\n未找到站点配置，注册后可能跑不起来' : ''}',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '手动补填 ext',
              onPressed: _busy ? null : () => unawaited(_editJarExt(site)),
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: '删除站点',
              onPressed: _busy ? null : () => unawaited(_removeJarSite(site)),
              icon: Icon(Icons.delete_outline, color: colors.error),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImportUrlDialog extends StatefulWidget {
  const _ImportUrlDialog();

  @override
  State<_ImportUrlDialog> createState() => _ImportUrlDialogState();
}

class _ImportUrlDialogState extends State<_ImportUrlDialog> {
  final TextEditingController _url = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    Navigator.pop(context, url);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导入 TVBox 配置'),
      content: SizedBox(
        width: 460,
        child: TextField(
          key: const ValueKey('import-center-url-field'),
          controller: _url,
          autofocus: true,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          onSubmitted: (_) => _submit(),
          decoration: const InputDecoration(
            labelText: '配置地址',
            hintText: 'https://…/config.json',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(14)),
              borderSide: BorderSide.none,
            ),
            helperText: '远程 jar 会下载到本机执行，仅导入你自己信任的配置。',
            helperMaxLines: 2,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('import-center-url-submit'),
          onPressed: _submit,
          child: const Text('导入'),
        ),
      ],
    );
  }
}
