/// 局域网服务设置：开关、端口、访问地址。
///
/// 服务默认关闭；开启后同一局域网的手机/电脑用浏览器打开地址就能看，
/// 内容走本机站源。同时开启流媒体网关：应用内播放的 http(s) 直链
/// 也会走本机网关补头与 m3u8 重写（关闭服务即恢复原样）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../local_store.dart';
import 'lan_web_server.dart';
import 'stream_gateway.dart';

class LanWebSettingsScreen extends StatefulWidget {
  const LanWebSettingsScreen({super.key, required this.store});

  final LocalStore store;

  @override
  State<LanWebSettingsScreen> createState() => _LanWebSettingsScreenState();
}

class _LanWebSettingsScreenState extends State<LanWebSettingsScreen> {
  final _portController = TextEditingController();
  bool _busy = false;
  String _address = '';
  String _message = '';

  @override
  void initState() {
    super.initState();
    _portController.text = '${widget.store.lanWebPort}';
    _refreshAddress();
  }

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  Future<void> _refreshAddress() async {
    final controller = LanWebController.current;
    if (controller == null || !controller.running) {
      if (mounted) setState(() => _address = '');
      return;
    }
    final address = await controller.lanAddress();
    if (mounted) setState(() => _address = address);
  }

  Future<void> _toggle(bool enabled) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    final controller = LanWebController.current;
    try {
      if (enabled) {
        if (controller == null) {
          setState(() => _message = '服务尚未初始化，请重启 App 再试');
          return;
        }
        final bound = await controller.start(widget.store.lanWebPort);
        if (bound < 0) {
          setState(() => _message = '启动失败：端口被占用，请换个端口再试');
          return;
        }
        await widget.store.setLanWebEnabled(true);
        if (bound != widget.store.lanWebPort) {
          setState(() => _message = '端口被占用，已顺延到 $bound');
        }
      } else {
        await controller?.stop();
        await widget.store.setLanWebEnabled(false);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _refreshAddress();
      }
    }
  }

  Future<void> _applyPort() async {
    final port = int.tryParse(_portController.text.trim()) ?? -1;
    if (port < 1024 || port > 65535) {
      setState(() => _message = '端口范围 1024–65535');
      return;
    }
    await widget.store.setLanWebPort(port);
    final controller = LanWebController.current;
    if (controller != null && controller.running) {
      final bound = await controller.start(port);
      if (bound < 0) {
        setState(() => _message = '重启失败：端口被占用');
        return;
      }
      if (bound != port) {
        setState(() => _message = '端口被占用，已顺延到 $bound');
      } else {
        setState(() => _message = '');
      }
    } else {
      setState(() => _message = '端口已保存，下次开启服务时生效');
    }
    await _refreshAddress();
  }

  @override
  Widget build(BuildContext context) {
    final controller = LanWebController.current;
    final running = controller?.running ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('局域网服务')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('局域网网页服务'),
            subtitle: const Text('同一局域网的手机/电脑用浏览器打开地址就能看'),
            value: widget.store.lanWebEnabled && running,
            onChanged: _busy ? null : _toggle,
          ),
          if (running) ...[
            ListTile(
              title: const Text('访问地址'),
              subtitle: Text(_address.isEmpty ? '正在获取…' : _address),
              trailing: _address.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _address));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('地址已复制')),
                        );
                      },
                    ),
            ),
            const ListTile(
              title: Text('流媒体网关'),
              subtitle: Text('服务开启时，应用内播放的直链也会走本机网关补头与 m3u8 重写'),
              trailing: Icon(Icons.check, color: Colors.green),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _portController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '端口',
              hintText: '8999',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _applyPort,
            child: const Text('保存端口'),
          ),
          if (_message.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_message),
          ],
          const SizedBox(height: 24),
          const Text(
            '说明：服务无鉴权，同一局域网的设备都能打开（与 TVBox_Web 一致的局域网信任模型）；服务随 App 前台运行，切后台后是否存活取决于系统，以手机实测为准；海阔规则只能在 App 内打开，局域网页只列规则名。',
          ),
          const SizedBox(height: 8),
          Text(
            '网关端口：${LanGatewayState.port}（与服务端口一致）',
          ),
        ],
      ),
    );
  }
}
