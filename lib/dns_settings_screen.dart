import 'dart:async';

import 'package:flutter/material.dart';

import 'dns_settings.dart';
import 'nexhub_scraper/network/model/network_config.dart';
import 'nexhub_scraper/network/network_config_service.dart';

/// DNS 设置：模式（系统 / 自定义 UDP / DoH / DoT）+ 服务器地址。
///
/// 配置存进 [NetworkConfigService]（`network_config_v1` 的 dns 一段），
/// 默认系统 DNS——不填、不用，网络行为与以前完全一致。改后即时生效：
/// 服务更新时清 DNS 缓存，Dart 侧新建的请求客户端按新配置解析。
///
/// 覆盖口径（界面上如实写明，不含糊）：只管 Dart 侧取数（站源页取数、
/// 直播取数、站标与封面、配置下载、海阔规则取数）；原生播放器分片、
/// jar/py/Go 蜘蛛自身的请求、WebView 不走这项设置。
class DnsSettingsScreen extends StatefulWidget {
  const DnsSettingsScreen({super.key});

  @override
  State<DnsSettingsScreen> createState() => _DnsSettingsScreenState();
}

class _DnsSettingsScreenState extends State<DnsSettingsScreen> {
  final _service = NetworkConfigService.instance;
  DnsMode _mode = DnsMode.system;
  final _serversController = TextEditingController();
  final _dohController = TextEditingController();
  final _dotHostController = TextEditingController();
  final _dotPortController = TextEditingController();
  final _testHostController = TextEditingController(text: dnsTestDefaultHost);
  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _serversController.dispose();
    _dohController.dispose();
    _dotHostController.dispose();
    _dotPortController.dispose();
    _testHostController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await _service.load();
    if (!mounted) return;
    final dns = _service.config.dns;
    setState(() {
      _mode = dns.mode;
      _serversController.text = dns.servers.join(', ');
      _dohController.text = dns.dohUrl;
      _dotHostController.text = dns.dotHost;
      _dotPortController.text = dns.dotPort.toString();
      _loading = false;
    });
  }

  DnsConfig get _edited => buildDnsConfig(
    previous: _service.config.dns,
    mode: _mode,
    serversInput: _serversController.text,
    dohUrlInput: _dohController.text,
    dotHostInput: _dotHostController.text,
    dotPortInput: _dotPortController.text,
  );

  String? get _validationError => validateDnsInput(
    mode: _mode,
    serversInput: _serversController.text,
    dohUrlInput: _dohController.text,
    dotHostInput: _dotHostController.text,
    dotPortInput: _dotPortController.text,
  );

  void _showMessage(String text) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save() async {
    final error = _validationError;
    if (error != null) {
      _showMessage(error);
      return;
    }
    setState(() => _saving = true);
    try {
      // 只改 dns 一段：代理/Hosts/SNI/ECH 原样保留。
      await _service.update(_service.config.copyWith(dns: _edited));
      if (!mounted) return;
      _showMessage('已保存，立即生效');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetToSystem() async {
    setState(() => _saving = true);
    try {
      await _service.update(
        _service.config.copyWith(dns: DnsConfig.defaults),
      );
      if (!mounted) return;
      setState(() {
        _mode = DnsMode.system;
        _serversController.text = '';
        _dohController.text = '';
        _dotHostController.text = '';
        _dotPortController.text = '853';
      });
      _showMessage('已恢复系统 DNS');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    final error = _validationError;
    if (error != null) {
      _showMessage(error);
      return;
    }
    final host = _testHostController.text.trim();
    if (host.isEmpty) {
      _showMessage('请填写要测试的域名');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      // 测试不用缓存：每次都真查一次，免得缓存把“走了哪条路”盖住。
      final cfg = _edited.copyWith(cacheEnabled: false);
      final (ips, ms) = await _service.testDns(
        host,
        cfg,
        _service.config.hosts,
      );
      if (!mounted) return;
      setState(() {
        _testResult = ips.isEmpty
            ? '解析失败（${ms}ms）：$host 没有返回地址，请检查服务器地址'
            : '解析成功（${ms}ms）：${ips.join(', ')}';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DNS 设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              children: [
                const Text(
                  '域名解析走哪台服务器。默认用系统 DNS，与以前完全一致；'
                  '域名被污染、打不开站时，可改填 DoH 或自定义 DNS 试试。',
                ),
                const SizedBox(height: 8),
                const Text(
                  '只对应用内 Dart 侧取数生效（站源页、直播、站标封面、海阔规则）；'
                  '播放器拉流、jar/py/Go 蜘蛛自身的请求、网页视图不走这项设置。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 16),
                RadioGroup<DnsMode>(
                  groupValue: _mode,
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _mode = value;
                        _testResult = null;
                      });
                    }
                  },
                  child: Column(
                    children: [
                      for (final mode in DnsMode.values)
                        RadioListTile<DnsMode>(
                          key: ValueKey('dns-mode-${mode.name}'),
                          value: mode,
                          title: Text(dnsModeLabel(mode)),
                          subtitle: Text(_modeHint(mode)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                if (_mode == DnsMode.custom) ...[
                  TextField(
                    key: const ValueKey('dns-servers-field'),
                    controller: _serversController,
                    decoration: const InputDecoration(
                      labelText: 'DNS 服务器',
                      hintText: dnsServersHint,
                      helperText: '填服务器 IP，多个用逗号隔开',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.text,
                  ),
                ],
                if (_mode == DnsMode.doh) ...[
                  TextField(
                    key: const ValueKey('dns-doh-field'),
                    controller: _dohController,
                    decoration: const InputDecoration(
                      labelText: 'DoH 地址',
                      hintText: dnsDohHint,
                      helperText: '加密 DNS 地址，以 https:// 开头',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                  ),
                ],
                if (_mode == DnsMode.dot) ...[
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          key: const ValueKey('dns-dot-host-field'),
                          controller: _dotHostController,
                          decoration: const InputDecoration(
                            labelText: 'DoT 服务器',
                            hintText: dnsDotHostHint,
                            border: OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.url,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 1,
                        child: TextField(
                          key: const ValueKey('dns-dot-port-field'),
                          controller: _dotPortController,
                          decoration: const InputDecoration(
                            labelText: '端口',
                            hintText: '853',
                            border: OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('dns-test-host-field'),
                        controller: _testHostController,
                        decoration: const InputDecoration(
                          labelText: '测试域名',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonal(
                      key: const ValueKey('dns-test-button'),
                      onPressed: _testing ? null : _test,
                      child: const Text('测试解析'),
                    ),
                  ],
                ),
                if (_testResult != null) ...[
                  const SizedBox(height: 8),
                  Text(_testResult!),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  key: const ValueKey('dns-save-button'),
                  onPressed: _saving ? null : _save,
                  child: const Text('保存'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const ValueKey('dns-reset-button'),
                  onPressed: _saving ? null : _resetToSystem,
                  child: const Text('恢复系统 DNS'),
                ),
              ],
            ),
    );
  }

  String _modeHint(DnsMode mode) => switch (mode) {
    DnsMode.system => '用手机系统 / 运营商的解析，默认',
    DnsMode.custom => '向自填的服务器发普通 DNS 查询（UDP 53 端口）',
    DnsMode.doh => '经 HTTPS 查域名，内容加密、防污染效果较好',
    DnsMode.dot => '经 TLS 查域名（853 端口），内容加密',
  };
}
