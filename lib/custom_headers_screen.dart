import 'package:flutter/material.dart';

import 'custom_headers.dart';
import 'local_store.dart';

class CustomHeadersScreen extends StatefulWidget {
  const CustomHeadersScreen({super.key, required this.store});

  final LocalStore store;

  @override
  State<CustomHeadersScreen> createState() => _CustomHeadersScreenState();
}

class _CustomHeadersScreenState extends State<CustomHeadersScreen> {
  List<CustomHeaderRule> _rules = const [];

  @override
  void initState() {
    super.initState();
    _rules = widget.store.customHeaderRules;
  }

  Future<void> _persist(List<CustomHeaderRule> rules) async {
    setState(() => _rules = rules);
    await widget.store.setCustomHeaderRules(rules);
  }

  Future<void> _edit(CustomHeaderRule? existing) async {
    final host = TextEditingController(text: existing?.host ?? '');
    final name = TextEditingController(text: existing?.name ?? '');
    final value = TextEditingController(text: existing?.value ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? '添加请求头' : '编辑请求头'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: host,
              decoration: const InputDecoration(
                labelText: '匹配域名',
                hintText: '如 example.com、*.example.com',
              ),
            ),
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '请求头名'),
            ),
            TextField(
              controller: value,
              decoration: const InputDecoration(labelText: '请求头值'),
            ),
          ],
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
    final rule = CustomHeaderRule(
      host: host.text.trim(),
      name: name.text.trim(),
      value: value.text.trim(),
    );
    if (rule.host.isEmpty || rule.name.isEmpty) return;
    final next = List<CustomHeaderRule>.from(_rules);
    if (existing == null) {
      next.add(rule);
    } else {
      final index = _rules.indexOf(existing);
      if (index >= 0) next[index] = rule;
    }
    await _persist(next);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('自定义请求头')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '只对匹配域名的视频请求生效，域名可写 example.com（含子域名）或 *.example.com；含 / 或 :// 时按网址包含匹配。站点自带的请求头优先，自定义的不覆盖它。',
            ),
          ),
          SwitchListTile.adaptive(
            title: const Text('启用自定义请求头'),
            value: widget.store.customHeadersEnabled,
            onChanged: (value) async {
              await widget.store.setCustomHeadersEnabled(value);
              if (mounted) setState(() {});
            },
          ),
          Expanded(
            child: _rules.isEmpty
                ? const Center(child: Text('还没有规则，点右下角添加'))
                : ListView.builder(
                    itemCount: _rules.length,
                    itemBuilder: (context, index) {
                      final rule = _rules[index];
                      return ListTile(
                        title: Text('${rule.name}: ${rule.value}'),
                        subtitle: Text(rule.host),
                        onTap: () => _edit(rule),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            final next =
                                List<CustomHeaderRule>.from(_rules)
                                  ..removeAt(index);
                            await _persist(next);
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(null),
        child: const Icon(Icons.add),
      ),
    );
  }
}
