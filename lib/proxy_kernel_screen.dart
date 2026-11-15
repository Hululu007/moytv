import 'dart:io';

import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'live_sources.dart';
import 'proxy_kernel.dart';
import 'proxy_kernel_service.dart';
import 'socks5_proxy.dart';
import 'socks5_proxy_picker.dart';

class ProxyKernelScreen extends StatefulWidget {
  const ProxyKernelScreen({
    super.key,
    this.service,
    this.repository,
    this.socks5Service,
  });

  final ProxyKernelService? service;
  final AppRepository? repository;
  final Socks5ProxyService? socks5Service;

  @override
  State<ProxyKernelScreen> createState() => _ProxyKernelScreenState();
}

class _ProxyKernelScreenState extends State<ProxyKernelScreen> {
  late final ProxyKernelService _service =
      widget.service ?? ProxyKernelService();
  late final Socks5ProxyService _socks5Service =
      widget.socks5Service ?? Socks5ProxyService();
  final _subscriptionController = TextEditingController();
  ProxyKernelState? _state;
  List<ProxyKernelNode> _nodes = const [];
  ProxyControllerState? _controller;
  final _delays = <String, int>{};
  bool _autoStart = false;
  bool _busy = false;
  String? _error;
  String _progress = '';
  List<Socks5ProxyEntry> _socks5Proxies = const [];
  bool _socks5Busy = false;
  String _socks5Progress = '';

  @override
  void initState() {
    super.initState();
    _reload();
    _loadSocks5();
  }

  @override
  void dispose() {
    _subscriptionController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final subscription = await _service.subscriptionUrl();
      final autoStart = await _service.autoStartEnabled();
      final state = await _service.status();
      final nodes = await _service.savedNodes();
      if (!mounted) return;
      setState(() {
        _subscriptionController.text = subscription;
        _autoStart = autoStart;
        _state = state;
        _nodes = nodes;
        _error = null;
      });
      if (state.running) await _reloadController();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _reloadController() async {
    try {
      final controller = await _service.proxies();
      if (mounted) setState(() => _controller = controller);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _updateKernel() => _run(() async {
    setState(() => _progress = '正在更新内核…');
    try {
      final state = await _service.updateKernel(
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _progress = total > 0
                ? '正在更新内核：$received / $total 字节'
                : '正在更新内核：$received 字节';
          });
        },
      );
      if (mounted) {
        setState(() {
          _state = state;
          _progress = '外置内核已更新：${state.externalVersion}';
        });
      }
    } finally {
      if (mounted && _progress.startsWith('正在更新')) {
        setState(() => _progress = '');
      }
    }
  });

  Future<void> _deleteExternal() => _run(() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除外置内核？'),
        content: Text(
          '将删除外置内核文件，下次启动回内置核 ${proxyKernelBuiltinVersion}；'
          '订阅地址与节点记录会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除外置内核'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final state = await _service.deleteExternalKernel();
    if (mounted) {
      setState(() {
        _state = state;
        _controller = null;
      });
    }
  });

  Future<void> _updateSubscription() => _run(() async {
    final url = _subscriptionController.text.trim();
    await _service.saveSubscriptionUrl(url);
    final nodes = await _service.updateSubscription(url: url);
    if (mounted) {
      setState(() {
        _nodes = nodes;
        _progress = '订阅已更新：${nodes.length} 个节点';
      });
    }
  });

  Future<void> _start() => _run(() async {
    final state = await _service.start();
    if (mounted) setState(() => _state = state);
    if (state.running) await _reloadController();
  });

  Future<void> _stop() => _run(() async {
    final state = await _service.stop();
    if (mounted) {
      setState(() {
        _state = state;
        _controller = null;
      });
    }
  });

  Future<void> _select(String name) => _run(() async {
    await _service.selectNode(proxyKernelSelectGroup, name);
    await _reloadController();
  });

  Future<void> _delay(String name) => _run(() async {
    final ms = await _service.delayNode(name);
    if (mounted) setState(() => _delays[name] = ms);
  });

