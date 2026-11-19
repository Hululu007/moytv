import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/models.dart';

const _oneSpec = JarSiteSpec(
  siteId: 'jar:one:One',
  configId: 'one',
  name: '🔞一点播',
  className: 'com.github.catvod.spider.One',
  jarUrl: 'assets/jars/one.jar',
  jarMd5: '1bae661a921446497c35f7cfee65dc6e',
  ext: '',
);

const _otherSpec = JarSiteSpec(
  siteId: 'jar:zakatv:Other',
  configId: 'zakatv',
  name: '他站',
  className: 'com.github.catvod.spider.Other',
  jarUrl: 'https://example.invalid/zakatv.jar',
  jarMd5: '0',
  ext: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('moyi/jarbridge');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('image proxy scope pins to the One site only', () {
    expect(JarBridge.imageProxySiteIds, {'jar:one:One'});
  });

  group('jarProxy carries siteId and ext for instance dispatch', () {
    late List<Map<String, dynamic>> calls;

    setUp(() {
      calls = [];
      JarBridge.setTestJarPath('one', '/tmp/one.jar');
      JarBridge.register(_oneSpec);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'jarProxy') return null;
        calls.add(Map<String, dynamic>.from(call.arguments as Map));
        return {
          'status': 200,
          'mime': 'image/jpeg',
          'bodyBase64': base64Encode([1, 2, 3]),
        };
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      JarBridge.unregister(_oneSpec.siteId);
      JarBridge.clearTestJarPaths();
    });

    test(
      'siteId, configId, className, ext and param all reach the bridge',
      () async {
        final result = await JarBridge.jarProxy(_oneSpec, {
          'url': 'https://example.invalid/cover.jpg',
        });
        expect(calls, hasLength(1));
        final args = calls.single;
        expect(args['siteId'], 'jar:one:One');
        expect(args['configId'], 'one');
        expect(args['className'], 'com.github.catvod.spider.One');
        expect(args['ext'], '');
        expect(args['jarPath'], '/tmp/one.jar');
        expect(args['param'], {'url': 'https://example.invalid/cover.jpg'});
        expect(result['status'], 200);
        expect(result['mime'], 'image/jpeg');
        expect(base64Decode(result['bodyBase64'] as String), [1, 2, 3]);
      },
    );
  });

  group('coverFile through instance localProxy', () {
    late Directory tempDir;
    late List<Map<String, dynamic>> proxyCalls;
    late List<int> proxyBody;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('moyi_one_cover_test');
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

    setUp(() {
      proxyCalls = [];
      proxyBody = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3];
      JarBridge.setTestJarPath('one', '/tmp/one.jar');
      JarBridge.register(_oneSpec);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'jarProxy') return null;
        proxyCalls.add(Map<String, dynamic>.from(call.arguments as Map));
        return {
          'status': 200,
          'mime': 'image/jpeg',
          'bodyBase64': base64Encode(proxyBody),
        };
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      JarBridge.unregister(_oneSpec.siteId);
      JarBridge.clearTestJarPaths();
    });

    test('One cover is fetched via jarProxy, never directly', () async {
      // 测试绑定的假 HttpClient 一律回 400：若错误地走了直取，
      // 这里会抛“封面下载失败：HTTP 400”而不是成功。
      final drama = Drama(
        id: '1',
        source: 'jar:one:One',
        title: '剧',
        cover: 'https://example.invalid/cover.jpg',
      );
      final path = await JarBridge.coverFile(drama);
      expect(path.split(Platform.pathSeparator).last.startsWith('px_'), isTrue);
      expect(await File(path).readAsBytes(), proxyBody);
      expect(proxyCalls, hasLength(1));
      expect(proxyCalls.single['param'], {
        'url': 'https://example.invalid/cover.jpg',
      });
      // 二次命中缓存，不再调代理。
      final second = await JarBridge.coverFile(drama);
      expect(second, path);
      expect(proxyCalls, hasLength(1));
    });

    test('empty proxy body fails without leaving a residual file', () async {
      proxyBody = [];
      final drama = Drama(
        id: '2',
        source: 'jar:one:One',
        title: '剧',
        cover: 'https://example.invalid/empty.jpg',
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

    test(
      'oversized proxy body fails without leaving a residual file',
      () async {
        proxyBody = List<int>.filled(JarBridge.maxCoverBytes + 1, 7);
        final drama = Drama(
          id: '3',
          source: 'jar:one:One',
          title: '剧',
          cover: 'https://example.invalid/big.jpg',
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
      },
    );
  });

  group('coverFile direct path unchanged for other jar sites', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('moyi_one_cover_direct');
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

    test(
      'non-One jar cover downloads directly and never calls jarProxy',
      () async {
        final savedOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var hits = 0;
        server.listen((request) async {
          hits++;
          request.response.add([9, 8, 7, 6]);
          await request.response.close();
        });
        messenger.setMockMethodCallHandler(channel, (call) async {
          throw StateError('jarProxy must not be called for other sites');
        });
        JarBridge.register(_otherSpec);
        try {
          final drama = Drama(
            id: '1',
            source: 'jar:zakatv:Other',
            title: '剧',
            cover: 'http://${server.address.host}:${server.port}/pic.jpg',
          );
          final path = await JarBridge.coverFile(drama);
          expect(
            path.split(Platform.pathSeparator).last.startsWith('px_'),
            isFalse,
          );
          expect(await File(path).readAsBytes(), [9, 8, 7, 6]);
          expect(hits, 1);
        } finally {
          HttpOverrides.global = savedOverrides;
          messenger.setMockMethodCallHandler(channel, null);
          JarBridge.unregister(_otherSpec.siteId);
          await server.close(force: true);
        }
      },
    );
  });
}
