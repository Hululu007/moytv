import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/global_search_page.dart';
import 'package:moyi/html_host/html_bridge.dart';
import 'package:moyi/html_host/html_play.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runner_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// Default-behavior overrides: instantiating this lifts the test
/// binding's mock-400 client for code built inside its zone.
class _RealHttpOverrides extends HttpOverrides {}

class _MemoryCache implements HtmlCacheStore {
  final map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async {
    map[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    map.remove(key);
  }
}

class _FakeHost {
  final pushed = <Widget>[];
  final toasts = <String>[];

  HtmlBridgeHost build() => HtmlBridgeHost(
    pushPage: pushed.add,
    showToast: toasts.add,
    popPage: () {},
    canGoBack: () async => false,
    goBack: () async {},
    reloadPage: () async {},
    viewport: () => {'width': 390, 'height': 844, 'pixelRatio': 3.0},
    precacheArtwork: (_) async {},
  );
}

/// Captures sendToPage scripts and decodes the fm response envelopes.
class _PageSink {
  final scripts = <String>[];

  void call(String javaScript) => scripts.add(javaScript);

  Map<String, dynamic>? lastEnvelope() {
    for (var i = scripts.length - 1; i >= 0; i--) {
      final script = scripts[i];
      if (script.contains('__moyiFmResolve')) {
        final match = RegExp(
          r'__moyiFmResolve\("([^"]+)",\s*("(?:\\.|[^"\\])*")\)',
        ).firstMatch(script);
        if (match == null) return null;
        return jsonDecode(jsonDecode(match.group(2)!)) as Map<String, dynamic>;
      }
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalStore store;
  late _FakeHost fakeHost;
  late _MemoryCache cache;
  late _PageSink sink;
  late HtmlBridge bridge;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    store = LocalStore(prefs);
    fakeHost = _FakeHost();
    cache = _MemoryCache();
    sink = _PageSink();
    bridge = HtmlBridge(
      siteKey: 'html:demo',
      siteName: '演示站',
      repository: FixtureRepository(),
      store: store,
      host: fakeHost.build(),
      cache: cache,
      sendToPage: sink.call,
      gatewayPort: 18099,
      cookieReader: (uri) async => const [],
      cookieWriter: (cookie) async {},
    );
  });

  Future<Map<String, dynamic>?> send(String method, [dynamic params]) async {
    final id = 'm${sink.scripts.length}';
    await bridge.handleMessage(
      jsonEncode({'id': id, 'method': method, 'params': params}),
    );
    return sink.lastEnvelope();
  }

  group('string params tolerance (shim normalization safety net)', () {
    test('fm.res with a bare string url builds a gateway url', () async {
      final envelope = await send(
        'fm.res',
        'https://cdn.example.com/a.m3u8',
      );
      expect(envelope?['ok'], isTrue);
      expect(
        envelope?['result'],
        startsWith('http://127.0.0.1:18099/__res?d='),
      );
    });

    test('fm.play with a bare string url pushes the player', () async {
      final envelope = await send(
        'fm.play',
        'https://cdn.example.com/1.mp4',
      );
      expect(envelope?['ok'], isTrue);
      expect(fakeHost.pushed.single, isA<HaikuoPlayPage>());
      expect(
        (fakeHost.pushed.single as HaikuoPlayPage).url,
        'https://cdn.example.com/1.mp4',
      );
    });

    test('fm.vodInline with a bare string url pushes the player', () async {
      final envelope = await send(
        'fm.vodInline',
        'https://cdn.example.com/1.mp4',
      );
      expect(envelope?['ok'], isTrue);
      expect(fakeHost.pushed.single, isA<HaikuoPlayPage>());
    });

    test('fm.search with a bare string keyword opens search', () async {
      final envelope = await send('fm.search', 'JUR-914');
      expect(envelope?['ok'], isTrue);
      expect(fakeHost.pushed.single, isA<GlobalSearchPage>());
    });

    test('fm.search accepts the keyword key', () async {
      await bridge.dispatch('fm.search', {'keyword': 'JUR-914'});
      expect(fakeHost.pushed.single, isA<GlobalSearchPage>());
    });

    test('fm.pan.check with an array does not crash the bridge', () async {
      final envelope = await send('fm.pan.check', [
        {'type': 'quark', 'url': 'https://pan.quark.cn/s/x'},
      ]);
      expect(envelope?['ok'], isFalse);
      expect(envelope?['error'], 'unsupported');
    });

    test('fm.req with a non-url string still rejects bad_payload', () async {
      final envelope = await send('fm.req', 'not a url');
      expect(envelope?['ok'], isFalse);
      expect(envelope?['error'], 'bad_payload');
    });

    test('fm.vod with only an id honestly reports no playable content', () async {
      final envelope = await send('fm.vod', {
        'siteKey': 'sitekey1',
        'vod_id': 'vod-1',
        'title': 'Title',
        'pic': 'https://cdn.example.com/p.jpg',
      });
      expect(envelope?['ok'], isFalse);
      expect(envelope?['error'], 'bad_payload');
      expect(fakeHost.pushed, isEmpty);
    });
  });

