import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'proxy_kernel.dart';
import 'proxy_egress.dart';

abstract class ProxyKernelController {
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]);
}

class MethodChannelProxyKernelController implements ProxyKernelController {
  const MethodChannelProxyKernelController([
    this.channel = const MethodChannel('moyi/proxykernel'),
  ]);

  final MethodChannel channel;

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        method,
        arguments,
      );
      if (result == null) return {};
      return Map<String, dynamic>.from(result);
    } on MissingPluginException {
      throw ProxyKernelFailure('当前平台不支持代理内核（仅 Android）');
    } on PlatformException catch (error) {
      throw ProxyKernelFailure(error.message ?? error.code);
    }
  }
}

abstract class ProxyKernelStore {
  Future<String> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

class SharedPreferencesProxyKernelStore implements ProxyKernelStore {
  @override
  Future<String> read(String key) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(key) ?? '';
  }

  @override
  Future<void> write(String key, String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(key);
  }
}

class MemoryProxyKernelStore implements ProxyKernelStore {
  final _values = <String, String>{};

  @override
  Future<String> read(String key) async => _values[key] ?? '';

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _values.remove(key);
  }
}

/// 兼容壳：历史入口，现统一读出口决策点（`proxy_egress.dart`）。
/// [proxyAddress] 是当前决策的 HTTP 代理地址（直连时为 null），
/// [findProxy] 是当前决策的路由判定（回环永远直连）；
/// [enable]/[disable] 改的是决策点的内核档，由内核启停时调用。
/// 三个取数客户端（推荐流探测、内容区、直播）仍经这里拿 findProxy，
/// 随决策链自动跟内核/SOCKS5/手填/系统/直连切换。
class ProxyKernelTraffic {
  ProxyKernelTraffic._();

  static String? get proxyAddress =>
      ProxyEgressController.instance.decision.httpProxy;

  static String findProxy(Uri uri) =>
      ProxyEgressController.instance.decision.findProxy(uri);

  static void enable(String address) =>
      ProxyEgressController.instance.setKernelAddress(address);

  static void disable() =>
      ProxyEgressController.instance.setKernelAddress(null);
}

class ProxyKernelService {
  ProxyKernelService({
    ProxyKernelController? controller,
    ProxyKernelStore? store,
    Future<Directory> Function()? supportDirectory,
  }) : _controller = controller ?? const MethodChannelProxyKernelController(),
       _store = store ?? SharedPreferencesProxyKernelStore(),
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final ProxyKernelController _controller;
  final ProxyKernelStore _store;
  final Future<Directory> Function() _supportDirectory;

  static const String _subscriptionKey = 'proxy_kernel_subscription_url';
  static const String _autoStartKey = 'proxy_kernel_auto_start';
  static const String _nodesKey = 'proxy_kernel_nodes_json';
  static const String _selectedKey = 'proxy_kernel_selected_node';
  static const String _rulesKey = 'proxy_kernel_subscription_rules_json';

  Future<String> subscriptionUrl() => _store.read(_subscriptionKey);

  Future<void> saveSubscriptionUrl(String url) =>
      _store.write(_subscriptionKey, url.trim());

  Future<bool> autoStartEnabled() async =>
      (await _store.read(_autoStartKey)) == '1';

  Future<void> setAutoStart(bool enabled) =>
      _store.write(_autoStartKey, enabled ? '1' : '0');

  Future<List<ProxyKernelNode>> savedNodes() async {
    final raw = await _store.read(_nodesKey);
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map)
            ProxyKernelNode.fromJson(item.cast<String, dynamic>()),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveNodes(List<ProxyKernelNode> nodes) => _store.write(
    _nodesKey,
    jsonEncode([for (final node in nodes) node.toJson()]),
  );

  /// 上次订阅里提取出的可用规则（空表示订阅无可用规则，启动时用内置
  /// 最小规则）。规则与节点同一批保存、同一批读取，不会张冠李戴。
  Future<List<String>> savedRules() async {
    final raw = await _store.read(_rulesKey);
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [for (final item in decoded) if (item is String) item];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveRules(List<String> rules) =>
      _store.write(_rulesKey, jsonEncode(rules));

  Future<String> selectedNode() => _store.read(_selectedKey);

  Future<void> saveSelectedNode(String name) =>
      _store.write(_selectedKey, name);

  Future<ProxyKernelState> status() async {
    try {
      final result = await _controller.call('status');
      return ProxyKernelState.fromJson(result);
    } on ProxyKernelFailure catch (error) {
      if (error.message.contains('仅 Android')) {
        return ProxyKernelState.unsupported();
      }
      rethrow;
    }
  }

  Future<ProxyKernelState> updateKernel({
    String version = proxyKernelDefaultVersion,
    void Function(int received, int total)? onProgress,
  }) async {
    final url = proxyKernelDownloadUrl(version: version);
    final support = await _supportDirectory();
    final directory = Directory(path.join(support.path, 'proxy_kernel'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final gzFile = File(path.join(directory.path, 'mihomo.download.gz'));
    final staged = File(path.join(directory.path, 'mihomo.staged'));
    // 控制面直连：内核/订阅拉取绝不走出口决策。节点死光时出口本身
    // 就是坏的，走出口会连新节点都拉不回来（自举死锁）。
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..findProxy = (_) => 'DIRECT';
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'moyi-proxy-kernel');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw ProxyKernelFailure('内核下载失败（HTTP ${response.statusCode}）');
      }
      final total = response.contentLength;
      var received = 0;
      final sink = gzFile.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.close();
      final gzBytes = await gzFile.readAsBytes();
      final raw = gzip.decode(gzBytes);
      await staged.writeAsBytes(raw, flush: true);
    } finally {
      client.close(force: true);
    }
    try {
      final result = await _controller.call('installBinary', {
        'path': staged.path,
      });
      final state = ProxyKernelState.fromJson(result);
      return state;
    } finally {
      if (await gzFile.exists()) await gzFile.delete();
      if (await staged.exists()) await staged.delete();
    }
  }

