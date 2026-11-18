import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/dns_settings.dart';
import 'package:moyi/nexhub_scraper/network/model/effective_network_profile.dart';
import 'package:moyi/nexhub_scraper/network/model/network_config.dart';
import 'package:moyi/nexhub_scraper/network/network_config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DNS 输入解析与校验', () {
    test('parseDnsServers：分隔符混用、非法过滤、去重保序', () {
      expect(
        parseDnsServers('8.8.8.8, 1.1.1.1\n8.8.8.8; not-an-ip  2001:4860:4860::8888'),
        ['8.8.8.8', '1.1.1.1', '2001:4860:4860::8888'],
      );
      expect(parseDnsServers(''), isEmpty);
      expect(parseDnsServers('dns.google'), isEmpty);
    });

    test('validateDohUrl：https/http 合法，其余拒绝', () {
      expect(validateDohUrl('https://dns.google/dns-query'), isNull);
      expect(validateDohUrl('http://127.0.0.1:8080/dns-query'), isNull);
      expect(validateDohUrl(''), isNotNull);
      expect(validateDohUrl('dns.google/dns-query'), isNotNull);
      expect(validateDohUrl('ftp://x/y'), isNotNull);
      expect(validateDohUrl('https://'), isNotNull);
    });

    test('parseDotServer：主机 / 主机:端口 / 非法', () {
      expect(parseDotServer('dns.google'), ('dns.google', 853));
      expect(parseDotServer('dns.google:8853'), ('dns.google', 8853));
      expect(parseDotServer('  1.1.1.1:853  '), ('1.1.1.1', 853));
      expect(parseDotServer(''), isNull);
      expect(parseDotServer('dns.google:0'), isNull);
      expect(parseDotServer('dns.google:99999'), isNull);
      expect(parseDotServer('dns.google:abc'), isNull);
      expect(parseDotServer('dns.google/path'), isNull);
    });

    test('buildDnsConfig：各模式只改自己字段，系统模式保留旧值', () {
      const prev = DnsConfig(
        mode: DnsMode.doh,
        dohUrl: 'https://old.example/dns-query',
        servers: ['9.9.9.9'],
      );
      final system = buildDnsConfig(
        previous: prev,
        mode: DnsMode.system,
        serversInput: '',
        dohUrlInput: '',
        dotHostInput: '',
        dotPortInput: '',
      );
      expect(system.mode, DnsMode.system);
      expect(system.dohUrl, 'https://old.example/dns-query');
      expect(system.servers, ['9.9.9.9']);

      final custom = buildDnsConfig(
        previous: prev,
        mode: DnsMode.custom,
        serversInput: '8.8.8.8, 1.1.1.1',
        dohUrlInput: '',
        dotHostInput: '',
        dotPortInput: '',
      );
      expect(custom.servers, ['8.8.8.8', '1.1.1.1']);

      final dot = buildDnsConfig(
        previous: prev,
        mode: DnsMode.dot,
        serversInput: '',
        dohUrlInput: '',
        dotHostInput: 'dns.google',
        dotPortInput: 'bogus',
      );
      expect(dot.dotHost, 'dns.google');
      expect(dot.dotPort, 853);
    });

    test('validateDnsInput：缺服务器/地址不许保存', () {
      String? check(DnsMode m, {String s = '', String u = '', String h = '', String p = ''}) =>
          validateDnsInput(
            mode: m,
            serversInput: s,
            dohUrlInput: u,
            dotHostInput: h,
            dotPortInput: p,
          );
      expect(check(DnsMode.system), isNull);
      expect(check(DnsMode.custom), isNotNull);
      expect(check(DnsMode.custom, s: '8.8.8.8'), isNull);
      expect(check(DnsMode.doh), isNotNull);
      expect(check(DnsMode.doh, u: 'https://dns.google/dns-query'), isNull);
      expect(check(DnsMode.dot), isNotNull);
      expect(check(DnsMode.dot, h: 'dns.google'), isNull);
      expect(check(DnsMode.dot, h: 'dns.google', p: '0'), isNotNull);
    });

    test('dnsSummary：各模式一行说清', () {
      expect(dnsSummary(DnsConfig.defaults), '系统 DNS');
      expect(
        dnsSummary(const DnsConfig(mode: DnsMode.custom, servers: ['8.8.8.8'])),
        '自定义 DNS · 8.8.8.8',
      );
      expect(
        dnsSummary(
          const DnsConfig(mode: DnsMode.doh, dohUrl: 'https://dns.google/dns-query'),
        ),
        'DoH · dns.google',
      );
      expect(
        dnsSummary(const DnsConfig(mode: DnsMode.dot, dotHost: 'dns.google')),
        'DoT · dns.google:853',
      );
      expect(
        dnsSummary(const DnsConfig(mode: DnsMode.doh)),
        'DoH · 未填地址',
      );
    });

    test('DnsConfig JSON 往返', () {
      const cfg = DnsConfig(
        mode: DnsMode.doh,
        dohUrl: 'https://dns.google/dns-query',
        dotHost: 'dns.google',
        dotPort: 8853,
        servers: ['8.8.8.8'],
      );
      final roundTrip = DnsConfig.fromJson(
        jsonDecode(jsonEncode(cfg.toJson())) as Map<String, dynamic>,
      );
      expect(roundTrip.toJson(), cfg.toJson());
    });

    test('needsCustomConnection：系统默认不触发，非系统触发', () {
      expect(
        EffectiveNetworkProfile.fromConfig(NetworkConfig.defaults)
            .needsCustomConnection,
        isFalse,
      );
      expect(
        EffectiveNetworkProfile.fromConfig(
          NetworkConfig.defaults.copyWith(
            dns: const DnsConfig(mode: DnsMode.doh, dohUrl: 'https://x/y'),
          ),
        ).needsCustomConnection,
        isTrue,
      );
      expect(
        EffectiveNetworkProfile.fromConfig(
          NetworkConfig.defaults.copyWith(
            dns: const DnsConfig(
              mode: DnsMode.custom,
              servers: ['8.8.8.8'],
            ),
          ),
        ).needsCustomConnection,
        isTrue,
      );
    });
  });

  group('DNS 配置持久化（经 NetworkConfigService）', () {
    final service = NetworkConfigService.instance;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      await service.load();
    });

    tearDown(() async {
      await service.update(NetworkConfig.defaults);
    });

    test('update 只改 dns 一段、落盘可读回', () async {
      const dns = DnsConfig(
        mode: DnsMode.doh,
        dohUrl: 'https://dns.google/dns-query',
      );
      await service.update(service.config.copyWith(dns: dns));
      expect(service.config.dns.mode, DnsMode.doh);
      expect(service.config.dns.dohUrl, 'https://dns.google/dns-query');
      expect(service.globalProfile.dns.mode, DnsMode.doh);
      final prefs = await SharedPreferences.getInstance();
      final stored = NetworkConfig.fromJson(
        jsonDecode(prefs.getString('network_config_v1')!) as Map<String, dynamic>,
      );
      expect(stored.dns.dohUrl, 'https://dns.google/dns-query');
      // 其余方面未被洗掉。
      expect(stored.proxy.mode, ProxyMode.system);
      expect(stored.hosts, isEmpty);
    });

    test('默认仍是系统 DNS', () async {
      await service.update(NetworkConfig.defaults);
      expect(service.config.dns.mode, DnsMode.system);
      expect(service.config.dns.dohUrl, isEmpty);
      expect(service.config.dns.servers, isEmpty);
    });
  });
}
