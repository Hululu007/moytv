import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'crack_config.dart';

class CrackConfigSection extends StatefulWidget {
  const CrackConfigSection({super.key, required this.repository});

  final AppRepository repository;

  @override
  State<CrackConfigSection> createState() => _CrackConfigSectionState();
}

class _CrackConfigSectionState extends State<CrackConfigSection> {
  bool _busy = false;
  bool _pushedOnce = false;
  Map<String, CrackSitePresence> _sites = const {};

  @override
  void initState() {
    super.initState();
    unawaited(_refresh(pushStored: true));
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _refresh({bool pushStored = false}) async {
    final summary = await CrackConfigStore.summary();
    if (!mounted) return;
    setState(() => _sites = summary);
    if (pushStored && !_pushedOnce) {
      _pushedOnce = true;
      final text = await CrackConfigStore.exportText();
      if (text.isNotEmpty) {
        try {
          await widget.repository.crackConfigSet(text);
        } catch (_) {}
      }
    }
  }

  Future<void> _pushToCore(String text) async {
    try {
      await widget.repository.crackConfigSet(text);
    } catch (error) {
      if (mounted) _showMessage('本地已保存，但同步到核心失败：$error');
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (files.isEmpty || !mounted) return;
      final bytes = await files.first.readAsBytes();
      String text;
      try {
        text = utf8.decode(bytes);
      } catch (_) {
        _showMessage('导入被拒绝：文件不是有效 UTF-8 文本');
        return;
      }
      final parsed = parseCrackConfig(text);
      if (!parsed.ok || parsed.config == null) {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('导入被拒绝'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('整单未导入，原因：'),
                  const SizedBox(height: 8),
                  for (final error in parsed.errors) Text('· $error'),
                ],
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
        return;
      }
      final saved = await CrackConfigStore.save(parsed.config!);
      await _pushToCore(saved);
      await _refresh();
      if (mounted) _showMessage('已导入 ${parsed.config!.sites.length} 站配置');
    } catch (error) {
      if (mounted) _showMessage('导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final text = await CrackConfigStore.exportText();
      if (text.isEmpty) {
        _showMessage('没有可导出的配置');
        return;
      }
      final saved = await FilePicker.saveFile(
        fileName:
            'crack-config-${DateTime.now().toIso8601String().substring(0, 10)}.json',
        bytes: Uint8List.fromList(utf8.encode(text)),
        mimeType: 'application/json',
      );
      if (saved != null && mounted) _showMessage('已导出到 $saved');
    } catch (error) {
      if (mounted) _showMessage('导出失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeSite(String slot) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除该站配置'),
        content: Text('删除 $slot 的过盾与 VIP 配置，不影响其他站。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final updated = await CrackConfigStore.removeSlot(slot);
      if (updated == null) return;
      if (updated.sites.isEmpty) {
        await _pushToCore('{"version":1,"sites":[]}');
      } else {
        await _pushToCore(jsonEncode(updated.toJson()));
      }
      await _refresh();
      if (mounted) _showMessage('已删除 $slot 配置');
    } catch (error) {
      if (mounted) _showMessage('删除失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final slots = _sites.keys.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Text('过盾与 VIP 配置', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          '导入 JSON 配置文件，让各站过盾与 VIP 配置由壳应用：过盾项按域名作用于抓取层，'
          'VIP 项只在本站已有令牌口子时生效。导入整单校验，不合格整单拒收；'
          '密钥只存本机，不写入日志；导出文件含密钥，请妥善保管。',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const ValueKey('crack-config-import'),
              onPressed: _busy ? null : () => unawaited(_import()),
              icon: const Icon(Icons.shield_outlined, size: 20),
              label: const Text('导入 JSON 配置'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('crack-config-export'),
              onPressed: _busy ? null : () => unawaited(_export()),
              icon: const Icon(Icons.ios_share_rounded, size: 20),
              label: const Text('导出当前配置'),
            ),
          ],
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (slots.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('已导入配置（${slots.length}）'),
          const SizedBox(height: 8),
          for (final slot in slots)
            Card(
              key: ValueKey('crack-config-$slot'),
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.key_rounded),
                title: Text(slot),
                subtitle: Text(
                  '过盾：${_sites[slot]!.hasShield ? '有' : '无'}'
                  ' · VIP：${_sites[slot]!.hasVip ? '有' : '无'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: IconButton(
                  tooltip: '删除',
                  onPressed: _busy ? null : () => unawaited(_removeSite(slot)),
                  icon: Icon(Icons.delete_outline, color: colors.error),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
