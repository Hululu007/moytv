import 'dart:async';

import 'package:flutter/material.dart';

import 'import_center.dart';
import 'zip_contents.dart';
import 'zip_install.dart';

/// ZIP 选择安装器：打开 zip 后先列出识别到的内容，分 影视源 /
/// 直播列表 / 组件 / 无法识别 四类，用户勾选后点“安装”才装，
/// 不勾选的不装，无法识别的置灰不装。
///
/// 两条入口共用本屏：文件管理器点 zip 选魔蚁（plugin_share_intent）
/// 与插件市场“从文件安装”（plugin_market_screen），都走 [openZipPicker]。

String _kindTitle(ZipItemKind kind) {
  switch (kind) {
    case ZipItemKind.videoSource:
      return '影视源';
    case ZipItemKind.liveList:
      return '直播列表';
    case ZipItemKind.component:
      return '组件';
    case ZipItemKind.unknown:
      return '无法识别';
  }
}

IconData _kindIcon(ZipItemKind kind) {
  switch (kind) {
    case ZipItemKind.videoSource:
      return Icons.movie_outlined;
    case ZipItemKind.liveList:
      return Icons.live_tv_rounded;
    case ZipItemKind.component:
      return Icons.extension_outlined;
    case ZipItemKind.unknown:
      return Icons.help_outline_rounded;
  }
}

/// 检查 zip 内容并打开选择器：解包失败或包里没有文件时只弹提示，
/// 不开屏。返回 true 表示装上了东西（调用方需刷新站点/订阅列表）。
Future<bool> openZipPicker({
  required BuildContext context,
  required String zipName,
  required List<int> zipBytes,
  required ZipPickInstaller installer,
}) async {
  final ZipInspection inspection;
  try {
    inspection = inspectZipBytes(zipBytes, zipName: zipName);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('zip 解包失败：$error')));
    }
    return false;
  }
  if (inspection.items.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('zip 里没有找到任何文件')));
    }
    return false;
  }
  final changed = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => ZipPickScreen(
        zipName: zipName,
        items: inspection.items,
        installer: installer,
      ),
    ),
  );
  return changed == true;
}

class ZipPickScreen extends StatefulWidget {
  const ZipPickScreen({
    super.key,
    required this.zipName,
    required this.items,
    required this.installer,
  });

  final String zipName;
  final List<ZipPickItem> items;
  final ZipPickInstaller installer;

  @override
  State<ZipPickScreen> createState() => _ZipPickScreenState();
}

class _ZipPickScreenState extends State<ZipPickScreen> {
  late final ZipPickSelection _selection = ZipPickSelection.allInstallable(
    widget.items,
  );
  var _installing = false;

  List<ZipPickItem> _of(ZipItemKind kind) =>
      [for (final item in widget.items) if (item.kind == kind) item];

  Future<void> _install() async {
    final selected = _selection.selectedItems(widget.items);
    if (selected.isEmpty || _installing) return;
    setState(() => _installing = true);
    final ImportReport report;
    try {
      report = await widget.installer.install(selected);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
    if (!mounted) return;
    await _showBatchReport(report);
    if (!mounted) return;
    Navigator.pop(context, report.successCount > 0);
  }

  Future<void> _showBatchReport(ImportReport report) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('安装结果'),
        content: SizedBox(
          width: double.maxFinite,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 400),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final outcome in report.outcomes)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      outcome.status == ImportOutcomeStatus.success
                          ? Icons.check_circle_outline
                          : outcome.status == ImportOutcomeStatus.duplicate
                          ? Icons.skip_next_rounded
                          : Icons.error_outline,
                    ),
                    title: Text(outcome.fileName),
                    subtitle: Text(
                      '${_outcomeLabel(outcome.status)}：${outcome.reason}',
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

  String _outcomeLabel(ImportOutcomeStatus status) {
    switch (status) {
      case ImportOutcomeStatus.success:
        return '成功';
      case ImportOutcomeStatus.duplicate:
        return '跳过';
      case ImportOutcomeStatus.failed:
        return '失败';
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedCount = _selection.selectedCount(widget.items);
    final installableCount = widget.items
        .where((item) => item.installable)
        .length;
    return Scaffold(
      appBar: AppBar(title: const Text('选择要安装的内容')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Text(
                  '「${widget.zipName}」里识别到 ${widget.items.length} 个文件，'
                  '勾选后点“安装”；不勾选的不装。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                if (installableCount == 0)
                  const Text('没有可安装的内容：下面列出的文件都无法识别。')
                else
                  Text(
                    '可安装 $installableCount 个，已选 $selectedCount 个。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 8),
                for (final kind in ZipItemKind.values) ...[
                  if (_of(kind).isNotEmpty) _section(kind),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(child: Text('已选 $selectedCount 项')),
                  TextButton(
                    onPressed: _installing
                        ? null
                        : () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: const ValueKey('zip-pick-install'),
                    onPressed: selectedCount == 0 || _installing
                        ? null
                        : () => unawaited(_install()),
                    icon: _installing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_rounded, size: 20),
                    label: Text(_installing ? '安装中…' : '安装'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(ZipItemKind kind) {
    final items = _of(kind);
    final installable = kind != ZipItemKind.unknown;
    final allSelected = installable && _selection.allSelected(items);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(_kindIcon(kind), size: 20),
            const SizedBox(width: 8),
            Text(
              '${_kindTitle(kind)}（${items.length}）',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            if (installable)
              TextButton(
                key: ValueKey('zip-pick-toggle-$kind'),
                onPressed: _installing
                    ? null
                    : () => setState(
                        () => _selection.selectKind(
                          widget.items,
                          kind,
                          !allSelected,
                        ),
                      ),
                child: Text(allSelected ? '全不选' : '全选'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _row(items[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(ZipPickItem item) {
    final enabled = item.installable && !_installing;
    final colors = Theme.of(context).colorScheme;
    return CheckboxListTile(
      key: ValueKey('zip-pick-item-${item.key}'),
      value: _selection.isSelected(item),
      onChanged: enabled
          ? (value) => setState(
              () => _selection.setSelected(item, value == true),
            )
          : null,
      secondary: Icon(
        _kindIcon(item.kind),
        color: item.installable ? null : colors.outline,
      ),
      title: Text(
        item.name,
        style: item.installable
            ? null
            : TextStyle(color: colors.onSurface.withValues(alpha: 0.45)),
      ),
      subtitle: Text(
        item.detail,
        style: item.installable
            ? null
            : TextStyle(color: colors.onSurface.withValues(alpha: 0.45)),
      ),
      controlAffinity: ListTileControlAffinity.trailing,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
    );
  }
}
