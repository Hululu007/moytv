import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/live_http.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/live_repository.dart';
import 'package:moyi/live_sources.dart';

void main() {
  group('LiveCookieJar', () {
    test('同主机收发、异主机隔离', () {
      final jar = LiveCookieJar();
      jar.record('a.example.com', ['sess=abc; Path=/']);
      expect(jar.headerFor('a.example.com'), 'sess=abc');
      expect(jar.headerFor('b.example.com'), isNull);
    });

    test('多 Cookie 合并为一个头', () {
      final jar = LiveCookieJar();
      jar.record('a.example.com', ['x=1']);
      jar.record('a.example.com', ['y=2; Path=/']);
      expect(jar.headerFor('a.example.com'), 'x=1; y=2');
    });

    test('Max-Age=0 删除 Cookie', () {
      final jar = LiveCookieJar();
      jar.record('a.example.com', ['sess=abc']);
      jar.record('a.example.com', ['sess=; Max-Age=0']);
      expect(jar.headerFor('a.example.com'), isNull);
    });

    test('已过期的 Expires 不收', () {
      final jar = LiveCookieJar();
      final now = DateTime.utc(2026, 11, 15, 8);
      jar.record(
        'a.example.com',
        ['old=1; Expires=Wed, 01 Jan 2025 00:00:00 GMT'],
        now: now,
      );
      expect(jar.headerFor('a.example.com'), isNull);
      jar.record(
        'a.example.com',
        ['fresh=1; Expires=Wed, 01 Jan 2027 00:00:00 GMT'],
        now: now,
      );
      expect(jar.headerFor('a.example.com'), 'fresh=1');
    });

    test('Domain 与主机不匹配不收，子域匹配收', () {
      final jar = LiveCookieJar();
      jar.record('a.example.com', ['x=1; Domain=evil.example.org']);
      expect(jar.headerFor('a.example.com'), isNull);
      jar.record('sub.example.com', ['y=2; Domain=.example.com']);
      expect(jar.headerFor('sub.example.com'), 'y=2');
    });

    test('无名与空值行被跳过', () {
      final jar = LiveCookieJar();
      jar.record('a.example.com', ['=noname', 'novalue']);
      expect(jar.headerFor('a.example.com'), isNull);
    });
  });

  group('LiveHttp 单一截止期', () {
    late HttpServer server;
    late LiveHttp http;

    setUp(() async {
      http = LiveHttp();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/slow') {
          // 每段都不到 500ms，但总耗时 800ms：三段各挂超时的旧实现
          // 会放行，单一截止期必须报超时。
          await Future<void>.delayed(const Duration(milliseconds: 400));
          request.response.write('a');
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 400));
          request.response.write('b');
          await request.response.close();
        } else if (request.uri.path == '/set') {
          request.response.headers.set(
            HttpHeaders.setCookieHeader,
            'sess=abc; Path=/',
          );
          request.response.write('ok');
          await request.response.close();
        } else if (request.uri.path == '/echo') {
          request.response.write(
            request.headers.value(HttpHeaders.cookieHeader) ?? '',
          );
          await request.response.close();
        } else {
          request.response.write('fast');
          await request.response.close();
        }
      });
    });

    tearDown(() async {
      http.close();
      await server.close(force: true);
    });

    String url(String path) =>
        'http://${server.address.host}:${server.port}$path';

    test('三段耗时之和超过预算即超时，不等到三倍', () async {
      final watch = Stopwatch()..start();
      await expectLater(
        http.get(url('/slow'), timeout: const Duration(milliseconds: 500)),
        throwsA(isA<AppFailure>()),
      );
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 750)));
    });

    test('总耗时在预算内正常返回', () async {
      final body = await http.get(
        url('/fast'),
        timeout: const Duration(seconds: 5),
      );
      expect(body, 'fast');
    });

    test('同主机 Cookie 会被带回', () async {
      await http.get(url('/set'));
      final echoed = await http.get(url('/echo'));
      expect(echoed, 'sess=abc');
    });
  });

  group('LiveRepository 缓存与并发', () {
    late _FakeLiveHttp fake;
    late LiveRepository repository;
    late DateTime fakeNow;

    const pingtaiSource = LiveSource(
      id: 'pt',
      name: '面板源',
      description: '',
      protocol: LiveProtocol.pingtai,
      endpoints: ['http://m1', 'http://m2'],
    );

    setUp(() {
      fakeNow = DateTime(2026, 11, 15, 8);
      fake = _FakeLiveHttp();
      repository = LiveRepository(
        http: fake,
        now: () => fakeNow,
        platformTtl: const Duration(minutes: 10),
        channelTtl: const Duration(minutes: 5),
        routeOrderTtl: const Duration(minutes: 15),
      );
    });

    tearDown(() => repository.dispose());

    test('镜像并行拉取：两镜像各 300ms，总耗时远小于串行 600ms', () async {
      fake.handler = (url) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (url == 'http://m1/json.txt') {
          return jsonEncode({
            'pingtai': [
              {'address': 'cat1', 'title': '分类一', 'Number': '5'},
            ],
          });
        }
        return jsonEncode({
          'pingtai': [
            {'address': 'cat1', 'title': '分类一', 'Number': '9'},
            {'address': 'cat2', 'title': '分类二', 'Number': '3'},
          ],
        });
      };
      final watch = Stopwatch()..start();
      final platforms = await repository.platforms(pingtaiSource);
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 550)));
      // 合并：同分类取计数大的镜像，分两类都在。
      expect(platforms.map((p) => p.id), ['cat1', 'cat2']);
      expect(platforms.first.count, 9);
      expect(platforms.first.endpoint, 'http://m2');
    });

    test('一镜像失败不影响另一镜像，失败按声明顺序记首条', () async {
      fake.handler = (url) async {
        if (url == 'http://m1/json.txt') throw AppFailure('m1 挂了');
        return jsonEncode({
          'pingtai': [
            {'address': 'cat1', 'title': '分类一', 'Number': '2'},
          ],
        });
      };
      final platforms = await repository.platforms(pingtaiSource);
      expect(platforms.map((p) => p.id), ['cat1']);

      fake.handler = (url) async => throw AppFailure('全挂 $url');
      repository.clear();
      await expectLater(
        repository.platforms(pingtaiSource),
        throwsA(
          predicate(
            (e) => e is AppFailure && e.toString().contains('http://m1'),
          ),
        ),
      );
    });

    test('分类缓存 TTL 内命中、过期后重拉', () async {
      var calls = 0;
      fake.handler = (url) async {
        calls++;
        return jsonEncode({
          'pingtai': [
            {'address': 'cat1', 'title': '分类一', 'Number': '1'},
          ],
        });
      };
      await repository.platforms(pingtaiSource);
      await repository.platforms(pingtaiSource);
      expect(calls, 2); // 两镜像各一次。
      fakeNow = fakeNow.add(const Duration(minutes: 11));
      await repository.platforms(pingtaiSource);
      expect(calls, 4);
    });

    test('并发取分类只发一次请求（在途去重）', () async {
      var calls = 0;
      fake.handler = (url) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return jsonEncode({
          'pingtai': [
            {'address': 'cat1', 'title': '分类一', 'Number': '1'},
          ],
        });
      };
      final results = await Future.wait([
        repository.platforms(pingtaiSource),
        repository.platforms(pingtaiSource),
        repository.platforms(pingtaiSource),
      ]);
      expect(calls, 2); // 两镜像各一次，不是 3 次 × 2。
      expect(results[0].single.id, 'cat1');
      expect(results[1].single.id, 'cat1');
      expect(results[2].single.id, 'cat1');
    });

    test('force 刷新不读缓存、不复用在途请求', () async {
      var calls = 0;
      fake.handler = (url) async {
        calls++;
        return jsonEncode({
          'pingtai': [
            {'address': 'cat1', 'title': '分类一', 'Number': '1'},
          ],
        });
      };
      await repository.platforms(pingtaiSource);
      await repository.platforms(pingtaiSource, force: true);
      expect(calls, 4);
    });

    test('cancel 后回来的频道结果不写缓存', () async {
      const listSource = LiveSource(
        id: 'lst',
        name: '列表源',
        description: '',
        protocol: LiveProtocol.list,
        endpoints: ['http://list/playlist.m3u'],
      );
      var calls = 0;
      fake.handler = (url) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return '#EXTM3U\n#EXTINF:-1,频道A\nhttp://example.com/a.m3u8\n';
      };
      const platform = LivePlatform(id: 'all', name: '全部频道');
      final pending = repository.channels(listSource, platform);
      repository.cancel();
      final first = await pending;
      expect(first.single.name, '频道A');
      // 缓存未被过期写入污染：再取一次必须重新请求。
      await repository.channels(listSource, platform);
      expect(calls, 2);
    });

    test('频道缓存过期后重拉', () async {
      const listSource = LiveSource(
        id: 'lst2',
        name: '列表源',
        description: '',
        protocol: LiveProtocol.list,
        endpoints: ['http://list/playlist.m3u'],
      );
      var calls = 0;
      fake.handler = (url) async {
        calls++;
        return '#EXTM3U\n#EXTINF:-1,频道A\nhttp://example.com/a.m3u8\n';
      };
      const platform = LivePlatform(id: 'all', name: '全部频道');
      await repository.channels(listSource, platform);
      await repository.channels(listSource, platform);
      expect(calls, 1);
      fakeNow = fakeNow.add(const Duration(minutes: 6));
      await repository.channels(listSource, platform);
      expect(calls, 2);
    });

    test('带代理的空列表报 AppFailure，不漏 StateError', () async {
      const proxied = LiveSource(
        id: 'lst3',
        name: '代理列表源',
        description: '',
        protocol: LiveProtocol.list,
        endpoints: ['http://list/empty.m3u'],
        proxies: ['http://proxy/'],
      );
      fake.handler = (url) async => '';
      const platform = LivePlatform(id: 'all', name: '全部频道');
      await expectLater(
        repository.channels(proxied, platform),
        throwsA(isA<AppFailure>()),
      );
    });

    test('频道缓存超 64 条丢弃最早的', () async {
      const listSource = LiveSource(
        id: 'lst4',
        name: '列表源',
        description: '',
        protocol: LiveProtocol.list,
        endpoints: ['http://list/playlist.m3u'],
      );
      fake.handler = (url) async =>
          '#EXTM3U\n#EXTINF:-1,频道A\nhttp://example.com/a.m3u8\n';
      // 70 个不同页码各取一次，缓存应只留 64 条（时钟每页 +1 秒，
      // 让存入顺序与时间戳一致，逐出确定性不依赖排序稳定性）。
      for (var page = 1; page <= 70; page++) {
        fakeNow = fakeNow.add(const Duration(seconds: 1));
        await repository.channels(
          listSource,
          const LivePlatform(id: 'all', name: '全部频道'),
          page: page,
        );
      }
      // 第 1 页已被逐出：再取要重新请求（计数 +1）。
      var extra = 0;
      final previous = fake.handler;
      fake.handler = (url) async {
        extra++;
        return previous!(url);
      };
      await repository.channels(
        listSource,
        const LivePlatform(id: 'all', name: '全部频道'),
        page: 1,
      );
      expect(extra, 1);
      // 第 70 页仍在缓存：不发请求。
      await repository.channels(
        listSource,
        const LivePlatform(id: 'all', name: '全部频道'),
        page: 70,
      );
      expect(extra, 1);
    });
  });
}

class _FakeLiveHttp extends LiveHttp {
  Future<String> Function(String url)? handler;

  @override
  Future<String> get(
    String url, {
    Map<String, String> headers = const {},
    Duration? timeout,
    String? proxyResourceKey,
  }) {
    final handle = handler;
    if (handle == null) throw StateError('no handler for $url');
    return handle(url);
  }
}
