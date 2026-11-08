import 'package:flutter/material.dart';

import 'core_bridge.dart';

String maskHongguoDeviceId(String value) {
  if (value.contains('…')) return value;
  if (value.length > 10) {
    return '${value.substring(0, 6)}…${value.substring(value.length - 4)}';
  }
  if (value.length > 4) return '…${value.substring(value.length - 4)}';
  if (value.isEmpty) return '暂无';
  return '****';
}

class HongguoDeviceProfile {
  const HongguoDeviceProfile({
    required this.registered,
    required this.limited,
    required this.deviceId,
    required this.installId,
    this.changed = false,
  });

  factory HongguoDeviceProfile.fromJson(Map<String, dynamic> json) =>
      HongguoDeviceProfile(
        registered: json['registered'] == true,
        limited: json['limited'] == true,
        deviceId: maskHongguoDeviceId(json['deviceId'] as String? ?? ''),
        installId: maskHongguoDeviceId(json['installId'] as String? ?? ''),
        changed: json['changed'] == true,
      );

  final bool registered;
  final bool limited;
  final String deviceId;
  final String installId;
  final bool changed;

  String get statusLabel {
    if (limited) return '受限';
    if (registered) return '已注册';
    return '未注册';
  }
}

class HongguoDeviceScreen extends StatefulWidget {
  const HongguoDeviceScreen({super.key, required this.repository});

  final AppRepository repository;

  @override
  State<HongguoDeviceScreen> createState() => _HongguoDeviceScreenState();
}

class _HongguoDeviceScreenState extends State<HongguoDeviceScreen> {
  HongguoDeviceProfile? _profile;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.repository.hongguoDeviceStatus();
      if (!mounted) return;
      setState(() {
        _profile = HongguoDeviceProfile.fromJson(result);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _profile = null;
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _run(
    Future<Map<String, dynamic>> Function() action,
    String doneLabel,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await action();
      if (!mounted) return;
      setState(() {
        _profile = HongguoDeviceProfile.fromJson(result);
        _busy = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(doneLabel)),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final registered = profile?.registered ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('设备注册档案')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loading || _busy) const LinearProgressIndicator(),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('注册状态'),
            subtitle: Text(_loading ? '读取中…' : profile?.statusLabel ?? '未知'),
          ),
          ListTile(
            leading: const Icon(Icons.perm_device_information_outlined),
            title: const Text('设备号'),
            subtitle: Text(
              profile == null || profile.deviceId.isEmpty
                  ? '暂无'
                  : profile.deviceId,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.install_mobile_outlined),
            title: const Text('安装号'),
            subtitle: Text(
              profile == null || profile.installId.isEmpty
                  ? '暂无'
                  : profile.installId,
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '失败原因：$_error',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton(
                onPressed: _loading || _busy || registered
                    ? null
                    : () => _run(
                        widget.repository.hongguoDeviceRegister,
                        '设备注册完成',
                      ),
                child: const Text('手动注册'),
              ),
              OutlinedButton(
                onPressed: _loading || _busy || !registered
                    ? null
                    : () => _run(
                        widget.repository.hongguoDeviceReregister,
                        '设备已重新注册',
                      ),
                child: const Text('重新注册'),
              ),
              OutlinedButton(
                onPressed: _loading || _busy
                    ? null
                    : () => _run(
                        widget.repository.hongguoDeviceRefresh,
                        '状态已刷新',
                      ),
                child: const Text('刷新状态'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            '设备身份仅用于红果播放与评论，不是账号登录；身份只截断显示。',
          ),
        ],
      ),
    );
  }
}
