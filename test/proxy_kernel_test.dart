import 'dart:convert';
import 'dart:io';

import 'package:moyi/proxy_kernel.dart';
import 'package:moyi/proxy_kernel_screen.dart';
import 'package:moyi/proxy_kernel_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _yamlSubscription = '''
port: 7890
proxies:
  - name: "Node A"
    type: ss
    server: 203.0.113.10
    port: 8388
    cipher: aes-256-gcm
    password: secret123
  - name: Node B
    type: trojan
    server: 198.51.100.20
    port: 443
    password: hunter2
    sni: example.com
    ws-opts:
      path: /ws
      headers:
        Host: example.com
proxy-groups:
  - name: PROXY
    type: select
''';

class _FakeController implements ProxyKernelController {
  var running = false;
  var hasExternal = false;
  var builtinVersion = 'v1.19.32';
  var externalVersion = '';
  var activeBinary = '';
  var selected = '';
  final nodes = <String>['Node A', 'Node B'];

  bool get installed => true;

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    switch (method) {
      case 'status':
        return {
          'supported': true,
          'installed': installed,
          'builtinAvailable': true,
          'hasExternal': hasExternal,
          'version': hasExternal ? externalVersion : builtinVersion,
          'builtinVersion': builtinVersion,
          'externalVersion': hasExternal ? externalVersion : '',
          'activeBinary': running ? activeBinary : '',
          'running': running,
          'mixedPort': running ? 7890 : 0,
          'controllerPort': running ? 9090 : 0,
          'selectedNode': selected,
          'logTail': '',
        };
      case 'pickPorts':
        return {'mixedPort': 7890, 'controllerPort': 9090};
      case 'installBinary':
        hasExternal = true;
        externalVersion = 'v1.19.32';
        return {
          'installed': true,
          'hasExternal': true,
          'externalVersion': externalVersion,
        };
      case 'start':
        running = true;
        activeBinary = hasExternal ? 'external' : 'builtin';
        return {
          'running': true,
          'mixedPort': 7890,
          'controllerPort': 9090,
          'activeBinary': activeBinary,
        };
      case 'stop':
        running = false;
        activeBinary = '';
        return {'running': false};
      case 'deleteBinary':
        hasExternal = false;
        externalVersion = '';
        running = false;
        return {'installed': true, 'hasExternal': false, 'running': false};
      case 'proxies':
        return {
          'body': jsonEncode({
            'proxies': {
              'PROXY': {
                'type': 'Selector',
                'now': selected.isEmpty ? 'Node A' : selected,
                'all': [...nodes, 'DIRECT'],
              },
              'Node A': {'type': 'Shadowsocks'},
              'Node B': {'type': 'Trojan'},
              'DIRECT': {'type': 'Direct'},
            },
          }),
        };
      case 'selectProxy':
        selected = arguments['name'] as String? ?? '';
        return {'selected': selected};
      case 'delay':
        return {
          'body': jsonEncode({'delay': 123}),
        };
      case 'logs':
        return {'log': 'time="2026-10-24" level=info msg="started"'};
      default:
        throw ProxyKernelFailure('unexpected method $method');
    }
  }
}

void main() {
  test('subscription YAML parses nodes and nested ws-opts', () {
    final nodes = parseProxySubscription(_yamlSubscription);
    expect(nodes, hasLength(2));
    expect(nodes.first.name, 'Node A');
    expect(nodes.first.fields['type'], 'ss');
    expect(nodes.first.fields['server'], '203.0.113.10');
    expect(nodes[1].fields['ws-opts.path'], '/ws');
    expect(nodes[1].fields['ws-opts.headers.Host'], 'example.com');
  });

  test('base64 subscription decodes before parsing', () {
    final encoded = base64.encode(utf8.encode(_yamlSubscription));
    final nodes = parseProxySubscription(encoded);
    expect(nodes, hasLength(2));
    expect(nodes.last.name, 'Node B');
  });

  test('bad subscription input fails with an explicit error', () {
    expect(
      () => parseProxySubscription('hello world, not yaml'),
      throwsA(isA<ProxyKernelFailure>()),
    );
    expect(
      () => parseProxySubscription('proxies: []'),
      throwsA(isA<ProxyKernelFailure>()),
    );
    expect(
      () => parseProxySubscription(''),
      throwsA(isA<ProxyKernelFailure>()),
    );
  });

  test('config generation builds select group with DIRECT fallback', () {
    final nodes = parseProxySubscription(_yamlSubscription);
    final config = buildProxyKernelConfig(
      nodes: nodes,
      mixedPort: 7890,
      controllerPort: 9090,
      secret: '0123456789abcdef0123456789abcdef',
    );
    expect(config, contains('mixed-port: 7890'));
    expect(config, contains('external-controller: 127.0.0.1:9090'));
    expect(config, contains('name: PROXY'));
    expect(config, contains('- "Node A"'));
    expect(config, contains('- DIRECT'));
    expect(config, contains('- MATCH,PROXY'));
    expect(config, contains('ws-opts:'));
    expect(config, contains('Host: example.com'));
    expect(
      () => buildProxyKernelConfig(
        nodes: nodes,
        mixedPort: 7890,
        controllerPort: 7890,
        secret: 'x',
      ),
      throwsA(isA<ProxyKernelFailure>()),
    );
    expect(
      () => buildProxyKernelConfig(
        nodes: [],
        mixedPort: 7890,
        controllerPort: 9090,
        secret: 'x',
      ),
      throwsA(isA<ProxyKernelFailure>()),
    );
  });

  test('download URL follows the mihomo android arm64-v8 asset name', () {
    expect(
      proxyKernelDownloadUrl(),
      'https://github.com/MetaCubeX/mihomo/releases/download/'
      'v1.19.32/mihomo-android-arm64-v8-v1.19.32.gz',
    );
  });

  test('secret is 32 lowercase hex chars', () {
    expect(proxyKernelRandomSecret(), matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('IPv4 extractor validates octets and dedupes', () {
    final ips = extractIpv4Addresses(
      'ok 104.16.0.1 and 104.16.0.1, bad 999.1.1.1, '
      'also 172.64.1.2 in text 172.64.1.2',
    );
    expect(ips, ['104.16.0.1', '172.64.1.2']);
  });

  test('CCWU JS shell page parses to zero IPs', () {
    final shell =
        '<html><head><title>裤佬全球优选ip</title></head>'
        '<body><div id="app">全球节点一览（点击勾选）</div></body></html>';
    expect(extractIpv4Addresses(shell), isEmpty);
    final withIps = '$shell 104.21.5.6 172.67.130.9';
    expect(extractIpv4Addresses(withIps), ['104.21.5.6', '172.67.130.9']);
  });

  test('controller state exposes select group and nodes', () {
    final state = ProxyControllerState.fromJson({
      'proxies': {
        'PROXY': {
          'type': 'Selector',
          'now': 'Node B',
          'all': ['Node A', 'Node B', 'DIRECT'],
        },
        'Node A': {'type': 'Shadowsocks'},
        'DIRECT': {'type': 'Direct'},
      },
    });
    expect(state.selectGroup?.current, 'Node B');
    expect(state.nodes.map((entry) => entry.name), ['Node A']);
  });

  test('builtin version constant is the bundled v1.19.32 asset', () {
    expect(proxyKernelBuiltinVersion, 'v1.19.32');
    expect(proxyKernelBuiltinAsset, 'assets/proxy_kernel/mihomo');
    final builtinState = ProxyKernelState.fromJson({
      'installed': true,
      'builtinAvailable': true,
      'builtinVersion': '',
      'activeBinary': 'builtin',
    });
    expect(builtinState.displayBuiltinVersion, 'v1.19.32');
    final externalState = ProxyKernelState.fromJson({
      'installed': true,
      'hasExternal': true,
      'builtinVersion': 'v1.19.32',
      'externalVersion': 'v1.19.31',
      'activeBinary': 'external',
    });
    expect(externalState.displayVersion, 'v1.19.31');
  });

  test('service start writes config and enables local traffic', () async {
    final temp = await Directory.systemTemp.createTemp('proxy_kernel');
    addTearDown(() async {
      ProxyKernelTraffic.disable();
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final controller = _FakeController();
    final service = ProxyKernelService(
      controller: controller,
      store: MemoryProxyKernelStore(),
      supportDirectory: () async => temp,
    );
    final nodes = parseProxySubscription(_yamlSubscription);
    final state = await service.start(nodes: nodes);
    expect(state.running, isTrue);
    expect(state.activeBinary, 'builtin');
    expect(ProxyKernelTraffic.proxyAddress, '127.0.0.1:7890');
    expect(
      ProxyKernelTraffic.findProxy(Uri.parse('https://example.com/')),
      'PROXY 127.0.0.1:7890',
    );
    expect(
      ProxyKernelTraffic.findProxy(Uri.parse('http://127.0.0.1:9090/')),
      'DIRECT',
    );
    final config = await File(
      '${temp.path}/proxy_kernel/config.yaml',
    ).readAsString();
    expect(config, contains('mixed-port: 7890'));
    expect(config, contains('secret: '));
    await service.stop();
    expect(ProxyKernelTraffic.proxyAddress, isNull);
  });

  test('update then delete-external falls back to builtin', () async {
    final controller = _FakeController();
    final service = ProxyKernelService(
      controller: controller,
      store: MemoryProxyKernelStore(),
      supportDirectory: () async => Directory.systemTemp,
    );
    var state = await service.status();
    expect(state.installed, isTrue);
    expect(state.hasExternal, isFalse);
    state = await service.updateKernel();
    expect(state.hasExternal, isTrue);
    expect(state.externalVersion, 'v1.19.32');
    state = await service.deleteExternalKernel();
    expect(state.installed, isTrue);
    expect(state.hasExternal, isFalse);
  });

  testWidgets('proxy kernel screen shows panel on a supported fake', (
    tester,
  ) async {
    final controller = _FakeController();
    final service = ProxyKernelService(
      controller: controller,
      store: MemoryProxyKernelStore(),
      supportDirectory: () async => Directory.systemTemp,
    );
    await tester.pumpWidget(
      MaterialApp(home: ProxyKernelScreen(service: service)),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('代理内核'), findsWidgets);
    expect(
      find.text('本地代理模式：只代理本应用自身的 HTTP 流量（经 127.0.0.1 本地端口），不做系统 VPN，不影响其它应用。'),
      findsOneWidget,
    );
    expect(find.text('订阅地址'), findsOneWidget);
    expect(find.text('开启'), findsOneWidget);
    expect(find.text('更新内核'), findsOneWidget);
    expect(find.text('删除外置内核'), findsNothing);
    expect(find.textContaining('内置核'), findsWidgets);
    expect(find.text('启动时自动开启'), findsOneWidget);
    expect(find.text('运行日志'), findsOneWidget);
  });
}
