import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('moyi/jarbridge');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const spec = JarSiteSpec(
    siteId: 'jar:testcfg:TestSpider',
    configId: 'testcfg',
    name: '测试站',
    className: 'com.github.catvod.spider.TestSpider',
    jarUrl: 'https://example.com/test.jar',
    jarMd5: '',
    ext: '{}',
  );

  group('JarHomeCache', () {
    test('TTL 内命中、到期失效', () {
      var now = DateTime(2026, 11, 15, 8);
      final cache = JarHomeCache(now: () => now);
      final result = {'class': []};
      cache.store('s1', result);
      now = now.add(const Duration(minutes: 9));
      expect(cache.lookup('s1'), same(result));
      now = now.add(const Duration(minutes: 1));
      expect(cache.lookup('s1'), isNull);
    });

    test('按站隔离、按配置清除', () {
      final cache = JarHomeCache(now: () => DateTime(2026, 11, 15, 8));
      cache.store('jar:cfg1:A', {'a': 1});
      cache.store('jar:cfg2:B', {'b': 2});
      cache.removeForConfig('cfg1');
      expect(cache.lookup('jar:cfg1:A'), isNull);
      expect(cache.lookup('jar:cfg2:B'), isNotNull);
    });
  });

  group('JarBridge home 缓存与去重', () {
    late List<String> calls;

    setUp(() {
      calls = [];
      JarBridge.setTestJarPath('testcfg', '/tmp/test.jar');
      JarBridge.register(spec);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'call') return null;
        final args = Map<String, dynamic>.from(call.arguments as Map);
        calls.add(args['method'] as String? ?? '');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return {
          'text': jsonEncode({
            'class': [
              {'type_id': '1', 'type_name': '电影'},
            ],
            'list': [],
          }),
        };
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      JarBridge.unregister(spec.siteId);
      JarBridge.clearTestJarPaths();
      JarBridge.resetTestHomeCache();
      JarBridge.setTestTimeout(null);
    });

    test('并发 home 只发一次 homeContent', () async {
      final results = await Future.wait([
        JarBridge.home(spec),
        JarBridge.home(spec),
        JarBridge.home(spec),
      ]);
      expect(calls, ['homeContent']);
      for (final result in results) {
        expect((result['class'] as List).single['type_name'], '电影');
      }
    });

    test('TTL 过期后 home 重新拉', () async {
      var now = DateTime(2026, 11, 15, 8);
      JarBridge.setTestHomeCache(JarHomeCache(now: () => now));
      await JarBridge.home(spec);
      await JarBridge.home(spec);
      expect(calls, ['homeContent']);
      now = now.add(const Duration(minutes: 11));
      await JarBridge.home(spec);
      expect(calls, ['homeContent', 'homeContent']);
    });

    test('force 刷新不读缓存', () async {
      await JarBridge.home(spec);
      await JarBridge.home(spec, force: true);
      expect(calls, ['homeContent', 'homeContent']);
    });

    test('ext 变更清缓存', () async {
      await JarBridge.home(spec);
      JarBridge.register(spec.copyWith(ext: '{"v":2}'));
      await JarBridge.home(spec.copyWith(ext: '{"v":2}'));
      expect(calls, ['homeContent', 'homeContent']);
    });
  });

  group('JarBridge 通道超时', () {
    setUp(() {
      JarBridge.setTestJarPath('testcfg', '/tmp/test.jar');
      JarBridge.setTestTimeout(const Duration(milliseconds: 100));
      JarBridge.register(spec);
      messenger.setMockMethodCallHandler(channel, (call) async {
        // 永远不回：无超时保护时会永久挂起。
        await Future<void>.delayed(const Duration(seconds: 30));
        return {'text': '{}'};
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      JarBridge.unregister(spec.siteId);
      JarBridge.clearTestJarPaths();
      JarBridge.resetTestHomeCache();
      JarBridge.setTestTimeout(null);
    });

    test('callJson 超时报 JarBridgeFailure，不永久挂起', () async {
      final watch = Stopwatch()..start();
      await expectLater(
        JarBridge.callJson(spec, 'searchContent', {'key': 'x'}),
        throwsA(isA<JarBridgeFailure>()),
      );
      watch.stop();
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('JarBridge ensureJar 去重', () {
    late int ensureCalls;

    setUp(() {
      ensureCalls = 0;
      JarBridge.setTestSupported(true);
      JarBridge.setTestTimeout(const Duration(seconds: 5));
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ensureJar') {
          ensureCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return {'path': '/tmp/downloaded.jar'};
        }
        return null;
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      JarBridge.setTestSupported(null);
      JarBridge.setTestTimeout(null);
      JarBridge.clearTestJarPaths();
      JarBridge.invalidateJar('cfgx');
    });

    test('并发 ensureJarPath 只下载一次', () async {
      final paths = await Future.wait([
        JarBridge.ensureJarPath(configId: 'cfgx', url: 'https://x/j.jar'),
        JarBridge.ensureJarPath(configId: 'cfgx', url: 'https://x/j.jar'),
        JarBridge.ensureJarPath(configId: 'cfgx', url: 'https://x/j.jar'),
      ]);
      expect(ensureCalls, 1);
      expect(paths, ['/tmp/downloaded.jar', '/tmp/downloaded.jar', '/tmp/downloaded.jar']);
      // 已缓存：后续调用不再发通道请求。
      await JarBridge.ensureJarPath(configId: 'cfgx', url: 'https://x/j.jar');
      expect(ensureCalls, 1);
    });
  });

  group('JarBridge coverFile', () {
    late Directory tempDir;
    late HttpServer server;
    late int hits;

    setUpAll(() async {
      // 测试绑定会把 HttpClient 换成一律回 400 的假实现；本组要跑真
      // 本地服务器，须把全局覆盖清掉才能发出真实请求。
      HttpOverrides.global = null;
      tempDir = await Directory.systemTemp.createTemp('moyi_jar_cover_test');
      const provider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(provider, (call) async => tempDir.path);
    });

    tearDownAll(() async {
      const provider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(provider, null);
      await tempDir.delete(recursive: true);
    });

    setUp(() async {
      hits = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        hits++;
        if (request.uri.path == '/slow') {
          await Future<void>.delayed(const Duration(seconds: 2));
          request.response.add([1, 2, 3]);
        } else if (request.uri.path == '/big') {
          request.response.add(List<int>.filled((8 << 20) + 1, 7));
        } else {
          request.response.add([1, 2, 3, 4]);
        }
        await request.response.close();
      });
      JarBridge.setTestTimeout(const Duration(milliseconds: 200));
    });

    tearDown(() async {
      await server.close(force: true);
      JarBridge.setTestTimeout(null);
    });

    String coverUrl(String path) =>
        'http://${server.address.host}:${server.port}$path';

    test('下载成功落盘，二次命中缓存不再请求', () async {
      JarBridge.setTestTimeout(const Duration(seconds: 5));
      final drama = Drama(
        id: '1',
        source: 'jar:testcfg:TestSpider',
        title: '剧',
        cover: coverUrl('/pic.jpg'),
      );
      final first = await JarBridge.coverFile(drama);
      expect(await File(first).readAsBytes(), [1, 2, 3, 4]);
      expect(hits, 1);
      final second = await JarBridge.coverFile(drama);
      expect(second, first);
      expect(hits, 1);
    });

    test('慢速封面超时报失败，不留残文件', () async {
      final drama = Drama(
        id: '2',
        source: 'jar:testcfg:TestSpider',
        title: '剧',
        cover: coverUrl('/slow'),
      );
      final cacheDir = Directory('${tempDir.path}/jar_covers');
      final before = cacheDir.existsSync()
          ? cacheDir.listSync().map((e) => e.path).toSet()
          : <String>{};
      await expectLater(
        JarBridge.coverFile(drama),
        throwsA(isA<JarBridgeFailure>()),
      );
      final after = cacheDir.existsSync()
          ? cacheDir.listSync().map((e) => e.path).toSet()
          : <String>{};
      expect(after, before);
    });

    test('超大封面报失败', () async {
      JarBridge.setTestTimeout(const Duration(seconds: 10));
      final drama = Drama(
        id: '3',
        source: 'jar:testcfg:TestSpider',
        title: '剧',
        cover: coverUrl('/big'),
      );
      await expectLater(
        JarBridge.coverFile(drama),
        throwsA(isA<JarBridgeFailure>()),
      );
    });
  });

  group('emptyUrlFailureMessage（取流空地址时的报错文案）', () {
    test('有蜘蛛 msg 时原样透传', () {
      expect(
        JarBridge.emptyUrlFailureMessage(const {
          'parse': 0,
          'playUrl': '',
          'url': '',
          'header': '',
          'msg': '该集需要登录或购买后才能播放',
        }, 'EroShort'),
        '该集需要登录或购买后才能播放',
      );
    });

    test('无 msg 时回落通用文案', () {
      expect(
        JarBridge.emptyUrlFailureMessage(const {'parse': 0, 'url': ''}, '测试站'),
        'jar 站点「测试站」未返回播放地址',
      );
    });

    test('msg 只有空白时回落通用文案', () {
      expect(
        JarBridge.emptyUrlFailureMessage(const {'url': '', 'msg': '  '}, '测试站'),
        'jar 站点「测试站」未返回播放地址',
      );
    });
  });
}
