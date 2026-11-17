import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'html_host/html_site.dart';
import 'import_center.dart';
import 'import_file_store.dart';
import 'imported_site_record.dart';
import 'local_store.dart';
import 'tvbox_config.dart';

/// 站点选择弹窗 + 号的导入分流：本地 py、远程配置与 HTML 站源三条。
///
/// 逻辑原样搬自已删的“内容源管理”页（`_importPy` / `_addInterface` /
/// `_AddInterfaceDialog`），只改挂名、不重写；弹窗一律用当前主题色
/// （AlertDialog / Dialog 主题），不固定白底。HTML 一条为新增：
/// 导入 .html 单文件首页或 .json 注入清单，注册成普通站点条目。

enum _SiteImportChoice { localPy, remoteConfig, htmlSite }

/// 打开导入分流弹窗，跑完一条导入流程后返回是否导进了东西。
/// 调用方据此决定是否刷新站源列表。
Future<bool> showSiteImportFlow({
  required BuildContext context,
  required AppRepository repository,
  required LocalStore store,
}) async {
  final choice = await showDialog<_SiteImportChoice>(
    context: context,
    builder: (_) => const SiteImportChoiceDialog(),
  );
  if (choice == null || !context.mounted) return false;
  switch (choice) {
    case _SiteImportChoice.localPy:
      return importLocalPyFiles(
        context: context,
        repository: repository,
        store: store,
      );
    case _SiteImportChoice.remoteConfig:
      return addRemoteInterface(context: context, repository: repository);
    case _SiteImportChoice.htmlSite:
      return importLocalHtmlFiles(context: context, store: store);
  }
}

/// 分流弹窗本体：两个选项，主题色 AlertDialog。
class SiteImportChoiceDialog extends StatelessWidget {
  const SiteImportChoiceDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('导入站点'),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const ValueKey('site-import-local-py'),
            leading: Icon(Icons.upload_rounded, color: colors.primary),
            title: const Text('导入本地 py'),
            subtitle: const Text('从手机里选 .py 蜘蛛文件'),
            onTap: () => Navigator.pop(context, _SiteImportChoice.localPy),
          ),
          ListTile(
            key: const ValueKey('site-import-remote-config'),
            leading: Icon(Icons.add_link_rounded, color: colors.primary),
            title: const Text('添加远程配置'),
            subtitle: const Text('填 TVBox 配置地址或选本地配置文件'),
            onTap: () =>
                Navigator.pop(context, _SiteImportChoice.remoteConfig),
          ),
          ListTile(
            key: const ValueKey('site-import-html-site'),
            leading: Icon(Icons.web_rounded, color: colors.primary),
            title: const Text('导入 HTML 站源'),
            subtitle: const Text('选 .html 单文件首页或 .json 注入清单'),
            onTap: () => Navigator.pop(context, _SiteImportChoice.htmlSite),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

void _showSiteImportMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// 本地 py 导入：原“内容源管理”页 `_importPy` 原样搬运。
Future<bool> importLocalPyFiles({
  required BuildContext context,
  required AppRepository repository,
  required LocalStore store,
}) async {
  final files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['py'],
  );
  if (files.isEmpty || !context.mounted) return false;
  try {
    final candidates = <ImportCandidate>[];
    for (final file in files) {
      candidates.add(
        ImportCandidate(name: file.name, bytes: await file.readAsBytes()),
      );
    }
    final engine = ImportEngine(store: store, repository: repository);
    final report = await engine.importAll(candidates);
    if (context.mounted) _showSiteImportMessage(context, report.summary);
    return report.successCount > 0;
  } catch (error) {
    if (context.mounted) _showSiteImportMessage(context, error.toString());
    return false;
  }
}

/// HTML 站源导入：.html 单文件首页（Route A）或 .json 注入清单
/// （Route B）。内容校验与命名走 HtmlSiteEntry，去重与登记走导入
/// 站登记表（与 py 导入同一套 id/哈希规则），导完即为普通站点条目。
Future<bool> importLocalHtmlFiles({
  required BuildContext context,
  required LocalStore store,
}) async {
  final files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['html', 'htm', 'json'],
  );
  if (files.isEmpty || !context.mounted) return false;
  final records = List<ImportedSiteRecord>.of(store.importedSiteRecords);
  var success = 0;
  var duplicate = 0;
  var failed = 0;
  final failures = <String>[];
  for (final file in files) {
    try {
      final bytes = await file.readAsBytes();
      final hash = contentHashOf(bytes);
      final sameHash = records
          .where((record) => record.contentHash == hash)
          .firstOrNull;
      if (sameHash != null) {
        duplicate++;
        continue;
      }
      final parsed = HtmlSiteEntry.fromFileContent(
        siteKey: 'html:preview',
        fileName: file.name,
        bytes: bytes,
      );
      final baseName = file.name.contains('.')
          ? file.name.substring(0, file.name.lastIndexOf('.'))
          : file.name;
      var id = 'html:${importSlug(baseName)}';
      if (records.any((record) => record.id == id)) {
        id = '$id-${hash.substring(0, 6)}';
      }
      final extension = file.name.toLowerCase().endsWith('.json') ? 'json' : 'html';
      final fileName = await ImportFileStore.save(id, extension, bytes);
      records.add(
        ImportedSiteRecord(
          id: id,
          name: parsed.siteName,
          type: ImportedSiteRecord.typeHtml,
          fileName: fileName,
          contentHash: hash,
          importedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      success++;
    } catch (error) {
      failed++;
      failures.add('${file.name}：$error');
    }
  }
  if (success > 0) await store.syncImportedSites(records);
  if (context.mounted) {
    final summary = '成功 $success · 重复跳过 $duplicate · 失败 $failed'
        '${failures.isEmpty ? '' : '（${failures.first}）'}';
    _showSiteImportMessage(context, summary);
  }
  return success > 0;
}

/// 远程配置导入：原“内容源管理”页 `_addInterface` 原样搬运。
Future<bool> addRemoteInterface({
  required BuildContext context,
  required AppRepository repository,
}) async {
  final result = await showDialog<InterfaceInput>(
    context: context,
    builder: (_) => const AddInterfaceDialog(),
  );
  if (result == null || !context.mounted) return false;
  try {
    final importer = TvBoxImporter(repository);
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
      _showSiteImportMessage(context, '请填写接口地址或选择本地文件');
      return false;
    }
    if (context.mounted) {
      _showSiteImportMessage(context, '已导入「${report.name}」');
    }
    return true;
  } catch (error) {
    if (context.mounted) _showSiteImportMessage(context, error.toString());
    return false;
  }
}

class InterfaceInput {
  const InterfaceInput({
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

/// 添加接口弹窗：原“内容源管理”页 `_AddInterfaceDialog` 原样搬运，
/// 字段与文案一字不动，主题色 AlertDialog。
class AddInterfaceDialog extends StatefulWidget {
  const AddInterfaceDialog({super.key});

  @override
  State<AddInterfaceDialog> createState() => _AddInterfaceDialogState();
}

class _AddInterfaceDialogState extends State<AddInterfaceDialog> {
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
            InterfaceInput(
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
