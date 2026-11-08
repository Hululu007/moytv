import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mini_app_settings.dart';

class MiniAppSettingsScreen extends StatefulWidget {
  const MiniAppSettingsScreen({super.key});

  @override
  State<MiniAppSettingsScreen> createState() => _MiniAppSettingsScreenState();
}

class _MiniAppSettingsScreenState extends State<MiniAppSettingsScreen> {
  MiniAppSettings? _settings;
  final _portController = TextEditingController();
  final _marketUrlController = TextEditingController();
  int _maxBackground = 3;
  bool _adFilter = true;
  bool _hybridComposition = true;
  bool _lanShare = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _portController.dispose();
    _marketUrlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await MiniAppSettings.load();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _portController.text = settings.basePort.toString();
      _marketUrlController.text = settings.marketUrl;
      _maxBackground = settings.maxBackground;
      _adFilter = settings.adFilter;
      _hybridComposition = settings.hybridComposition;
      _lanShare = settings.lanShare;
    });
  }

  Future<void> _save() async {
    final port = int.tryParse(_portController.text.trim());
    if (port == null || port < 1024 || port > 65535) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('端口号须在 1024 到 65535 之间')),
      );
      return;
    }
    final marketUrl = _marketUrlController.text.trim();
    if (marketUrl.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('市场地址不能为空')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final settings = MiniAppSettings(
        basePort: port,
        maxBackground: _maxBackground,
        adFilter: _adFilter,
        hybridComposition: _hybridComposition,
        lanShare: _lanShare,
        marketUrl: marketUrl,
      );
      await settings.save();
      if (!mounted) return;
      setState(() => _settings = settings);
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('已保存，下次启动小程序生效')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('保存失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('小程序设置')),
      body: _settings == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TextField(
                      controller: _portController,
                      decoration: const InputDecoration(
                        labelText: '本地服务起始端口',
                        helperText:
                            '每个运行中的小程序从这个端口往上用第一个空闲端口；改动下次启动小程序生效',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('最多同时启动后台'),
                      subtitle: const Text(
                        '每个后台保留一个本地服务实例；超出上限时结束最久没活动的那个',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove_rounded),
                            onPressed: _maxBackground <= 1
                                ? null
                                : () => setState(() => _maxBackground--),
                          ),
                          Text(
                            '$_maxBackground',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          IconButton(
                            icon: const Icon(Icons.add_rounded),
                            onPressed: _maxBackground >= 10
                                ? null
                                : () => setState(() => _maxBackground++),
                          ),
                        ],
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('在线网站广告过滤'),
                      subtitle: const Text(
                        '拦截在线网站的广告请求；用 WebView 请求拦截 + 内置广告域名表实现，简化版',
                      ),
                      value: _adFilter,
                      onChanged: (value) =>
                          setState(() => _adFilter = value),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('混合合成模式（Android）'),
                      subtitle: Text(
                        Platform.isAndroid
                            ? '改动下次启动小程序生效'
                            : '当前平台无此开关：设置会保存，实际按平台默认行为',
                      ),
                      value: _hybridComposition,
                      onChanged: (value) =>
                          setState(() => _hybridComposition = value),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('局域网共享'),
                      subtitle: const Text(
                        '开后本地服务同时监听局域网地址，同一网络里的设备能访问；关时只绑 127.0.0.1',
                      ),
                      value: _lanShare,
                      onChanged: (value) =>
                          setState(() => _lanShare = value),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _marketUrlController,
                      decoration: const InputDecoration(
                        labelText: '市场地址',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.url,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? '保存中…' : '保存'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
