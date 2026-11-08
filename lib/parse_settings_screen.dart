import 'dart:async';

import 'package:flutter/material.dart';

import 'playback_parse.dart';

/// 解析接口设置：列表增删改 + 默认选中，读写 ParseInterfaceStore
/// （播放器 initState 自动读取选中项套用）。
class ParseSettingsScreen extends StatefulWidget {
  const ParseSettingsScreen({super.key});

  @override
  State<ParseSettingsScreen> createState() => _ParseSettingsScreenState();
}

class _ParseSettingsScreenState extends State<ParseSettingsScreen> {
  List<ParseInterface> _items = const [];
  String _selectedId = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final items = await ParseInterfaceStore.load();
      final selected = await ParseInterfaceStore.loadSelectedId();
      if (!mounted) return;
      setState(() {
        _items = items;
        _selectedId = selected;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _persist(List<ParseInterface> items) async {
    setState(() => _items = items);
    await ParseInterfaceStore.save(items);
  }

  Future<void> _select(String id) async {
    setState(() => _selectedId = id);
    await ParseInterfaceStore.saveSelectedId(id);
  }

  Future<void> _edit(ParseInterface? existing) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final url = TextEditingController(text: existing?.url ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? '添加解析接口' : '编辑解析接口'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            TextField(
              controller: url,
              decoration: const InputDecoration(
                labelText: '接口地址',
                hintText: 'https://example.com/?url={url}',
              ),
              keyboardType: TextInputType.url,
            ),
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                '地址可含 {url} 占位符；不含时将原始播放页地址直接拼在后面。',
                style: TextStyle(fontSize: 12),
              ),
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
    final cleanUrl = url.text.trim();
    if (cleanUrl.isEmpty ||
        (!cleanUrl.startsWith('http://') && !cleanUrl.startsWith('https://'))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('接口地址需以 http:// 或 https:// 开头')),
      );
      return;
    }
    final cleanName = name.text.trim().isEmpty ? cleanUrl : name.text.trim();
    if (existing == null) {
      await _persist([
        ..._items,
        ParseInterface(
          id: 'p${DateTime.now().microsecondsSinceEpoch}',
          name: cleanName,
          url: cleanUrl,
        ),
      ]);
    } else {
      await _persist([
        for (final item in _items)
          if (item.id == existing.id)
            ParseInterface(
              id: item.id,
              name: cleanName,
              url: cleanUrl,
              source: existing.source,
              enabled: existing.enabled,
            )
          else
            item,
      ]);
    }
  }

  Future<void> _toggleEnabled(ParseInterface item, bool value) async {
    await _persist([
      for (final entry in _items)
        if (entry.id == item.id)
          ParseInterface(
            id: entry.id,
            name: entry.name,
            url: entry.url,
            source: entry.source,
            enabled: value,
          )
        else
          entry,
    ]);
    if (!value && _selectedId == item.id) await _select('');
  }

  Future<void> _move(ParseInterface item, int delta) async {
    final items = [..._items];
    final index = items.indexWhere((entry) => entry.id == item.id);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= items.length) return;
    final moved = items.removeAt(index);
    items.insert(target, moved);
    await _persist(items);
  }

  Future<void> _remove(ParseInterface item) async {
    await _persist([
      for (final entry in _items)
        if (entry.id != item.id) entry,
    ]);
    if (_selectedId == item.id) await _select('');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('解析接口')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: _loading
            ? const Center(child: CircularProgressIndicator.adaptive())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text(
                      '启用的接口按顺序用于需要解析的播放（依次尝试，全部失败则报错）；'
                      '选中的默认接口用于传统壳源的地址改写。接口由你自行填写，本机保存，默认无任何接口。',
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  RadioGroup<String>(
                    groupValue: _selectedId,
                    onChanged: (value) => _select(value ?? ''),
                    child: Column(
                      children: [
                        RadioListTile<String>(
                          value: '',
                          title: const Text('不使用解析'),
                          subtitle: const Text('播放地址原样交给播放器'),
                        ),
                        for (final item in _items)
                          RadioListTile<String>(
                            value: item.id,
                            title: Text(item.name),
                            subtitle: Text(
                              item.url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            secondary: Wrap(
                              spacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Switch(
                                  value: item.enabled,
                                  onChanged: (value) =>
                                      _toggleEnabled(item, value),
                                ),
                                IconButton(
                                  tooltip: '上移',
                                  icon: const Icon(Icons.arrow_upward_rounded),
                                  onPressed: () => _move(item, -1),
                                ),
                                IconButton(
                                  tooltip: '下移',
                                  icon: const Icon(
                                    Icons.arrow_downward_rounded,
                                  ),
                                  onPressed: () => _move(item, 1),
                                ),
                                IconButton(
                                  tooltip: '编辑',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => _edit(item),
                                ),
                                IconButton(
                                  tooltip: '删除',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _remove(item),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => _edit(null),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('添加解析接口'),
                  ),
                ],
              ),
      ),
    ),
  );
}
