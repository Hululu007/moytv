import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/models.dart';
import 'package:moyi/py_lazy_fetch.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _validSpider = '''
class Spider:
    def playerContent(self, flag, id, vipFlags):
        return {}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late HttpServer server;
  late int hits;

  setUpAll(() async {
    // 测试绑定会把 HttpClient 换成一律回 400 的假实现；本文件要跑真
    // 本地服务器，须把全局覆盖清掉才能发出真实请求。
    HttpOverrides.global = null;
    tempDir = await Directory.systemTemp.createTemp('moyi_py_lazy_test');
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
    SharedPreferences.setMockInitialValues({});
    hits = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      hits++;
      if (request.uri.path == '/slow') {
        request.response.write('class Spider:\n');
        await request.response.flush();
        await Future<void>.delayed(const Duration(seconds: 2));
        request.response.write('    def playerContent(self, a, b, c):\n');
        await request.response.close();
      } else if (request.uri.path == '/big') {
        request.response.add(List<int>.filled((8 << 20) + 1, 65));
        await request.response.close();
      } else if (request.uri.path == '/spider.py') {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        request.response.write(_validSpider);
        await request.response.close();
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
    for (final id in ['siteA', 'siteB', 'siteC', 'siteD']) {
      SourceSite.importedPyFiles.remove(id);
    }
  });

  String url(String path) =>
      'http://${server.address.host}:${server.port}$path';

  test('collectCappedBytes：超限抛错，未超限原样返回', () async {
    final ok = await collectCappedBytes(
      Stream<List<int>>.fromIterable([
        [1, 2],
        [3],
      ]),
      10,
    );
    expect(ok, [1, 2, 3]);
    await expectLater(
      collectCappedBytes(
        Stream<List<int>>.fromIterable([
          [1, 2, 3],
          [4],
        ]),
        3,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('同站并发下载只发一次请求，两调用同回一个文件名', () async {
    final names = await Future.wait([
      PyLazyFetch.fetchAndSave('siteA', url('/spider.py')),
      PyLazyFetch.fetchAndSave('siteA', url('/spider.py')),
      PyLazyFetch.fetchAndSave('siteA', url('/spider.py')),
    ]);
    expect(hits, 1);
    expect(names.toSet(), hasLength(1));
    expect(names.first, endsWith('.py'));
    // 落盘文件与 prefs 映射一致。
    final saved = await PyLazyFetch.savedFileName('siteA');
    expect(saved, names.first);
    expect(
      File('${tempDir.path}/imported_spiders/${names.first}').existsSync(),
      isTrue,
    );
  });

  test('不同站各发一次请求', () async {
    await Future.wait([
      PyLazyFetch.fetchAndSave('siteA', url('/spider.py')),
      PyLazyFetch.fetchAndSave('siteB', url('/spider.py')),
    ]);
    expect(hits, 2);
  });

  test('超大文件报格式错，不落盘', () async {
    await expectLater(
      PyLazyFetch.fetchAndSave('siteC', url('/big')),
      throwsA(isA<FormatException>()),
    );
    expect(await PyLazyFetch.savedFileName('siteC'), isNull);
  });

  test('慢速滴漏下载超时报格式错', () async {
    await expectLater(
      PyLazyFetch.fetchAndSave(
        'siteD',
        url('/slow'),
        downloadTimeout: const Duration(milliseconds: 200),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('下载失败后可重试（在途记录不钉死失败）', () async {
    await expectLater(
      PyLazyFetch.fetchAndSave('siteA', url('/missing.py')),
      throwsA(isA<FormatException>()),
    );
    final name = await PyLazyFetch.fetchAndSave('siteA', url('/spider.py'));
    expect(name, endsWith('.py'));
    expect(hits, 2);
  });
}
