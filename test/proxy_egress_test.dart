import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/models.dart';
import 'package:moyi/proxy_egress.dart';
import 'package:moyi/proxy_egress_wiring.dart';
import 'package:moyi/proxy_kernel.dart';
import 'package:moyi/proxy_kernel_service.dart';
import 'package:moyi/resource_settings.dart';
import 'package:moyi/socks5_proxy.dart';

void main() {
  setUp(() {
    ProxyEgressController.resetForTest();
    Socks5ProxyRouter.instance.update(const [], const {});
    Socks5ProxyRouter.onUpdated = null;
  });

  tearDown(() async {
    ProxyEgressWiring.resetForTest();
    ProxyEgressController.resetForTest();
    Socks5ProxyRouter.instance.update(const [], const {});
    Socks5ProxyRouter.onUpdated = null;
    await Socks5ForwarderPool.instance.closeAll();
  });

  group('resolveEgressDecision 优先级链', () {
    test('内核高于一切', () {
      final decision = resolveEgressDecision(
        kernelHttpAddress: '127.0.0.1:7890',
        socks5HttpAddress: '127.0.0.1:10001',
        manualHttpAddress: '10.0.0.9:1080',
        manualGoUrl: 'http://10.0.0.9:1080',
        systemHttpAddress: '10.0.0.8:8080',
      );
      expect(decision.source, EgressSource.kernel);
      expect(decision.httpProxy, '127.0.0.1:7890');
      expect(decision.goUrl, 'http://127.0.0.1:7890');
    });

    test('SOCKS5 高于手填与系统', () {
      final decision = resolveEgressDecision(
        socks5HttpAddress: '127.0.0.1:10001',
        manualHttpAddress: '10.0.0.9:1080',
        manualGoUrl: 'http://10.0.0.9:1080',
        systemHttpAddress: '10.0.0.8:8080',
      );
      expect(decision.source, EgressSource.socks5);
      expect(decision.httpProxy, '127.0.0.1:10001');
      expect(decision.goUrl, 'http://127.0.0.1:10001');
    });

    test('手填高于系统，Go 核拿原始地址', () {
      final decision = resolveEgressDecision(
        manualHttpAddress: '127.0.0.1:10002',
        manualGoUrl: 'socks5://10.0.0.9:1080',
        systemHttpAddress: '10.0.0.8:8080',
      );
      expect(decision.source, EgressSource.manual);
      expect(decision.httpProxy, '127.0.0.1:10002');
      expect(decision.goUrl, 'socks5://10.0.0.9:1080');
    });

    test('系统档 Go 核拿 null（走自身 auto 模式）', () {
      final decision = resolveEgressDecision(
        systemHttpAddress: '10.0.0.8:8080',
      );
      expect(decision.source, EgressSource.system);
      expect(decision.httpProxy, '10.0.0.8:8080');
      expect(decision.goUrl, isNull);
    });

    test('全空则直连，空字符串视作无', () {
      expect(resolveEgressDecision().source, EgressSource.direct);
      expect(
        resolveEgressDecision(kernelHttpAddress: '').source,
        EgressSource.direct,
      );
      expect(resolveEgressDecision().httpProxy, isNull);
      expect(resolveEgressDecision().findProxy(Uri.parse('https://a.b/')), 'DIRECT');
    });
  });

  group('EgressDecision.findProxy', () {
    test('回环目标永远直连', () {
      final decision = resolveEgressDecision(
        kernelHttpAddress: '127.0.0.1:7890',
      );
      for (final url in [
        'http://127.0.0.1:9090/proxies',
        'http://localhost:7890/x',
        'http://[::1]:8080/x',
      ]) {
        expect(decision.findProxy(Uri.parse(url)), 'DIRECT', reason: url);
      }
      expect(
        decision.findProxy(Uri.parse('https://example.com/v.m3u8')),
        'PROXY 127.0.0.1:7890',
      );
    });
  });

  group('ProxyEgressController', () {
    test('内核停了落到下一档，不留死地址', () {
      final controller = ProxyEgressController();
      controller.setSystemAddress('10.0.0.8:8080');
      controller.setKernelAddress('127.0.0.1:7890');
      expect(controller.decision.source, EgressSource.kernel);
      controller.setKernelAddress(null);
      expect(controller.decision.source, EgressSource.system);
      expect(controller.decision.httpProxy, '10.0.0.8:8080');
      controller.setSystemAddress(null);
      expect(controller.decision.source, EgressSource.direct);
      expect(controller.decision.httpProxy, isNull);
    });

    test('决策不变时不重复通知', () {
      final controller = ProxyEgressController();
      var notifications = 0;
      controller.decisionNotifier.addListener(() => notifications++);
      controller.setKernelAddress('127.0.0.1:7890');
      controller.setKernelAddress('127.0.0.1:7890');
      expect(notifications, 1);
    });

    test('手填 http 地址直接用', () async {
      final controller = ProxyEgressController();
      await controller.refreshManualEgress(
        'manual',
        'http://10.0.0.9:1080',
      );
      expect(controller.decision.source, EgressSource.manual);
      expect(controller.decision.httpProxy, '10.0.0.9:1080');
      expect(controller.decision.goUrl, 'http://10.0.0.9:1080');
    });

    test('手填 socks5 地址起转发器给 Dart 侧，Go 核拿原始地址', () async {
      final controller = ProxyEgressController();
      await controller.refreshManualEgress(
        'manual',
        'socks5://user:pass@10.0.0.9:1080',
      );
      expect(controller.decision.source, EgressSource.manual);
      expect(controller.decision.httpProxy, startsWith('127.0.0.1:'));
      expect(controller.decision.goUrl, 'socks5://user:pass@10.0.0.9:1080');
    });

    test('手填档非法输入视为空', () async {
      final controller = ProxyEgressController();
      for (final (mode, url) in [
        ('auto', 'http://10.0.0.9:1080'),
        ('direct', 'http://10.0.0.9:1080'),
        ('manual', ''),
        ('manual', 'ftp://10.0.0.9:21'),
        ('manual', 'http://10.0.0.9:99999'),
        ('manual', 'not a url'),
      ]) {
        await controller.refreshManualEgress(mode, url);
        expect(
          controller.decision.source,
          EgressSource.direct,
          reason: '$mode $url',
        );
      }
    });

    test('SOCKS5 档取第一个已启用条目', () async {
      Socks5ProxyRouter.instance.update(const [
        Socks5ProxyEntry(
          id: 'off',
          name: 'off',
          host: '10.0.0.1',
          port: 1080,
          enabled: false,
        ),
        Socks5ProxyEntry(id: 'on', name: 'on', host: '10.0.0.2', port: 1081),
      ], const {});
      final controller = ProxyEgressController();
      await controller.refreshSocks5Egress();
      expect(controller.decision.source, EgressSource.socks5);
      expect(controller.decision.httpProxy, startsWith('127.0.0.1:'));

      Socks5ProxyRouter.instance.update(const [], const {});
      await controller.refreshSocks5Egress();
      expect(controller.decision.source, EgressSource.direct);
    });

    test('MPV 应用器跟决策走，抛错的被摘掉', () async {
      final controller = ProxyEgressController();
      final seen = <String?>[];
      controller.registerMpvApplier('a', (url) async => seen.add(url));
      controller.setKernelAddress('127.0.0.1:7890');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen, ['http://127.0.0.1:7890']);
      controller.registerMpvApplier('boom', (_) async {
        throw StateError('boom');
      });
      controller.setKernelAddress(null);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen, ['http://127.0.0.1:7890', null]);
      // 抛错的已摘掉：再变一次决策不应再触发它（无从直接观察，
      // 但重复抛错不会导致未处理异常，seen 仍只多一条）。
      controller.setKernelAddress('127.0.0.1:7890');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen, ['http://127.0.0.1:7890', null, 'http://127.0.0.1:7890']);
      controller.unregisterMpvApplier('a');
      controller.setKernelAddress(null);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen.length, 3);
    });
  });

  group('ProxyKernelTraffic 兼容壳', () {
    test('enable/disable 改内核档，findProxy 跟决策', () {
      ProxyKernelTraffic.enable('127.0.0.1:7890');
      expect(ProxyKernelTraffic.proxyAddress, '127.0.0.1:7890');
      expect(
        ProxyKernelTraffic.findProxy(Uri.parse('https://example.com/')),
        'PROXY 127.0.0.1:7890',
      );
      expect(
        ProxyKernelTraffic.findProxy(Uri.parse('http://127.0.0.1:9090/')),
        'DIRECT',
      );
      ProxyKernelTraffic.disable();
      expect(ProxyKernelTraffic.proxyAddress, isNull);
      expect(
        ProxyKernelTraffic.findProxy(Uri.parse('https://example.com/')),
        'DIRECT',
      );
    });
  });

  group('系统代理映射解析', () {
    test('http 静态地址', () {
      expect(
        systemProxyAddressFromMap({
          'http': 'http://10.0.0.8:8080',
          'https': 'http://10.0.0.8:8080',
          'pac': false,
        }),
        '10.0.0.8:8080',
      );
    });

    test('纯 PAC 与空地址返回 null', () {
      expect(
        systemProxyAddressFromMap({'http': '', 'https': '', 'pac': true}),
        isNull,
      );
      expect(systemProxyAddressFromMap({}), isNull);
    });

    test('http 为空时用 https', () {
      expect(
        systemProxyAddressFromMap({
          'http': '',
          'https': 'http://10.0.0.8:8080',
        }),
        '10.0.0.8:8080',
      );
    });
  });

  group('全局 HttpOverrides', () {
    test('新建客户端默认走决策：非回环进代理、回环直连、决策变化实时生效', () async {
      final hits = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        hits.add('${request.method} ${request.uri}');
        request.response.write('ok');
        await request.response.close();
      });
      final port = server.port;

      ProxyEgressController.instance.setKernelAddress('127.0.0.1:$port');
      final client = ProxyEgressHttpOverrides().createHttpClient(null);
      addTearDown(() => client.close(force: true));

      // 非回环目标：经代理，绝对形式到达。
      final proxied = await client.getUrl(Uri.parse('http://example.invalid/x'));
      final proxiedResponse = await proxied.close();
      await proxiedResponse.drain<void>();
      expect(hits, ['GET http://example.invalid/x']);

      // 回环目标：直连，源站形式到达同一服务器。
      final direct = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/direct'),
      );
      final directResponse = await direct.close();
      await directResponse.drain<void>();
      expect(hits, ['GET http://example.invalid/x', 'GET /direct']);

      // 同一个客户端，决策变直连后不再进代理（闭包读当前决策）。
      // getUrl 本身不建连，DNS 失败在 close() 时才抛出来。
      ProxyEgressController.instance.setKernelAddress(null);
      final pending = await client.getUrl(
        Uri.parse('http://example.invalid/after'),
      );
      // 失败形态随环境而定（DNS 失败是 SocketException，本机出口
      // 解析出脏地址时是 HttpException）；关键断言是没进代理服务器。
      await expectLater(pending.close(), throwsA(isA<IOException>()));
      expect(hits.length, 2);
    });

    test('显式赋值覆盖全局：规则自带 proxy 的优先级高于全局', () async {
      final hits = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        hits.add('${request.method} ${request.uri}');
        request.response.write('ok');
        await request.response.close();
      });
      // 决策是直连，但客户端显式写了代理：显式胜出。
      final client = ProxyEgressHttpOverrides().createHttpClient(null);
      addTearDown(() => client.close(force: true));
      client.findProxy = (_) => 'PROXY 127.0.0.1:${server.port}';
      final request = await client.getUrl(Uri.parse('http://example.invalid/y'));
      final response = await request.close();
      await response.drain<void>();
      expect(hits, ['GET http://example.invalid/y']);
    });
  });

  group('订阅规则提取', () {
    const subscription = '''
proxies:
  - name: "Node A"
    type: ss
    server: 203.0.113.10
    port: 8388
rules:
  - DOMAIN-SUFFIX,example.com,DIRECT
  - DOMAIN-KEYWORD,ads,REJECT
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - DOMAIN-SUFFIX,video.com,PROXY
  - DOMAIN-SUFFIX,node.com,Node A
  - GEOIP,CN,DIRECT
  - GEOSITE,CN,DIRECT
  - RULE-SET,custom,PROXY
  - DOMAIN-SUFFIX,other.com,UNKNOWN-GROUP
  - MATCH,PROXY
''';

    test('只保留可用规则', () {
      final rules = extractSubscriptionRules(subscription, {'Node A'});
      expect(rules, [
        'DOMAIN-SUFFIX,example.com,DIRECT',
        'DOMAIN-KEYWORD,ads,REJECT',
        'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
        'DOMAIN-SUFFIX,video.com,PROXY',
        'DOMAIN-SUFFIX,node.com,Node A',
        'MATCH,PROXY',
      ]);
    });

    test('无 rules 段返回空', () {
      expect(
        extractSubscriptionRules('proxies:\n  - name: X\n', {'X'}),
        isEmpty,
      );
    });

    test('非法内容不抛错', () {
      expect(extractSubscriptionRules('not yaml at all', {}), isEmpty);
      expect(extractSubscriptionRules('', {}), isEmpty);
    });
  });

  group('内核配置规则段', () {
    List<ProxyKernelNode> nodes() => const [
      ProxyKernelNode(name: 'Node A', fields: {
        'name': 'Node A',
        'type': 'ss',
        'server': '203.0.113.10',
        'port': '8388',
      }),
    ];

    test('默认用内置最小规则', () {
      final config = buildProxyKernelConfig(
        nodes: nodes(),
        mixedPort: 7890,
        controllerPort: 9090,
        secret: 's',
      );
      expect(config, contains('IP-CIDR,127.0.0.0/8,DIRECT,no-resolve'));
      expect(config, contains('IP-CIDR,192.168.0.0/16,DIRECT,no-resolve'));
      expect(config, contains('- MATCH,PROXY'));
      expect(config, isNot(contains('GEOIP')));
      expect(config, isNot(contains('GEOSITE')));
    });

    test('订阅规则优先，无 MATCH 时补兜底', () {
      final config = buildProxyKernelConfig(
        nodes: nodes(),
        mixedPort: 7890,
        controllerPort: 9090,
        secret: 's',
        rules: const ['DOMAIN-SUFFIX,example.com,DIRECT'],
      );
      expect(config, contains('DOMAIN-SUFFIX,example.com,DIRECT'));
      expect(config, contains('- MATCH,PROXY'));
      expect(config, isNot(contains('IP-CIDR,127.0.0.0/8')));
    });

    test('订阅规则自带 MATCH 时不重复补', () {
      final config = buildProxyKernelConfig(
        nodes: nodes(),
        mixedPort: 7890,
        controllerPort: 9090,
        secret: 's',
        rules: const ['DOMAIN-SUFFIX,example.com,DIRECT', 'MATCH,DIRECT'],
      );
      expect('MATCH,PROXY'.allMatches(config).length, 0);
      expect('MATCH,DIRECT'.allMatches(config).length, 1);
    });
  });

  group('接线层同步', () {
    test('初始同步手填档，内核启停同步切换且落回手填', () async {
      final repository = _FakeRepository(
        const ResourceSettings(
          proxyMode: 'manual',
          proxyUrl: 'http://10.0.0.9:1080',
        ),
      );
      final goCalls = <String?>[];
      final pyCalls = <String?>[];
      final nativeCalls = <String?>[];
      await ProxyEgressWiring.bind(
        repository: repository,
        goSink: (url) async => goCalls.add(url),
        pySink: (url) async => pyCalls.add(url),
        nativeSink: (url) async => nativeCalls.add(url),
      );
      expect(goCalls, ['http://10.0.0.9:1080']);
      expect(pyCalls, ['http://10.0.0.9:1080']);
      expect(nativeCalls, ['http://10.0.0.9:1080']);

      ProxyKernelTraffic.enable('127.0.0.1:7890');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(goCalls.last, 'http://127.0.0.1:7890');
      expect(pyCalls.last, 'http://127.0.0.1:7890');
      expect(nativeCalls.last, 'http://127.0.0.1:7890');

      ProxyKernelTraffic.disable();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(goCalls.last, 'http://10.0.0.9:1080');
      expect(pyCalls.last, 'http://10.0.0.9:1080');
      expect(nativeCalls.last, 'http://10.0.0.9:1080');
      expect(repository.egressCalls, isEmpty);
    });

    test('全直连时不推 py（不无故启动解释器），有出口才推', () async {
      final repository = _FakeRepository(const ResourceSettings());
      final pyCalls = <String?>[];
      await ProxyEgressWiring.bind(
        repository: repository,
        goSink: (_) async {},
        pySink: (url) async => pyCalls.add(url),
        nativeSink: (_) async {},
      );
      expect(pyCalls, isEmpty);
      ProxyKernelTraffic.enable('127.0.0.1:7890');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(pyCalls, ['http://127.0.0.1:7890']);
      ProxyKernelTraffic.disable();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(pyCalls, ['http://127.0.0.1:7890', null]);
    });

    test('SOCKS5 路由快照变化经钩子刷新决策', () async {
      final repository = _FakeRepository(const ResourceSettings());
      final goCalls = <String?>[];
      await ProxyEgressWiring.bind(
        repository: repository,
        goSink: (url) async => goCalls.add(url),
        pySink: (_) async {},
        nativeSink: (_) async {},
      );
      expect(goCalls, [null]);
      Socks5ProxyRouter.instance.update(const [
        Socks5ProxyEntry(id: 's1', name: 's1', host: '10.0.0.2', port: 1080),
      ], const {});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(goCalls.last, startsWith('http://127.0.0.1:'));
      expect(
        ProxyEgressController.instance.decision.source,
        EgressSource.socks5,
      );
      Socks5ProxyRouter.instance.update(const [], const {});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(goCalls.last, isNull);
      expect(
        ProxyEgressController.instance.decision.source,
        EgressSource.direct,
      );
    });

    test('默认 Go 同步走 repository.setEgressProxy', () async {
      final repository = _FakeRepository(const ResourceSettings());
      await ProxyEgressWiring.bind(
        repository: repository,
        pySink: (_) async {},
        nativeSink: (_) async {},
      );
      ProxyKernelTraffic.enable('127.0.0.1:7890');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(repository.egressCalls, contains('http://127.0.0.1:7890'));
    });
  });
}

class _FakeRepository extends AppRepository {
  _FakeRepository(this._settings);

  final ResourceSettings _settings;
  final List<String?> egressCalls = [];

  @override
  Future<ResourceSettings> resourceSettings() async => _settings;

  @override
  Future<void> setEgressProxy(String? goUrl) async {
    egressCalls.add(goUrl);
  }

  // 以下抽象方法与出口同步无关，统一以“不支持”占位。
  @override
  Future<void> initialize() async {}

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async => throw AppFailure('不支持');

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      throw AppFailure('不支持');

  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      throw AppFailure('不支持');

  @override
  Future<String> cover(Drama drama, {bool force = false}) async =>
      throw AppFailure('不支持');

  @override
  Future<DramaDetail> detail(Drama drama) async => throw AppFailure('不支持');

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async => throw AppFailure('不支持');

  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async =>
      throw AppFailure('不支持');

  @override
  Future<void> cancelPlayback() async {}

  @override
  Future<void> release(String session) async {}
}
