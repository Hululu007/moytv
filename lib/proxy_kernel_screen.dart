import 'dart:io';

import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'proxy_kernel.dart';
import 'proxy_kernel_service.dart';

class ProxyKernelScreen extends StatefulWidget {
  const ProxyKernelScreen({super.key, this.service, this.repository});

  final ProxyKernelService? service;
  final AppRepository? repository;

  @override
  State<ProxyKernelScreen> createState() => _ProxyKernelScreenState();
}

class _ProxyKernelScreenState extends State<ProxyKernelScreen> {
  late final ProxyKernelService _service =
      widget.service ?? ProxyKernelService();
  final _subscriptionController = TextEditingController();
  ProxyKernelState? _state;
  List<ProxyKernelNode> _nodes = const [];
  ProxyControllerState? _controller;
  final _delays = <String, int>{};
  bool _autoStart = false;
  bool _busy = false;
  String? _error;
  String _progress = '';

  @override
  void initState() {
    super.initState();
    _reload();
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
