import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/proxy_kernel.dart';
import 'package:moyi/proxy_kernel_screen.dart';
import 'package:moyi/proxy_kernel_service.dart';
import 'package:moyi/socks5_proxy.dart';
import 'package:moyi/socks5_proxy_picker.dart';

const _entryA = Socks5ProxyEntry(
  id: 'a',
  name: '代理甲',
  host: '10.0.0.1',
  port: 1080,
  username: 'user',
  password: 'pw-123',
  lastLatencyMs: 123,
  lastAvailable: true,
  lastCheckedAtMs: 1700000000000,
);

Socks5ProxyEntry _entry({String id = 'x', bool enabled = true}) =>
    Socks5ProxyEntry(
      id: id,
      name: '代理$id',
      host: '127.0.0.1',
      port: 1080,
      enabled: enabled,
    );

class _FakeClock {
  var now = DateTime(2026, 1, 1, 12);
  DateTime call() => now;
}

class _FakeTransport implements Socks5ProbeTransport {
  _FakeTransport({required this.clock, this.advance = Duration.zero});

  final _FakeClock clock;
  final Duration advance;
  final Map<String, Object> outcomes = {};
  final List<String> probed = [];

  @override
  Future<int> fetchStatus(Socks5ProxyEntry entry) async {
    probed.add(entry.id);
    clock.now = clock.now.add(advance);
    final outcome = outcomes[entry.id];
    if (outcome is int) return outcome;
    if (outcome is Object) throw outcome;
    throw const SocketException('fake down');
  }
}

class _FakeKernelController implements ProxyKernelController {
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    if (method == 'status') {
      return {
        'supported': true,
        'installed': true,
        'builtinAvailable': true,
        'hasExternal': false,
        'builtinVersion': proxyKernelBuiltinVersion,
        'externalVersion': '',
        'activeBinary': '',
        'running': false,
        'mixedPort': 0,
        'controllerPort': 0,
        'selectedNode': '',
        'logTail': '',
      };
    }
    throw ProxyKernelFailure('unexpected method $method');
  }
}

/// 把 ListView 往上拖，直到 [finder] 出现：页面里有多个 Scrollable
///（输入框自带滚动），scrollUntilVisible 的默认查找会撞上“太多元素”，
/// 直接拖 ListView 最稳妥（预览测试同款做法）。
Future<void> _scrollListToVisible(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 25 && !tester.any(finder); i++) {
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
  }
  expect(finder, findsWidgets);
}