  group('fm.cache del op', () {
    test('del removes like remove', () async {
      await bridge.dispatch('fm.cache', {
        'op': 'set',
        'key': 'k1',
        'value': 'v1',
      });
      await bridge.dispatch('fm.cache', {'op': 'del', 'key': 'k1'});
      expect(
        await bridge.dispatch('fm.cache', {'op': 'get', 'key': 'k1'}),
        isNull,
      );
    });
  });

  group('fm.req shape and timeout units (live loopback stub)', () {
    late HttpServer stub;

    HttpClient realClient() => HttpOverrides.runWithHttpOverrides(
      HttpClient.new,
      _RealHttpOverrides(),
    );

    HtmlBridge reqBridge() => HtmlBridge(
      siteKey: 'html:demo',
      siteName: '演示站',
      repository: FixtureRepository(),
      store: store,
      host: fakeHost.build(),
      cache: cache,
      sendToPage: sink.call,
      gatewayPort: 18099,
      httpClientFactory: realClient,
      cookieReader: (_) async => const [],
      cookieWriter: (_) async {},
    );

    setUp(() async {
      stub = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      stub.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/echo') {
          response.headers.set('set-cookie', 'sid=abc123; Path=/');
          response.write('echo-body');
        } else if (request.uri.path == '/slow') {
          await Future.delayed(const Duration(seconds: 2));
          response.write('slow-ok');
        } else {
          response.statusCode = HttpStatus.notFound;
          response.write('missing');
        }
        await response.close();
      });
    });

    tearDown(() async => stub.close(force: true));

    String stubUrl(String path) => 'http://127.0.0.1:${stub.port}$path';

    test('string params reach the network instead of bad_payload', () async {
      final req = reqBridge();
      final envelopeId = 'reqstr1';
      await req.handleMessage(
        jsonEncode({
          'id': envelopeId,
          'method': 'fm.req',
          'params': stubUrl('/echo'),
        }),
      );
      final envelope = sink.lastEnvelope();
      expect(envelope?['id'], envelopeId);
      expect(envelope?['ok'], isTrue);
      final result = envelope?['result'] as Map<String, dynamic>;
      expect(result['status'], HttpStatus.ok);
      expect(result['body'], 'echo-body');
    });

    test('result carries ok, cookies and the data alias', () async {
      final result = await reqBridge().dispatch('fm.req', {
        'url': stubUrl('/echo'),
      }) as Map<String, dynamic>;
      expect(result['ok'], isTrue);
      expect(result['status'], HttpStatus.ok);
      expect(result['body'], 'echo-body');
      expect(result['data'], 'echo-body');
      expect(result['cookies'], contains('sid=abc123; Path=/'));
      expect(result['url'], stubUrl('/echo'));
    });

    test('timeout in seconds survives a slow response', () async {
      final result = await reqBridge().dispatch('fm.req', {
        'url': stubUrl('/slow'),
        'timeout': 30,
      }) as Map<String, dynamic>;
      expect(result['status'], HttpStatus.ok);
      expect(result['body'], 'slow-ok');
    });

    test('timeout in milliseconds survives a slow response', () async {
      final result = await reqBridge().dispatch('fm.req', {
        'url': stubUrl('/slow'),
        'timeout': 20000,
      }) as Map<String, dynamic>;
      expect(result['body'], 'slow-ok');
    });

    test('timeout as a string is parsed', () async {
      final result = await reqBridge().dispatch('fm.req', {
        'url': stubUrl('/slow'),
        'timeout': '30',
      }) as Map<String, dynamic>;
      expect(result['body'], 'slow-ok');
    });

