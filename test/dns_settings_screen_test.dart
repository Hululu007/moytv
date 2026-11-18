import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/dns_settings_screen.dart';
import 'package:moyi/nexhub_scraper/network/model/network_config.dart';
import 'package:moyi/nexhub_scraper/network/network_config_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = NetworkConfigService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await service.load();
    await service.update(NetworkConfig.defaults);
  });

  tearDown(() async {
    await service.update(NetworkConfig.defaults);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // 高视口：整页一次建成，免得 ListView 懒建导致折叠区按钮找不到。
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: DnsSettingsScreen()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapButton(WidgetTester tester, String keyName) async {
    await tester.tap(find.byKey(ValueKey(keyName)));
    await tester.pumpAndSettle();
  }

  testWidgets('默认系统 DNS：不显示地址输入框', (tester) async {
    await pumpPage(tester);
    expect(find.text('DNS 设置'), findsOneWidget);
    expect(find.text('系统 DNS'), findsOneWidget);
    expect(find.byKey(const ValueKey('dns-doh-field')), findsNothing);
    expect(find.byKey(const ValueKey('dns-servers-field')), findsNothing);
  });

  testWidgets('选 DoH 填地址保存后配置落地', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('dns-mode-doh')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dns-doh-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('dns-doh-field')),
      'https://dns.google/dns-query',
    );
    await tapButton(tester, 'dns-save-button');
    expect(service.config.dns.mode, DnsMode.doh);
    expect(service.config.dns.dohUrl, 'https://dns.google/dns-query');
  });

  testWidgets('DoH 地址非法时不保存', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('dns-mode-doh')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('dns-doh-field')),
      'not-a-url',
    );
    await tapButton(tester, 'dns-save-button');
    expect(service.config.dns.mode, DnsMode.system);
  });

  testWidgets('自定义 DNS：非法服务器不保存，合法保存', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('dns-mode-custom')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('dns-servers-field')),
      'not-an-ip',
    );
    await tapButton(tester, 'dns-save-button');
    expect(service.config.dns.mode, DnsMode.system);

    await tester.enterText(
      find.byKey(const ValueKey('dns-servers-field')),
      '8.8.8.8, 1.1.1.1',
    );
    await tapButton(tester, 'dns-save-button');
    expect(service.config.dns.mode, DnsMode.custom);
    expect(service.config.dns.servers, ['8.8.8.8', '1.1.1.1']);
  });

  testWidgets('DoT 保存与恢复系统 DNS', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('dns-mode-dot')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('dns-dot-host-field')),
      'dns.google',
    );
    await tester.enterText(
      find.byKey(const ValueKey('dns-dot-port-field')),
      '8853',
    );
    await tapButton(tester, 'dns-save-button');
    expect(service.config.dns.mode, DnsMode.dot);
    expect(service.config.dns.dotHost, 'dns.google');
    expect(service.config.dns.dotPort, 8853);

    await tapButton(tester, 'dns-reset-button');
    expect(service.config.dns.mode, DnsMode.system);
  });
}
