import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bottom_nav_config.dart';

/// 设置 → 底部导航管理（用户 2026-11-27 令）：被隐藏的底部页签都在
/// 这里逐个恢复，也可一键重置默认布局。隐藏只是不显示、不是删除，
/// 恢复后页签回到它在排列里的原位；顺序调整在底部栏长按进编辑态
/// 拖动完成，这里同时列出当前顺序供查看。
class BottomNavManagerPage extends StatefulWidget {
  const BottomNavManagerPage({super.key, required this.preferences});

  final SharedPreferences preferences;

  @override
  State<BottomNavManagerPage> createState() => _BottomNavManagerPageState();
}

class _BottomNavManagerPageState extends State<BottomNavManagerPage> {
  late BottomNavLayout _layout;

  @override
  void initState() {
    super.initState();
    _layout = BottomNavLayout.load(widget.preferences);
  }

  void _persist() {
    unawaited(_layout.save(widget.preferences));
  }

  void _hide(BottomNavTab tab) {
    if (!_layout.hide(tab)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('至少保留一个页签')));
      return;
    }
    setState(() {});
    _persist();
  }

  void _show(BottomNavTab tab) {
    setState(() => _layout.show(tab));
    _persist();
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重置默认布局'),
        content: const Text('底部导航恢复成出厂顺序（片库/直播/听读/网盘/小程序/演员库/游戏区/我的），被隐藏的页签全部恢复显示。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _layout.reset());
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _layout.visible;
    final hiddenTabs = [
      for (final tab in _layout.order)
        if (_layout.hidden.contains(tab)) tab,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('底部导航管理')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              '显示中（长按底部栏任意页签可进编辑态拖动排序）',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          for (final tab in visible)
            ListTile(
              leading: Icon(tab.icon),
              title: Text(tab.label),
              trailing: TextButton(
                key: ValueKey('nav-manager-hide-${tab.id}'),
                onPressed: visible.length > 1 ? () => _hide(tab) : null,
                child: const Text('隐藏'),
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text(
              '已隐藏',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          if (hiddenTabs.isEmpty)
            const ListTile(title: Text('没有被隐藏的页签', style: TextStyle(fontSize: 13)))
          else
            for (final tab in hiddenTabs)
              ListTile(
                leading: Icon(tab.icon),
                title: Text(tab.label),
                trailing: TextButton(
                  key: ValueKey('nav-manager-show-${tab.id}'),
                  onPressed: () => _show(tab),
                  child: const Text('恢复显示'),
                ),
              ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              '隐藏只是不在底部栏显示，随时可以在这里恢复，不会删除任何功能。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
            child: OutlinedButton(
              key: const ValueKey('nav-manager-reset'),
              onPressed: _reset,
              child: const Text('重置默认布局'),
            ),
          ),
        ],
      ),
    );
  }
}
