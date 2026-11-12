import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moyi/miniapp/mini_app_ad_filter.dart';
import 'package:moyi/miniapp/mini_app_bridge.dart';
import 'package:moyi/miniapp/mini_app_manifest.dart';
import 'package:moyi/miniapp/mini_app_runtime.dart';
import 'package:moyi/miniapp/mini_app_server.dart';
import 'package:moyi/miniapp/mini_app_settings.dart';
import 'package:moyi/miniapp/mini_app_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MiniAppSettings', () {
    test('defaults match the video', () {
      const settings = MiniAppSettings();
      expect(settings.basePort, 7810);
      expect(settings.maxBackground, 3);
      expect(settings.adFilter, isTrue);
      expect(settings.hybridComposition, isTrue);
      expect(settings.lanShare, isFalse);
      expect(
        settings.marketUrl,
        'https://ghfast.top/https://raw.githubusercontent.com/ant-video/ant-video/refs/heads/main/mini-app/market/market.json',
      );
    });

    test('port and background count are clamped', () {
      expect(MiniAppSettings.clampPort(80), 1024);
      expect(MiniAppSettings.clampPort(70000), 65535);
      expect(MiniAppSettings.clampMaxBackground(0), 1);
      expect(MiniAppSettings.clampMaxBackground(99), 10);
    });

    test('save and load round-trip', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      const settings = MiniAppSettings(
        basePort: 7900,
        maxBackground: 2,
        adFilter: false,
        hybridComposition: false,
        lanShare: true,
        marketUrl: 'https://example.com/market.json',
      );
      await settings.save(prefs);
      final loaded = await MiniAppSettings.load(prefs);
      expect(loaded.basePort, 7900);
      expect(loaded.maxBackground, 2);
      expect(loaded.adFilter, isFalse);
      expect(loaded.hybridComposition, isFalse);
      expect(loaded.lanShare, isTrue);
      expect(loaded.marketUrl, 'https://example.com/market.json');
    });
  });

  group('MiniAppAdFilter', () {
    test('blocks known ad hosts, allows normal and local hosts', () {
      expect(
        miniAppShouldBlockUrl('https://pagead2.googlesyndication.com/x.js'),
        isTrue,
      );
      expect(
        miniAppShouldBlockUrl('https://sub.doubleclick.net/ads'),
        isTrue,
      );
      expect(miniAppShouldBlockUrl('https://example.com/page'), isFalse);
      expect(miniAppShouldBlockUrl('http://127.0.0.1:7810/index.html'), isFalse);
      expect(miniAppShouldBlockUrl('miniapp://com.example.app/'), isFalse);
    });
  });

  group('MiniAppManifest and market', () {
    test('parses the demo manifest', () {
      const raw = '''
{
  "appId": "com.ant.demo",
  "name": "示例小程序",
  "version": "1.0.0",
  "versionCode": 2,
  "renderer": "webview",
  "entry": "index.html",
  "description": "演示",
  "permissions": ["network", "storage", "ui", "navigate", "player", "source", "python"],
  "network": {"allowlist": ["*"]},
  "python": {"entry": "app.py"}
}
''';
      final manifest = MiniAppManifest.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      expect(manifest.isValid, isTrue);
      expect(manifest.appId, 'com.ant.demo');
      expect(manifest.pythonEntry, 'app.py');
      expect(manifest.hasPermission('network'), isTrue);
      expect(manifest.hasPermission('node'), isFalse);
    });

    test('rejects invalid app ids', () {
      const manifest = MiniAppManifest(appId: 'Demo', name: 'x');
      expect(manifest.isValid, isFalse);
    });

    test('parses market json and drops invalid entries', () {
      const raw = '''
{"apps": [
  {"appId": "com.example.a", "name": "A", "version": "1.0",
   "url": "https://example.com/a.zip", "md5": "abc", "size": 10,
   "author": "someone", "description": "d"},
  {"appId": "", "name": "bad", "url": "https://example.com/b.zip"},
  {"appId": "com.example.c", "name": "C", "url": ""}
]}
''';
      final items = parseMiniAppMarketJson(raw);
      expect(items.length, 1);
      expect(items.first.appId, 'com.example.a');
      expect(items.first.md5, 'abc');
      expect(items.first.size, 10);
    });

    test('malformed market json yields an empty list', () {
      expect(parseMiniAppMarketJson('not json'), isEmpty);
      expect(parseMiniAppMarketJson('{"apps": "nope"}'), isEmpty);
      expect(parseMiniAppMarketJson('{"other": []}'), isEmpty);
    });
  });

  group('path safety', () {
    test('safeJoinPath blocks escape', () {
      expect(safeJoinPath('/base', 'a/b.html'), '/base/a/b.html');
      expect(safeJoinPath('/base', '../evil.txt'), isNull);
      expect(safeJoinPath('/base', 'a/../../evil.txt'), isNull);
      expect(safeJoinPath('/base', '/etc/passwd'), isNull);
    });

    test('zip entry names are validated', () {
      expect(isSafeZipEntryName('index.html'), isTrue);
      expect(isSafeZipEntryName('sub/page.html'), isTrue);
      expect(isSafeZipEntryName('../evil.txt'), isFalse);
      expect(isSafeZipEntryName('/abs.txt'), isFalse);
      expect(isSafeZipEntryName('C:\\evil.txt'), isFalse);
    });
  });

  group('MiniAppStore', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('miniapp_store_');
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    Archive demoArchive({String prefix = ''}) {
      final manifest = utf8.encode(jsonEncode({
        'appId': 'com.example.demo',
        'name': '演示',
        'version': '1.0.0',
        'versionCode': 1,
        'entry': 'index.html',
        'permissions': ['storage'],
      }));
      final archive = Archive()
        ..addFile(
          ArchiveFile('${prefix}manifest.json', manifest.length, manifest),
        )
        ..addFile(
          ArchiveFile(
            '${prefix}index.html',
            utf8.encode('<h1>hello</h1>').length,
            utf8.encode('<h1>hello</h1>'),
          ),
        );
      return archive;
    }

    test('installs a zip, lists it, deletes it', () async {
      final store = MiniAppStore(rootOverride: temp);
      final bytes = ZipEncoder().encode(demoArchive());
      final manifest = await store.installFromZipBytes(bytes);
      expect(manifest.appId, 'com.example.demo');
      final installed = await store.listInstalled();
      expect(installed.length, 1);
      expect(installed.first.name, '演示');
      final dir = await store.installedDir('com.example.demo');
      expect(dir, isNotNull);
      expect(
        await File('${dir!.path}/index.html').exists(),
        isTrue,
      );
      await store.deleteApp('com.example.demo');
      expect(await store.listInstalled(), isEmpty);
    });

    test('installs a zip with a single top-level folder', () async {
      final store = MiniAppStore(rootOverride: temp);
      final bytes = ZipEncoder().encode(demoArchive(prefix: 'demo/'));
      final manifest = await store.installFromZipBytes(bytes);
      expect(manifest.appId, 'com.example.demo');
      final dir = await store.installedDir('com.example.demo');
      expect(await File('${dir!.path}/index.html').exists(), isTrue);
    });

    test('rejects a zip with a traversal entry', () async {
      final store = MiniAppStore(rootOverride: temp);
      final archive = demoArchive()
        ..addFile(ArchiveFile('../evil.txt', 1, [0]));
      final bytes = ZipEncoder().encode(archive);
      await expectLater(
        store.installFromZipBytes(bytes),
        throwsA(isA<FormatException>()),
      );
      expect(await store.listInstalled(), isEmpty);
    });

    test('rejects a zip without a manifest', () async {
      final store = MiniAppStore(rootOverride: temp);
      final archive = Archive()
        ..addFile(ArchiveFile('index.html', 3, [1, 2, 3]));
      final bytes = ZipEncoder().encode(archive);
      await expectLater(
        store.installFromZipBytes(bytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('md5 mismatch is rejected', () async {
      final store = MiniAppStore(rootOverride: temp);
      final bytes = ZipEncoder().encode(demoArchive());
      await expectLater(
        store.installFromZipBytes(bytes, expectedMd5: '0' * 32),
        throwsA(isA<FormatException>()),
      );
    });

    test('installs from a folder', () async {
      final sourceRoot =
          await Directory.systemTemp.createTemp('miniapp_source_');
      addTearDown(() async {
        if (await sourceRoot.exists()) {
          await sourceRoot.delete(recursive: true);
        }
      });
      final source = Directory('${sourceRoot.path}/source');
      await source.create(recursive: true);
      await File('${source.path}/manifest.json').writeAsString(
        jsonEncode({
          'appId': 'com.example.folder',
          'name': '文件夹版',
          'entry': 'index.html',
        }),
      );
      await File(
        '${source.path}/index.html',
      ).writeAsString('<h1>hi</h1>');
      final store = MiniAppStore(rootOverride: temp);
      final manifest = await store.installFromDirectory(source);
      expect(manifest.appId, 'com.example.folder');
      expect((await store.listInstalled()).length, 1);
    });
  });

  group('MiniAppServer', () {
    late Directory appDir;

    setUp(() async {
      appDir = await Directory.systemTemp.createTemp('miniapp_server_');
      await File(
        '${appDir.path}/index.html',
      ).writeAsString('<html><head></head><body>hi</body></html>');
      await File('${appDir.path}/style.css').writeAsString('body{}');
    });

    tearDown(() async {
      if (await appDir.exists()) await appDir.delete(recursive: true);
    });

    Future<({int status, Map<String, String> headers, String body})>
    getRaw(int port, String path) async {
      final socket = await Socket.connect('127.0.0.1', port);
      socket.write(
        'GET $path HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n',
      );
      final bytes = await socket.fold<List<int>>(
        <int>[],
        (list, chunk) => list..addAll(chunk),
      );
      await socket.close();
      final text = utf8.decode(bytes);
      final headEnd = text.indexOf('\r\n\r\n');
      final head = text.substring(0, headEnd);
      final lines = head.split('\r\n');
      final status = int.parse(lines.first.split(' ')[1]);
      final headers = <String, String>{};
      for (final line in lines.skip(1)) {
        final colon = line.indexOf(':');
        if (colon > 0) {
          headers[line.substring(0, colon).trim().toLowerCase()] =
              line.substring(colon + 1).trim();
        }
      }
      return (
        status: status,
        headers: headers,
        body: text.substring(headEnd + 4),
      );
    }

    test('serves files and injects the sdk into html', () async {
      final server = await MiniAppServer.start(
        root: appDir,
        entry: 'index.html',
        sdkScript: 'window.ant={};',
        basePort: 0,
        usedPorts: {},
        lanShare: false,
      );
      try {
        final index = await getRaw(server.port, '/index.html');
        expect(index.status, 200);
        expect(index.body, contains('window.ant={};'));

        final css = await getRaw(server.port, '/style.css');
        expect(css.status, 200);
        expect(css.headers['content-type'], contains('text/css'));

        final missing = await getRaw(server.port, '/nope.html');
        expect(missing.status, 404);

        final traversal = await getRaw(
          server.port,
          '/..%2F..%2Fsecret.txt',
        );
        expect(traversal.status, 404);
      } finally {
        await server.close();
      }
    });
  });

  group('MiniAppBridge', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    MiniAppBridge makeBridge(MiniAppManifest manifest) {
      return MiniAppBridge(
        manifest: manifest,
        appDir: Directory.systemTemp,
        prefs: prefs,
        callbacks: MiniAppBridgeCallbacks(
          evaluateJavascript: (_) async {},
          showToast: (_) {},
          showLoading: (_) {},
          hideLoading: () {},
          confirm: ({required title, required content}) async => true,
          actionSheet: (_) async => 0,
          navigateTo: (_) async {},
          navigateBack: () async {},
          exit: () {},
          openMiniApp: (_) async {},
          resolveMiniAppUrl: (_) async => null,
          log: (_) {},
        ),
      );
    }

    test('storage round-trip is namespaced per app', () async {
      const manifest = MiniAppManifest(
        appId: 'com.example.a',
        name: 'A',
        permissions: ['storage'],
      );
      final bridge = makeBridge(manifest);
      await bridge.invoke('storage.set', {'key': 'k', 'value': 'v'});
      expect(await bridge.invoke('storage.get', {'key': 'k'}), 'v');
      expect(await bridge.invoke('storage.keys', {}), ['k']);
      await bridge.invoke('storage.remove', {'key': 'k'});
      expect(await bridge.invoke('storage.get', {'key': 'k'}), isNull);
    });

    test('undeclared network permission is denied', () async {
      const manifest = MiniAppManifest(
        appId: 'com.example.a',
        name: 'A',
        permissions: ['storage'],
      );
      final bridge = makeBridge(manifest);
      await expectLater(
        bridge.invoke('request', {'url': 'https://example.com/'}),
        throwsA(
          isA<MiniAppApiException>().having(
            (e) => e.code,
            'code',
            'PERMISSION_DENIED',
          ),
        ),
      );
    });

    test('request to a host outside the allowlist is denied', () async {
      const manifest = MiniAppManifest(
        appId: 'com.example.a',
        name: 'A',
        permissions: ['network'],
        networkAllowlist: ['example.com'],
      );
      final bridge = makeBridge(manifest);
      await expectLater(
        bridge.invoke('request', {'url': 'https://other.com/'}),
        throwsA(
          isA<MiniAppApiException>().having(
            (e) => e.code,
            'code',
            'PERMISSION_DENIED',
          ),
        ),
      );
    });

    test('request to an allowed host works', () async {
      const manifest = MiniAppManifest(
        appId: 'com.example.a',
        name: 'A',
        permissions: ['network'],
        networkAllowlist: ['example.com'],
      );
      final mockClient = MockClient((request) async {
        expect(request.url.host, 'example.com');
        return http.Response('pong', 200);
      });
      final bridge = MiniAppBridge(
        manifest: manifest,
        appDir: Directory.systemTemp,
        prefs: prefs,
        httpClient: mockClient,
        callbacks: MiniAppBridgeCallbacks(
          evaluateJavascript: (_) async {},
          showToast: (_) {},
          showLoading: (_) {},
          hideLoading: () {},
          confirm: ({required title, required content}) async => true,
          actionSheet: (_) async => 0,
          navigateTo: (_) async {},
          navigateBack: () async {},
          exit: () {},
          openMiniApp: (_) async {},
          resolveMiniAppUrl: (_) async => null,
          log: (_) {},
        ),
      );
      final result = await bridge.invoke('request', {
        'url': 'https://example.com/ping',
      });
      expect(result, isA<Map<String, dynamic>>());
      expect(result['statusCode'], 200);
      expect(result['data'], 'pong');
    });

    test('source.list returns builtin sites, player still NOT_IMPLEMENTED',
        () async {
      const manifest = MiniAppManifest(
        appId: 'com.example.a',
        name: 'A',
        permissions: ['source', 'player'],
      );
      final bridge = makeBridge(manifest);
      final result = await bridge.invoke('source.list', {});
      expect(result, isA<List>());
      final sites = result as List;
      expect(sites, isNotEmpty);
      for (final entry in sites) {
        expect(entry, isA<Map<String, dynamic>>());
        final site = entry as Map<String, dynamic>;
        expect(site['key'], isA<String>());
        expect((site['key'] as String), isNotEmpty);
        expect(site['name'], isA<String>());
        expect(site['type'], isA<String>());
        expect(site['searchable'], isA<bool>());
        expect(site['available'], isA<bool>());
      }
      // 本用例的隔离区里没有注册任何站：只有 jar 静态表条目，且都不可用。
      expect(
        sites.every((e) => (e as Map)['type'] == 'jar'),
        isTrue,
      );
      expect(
        sites.every((e) => (e as Map)['available'] == false),
        isTrue,
      );
      await expectLater(
        bridge.invoke('player.open', {'url': 'https://example.com/v.mp4'}),
        throwsA(
          isA<MiniAppApiException>().having(
            (e) => e.code,
            'code',
            'NOT_IMPLEMENTED',
          ),
        ),
      );
    });

    test('env returns sdk version 1', () async {
      const manifest = MiniAppManifest(appId: 'com.example.a', name: 'A');
      final bridge = makeBridge(manifest);
      final info = await bridge.invoke('env.getSystemInfo', {});
      expect(info, isA<Map<String, dynamic>>());
      expect(info['sdkVersion'], 1);
    });
  });

  group('MiniAppRuntime', () {
    test('evicts the least recently active background server', () async {
      final temp = await Directory.systemTemp.createTemp('miniapp_rt_');
      try {
        final store = MiniAppStore(rootOverride: temp);
        Future<MiniAppManifest> install(String appId) async {
          final archive = Archive()
            ..addFile(
              ArchiveFile(
                'manifest.json',
                utf8.encode(
                  jsonEncode({
                    'appId': appId,
                    'name': appId,
                    'entry': 'index.html',
                  }),
                ).length,
                utf8.encode(
                  jsonEncode({
                    'appId': appId,
                    'name': appId,
                    'entry': 'index.html',
                  }),
                ),
              ),
            )
            ..addFile(ArchiveFile('index.html', 2, [60, 62]));
          final bytes = ZipEncoder().encode(archive);
          return store.installFromZipBytes(bytes);
        }

        final first = await install('com.example.one');
        final second = await install('com.example.two');
        final third = await install('com.example.three');
        final runtime = MiniAppRuntime(
          store: store,
          settings: const MiniAppSettings(basePort: 0, maxBackground: 1),
        );
        await runtime.ensureRunning(first);
        await runtime.ensureRunning(second);
        runtime.markBackground('com.example.one');
        runtime.markBackground('com.example.two');
        await runtime.ensureRunning(third);
        runtime.markBackground('com.example.three');
        expect(
          runtime.running.map((e) => e.appId),
          contains('com.example.three'),
        );
        expect(runtime.running.length, lessThanOrEqualTo(2));
        await runtime.stopAll();
      } finally {
        if (await temp.exists()) await temp.delete(recursive: true);
      }
    });
  });
}
