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

/// 站点选择弹窗 + 号的导入分流：本地文件（.py / .json / .html，
/// 一次多选批量）、远程配置两条。
///
/// 本地文件一条由旧的三个入口合并而来（导入本地 py、导入 HTML 站源、
/// 导入 JSON）：选择器一次打开、可多选，按扩展名分流到现有解析器
/// （.py 走蜘蛛导入、.json 走视频列表/注入清单/TVBox 配置、
/// .html 走单文件首页），解析逻辑一字不改，只换入口。
/// “添加远程配置”不动，仍是单独入口。
///
/// 反馈铁律（修“选完文件没提示”的毛病）：
/// - 选择器打不开/抛错：立刻弹错，不静默；
/// - 导入中有进度条在转，不再是选完就死等；
/// - 单个文件读失败/解析失败只记一条失败 outcome，继续导后面；
/// - 每成功一个立刻同步登记，先导进的站不等整批跑完就进列表；
/// - 整批跑完弹一次汇总：成功/重复/失败数 + 每个未成功文件的
///   名字与原因。
///
/// 弹窗一律用当前主题色（AlertDialog / Dialog 主题），不固定白底。

enum _SiteImportChoice { localFiles, remoteConfig }

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
    case _SiteImportChoice.localFiles:
      return importLocalFiles(
        context: context,
        repository: repository,
        store: store,
      );
    case _SiteImportChoice.remoteConfig:
      return addRemoteInterface(context: context, repository: repository);
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
            key: const ValueKey('site-import-local-files'),
            leading: Icon(Icons.upload_rounded, color: colors.primary),
            title: const Text('导入本地文件'),
            subtitle: const Text('从手机里选 .py / .json / .html 文件，可多选批量导入'),
            onTap: () => Navigator.pop(context, _SiteImportChoice.localFiles),
          ),
          ListTile(
            key: const ValueKey('site-import-remote-config'),
            leading: Icon(Icons.add_link_rounded, color: colors.primary),
            title: const Text('添加远程配置'),
            subtitle: const Text('填 TVBox 配置地址或选本地配置文件'),
            onTap: () =>
                Navigator.pop(context, _SiteImportChoice.remoteConfig),
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

/// 汇总文本：第一行是成功/重复/失败计数，其后逐条列出每个未成功
/// （重复跳过/失败）的文件名与原因；全部成功时只有计数行。
/// 纯函数，便于单测。
String buildImportResultText(List<ImportOutcome> outcomes) {
  final report = ImportReport(outcomes);
  final lines = <String>[
    '成功 ${report.successCount} · 重复跳过 ${report.duplicateCount} · 失败 ${report.failedCount}',
  ];
  for (final outcome in outcomes) {
    if (outcome.ok) continue;
    lines.add('${outcome.fileName}：${outcome.reason}');
  }
  return lines.join('\n');
}

/// 导入完成汇总弹窗：成功/重复/失败数 + 每个未成功文件的名字与
/// 原因，一次弹清。点“确定”后调用方再按返回值切到导入区。
Future<void> showImportResultDialog(
  BuildContext context,
  List<ImportOutcome> outcomes,
) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('导入完成'),
      content: SingleChildScrollView(
        child: Text(buildImportResultText(outcomes)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

/// HTML 单文件导入（Route A）/ .json 注入清单（Route B）：
/// 原 importLocalHtmlFiles 的单文件体原样搬运，只改成逐个文件
/// 返回 ImportOutcome、每成功一个立刻同步登记（多文件混批时
/// 先导进的站不等后一个文件，立刻在列表里看得见）。
/// 每次现读登记表再写回，不拿旧快照覆盖后导进的站。
Future<ImportOutcome> _importOneHtml(
  String fileName,
  List<int> bytes,
  LocalStore store,
) async {
  try {
    final records = List<ImportedSiteRecord>.of(store.importedSiteRecords);
    final hash = contentHashOf(bytes);
    final sameHash =
        records.where((record) => record.contentHash == hash).firstOrNull;
    if (sameHash != null) {
      return ImportOutcome(
        fileName: fileName,
        status: ImportOutcomeStatus.duplicate,
        reason: '内容与已导入的「${sameHash.name}」完全相同，跳过',
        siteName: sameHash.name,
        siteId: sameHash.id,
      );
    }
    final parsed = HtmlSiteEntry.fromFileContent(
      siteKey: 'html:preview',
      fileName: fileName,
      bytes: bytes,
    );
    final baseName = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;
    var id = 'html:${importSlug(baseName)}';
    if (records.any((record) => record.id == id)) {
      id = '$id-${hash.substring(0, 6)}';
    }
    final extension =
        fileName.toLowerCase().endsWith('.json') ? 'json' : 'html';
    final savedFileName = await ImportFileStore.save(id, extension, bytes);
    records.add(
      ImportedSiteRecord(
        id: id,
        name: parsed.siteName,
        type: ImportedSiteRecord.typeHtml,
        fileName: savedFileName,
        contentHash: hash,
        importedAtMs: DateTime.now().millisecondsSinceEpoch,
        baseName: parsed.siteName,
      ),
    );
    await store.syncImportedSites(records);
    return ImportOutcome(
      fileName: fileName,
      status: ImportOutcomeStatus.success,
      reason: '已注册为 HTML 站源「${parsed.siteName}」',
      siteName: parsed.siteName,
      siteId: id,
    );
  } catch (error) {
    return ImportOutcome(
      fileName: fileName,
      status: ImportOutcomeStatus.failed,
      reason: error.toString(),
    );
  }
}

/// 本地文件统一导入：.py / .json / .html（.htm）一次选多个、批量导。
/// 按扩展名分流到现有解析器：py/json 走 ImportEngine（蜘蛛导入、视频
/// 列表、TVBox 配置、XBPQ 规则、自定义源全是它原有分支），html 走
/// _importOneHtml（单文件首页 / 注入清单）。解析逻辑一字不改，只换入口。
///
/// 旧毛病修法（对照诊断）：
/// - 选择器调用原来在 try 外面：打不开/抛错直接炸到调用方，全程无提示。
///   现在包进 try/catch，打不开立刻弹错。
/// - 选择器返回空原来直接 return false：用户分不清是取消还是选完丢了。
///   现在只有用户主动取消才静默返回（没选文件本就没什么可报）；选到的
///   文件从读字节起每一步都有 outcome、有汇总。
/// - 桥校验/点名原来最长能静默等 30+70 秒、登记又要等整批跑完才同步，
///   用户以为导失败了。点名 ping 已在引擎里压到 10 秒（见 import_center.dart）；
///   这里再逐个文件调 importAll、每成功一个立刻同步，先导进的站不等
///   后一个文件就进列表；全程进度条在转，跑完弹一次汇总。
Future<bool> importLocalFiles({
  required BuildContext context,
  required AppRepository repository,
  required LocalStore store,
}) async {
  // file_picker 13.1.0：pickFiles 直接回 List<PlatformFile>（无
  // FilePickerResult、也无 allowMultiple 参数，pickFiles 本来就
  // 允许多选；用户取消回空列表），照树里别处的写法调。
  List<PlatformFile> files;
  try {
    files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['py', 'json', 'html', 'htm'],
    );
  } catch (error) {
    if (context.mounted) {
      _showSiteImportMessage(context, '打开文件选择器失败：$error');
    }
    return false;
  }
  if (files.isEmpty || !context.mounted) {
    return false; // 用户在选择器里点了取消：不算失败，不弹提示。
  }
  final progressText = ValueNotifier<String>('正在准备…');
  var progressOpen = false;
  if (context.mounted) {
    progressOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 16),
                Expanded(
                  child: ValueListenableBuilder<String>(
                    valueListenable: progressText,
                    builder: (_, text, _) => Text(text),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  final outcomes = <ImportOutcome>[];
  try {
    final engine = ImportEngine(store: store, repository: repository);
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      progressText.value = '正在导入第 ${i + 1}/${files.length} 个：${file.name}';
      List<int> bytes;
      try {
        bytes = await file.readAsBytes();
      } catch (error) {
        outcomes.add(
          ImportOutcome(
            fileName: file.name,
            status: ImportOutcomeStatus.failed,
            reason: '读取文件失败：$error',
          ),
        );
        continue;
      }
      final ext = file.name.contains('.')
          ? file.name
                .substring(file.name.lastIndexOf('.') + 1)
                .toLowerCase()
          : '';
      if (ext == 'html' || ext == 'htm') {
        outcomes.add(await _importOneHtml(file.name, bytes, store));
        continue;
      }
      try {
        final report = await engine.importAll([
          ImportCandidate(name: file.name, bytes: bytes),
        ]);
        outcomes.addAll(report.outcomes);
      } catch (error) {
        outcomes.add(
          ImportOutcome(
            fileName: file.name,
            status: ImportOutcomeStatus.failed,
            reason: error.toString(),
          ),
        );
      }
    }
  } finally {
    if (progressOpen && context.mounted) Navigator.of(context).pop();
    progressText.dispose();
  }
  final anySuccess = outcomes.any((outcome) => outcome.ok);
  if (!context.mounted) return anySuccess;
  await showImportResultDialog(context, outcomes);
  return anySuccess;
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

  // 选文件按钮原来没有 try/catch：选择器打不开/抛错直接炸到
  // unawaited 调用方，全程无提示（与旧的三个本地导入入口同一毛病）。
  // 读不到路径也弹一句，不静默返回。
  Future<void> _pickFile() async {
    try {
      final file = await FilePicker.pickFile(type: FileType.any);
      if (file == null) return;
      if (file.path == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('无法读取所选文件')),
          );
        }
        return;
      }
      setState(() {
        _filePath = file.path;
        _fileName = file.name;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('选择文件失败：$error')));
      }
    }
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