  Future<void> _refreshLogs() => _run(() async {
    final log = await _service.logs();
    final state = _state;
    if (mounted && state != null) {
      setState(
        () => _state = ProxyKernelState(
          supported: state.supported,
          installed: state.installed,
          builtinAvailable: state.builtinAvailable,
          hasExternal: state.hasExternal,
          version: state.version,
          builtinVersion: state.builtinVersion,
          externalVersion: state.externalVersion,
          activeBinary: state.activeBinary,
          running: state.running,
          mixedPort: state.mixedPort,
          controllerPort: state.controllerPort,
          selectedNode: state.selectedNode,
          logTail: log,
        ),
      );
    }
  });

  Future<void> _loadSocks5() async {
    try {
      final proxies = await _socks5Service.loadProxies();
      if (mounted) setState(() => _socks5Proxies = proxies);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _runSocks5(Future<void> Function() action) async {
    setState(() {
      _socks5Busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() {
          _socks5Busy = false;
          _socks5Progress = '';
        });
      }
    }
  }

  Future<void> _testSocks5(Socks5ProxyEntry entry) => _runSocks5(() async {
    setState(() => _socks5Progress = '正在测 ${entry.name}…');
    await _socks5Service.testOne(entry);
    await _loadSocks5();
  });

  Future<void> _identifySocks5() => _runSocks5(() async {
    final proxies = await _socks5Service.identifyAll(
      onProgress: (entry, index, total) {
        if (!mounted) return;
        setState(
          () => _socks5Progress =
              '正在识别 ${index + 1}/$total：${entry.name} '
              '${entry.lastAvailable == true ? '可用' : '不可用'}',
        );
      },
    );
    if (mounted) setState(() => _socks5Proxies = proxies);
  });

  Future<void> _toggleSocks5(Socks5ProxyEntry entry, bool enabled) =>
      _runSocks5(() async {
        await _socks5Service.setProxyEnabled(entry.id, enabled);
        await _loadSocks5();
      });

  Future<void> _editSocks5([Socks5ProxyEntry? entry]) async {
    final saved = await showDialog<Socks5ProxyEntry>(
      context: context,
      builder: (context) => _Socks5ProxyEditDialog(entry: entry),
    );
    if (saved == null || !mounted) return;
    await _runSocks5(() async {
      if (entry == null) {
        await _socks5Service.addProxy(
          name: saved.name,
          host: saved.host,
          port: saved.port,
          username: saved.username,
          password: saved.password,
          enabled: saved.enabled,
        );
      } else {
        await _socks5Service.updateProxy(
          saved.copyWith(
            id: entry.id,
            lastLatencyMs: entry.lastLatencyMs,
            lastAvailable: entry.lastAvailable,
            lastCheckedAtMs: entry.lastCheckedAtMs,
          ),
        );
      }
      await _loadSocks5();
    });
  }

  Future<void> _deleteSocks5(Socks5ProxyEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除该代理？'),
        content: Text('将删除「${entry.name}」（${entry.displayAddress}），'
            '用到它的资源分配会一起清除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runSocks5(() async {
      await _socks5Service.removeProxy(entry.id);
      await _loadSocks5();
    });
  }