  Future<ProxyKernelState> deleteExternalKernel() async {
    await stop();
    final result = await _controller.call('deleteBinary');
    return ProxyKernelState.fromJson(result);
  }

  Future<List<ProxyKernelNode>> updateSubscription({String? url}) async {
    final target = (url ?? await subscriptionUrl()).trim();
    if (target.isEmpty) {
      throw ProxyKernelFailure('订阅地址为空，请先填写订阅地址');
    }
    final uri = Uri.tryParse(target);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ProxyKernelFailure('订阅地址无效');
    }
    // 控制面直连：理由同 updateKernel，订阅拉取不走出口决策。
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..findProxy = (_) => 'DIRECT';
    String body;
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'moyi-proxy-kernel');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw ProxyKernelFailure('订阅拉取失败（HTTP ${response.statusCode}）');
      }
      body = await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
    final nodes = parseProxySubscription(body);
    final rules = extractSubscriptionRules(
      body,
      {for (final node in nodes) node.name},
    );
    await _saveNodes(nodes);
    await _saveRules(rules);
    return nodes;
  }

  Future<ProxyKernelState> start({List<ProxyKernelNode>? nodes}) async {
    final current = await status();
    if (!current.supported) {
      throw ProxyKernelFailure('当前平台不支持代理内核（仅 Android）');
    }
    if (!current.installed) {
      throw ProxyKernelFailure('内核不可用：内置核缺失且无外置核，请重装完整安装包');
    }
    final effectiveNodes = nodes ?? await savedNodes();
    if (effectiveNodes.isEmpty) {
      throw ProxyKernelFailure('没有可用节点，请先更新订阅');
    }
    final ports = await _controller.call('pickPorts', {
      'mixedPort': proxyKernelDefaultMixedPort,
      'controllerPort': proxyKernelDefaultControllerPort,
    });
    final mixedPort =
        (ports['mixedPort'] as num?)?.toInt() ?? proxyKernelDefaultMixedPort;
    final controllerPort =
        (ports['controllerPort'] as num?)?.toInt() ??
        proxyKernelDefaultControllerPort;
    final secret = proxyKernelRandomSecret();
    final rules = await savedRules();
    final config = buildProxyKernelConfig(
      nodes: effectiveNodes,
      mixedPort: mixedPort,
      controllerPort: controllerPort,
      secret: secret,
      rules: rules,
    );
    final support = await _supportDirectory();
    final directory = Directory(path.join(support.path, 'proxy_kernel'));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final configFile = File(path.join(directory.path, 'config.yaml'));
    await configFile.writeAsString(config, flush: true);
    Map<String, dynamic> result;
    try {
      result = await _controller.call('start', {
        'configPath': configFile.path,
        'workDir': directory.path,
        'controllerPort': controllerPort,
        'secret': secret,
      });
    } catch (error) {
      rethrow;
    }
    final state = ProxyKernelState.fromJson(result);
    if (state.running) {
      ProxyKernelTraffic.enable('127.0.0.1:$mixedPort');
    }
    return state;
  }

  Future<ProxyKernelState> stop() async {
    ProxyKernelTraffic.disable();
    try {
      final result = await _controller.call('stop');
      return ProxyKernelState.fromJson(result);
    } on ProxyKernelFailure catch (error) {
      if (error.message.contains('仅 Android')) {
        return ProxyKernelState.unsupported();
      }
      rethrow;
    }
  }

  Future<ProxyControllerState> proxies() async {
    final result = await _controller.call('proxies');
    final raw = result['body'];
    if (raw is! String || raw.isEmpty) {
      throw ProxyKernelFailure('控制接口没有返回节点列表');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw ProxyKernelFailure('控制接口返回的节点列表格式无效');
    }
    return ProxyControllerState.fromJson(decoded.cast<String, dynamic>());
  }

  Future<void> selectNode(String group, String name) async {
    await _controller.call('selectProxy', {'group': group, 'name': name});
    await saveSelectedNode(name);
  }

  Future<int> delayNode(String name, {int timeoutMs = 5000}) async {
    final result = await _controller.call('delay', {
      'name': name,
      'timeoutMs': timeoutMs,
    });
    final raw = result['body'];
    if (raw is! String || raw.isEmpty) {
      throw ProxyKernelFailure('测速没有返回结果');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['delay'] is! num) {
      throw ProxyKernelFailure('测速返回格式无效');
    }
    return (decoded['delay'] as num).toInt();
  }

  Future<String> logs() async {
    final result = await _controller.call('logs');
    return '${result['log'] ?? ''}';
  }

  static Future<void> maybeAutostart() async {
    try {
      final service = ProxyKernelService();
      if (!await service.autoStartEnabled()) return;
      final state = await service.status();
      if (!state.supported || !state.installed || state.running) return;
      final nodes = await service.savedNodes();
      if (nodes.isEmpty) return;
      await service.start(nodes: nodes);
    } catch (_) {}
  }
}
