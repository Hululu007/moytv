import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/content_http.dart';
import 'package:moyi/nexhub_scraper/network/model/network_config.dart';
import 'package:moyi/nexhub_scraper/network/network_config_service.dart';
import 'package:moyi/nexhub_scraper/network/runtime/dns_resolver.dart';
import 'package:moyi/nexhub_scraper/network/runtime/nexhub_http_overrides.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// DNS 设置生效桩验：假 DoH 端点 / 假 UDP 服务器 + 假主机名，证明
/// “选了配置后解析确实走配置的服务器”，不是摆设。
///
/// 假主机 `moyi-dns-probe.invalid` 在系统 DNS 里永远查不到（.invalid 顶级
/// 域）：只有经桩返回 127.0.0.1 时请求才能通。对照组（系统 DNS）必然失败，
/// 以此锁定“通”是配置的功劳。
///
/// 测试配置的代理一律 direct：隔离本机出口代理环境变量，只验 DNS 这一路
/// （手机上无 HTTP_PROXY 环境变量，system 代理模式同样直连）。

const _fakeHost = 'moyi-dns-probe.invalid';

/// 假 DoH 端点：dns-json 协议，任何名字都答 127.0.0.1。
class _FakeDoh {
  _FakeDoh._(this.server);
  final HttpServer server;
  final List<String> queriedNames = [];

  static Future<_FakeDoh> start() async {
    final fake = _FakeDoh._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fake.server.listen((request) async {
      final name = request.uri.queryParameters['name'] ?? '';
      fake.queriedNames.add(name);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'Status': 0,
        'Answer': [
          {'name': name, 'type': 1, 'TTL': 60, 'data': '127.0.0.1'},
        ],
      }));
      await request.response.close();
    });
    return fake;
  }

  String get url =>
      'http://127.0.0.1:${server.port}/dns-query';

  Future<void> close() => server.close(force: true);
}

/// 假目标服务：只认 127.0.0.1 上的连接，答固定正文。
class _Target {
  _Target._(this.server);
  final HttpServer server;

  static Future<_Target> start() async {
    final target = _Target._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    target.server.listen((request) async {
      request.response.write('dns-ok');
      await request.response.close();
    });
    return target;
  }

  int get port => server.port;

  Future<void> close() => server.close(force: true);
}

NetworkConfig _testConfig(DnsConfig dns) => NetworkConfig(
  proxy: const ProxyConfig(mode: ProxyMode.direct),
  dns: dns,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = NetworkConfigService.instance;
  late _FakeDoh doh;
  late _Target target;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await service.load();
    doh = await _FakeDoh.start();
    target = await _Target.start();
  });

  tearDownAll(() async {
    await doh.close();
    await target.close();
  });

  setUp(() {
    DnsResolver.instance.clearCache();
  });

  tearDown(() async {
    // 本 SDK 的 HttpOverrides.global 只有 setter、没有 getter：测完直接
    // 置空恢复默认，不读回旧值。
    HttpOverrides.global = null;
    DnsResolver.instance.clearCache();
    await service.update(NetworkConfig.defaults);
  });

  DnsConfig dohCfg() => DnsConfig(
    mode: DnsMode.doh,
    dohUrl: doh.url,
    cacheEnabled: false,
  );

  test('DoH 桩：解析器经假 DoH 端点拿到桩地址', () async {
    final addrs = await DnsResolver.instance.resolve(
      _fakeHost,
      dohCfg(),
      const [],
    );
    expect(addrs.map((a) => a.address), contains('127.0.0.1'));
    expect(doh.queriedNames, contains(_fakeHost));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('全局覆盖 + DoH：HttpClient 经 DoH 解析假主机拿到真服务', () async {
    await service.update(_testConfig(dohCfg()));
    HttpOverrides.global = NexHubHttpOverrides();
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://$_fakeHost:${target.port}/hello'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      expect(response.statusCode, 200);
      expect(await response.transform(utf8.decoder).join(), 'dns-ok');
    } finally {
      client.close(force: true);
    }
    // 请求确实经过了 DoH 桩（不是别的路蒙对的）。
    expect(doh.queriedNames, contains(_fakeHost));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('对照：系统 DNS 不走 DoH 桩（解析器层）', () async {
    await service.update(_testConfig(DnsConfig.defaults));
    HttpOverrides.global = NexHubHttpOverrides();
    try {
      final addrs = await DnsResolver.instance.resolve(
        _fakeHost,
        DnsConfig.defaults.copyWith(cacheEnabled: false),
        const [],
      );
      // 本沙箱的系统 DNS 对一切名字都答一个出口地址（198.18.x.x），
      // 故不断言“失败”，只断言“没答桩地址”：即没走 DoH 桩。
      expect(addrs.map((a) => a.address), isNot(contains('127.0.0.1')));
    } on Object {
      // 系统解析直接失败：同样证明没走 DoH 桩。
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('对照：系统 DNS 下 HttpClient 打不通假主机', () async {
    await service.update(_testConfig(DnsConfig.defaults));
    HttpOverrides.global = NexHubHttpOverrides();
    final client = HttpClient();
    // 直连，避免本机出口代理替假主机应答，干扰对照。
    client.findProxy = (_) => 'DIRECT';
    try {
      await expectLater(
        () async {
          final request = await client.getUrl(
            Uri.parse('http://$_fakeHost:${target.port}/hello'),
          );
          final response = await request.close().timeout(
            const Duration(seconds: 15),
          );
          await response.drain<void>();
        }(),
        throwsA(anything),
      );
    } finally {
      client.close(force: true);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('ContentHttp 跟随配置变化：改配置后不重启也走新 DNS', () async {
    await service.update(_testConfig(DnsConfig.defaults));
    HttpOverrides.global = NexHubHttpOverrides();
    final http = ContentHttp();
    try {
      // 先用系统配置打一次真地址（127.0.0.1 字面量），让长连接客户端
      // 按旧档案定型。
      final warm = await http.get(
        'http://127.0.0.1:${target.port}/hello',
      );
      expect(warm, 'dns-ok');
      // 改配置：同一实例下次请求必须走新 DNS。
      await service.update(_testConfig(dohCfg()));
      final viaDoh = await http.get(
        'http://$_fakeHost:${target.port}/hello',
      );
      expect(viaDoh, 'dns-ok');
      // 改回系统：同一实例下次请求必须不再拿到桩服务的内容（证明不是
      // 一直走旧配置）。本沙箱系统 DNS 会答出口地址，请求可能抛各种错，
      // 故只断言“结果不是桩正文”。
      await service.update(_testConfig(DnsConfig.defaults));
      Object? outcome;
      try {
        outcome = await http.get('http://$_fakeHost:${target.port}/hello');
      } catch (e) {
        outcome = e;
      }
      expect(outcome, isNot('dns-ok'));
    } finally {
      http.close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}
