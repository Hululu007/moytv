import 'package:flutter/material.dart';

import 'socks5_proxy.dart';

/// 某资源的代理选择行：跟随默认 / 直连 / 某个已存 SOCKS5 代理。
///
/// 选择实时写回持久化并同步路由快照，之后该资源的请求就走所选
/// 路由（直播链路 LiveHttp、抓取链路 ContentHttp）。已停用的代理
/// 仍可被选中但不生效（路由回落默认），行内会标“已停用”。
class Socks5ResourceProxyPicker extends StatefulWidget {
  const Socks5ResourceProxyPicker({
    super.key,
    required this.resourceKey,
    required this.label,
    this.service,
  });

  final String resourceKey;
  final String label;
  final Socks5ProxyService? service;

  @override
  State<Socks5ResourceProxyPicker> createState() =>
      _Socks5ResourceProxyPickerState();
}

class _Socks5ResourceProxyPickerState
    extends State<Socks5ResourceProxyPicker> {
  late final Socks5ProxyService _service =
      widget.service ?? Socks5ProxyService();
  List<Socks5ProxyEntry> _proxies = const [];
  String _assignment = '';
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final proxies = await _service.loadProxies();
    final assignments = await _service.loadAssignments();
    if (!mounted) return;
    setState(() {
      _proxies = proxies;
      _assignment = assignments[widget.resourceKey] ?? '';
      _loaded = true;
    });
  }

  Future<void> _change(String? value) async {
    if (value == null || _saving) return;
    setState(() => _saving = true);
    try {
      await _service.setAssignment(
        widget.resourceKey,
        value.isEmpty ? null : value,
      );
      if (mounted) setState(() => _assignment = value);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(widget.label),
        trailing: const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final knownIds = {
      '',
      socks5DirectAssignment,
      for (final proxy in _proxies) proxy.id,
    };
    final value = knownIds.contains(_assignment) ? _assignment : '';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(widget.label),
      trailing: SizedBox(
        width: 190,
        child: DropdownButtonFormField<String>(
          initialValue: value,
          isDense: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
          items: [
            const DropdownMenuItem(value: '', child: Text('跟随默认')),
            const DropdownMenuItem(
              value: socks5DirectAssignment,
              child: Text('直连'),
            ),
            for (final proxy in _proxies)
              DropdownMenuItem(
                value: proxy.id,
                child: Text(
                  proxy.enabled
                      ? proxy.name
                      : '${proxy.name}（已停用）',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: _saving ? null : _change,
        ),
      ),
    );
  }
}
