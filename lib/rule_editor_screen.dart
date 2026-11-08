import 'package:flutter/material.dart';

import 'core_bridge.dart';

class RuleEditorScreen extends StatefulWidget {
  const RuleEditorScreen({super.key, required this.repository});

  final AppRepository repository;

  @override
  State<RuleEditorScreen> createState() => _RuleEditorScreenState();
}

class _RuleEditorScreenState extends State<RuleEditorScreen> {
  final _name = TextEditingController();
  final _base = TextEditingController();
  final _rule = TextEditingController();
  String _kind = '';
  bool _busy = false;
  String? _result;
  List<Map<String, String>> _preview = const [];

  @override
  void dispose() {
    _name.dispose();
    _base.dispose();
    _rule.dispose();
    super.dispose();
  }

  Future<void> _validate() async {
    setState(() {
      _busy = true;
      _result = null;
      _preview = const [];
    });
    try {
      final checked = await widget.repository.validateCustomRule(
        name: _name.text,
        base: _base.text,
        rule: _rule.text,
        kind: _kind,
      );
      if (mounted) {
        setState(
          () => _result =
              '校验通过：${checked['name'] ?? ''}（${checked['base'] ?? ''}）',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _result = '校验失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runPreview() async {
    setState(() {
      _busy = true;
      _result = null;
      _preview = const [];
    });
    try {
      final items = await widget.repository.previewCustomRule(
        name: _name.text,
        base: _base.text,
        rule: _rule.text,
        kind: _kind,
      );
      if (mounted) {
        setState(() {
          _preview = items;
          _result = items.isEmpty ? '试跑成功：未取到条目' : '试跑成功：${items.length} 条';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _result = '试跑失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('蜘蛛规则编辑器')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '名称'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _base,
            decoration: const InputDecoration(
              labelText: '源网址',
              hintText: 'https://example.com',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _kind,
            decoration: const InputDecoration(labelText: '源类型'),
            items: const [
              DropdownMenuItem(value: '', child: Text('自动识别')),
              DropdownMenuItem(value: 'web', child: Text('网页源')),
              DropdownMenuItem(value: 'json', child: Text('JSON 源')),
            ],
            onChanged: (value) => setState(() => _kind = value ?? ''),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _rule,
            maxLines: 12,
            decoration: const InputDecoration(
              labelText: 'XBPQ 规则 JSON',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _validate,
                icon: const Icon(Icons.check_rounded),
                label: const Text('校验'),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _runPreview,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('本地试跑'),
              ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: SelectableText(_result!),
            ),
          if (_preview.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final item in _preview)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  item['title'] ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if ((item['id'] ?? '').isNotEmpty) Text(item['id']!),
                    if ((item['cover'] ?? '').isNotEmpty)
                      Text(
                        item['cover']!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