    test('a one second budget times out on the slow endpoint', () async {
      expect(
        reqBridge().dispatch('fm.req', {
          'url': stubUrl('/slow'),
          'timeout': 1,
        }),
        throwsA(
          isA<HtmlBridgeError>().having((e) => e.code, 'code', 'timeout'),
        ),
      );
    });
  });

  group('parseHtmlPlayPayload alignment', () {
    test('whos vodInline payload: vod_name title, resolve:false episode', () {
      final request = parseHtmlPlayPayload({
        'vod_id': 'whos_jur-914',
        'vod_name': 'JUR-914 title',
        'vod_pic': 'https://cdn.example.com/p.jpg',
        'vod_play_from': 'whos.tv',
        'vod_play_url': '正片\$https://cdn.example.com/1.m3u8',
        'mark': '正片',
        'episodes': [
          {
            'name': '正片',
            'url': 'https://cdn.example.com/1.m3u8',
            'resolve': false,
          },
        ],
      });
      expect(request.episodes, hasLength(1));
      expect(request.episodes.single.name, '正片');
      expect(request.episodes.single.url, 'https://cdn.example.com/1.m3u8');
      expect(request.title, 'JUR-914 title');
      expect(request.initialIndex, 0);
    });

    test('vodInline pushes the player with the vod_name series title', () async {
      await bridge.dispatch('fm.vodInline', {
        'vod_id': 'whos_jur-914',
        'vod_name': 'JUR-914 title',
        'vod_play_url': '正片\$https://cdn.example.com/1.m3u8',
        'episodes': [
          {
            'name': '正片',
            'url': 'https://cdn.example.com/1.m3u8',
            'resolve': false,
          },
        ],
      });
      final page = fakeHost.pushed.single as HaikuoPlayPage;
      expect(page.seriesTitle, 'JUR-914 title');
      expect(page.title, '正片');
    });

    test('vod_play_url alone expands into episodes', () {
      final request = parseHtmlPlayPayload({
        'vod_name': '剧名',
        'vod_play_url':
            '第1集\$https://cdn.example.com/1.mp4#第2集\$https://cdn.example.com/2.mp4'
            '\$\$\$第1集\$https://cdn.example.com/b1.mp4',
      });
      expect(request.episodes, hasLength(3));
      expect(request.episodes[0].name, '第1集');
      expect(request.episodes[1].name, '第2集');
      expect(request.episodes[2].url, 'https://cdn.example.com/b1.mp4');
    });

    test('mark selects the starting episode by name', () {
      final request = parseHtmlPlayPayload({
        'mark': '02',
        'episodes': [
          {'name': '01', 'url': 'https://cdn.example.com/1.mp4'},
          {'name': '02', 'url': 'https://cdn.example.com/2.mp4'},
          {'name': '03', 'url': 'https://cdn.example.com/3.mp4'},
        ],
      });
      expect(request.initialIndex, 1);
    });

    test('active beats mark', () {
      final request = parseHtmlPlayPayload({
        'mark': '01',
        'episodes': [
          {'name': '01', 'url': 'https://cdn.example.com/1.mp4'},
          {
            'name': '02',
            'url': 'https://cdn.example.com/2.mp4',
            'active': true,
          },
        ],
      });
      expect(request.initialIndex, 1);
    });

    test('an explicit index beats mark', () {
      final request = parseHtmlPlayPayload({
        'mark': '02',
        'index': 0,
        'episodes': [
          {'name': '01', 'url': 'https://cdn.example.com/1.mp4'},
          {'name': '02', 'url': 'https://cdn.example.com/2.mp4'},
        ],
      });
      expect(request.initialIndex, 0);
    });

    test('an unmatched mark keeps the first episode', () {
      final request = parseHtmlPlayPayload({
        'mark': '99',
        'episodes': [
          {'name': '01', 'url': 'https://cdn.example.com/1.mp4'},
        ],
      });
      expect(request.initialIndex, 0);
    });

    test('resolver episodes still reject honestly', () {
      expect(
        () => parseHtmlPlayPayload({
          'episodes': [
            {'name': '01', 'pageUrl': 'https://site.example.com/e1', 'resolve': true},
          ],
        }),
        throwsA(isA<HtmlResolverUnsupported>()),
      );
      expect(
        () => parseHtmlPlayPayload({
          'episodes': [
            {'name': '01', 'resolver': 'https://site.example.com/r.js'},
          ],
        }),
        throwsA(isA<HtmlResolverUnsupported>()),
      );
    });

    test('mediaUrl plays without a resolver callback', () {
      final request = parseHtmlPlayPayload({
        'episodes': [
          {
            'name': '01',
            'pageUrl': 'https://site.example.com/e1',
            'mediaUrl': 'https://cdn.example.com/1.m3u8',
            'resolve': true,
          },
        ],
      });
      expect(request.episodes.single.url, 'https://cdn.example.com/1.m3u8');
    });

    test('mediaUrl wins over the raw url', () {
      final request = parseHtmlPlayPayload({
        'mediaUrl': 'https://cdn.example.com/resolved.m3u8',
        'url': 'https://site.example.com/page',
      });
      expect(
        request.episodes.single.url,
        'https://cdn.example.com/resolved.m3u8',
      );
    });
  });
}