  String _socks5Status(Socks5ProxyEntry entry) {
    final available = entry.lastAvailable;
    if (available == null) return '未测试';
    if (!available) return '不可用';
    final latency = entry.lastLatencyMs;
    return latency == null ? '可用' : '可用 · $latency ms';
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(title: const Text('代理内核')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '本地代理模式：只代理本应用自身的 HTTP 流量（经 127.0.0.1 本地端口），'
            '不做系统 VPN，不影响其它应用。',
          ),
          if (state != null && !state.supported) ...[
            const SizedBox(height: 16),
            const Card(
              child: ListTile(
                title: Text('iOS 暂不支持代理内核'),
                subtitle: Text(
                  'iOS 受系统限制无法在本应用内运行 mihomo 子进程，'
                  '此处仅作说明占位；内核随整包发布更新，相关能力请在 Android 端使用。',
                ),
              ),
            ),
          ] else ...[
            const SizedBox(height: 16),
            if (state == null)
              const LinearProgressIndicator()
            else ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(state.running ? '运行中' : '已停止'),
                subtitle: Text(
                  state.installed
                      ? '内置核 ${state.displayBuiltinVersion}'
                            '${state.hasExternal ? ' · 外置核 ${state.externalVersion}' : ''}'
                            '${state.running && state.activeBinary.isNotEmpty ? ' · 当前使用${state.activeBinary == 'external' ? '外置核' : '内置核'}' : ''}'
                            '${state.running ? ' · 本地端口 ${state.mixedPort} · 控制端口 ${state.controllerPort}' : ''}'
                      : '内核不可用：内置核缺失且无外置核，请重装完整安装包',
                ),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_progress.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_progress),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!state.running)
                    FilledButton.icon(
                      onPressed: _busy || !state.installed ? null : _start,
                      icon: const Icon(Icons.play_arrow_outlined),
                      label: const Text('开启'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _busy ? null : _stop,
                      icon: const Icon(Icons.stop_outlined),
                      label: const Text('停止'),
                    ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _updateKernel,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('更新内核'),
                  ),
                  if (state.hasExternal)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _deleteExternal,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('删除外置内核'),
                    ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _reload,
                    icon: const Icon(Icons.refresh_outlined),
                    label: const Text('刷新状态'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _autoStart,
                title: const Text('启动时自动开启'),
                subtitle: const Text('应用启动后若内核已下载且订阅已有节点，自动按上次订阅启动'),
                onChanged: _busy
                    ? null
                    : (value) async {
                        await _service.setAutoStart(value);
                        if (mounted) setState(() => _autoStart = value);
                      },
              ),
              const Divider(height: 32),
              Text('订阅地址', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('默认空，用户自填；只用于拉取 Clash YAML 订阅。'),
              const SizedBox(height: 8),
              TextField(
                controller: _subscriptionController,
                decoration: const InputDecoration(
                  hintText: 'https://…（Clash 订阅地址）',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy ? null : _updateSubscription,
                icon: const Icon(Icons.sync_outlined),
                label: const Text('保存并更新订阅'),
              ),
              if (_nodes.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  '节点（${_nodes.length}）',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                const Text('点节点名切换；测速走控制接口的延迟测试。'),
                for (final node in _nodes)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(node.name),
                    subtitle: Text(
                      _delays[node.name] == null
                          ? (node.fields['type'] ?? '')
                          : '${node.fields['type'] ?? ''} · ${_delays[node.name]} ms',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: _busy ? null : () => _delay(node.name),
                          child: const Text('测速'),
                        ),
                        TextButton(
                          onPressed: _busy || !state.running
                              ? null
                              : () => _select(node.name),
                          child: const Text('选用'),
                        ),
                      ],
                    ),
                  ),
              ],
              if (controller != null && controller.selectGroup != null) ...[
                const SizedBox(height: 8),
                Text(
                  '当前选中：${controller.selectGroup!.current.isEmpty ? '未选择' : controller.selectGroup!.current}',
                ),
              ],
              const Divider(height: 32),
              Row(
                children: [
                  Text('运行日志', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _busy ? null : _refreshLogs,
                    icon: const Icon(Icons.refresh_outlined),
                    label: const Text('刷新日志'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  state.logTail.isEmpty ? '暂无日志' : state.logTail,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              if (!Platform.isAndroid)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('当前平台不是 Android，启停与节点控制在真机 Android 端验证。'),
                ),
            ],
          ],
          const Divider(height: 32),
          Text('SOCKS5 代理', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            '手动添加的 SOCKS5 代理，经本机转发器连接，不依赖上面的代理内核。'
            '测速发真实请求计时；一键识别逐个测全部代理并标可用/不可用。',
          ),
          const SizedBox(height: 8),
          if (_socks5Busy) const LinearProgressIndicator(),
          if (_socks5Progress.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_socks5Progress),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _socks5Busy ? null : () => _editSocks5(),
                icon: const Icon(Icons.add_outlined),
                label: const Text('新增代理'),
              ),
              FilledButton.icon(
                onPressed: _socks5Busy || _socks5Proxies.isEmpty
                    ? null
                    : _identifySocks5,
                icon: const Icon(Icons.radar_outlined),
                label: const Text('一键识别'),
              ),
            ],
          ),
          if (_socks5Proxies.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('还没有 SOCKS5 代理，点“新增代理”添加。'),
            )
          else
            for (final proxy in _socks5Proxies)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(proxy.name),
                subtitle: Text(
                  '${proxy.displayAddress} · ${_socks5Status(proxy)}'
                  '${proxy.enabled ? '' : ' · 已停用'}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: _socks5Busy ? null : () => _testSocks5(proxy),
                      child: const Text('测速'),
                    ),
                    IconButton(
                      tooltip: '编辑',
                      onPressed: _socks5Busy ? null : () => _editSocks5(proxy),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: '删除',
                      onPressed: _socks5Busy
                          ? null
                          : () => _deleteSocks5(proxy),
                      icon: const Icon(Icons.delete_outline),
                    ),
                    Switch.adaptive(
                      value: proxy.enabled,
                      onChanged: _socks5Busy
                          ? null
                          : (value) => _toggleSocks5(proxy, value),
                    ),
                  ],
                ),
              ),
          const Divider(height: 32),
          Text('各资源代理', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            '每个资源单独选代理或直连；跟随默认则走上面的代理内核链路。'
            '影视站源的取流走 Go 核全局代理（在“网络与资源”里设置），'
            '这里只管直播与抓取链路。',
          ),
          Socks5ResourceProxyPicker(
            resourceKey: socks5ScrapeResourceKey,
            label: '网页抓取与探站',
            service: _socks5Service,
          ),
          for (final source in LiveSource.allValues)
            Socks5ResourceProxyPicker(
              key: ValueKey('socks5-live-${source.id}'),
              resourceKey: socks5LiveResourceKey(source.id),
              label: '直播 · ${source.name}',
              service: _socks5Service,
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

/// 新增/编辑 SOCKS5 代理的对话框。密码框默认遮掩显示，可点眼睛切换；
/// 保存时只做校验，落盘由调用方经 Socks5ProxyService 完成。
class _Socks5ProxyEditDialog extends StatefulWidget {
  const _Socks5ProxyEditDialog({this.entry});

  final Socks5ProxyEntry? entry;

  @override
  State<_Socks5ProxyEditDialog> createState() =>
      _Socks5ProxyEditDialogState();
}

class _Socks5ProxyEditDialogState extends State<_Socks5ProxyEditDialog> {
  late final _nameController = TextEditingController(
    text: widget.entry?.name ?? '',
  );
  late final _hostController = TextEditingController(
    text: widget.entry?.host ?? '',
  );
  late final _portController = TextEditingController(
    text: widget.entry == null ? '' : '${widget.entry!.port}',
  );
  late final _usernameController = TextEditingController(
    text: widget.entry?.username ?? '',
  );
  late final _passwordController = TextEditingController(
    text: widget.entry?.password ?? '',
  );
  late bool _enabled = widget.entry?.enabled ?? true;
  bool _showPassword = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _save() {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 0;
    final error = validateSocks5ProxyEntry(
      host: host,
      port: port,
      username: _usernameController.text,
      password: _passwordController.text,
    );
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final name = _nameController.text.trim();
    Navigator.of(context).pop(
      Socks5ProxyEntry(
        id: widget.entry?.id ?? '',
        name: name.isEmpty ? '$host:$port' : name,
        host: host,
        port: port,
        username: _usernameController.text,
        password: _passwordController.text,
        enabled: _enabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.entry == null ? '新增 SOCKS5 代理' : '编辑代理'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '名称（可空，默认用地址）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _hostController,
              decoration: const InputDecoration(
                labelText: '代理地址',
                hintText: '127.0.0.1 或域名',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: '端口',
                hintText: '1080',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: '用户名（无认证可空）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: !_showPassword,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: '密码（无认证可空）',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _showPassword ? '隐藏密码' : '显示密码',
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                  icon: Icon(
                    _showPassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              title: const Text('启用'),
              onChanged: (value) => setState(() => _enabled = value),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