void main() {
  group('Socks5ProxyEntry', () {
    test('toJson/fromJson round-trip keeps every field', () {
      final restored = Socks5ProxyEntry.fromJson(_entryA.toJson());
      expect(restored.id, 'a');
      expect(restored.name, '代理甲');
      expect(restored.host, '10.0.0.1');
      expect(restored.port, 1080);
      expect(restored.username, 'user');
      expect(restored.password, 'pw-123');
      expect(restored.enabled, true);
      expect(restored.lastLatencyMs, 123);
      expect(restored.lastAvailable, true);
      expect(restored.lastCheckedAtMs, 1700000000000);
    });

    test('displayAddress never carries credentials', () {
      expect(_entryA.displayAddress, '10.0.0.1:1080');
      expect(_entryA.displayAddress.contains('pw-123'), false);
      expect(_entryA.displayAddress.contains('user'), false);
    });

    test('validation rejects bad host/port/oversized credentials', () {
      expect(
        validateSocks5ProxyEntry(host: '', port: 1080, username: '', password: ''),
        isNotNull,
      );
      expect(
        validateSocks5ProxyEntry(host: 'a b', port: 1080, username: '', password: ''),
        isNotNull,
      );
      expect(
        validateSocks5ProxyEntry(host: 'h', port: 0, username: '', password: ''),
        isNotNull,
      );
      expect(
        validateSocks5ProxyEntry(host: 'h', port: 70000, username: '', password: ''),
        isNotNull,
      );
      expect(
        validateSocks5ProxyEntry(host: 'h', port: 1080, username: '', password: 'x'),
        isNotNull,
      );
      expect(
        validateSocks5ProxyEntry(
          host: 'h',
          port: 1080,
          username: 'u' * 300,
          password: '',
        ),
        isNotNull,
      );
      expect(
        validateSocks5ProxyEntry(
          host: 'h',
          port: 1080,
          username: 'u',
          password: 'p',
        ),
        isNull,
      );
    });
  });

  group('Socks5ProxyService persistence', () {
    test('add/update/remove/toggle round-trips through the store', () async {
      final store = MemorySocks5ProxyStore();
      final service = Socks5ProxyService(
        store: store,
        router: Socks5ProxyRouter(),
      );
      final added = await service.addProxy(
        name: '甲',
        host: '10.0.0.1',
        port: 1080,
        username: 'u',
        password: 'p',
      );
      expect((await service.loadProxies()), hasLength(1));

      await service.updateProxy(added.copyWith(name: '甲改名', port: 1081));
      final updated = (await service.loadProxies()).single;
      expect(updated.name, '甲改名');
      expect(updated.port, 1081);
      expect(updated.password, 'p');

      await service.setProxyEnabled(added.id, false);
      expect((await service.loadProxies()).single.enabled, false);

      await service.removeProxy(added.id);
      expect(await service.loadProxies(), isEmpty);
    });

    test('assignments persist and removing a proxy clears its assignments',
        () async {
      final store = MemorySocks5ProxyStore();
      final service = Socks5ProxyService(
        store: store,
        router: Socks5ProxyRouter(),
      );
      final added = await service.addProxy(name: '甲', host: 'h', port: 1080);
      await service.setAssignment('live:xiuguo', added.id);
      await service.setAssignment('scrape', socks5DirectAssignment);
      expect(await service.loadAssignments(), {
        'live:xiuguo': added.id,
        'scrape': socks5DirectAssignment,
      });
      await service.setAssignment('scrape', null);
      expect(await service.loadAssignments(), {'live:xiuguo': added.id});
      await service.removeProxy(added.id);
      expect(await service.loadAssignments(), isEmpty);
    });

    test('mutations sync the router snapshot', () async {
      final router = Socks5ProxyRouter();
      final service = Socks5ProxyService(
        store: MemorySocks5ProxyStore(),
        router: router,
      );
      final generation = router.generation;
      final added = await service.addProxy(name: '甲', host: 'h', port: 1080);
      await service.setAssignment('live:xiuguo', added.id);
      expect(router.generation, greaterThan(generation));
      expect(router.resolve('live:xiuguo').kind, Socks5RouteKind.via);
    });

    test('corrupt stored JSON loads as empty instead of throwing', () async {
      final store = MemorySocks5ProxyStore();
      await store.write(Socks5ProxyService.proxiesKey, 'not-json{{{');
      await store.write(Socks5ProxyService.assignmentsKey, '[]');
      final service = Socks5ProxyService(
        store: store,
        router: Socks5ProxyRouter(),
      );
      expect(await service.loadProxies(), isEmpty);
      expect(await service.loadAssignments(), isEmpty);
    });
  });

  group('resolveSocks5Route', () {
    test('no key / no assignment falls back', () {
      expect(
        resolveSocks5Route(null, [_entry()], {}).kind,
        Socks5RouteKind.fallback,
      );
      expect(
        resolveSocks5Route('live:a', [_entry()], {}).kind,
        Socks5RouteKind.fallback,
      );
    });

    test('direct assignment forces direct', () {
      expect(
        resolveSocks5Route(
          'live:a',
          [_entry()],
          {'live:a': socks5DirectAssignment},
        ).kind,
        Socks5RouteKind.direct,
      );
    });

    test('enabled proxy assignment routes via that proxy', () {
      final route = resolveSocks5Route(
        'live:a',
        [_entry(id: 'p1'), _entry(id: 'p2')],
        {'live:a': 'p2'},
      );
      expect(route.kind, Socks5RouteKind.via);
      expect(route.entry!.id, 'p2');
    });

    test('disabled or unknown proxy assignment falls back, never breaks', () {
      expect(
        resolveSocks5Route(
          'live:a',
          [_entry(id: 'p1', enabled: false)],
          {'live:a': 'p1'},
        ).kind,
        Socks5RouteKind.fallback,
      );
      expect(
        resolveSocks5Route(
          'live:a',
          [_entry(id: 'p1')],
          {'live:a': 'gone'},
        ).kind,
        Socks5RouteKind.fallback,
      );
    });

    test('different resources resolve independently', () {
      final proxies = [_entry(id: 'p1'), _entry(id: 'p2')];
      final assignments = {
        'live:a': 'p1',
        'live:b': socks5DirectAssignment,
      };
      expect(
        resolveSocks5Route('live:a', proxies, assignments).entry!.id,
        'p1',
      );
      expect(
        resolveSocks5Route('live:b', proxies, assignments).kind,
        Socks5RouteKind.direct,
      );
      expect(
        resolveSocks5Route('live:c', proxies, assignments).kind,
        Socks5RouteKind.fallback,
      );
    });
  });

  group('Socks5LatencyTester', () {
    test('fake clock + fake client report the injected latency', () async {
      final clock = _FakeClock();
      final transport = _FakeTransport(
        clock: clock,
        advance: const Duration(milliseconds: 150),
      )..outcomes['x'] = 204;
      final tester = Socks5LatencyTester(transport: transport, clock: clock.call);
      final result = await tester.test(_entry());
      expect(result.available, true);
      expect(result.latencyMs, 150);
    });

    test('failing transport reports unavailable with no latency number',
        () async {
      final clock = _FakeClock();
      final transport = _FakeTransport(clock: clock);
      final tester = Socks5LatencyTester(transport: transport, clock: clock.call);
      final result = await tester.test(_entry());
      expect(result.available, false);
      expect(result.latencyMs, isNull);
    });

    test('5xx status reports unavailable', () async {
      final clock = _FakeClock();
      final transport = _FakeTransport(clock: clock)..outcomes['x'] = 500;
      final tester = Socks5LatencyTester(transport: transport, clock: clock.call);
      expect((await tester.test(_entry())).available, false);
    });
  });

  group('identifyAll', () {
    test('tests every stored proxy sequentially and persists results',
        () async {
      final clock = _FakeClock();
      final transport = _FakeTransport(
        clock: clock,
        advance: const Duration(milliseconds: 42),
      );
      final service = Socks5ProxyService(
        store: MemorySocks5ProxyStore(),
        router: Socks5ProxyRouter(),
        tester: Socks5LatencyTester(transport: transport, clock: clock.call),
      );
      final first = await service.addProxy(name: '甲', host: 'h1', port: 1080);
      final second = await service.addProxy(name: '乙', host: 'h2', port: 1080);
      transport.outcomes[first.id] = 204;
      transport.outcomes[second.id] = const SocketException('down');
      final progress = <String>[];
      final results = await service.identifyAll(
        onProgress: (entry, index, total) =>
            progress.add('$index/$total:${entry.id}'),
      );
      expect(transport.probed, [first.id, second.id]);
      expect(progress, hasLength(2));
      expect(results[0].lastAvailable, true);
      expect(results[0].lastLatencyMs, 42);
      expect(results[1].lastAvailable, false);
      expect(results[1].lastLatencyMs, isNull);
      final stored = await service.loadProxies();
      expect(stored[0].lastAvailable, true);
      expect(stored[1].lastAvailable, false);
    });
  });

  group('Socks5ResourceProxyPicker widget', () {
    testWidgets('shows options and persists the selection', (tester) async {
      final service = Socks5ProxyService(
        store: MemorySocks5ProxyStore(),
        router: Socks5ProxyRouter(),
      );
      final proxy = await service.addProxy(
        name: '代理甲',
        host: '10.0.0.1',
        port: 1080,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Socks5ResourceProxyPicker(
              resourceKey: 'live:xiuguo',
              label: '直播 · 秀果',
              service: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('直播 · 秀果'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      expect(find.text('跟随默认'), findsWidgets);
      expect(find.text('直连'), findsOneWidget);
      await tester.tap(find.text('代理甲').last);
      await tester.pumpAndSettle();
      expect(
        (await service.loadAssignments())['live:xiuguo'],
        proxy.id,
      );
    });
  });

  testWidgets('ProxyKernelScreen shows the SOCKS5 section with statuses',
      (tester) async {
    final store = MemorySocks5ProxyStore();
    final socks5 = Socks5ProxyService(store: store, router: Socks5ProxyRouter());
    final first = await socks5.addProxy(
      name: '代理甲',
      host: '10.0.0.1',
      port: 1080,
      username: 'u',
      password: 'secret-pw-123',
    );
    await socks5.updateProxy(
      first.copyWith(lastAvailable: true, lastLatencyMs: 123),
    );
    await socks5.addProxy(name: '代理乙', host: '10.0.0.2', port: 1080);
    final kernel = ProxyKernelService(
      controller: _FakeKernelController(),
      store: MemoryProxyKernelStore(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ProxyKernelScreen(service: kernel, socks5Service: socks5),
      ),
    );
    await tester.pumpAndSettle();
    // SOCKS5 区在页面底部：须滚动到可见处 ListView 才会构建对应行，
    // 逐段滚到可见再断言，避免滚过头后上方的行被回收。
    await _scrollListToVisible(tester, find.text('SOCKS5 代理'));
    await _scrollListToVisible(tester, find.text('一键识别'));
    await tester.pumpAndSettle();
    expect(find.text('SOCKS5 代理'), findsOneWidget);
    expect(find.text('一键识别'), findsOneWidget);
    await _scrollListToVisible(tester, find.textContaining('可用 · 123 ms'));
    await tester.pumpAndSettle();
    expect(find.text('代理甲'), findsWidgets);
    expect(find.textContaining('可用 · 123 ms'), findsOneWidget);
    await _scrollListToVisible(tester, find.text('代理乙'));
    await tester.pumpAndSettle();
    expect(find.textContaining('未测试'), findsWidgets);
    expect(find.textContaining('secret-pw-123'), findsNothing);
    await _scrollListToVisible(tester, find.text('各资源代理'));
    await tester.pumpAndSettle();
    expect(find.text('各资源代理'), findsOneWidget);
  });
}
