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
  jarMd5: 'af504c50de9f88246da9b086b5893c42',
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

  test('no site needs the image proxy anymore', () {
    // 2026-11-19：一点播换成新蜘蛛重写版，封面是明文 JPEG 直链，新蜘蛛
    // 也没有 localProxy 方法；再钉着它封面全挂，故集合已清空。
    expect(JarBridge.imageProxySiteIds, isEmpty);
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

  group('coverFile downloads One covers directly', () {
    late Directory tempDir;
    late HttpServer server;
    late List<int> servedBody;
    var hits = 0;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('moyi_one_cover_test');
      const provider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(provider, (call) async => tempDir.path);
      servedBody = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        hits++;
        request.response.add(servedBody);
        await request.response.close();
      });
    });

    tearDownAll(() async {
      const provider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(provider, null);
      await server.close(force: true);
      await tempDir.delete(recursive: true);
    });

    setUp(() {
      hits = 0;
      JarBridge.setTestJarPath('one', '/tmp/one.jar');
      JarBridge.register(_oneSpec);
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw StateError('jarProxy must not be called for One covers');
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      JarBridge.unregister(_oneSpec.siteId);
      JarBridge.clearTestJarPaths();
    });

    test('One cover downloads directly, never calls jarProxy', () async {
      final savedOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        servedBody = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3];
        final drama = Drama(
          id: '1',
          source: 'jar:one:One',
          title: '剧',
          cover: 'http://${server.address.host}:${server.port}/pic.jpg',
        );
        final path = await JarBridge.coverFile(drama);
        expect(
          path.split(Platform.pathSeparator).last.startsWith('px_'),
          isFalse,
        );
        expect(await File(path).readAsBytes(), servedBody);
        expect(hits, 1);
        // 二次命中缓存，不再发请求。
        final second = await JarBridge.coverFile(drama);
        expect(second, path);
        expect(hits, 1);
      } finally {
        HttpOverrides.global = savedOverrides;
      }
    });

    test(
      'oversized direct body fails without leaving a residual file',
      () async {
        final savedOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        try {
          servedBody = List<int>.filled(JarBridge.maxCoverBytes + 1, 7);
          final drama = Drama(
            id: '3',
            source: 'jar:one:One',
            title: '剧',
            cover: 'http://${server.address.host}:${server.port}/big.jpg',
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
        } finally {
          HttpOverrides.global = savedOverrides;
        }
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
