import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/global_search_page.dart';
import 'package:moyi/html_host/html_bridge.dart';
import 'package:moyi/html_host/html_play.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runner_page.dart';
import 'package:moyi/models.dart';
import 'package:moyi/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

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
  var popped = 0;
  var exited = 0;
  var wentBack = 0;
  var reloaded = 0;
  var canGoBackValue = false;
  final precached = <String>[];
  final chromeModes = <String>[];
  var chromeRestored = 0;

  HtmlBridgeHost build({
    Future<bool> Function(Map<String, dynamic>)? onOpenLive,
    Future<bool> Function(Map<String, dynamic>)? onOpenKeep,
    bool wireChrome = false,
    bool wireExit = true,
  }) => HtmlBridgeHost(
    pushPage: pushed.add,
    showToast: toasts.add,
    popPage: () => popped++,
    canGoBack: () async => canGoBackValue,
    goBack: () async => wentBack++,
    reloadPage: () async => reloaded++,
    viewport: () => {
      'width': 390,
      'height': 844,
      'pixelRatio': 3.0,
    },
    precacheArtwork: (urls) async => precached.addAll(urls),
    onOpenLive: onOpenLive,
    onOpenKeep: onOpenKeep,
    setChrome: wireChrome
        ? (mode, _) async {
            chromeModes.add(mode);
            return mode;
          }
        : null,
    restoreChrome: wireChrome
        ? () async {
            chromeRestored++;
            return 'normal';
          }
        : null,
    exitPage: wireExit ? () => exited++ : null,
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

  /// Reassembles chunked responses the way the page shim does.
  Map<String, dynamic>? chunkedEnvelope() {
    final parts = <int, String>{};
    var total = 0;
    for (final script in scripts) {
      final match = RegExp(
        r'__moyiFmChunk\("([^"]+)",(\d+),(\d+),\s*("(?:\\.|[^"\\])*")\)',
      ).firstMatch(script);
      if (match == null) continue;
      total = int.parse(match.group(3)!);
      parts[int.parse(match.group(2)!)] = jsonDecode(match.group(4)!);
    }
    if (parts.isEmpty || parts.length != total) return null;
    final text = [for (var i = 0; i < total; i++) parts[i]!].join();
    return jsonDecode(text) as Map<String, dynamic>;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalStore store;
  late _FakeHost fakeHost;
  late _MemoryCache cache;
  late _PageSink sink;
  late HtmlBridge bridge;
  late List<WebViewCookie> storedCookies;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    store = LocalStore(prefs);
    fakeHost = _FakeHost();
    cache = _MemoryCache();
    sink = _PageSink();
    storedCookies = [];
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
      cookieWriter: (cookie) async => storedCookies.add(cookie),
    );
  });

  Future<Map<String, dynamic>?> send(String method, [dynamic params]) async {
    final id = 'm${sink.scripts.length}';
    await bridge.handleMessage(
      jsonEncode({'id': id, 'method': method, 'params': params ?? {}}),
    );
    return sink.lastEnvelope();
  }

  group('dispatch basics', () {
    test('unknown method rejects with unknown_method', () async {
      final envelope = await send('fm.nope');
      expect(envelope?['ok'], isFalse);
      expect(envelope?['error'], 'unknown_method');
    });

    test('malformed messages get no response', () async {
      await bridge.handleMessage('not json');
      await bridge.handleMessage(jsonEncode({'method': 'fm.site'}));
      await bridge.handleMessage(jsonEncode({'id': 'x'}));
      expect(sink.scripts, isEmpty);
    });

    test('oversized messages reject with message_too_large', () async {
      final big = 'x' * (600 * 1024);
      await bridge.handleMessage(
        jsonEncode({'id': 'big1', 'method': 'fm.site', 'params': {'pad': big}}),
      );
      final envelope = sink.lastEnvelope();
      expect(envelope?['id'], 'big1');
      expect(envelope?['ok'], isFalse);
      expect(envelope?['error'], 'message_too_large');
    });

    test('large responses are chunked and reassemble', () async {
      await cache.write('big', jsonEncode('y' * 200000));
      final envelope = await send('fm.cache', {'op': 'get', 'key': 'big'});
      expect(envelope, isNull, reason: 'chunked responses use no resolve call');
      final reassembled = sink.chunkedEnvelope();
      expect(reassembled?['ok'], isTrue);
      expect((reassembled?['result'] as String).length, 200000);
    });
  });

  group('fm.site / fm.config / fm.device / fm.ext.info', () {
    test('return the site identity and documented config shape', () async {
      expect(
        await bridge.dispatch('fm.site', {}),
        {'siteKey': 'html:demo', 'siteName': '演示站'},
      );
      final config =
          await bridge.dispatch('fm.config', {}) as Map<String, dynamic>;
      expect(config['driveCheck'], isFalse);
      final device =
          await bridge.dispatch('fm.device', {}) as Map<String, dynamic>;
      expect(device['platform'], isNotEmpty);
      final info =
          await bridge.dispatch('fm.ext.info', {}) as Map<String, dynamic>;
      expect(info['route'], 'html');
    });
  });

  group('fm.cache', () {
    test('set/get/remove round-trip with json values', () async {
      await bridge.dispatch('fm.cache', {
        'op': 'set',
        'key': 'k1',
        'value': {'a': 1},
      });
      expect(await bridge.dispatch('fm.cache', {'op': 'get', 'key': 'k1'}), {
        'a': 1,
      });
      await bridge.dispatch('fm.cache', {'op': 'remove', 'key': 'k1'});
      expect(
        await bridge.dispatch('fm.cache', {'op': 'get', 'key': 'k1'}),
        isNull,
      );
    });

    test('empty key rejects', () async {
      expect(
        bridge.dispatch('fm.cache', {'op': 'get', 'key': ''}),
        throwsA(
          isA<HtmlBridgeError>().having((e) => e.code, 'code', 'bad_payload'),
        ),
      );
    });
  });

  group('fm.req', () {
    late HttpServer stub;

    // TestWidgetsFlutterBinding mocks every HttpClient to answer 400.
    // The factory builds a real client inside a null-override zone, so
    // fm.req talks to the loopback stub for real.
    HttpClient realClient() => HttpOverrides.runWithHttpOverrides(
      HttpClient.new,
      _RealHttpOverrides(),
    );

    HtmlBridge reqBridge({
      Future<List<WebViewCookie>> Function(Uri)? cookieReader,
      Future<void> Function(WebViewCookie)? cookieWriter,
      Future<String?> Function()? userAgentReader,
    }) => HtmlBridge(
      siteKey: 'html:demo',
      siteName: '演示站',
      repository: FixtureRepository(),
      store: store,
      host: fakeHost.build(),
      cache: cache,
      sendToPage: sink.call,
      gatewayPort: 18099,
      httpClientFactory: realClient,
      cookieReader: cookieReader ?? (_) async => const [],
      cookieWriter:
          cookieWriter ?? (cookie) async => storedCookies.add(cookie),
      userAgentReader: userAgentReader,
    );

    setUp(() async {
      stub = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      stub.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/json') {
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode({'hello': 'world'}));
        } else if (request.uri.path == '/echo') {
          response.headers.set('set-cookie', 'sid=abc123; Path=/');
          final body = await utf8.decoder.bind(request).join();
          response.write(
            jsonEncode({
              'method': request.method,
              'ua': request.headers.value('user-agent'),
              'cookie': request.headers.value('cookie'),
              'body': body,
            }),
          );
        } else {
          response.statusCode = HttpStatus.notFound;
          response.write('missing');
        }
        await response.close();
      });
    });

    tearDown(() async => stub.close(force: true));

    String stubUrl(String path) => 'http://127.0.0.1:${stub.port}$path';

    test('text and json response types', () async {
      final req = reqBridge();
      final text = await req.dispatch('fm.req', {
        'url': stubUrl('/json'),
      }) as Map<String, dynamic>;
      expect(text['status'], HttpStatus.ok);
      expect(text['body'], contains('hello'));
      final json = await req.dispatch('fm.req', {
        'url': stubUrl('/json'),
        'responseType': 'json',
      }) as Map<String, dynamic>;
      expect(json['body'], {'hello': 'world'});
      final base64 = await req.dispatch('fm.req', {
        'url': stubUrl('/json'),
        'responseType': 'base64',
      }) as Map<String, dynamic>;
      expect(
        utf8.decode(base64Decode(base64['body'] as String)),
        contains('hello'),
      );
    });

    test('headers, body and cookie round-trip', () async {
      final req = reqBridge(
        cookieReader: (uri) async => [
          WebViewCookie(
            name: 'pre',
            value: '1',
            domain: uri.host,
            path: '/',
          ),
        ],
      );
      final result = await req.dispatch('fm.req', {
        'url': stubUrl('/echo'),
        'method': 'POST',
        'headers': {'User-Agent': 'moyi-test'},
        'body': 'payload-body',
      }) as Map<String, dynamic>;
      final echoed = jsonDecode(result['body'] as String) as Map;
      expect(echoed['method'], 'POST');
      expect(echoed['ua'], 'moyi-test');
      expect(echoed['cookie'], 'pre=1');
      expect(echoed['body'], 'payload-body');
      expect(storedCookies, hasLength(1));
      expect(storedCookies.single.name, 'sid');
      expect(storedCookies.single.value, 'abc123');
    });

    test('default UA comes from the host WebView reader', () async {
      // cf_clearance 绑定解题时的 UA：_req 默认必须发宿主 WebView
      // 的 UA，Dart 默认 UA 会让票据作废、复用断掉。
      const webviewUa =
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36';
      final req = reqBridge(userAgentReader: () async => webviewUa);
      final result = await req.dispatch('fm.req', {
        'url': stubUrl('/echo'),
      }) as Map<String, dynamic>;
      final echoed = jsonDecode(result['body'] as String) as Map;
      expect(echoed['ua'], webviewUa);
    });

    test('page-supplied User-Agent wins and the reader is not consulted', () async {
      var readerCalls = 0;
      final req = reqBridge(
        userAgentReader: () async {
          readerCalls++;
          return 'webview-ua';
        },
      );
      final result = await req.dispatch('fm.req', {
        'url': stubUrl('/echo'),
        'headers': {'User-Agent': 'page-ua'},
      }) as Map<String, dynamic>;
      final echoed = jsonDecode(result['body'] as String) as Map;
      expect(echoed['ua'], 'page-ua');
      expect(readerCalls, 0);
    });

    test('reader returning null or throwing keeps the request working', () async {
      for (final reader in <Future<String?> Function()?>[
        () async => null,
        () async => throw StateError('no controller'),
      ]) {
        final req = reqBridge(userAgentReader: reader);
        final result = await req.dispatch('fm.req', {
          'url': stubUrl('/echo'),
        }) as Map<String, dynamic>;
        final echoed = jsonDecode(result['body'] as String) as Map;
        expect((echoed['ua'] as String).startsWith('Dart/'), isTrue);
      }
    });

    test('WebView UA is resolved once and cached', () async {
      var readerCalls = 0;
      final req = reqBridge(
        userAgentReader: () async {
          readerCalls++;
          return 'webview-ua';
        },
      );
      for (var i = 0; i < 2; i++) {
        final result = await req.dispatch('fm.req', {
          'url': stubUrl('/echo'),
        }) as Map<String, dynamic>;
        final echoed = jsonDecode(result['body'] as String) as Map;
        expect(echoed['ua'], 'webview-ua');
      }
      expect(readerCalls, 1);
    });

    test('credentials omit still sends the WebView UA but no cookies', () async {
      final req = reqBridge(
        cookieReader: (uri) async => [
          WebViewCookie(
            name: 'pre',
            value: '1',
            domain: uri.host,
            path: '/',
          ),
        ],
        userAgentReader: () async => 'webview-ua',
      );
      final result = await req.dispatch('fm.req', {
        'url': stubUrl('/echo'),
        'credentials': 'omit',
      }) as Map<String, dynamic>;
      final echoed = jsonDecode(result['body'] as String) as Map;
      expect(echoed['ua'], 'webview-ua');
      expect(echoed['cookie'], isNull);
    });

    test('non-200 status does not throw', () async {
      final result = await reqBridge().dispatch('fm.req', {
        'url': stubUrl('/nope'),
      }) as Map<String, dynamic>;
      expect(result['status'], HttpStatus.notFound);
      expect(result['body'], 'missing');
    });

    test('bad url, method and responseType reject', () async {
      final req = reqBridge();
      for (final params in [
        {'url': 'ftp://example.com/x'},
        {'url': stubUrl('/json'), 'method': 'TRACE'},
        {'url': stubUrl('/json'), 'responseType': 'blob'},
      ]) {
        expect(
          req.dispatch('fm.req', params),
          throwsA(
            isA<HtmlBridgeError>().having((e) => e.code, 'code', 'bad_payload'),
          ),
        );
      }
    });
  });

  group('fm.res', () {
    test('builds a loopback gateway url carrying the payload', () async {
      final url = await bridge.dispatch('fm.res', {
        'url': 'https://cdn.example.com/a.m3u8',
        'referer': 'https://site.example.com/',
      }) as String;
      expect(url, startsWith('http://127.0.0.1:18099/__res?d='));
    });
  });

  group('fm.play / fm.vod / fm.vodInline', () {
    test('fm.play pushes the player page', () async {
      await bridge.dispatch('fm.play', {
        'episodes': [
          {'name': 'E1', 'url': 'https://cdn.example.com/1.mp4'},
        ],
      });
      expect(fakeHost.pushed, hasLength(1));
      expect(fakeHost.pushed.single, isA<HaikuoPlayPage>());
    });

    test('fm.play with a pics url pushes the non-video page', () async {
      await bridge.dispatch('fm.play', {
        'episodes': [
          {
            'name': 'E1',
            'url':
                'pics://https://cdn.example.com/1.jpg&&https://cdn.example.com/2.jpg',
          },
        ],
      });
      expect(fakeHost.pushed.single, isA<HtmlNonVideoPage>());
    });

    test('fm.vod pushes the detail page', () async {
      await bridge.dispatch('fm.vod', {
        'vod_name': '测试剧',
        'episodes': [
          {'name': 'E1', 'url': 'https://cdn.example.com/1.mp4'},
        ],
      });
      expect(fakeHost.pushed.single, isA<HtmlVodDetailPage>());
    });

    test('fm.vod without playable content rejects', () async {
      expect(
        bridge.dispatch('fm.vod', {'vod_id': '123'}),
        throwsA(
          isA<HtmlBridgeError>().having((e) => e.code, 'code', 'bad_payload'),
        ),
      );
      expect(fakeHost.pushed, isEmpty);
    });

    test('fm.vod cross-site opens the native detail page', () async {
      await bridge.dispatch('fm.vod', {
        'siteKey': 'hongguo',
        'vod_id': '456',
        'title': '跨站剧',
        'pic': 'https://cdn.example.com/p.jpg',
      });
      final pushed = fakeHost.pushed.single as DetailScreen;
      expect(pushed.drama.source, 'hongguo');
      expect(pushed.drama.sourceId, '456');
      expect(pushed.drama.id, 'hongguo:456');
      expect(pushed.drama.title, '跨站剧');
      expect(pushed.drama.cover, 'https://cdn.example.com/p.jpg');
    });

    test('fm.vod cross-site strips a site-prefixed vod id', () async {
      await bridge.dispatch('fm.vod', {
        'siteKey': 'hongguo',
        'vodId': 'hongguo:789',
      });
      final pushed = fakeHost.pushed.single as DetailScreen;
      expect(pushed.drama.sourceId, '789');
      expect(pushed.drama.id, 'hongguo:789');
    });

    test('fm.vod with episodes wins over a foreign siteKey', () async {
      await bridge.dispatch('fm.vod', {
        'siteKey': 'hongguo',
        'vod_id': '456',
        'episodes': [
          {'name': 'E1', 'url': 'https://cdn.example.com/1.mp4'},
        ],
      });
      expect(fakeHost.pushed.single, isA<HtmlVodDetailPage>());
    });

    test('fm.vod to an unknown site rejects bad_payload', () async {
      expect(
        bridge.dispatch('fm.vod', {
          'siteKey': 'no-such-site',
          'vod_id': '123',
        }),
        throwsA(
          isA<HtmlBridgeError>().having((e) => e.code, 'code', 'bad_payload'),
        ),
      );
      expect(fakeHost.pushed, isEmpty);
    });

    test('fm.vod to its own html site rejects bad_payload', () async {
      expect(
        bridge.dispatch('fm.vod', {
          'siteKey': 'html:demo',
          'vod_id': '123',
        }),
        throwsA(
          isA<HtmlBridgeError>().having((e) => e.code, 'code', 'bad_payload'),
        ),
      );
      expect(fakeHost.pushed, isEmpty);
    });

    test('fm.vod to another html site reports unsupported', () async {
      SourceSite.importedSites['html:w3fake'] = const SourceSite(
        'html:w3fake',
        '假 HTML 站',
        'test',
        origin: SourceSite.originImport,
        importType: 'html',
      );
      try {
        await expectLater(
          bridge.dispatch('fm.vod', {
            'siteKey': 'html:w3fake',
            'vod_id': '123',
          }),
          throwsA(
            isA<HtmlBridgeError>().having(
              (e) => e.code,
              'code',
              'unsupported',
            ),
          ),
        );
      } finally {
        SourceSite.importedSites.remove('html:w3fake');
      }
      expect(fakeHost.pushed, isEmpty);
    });

    test('resolver episodes reject honestly', () async {
      expect(
        bridge.dispatch('fm.vodInline', {
          'episodes': [
            {'name': 'E1', 'resolver': 'https://site.example.com/r.js'},
          ],
        }),
        throwsA(
          isA<HtmlBridgeError>().having(
            (e) => e.code,
            'code',
            'resolver_not_supported',
          ),
        ),
      );
    });
  });

  group('fm.ctrl / fm.stat', () {
    test('fm.ctrl silently succeeds, fm.stat returns the last snapshot', () async {
      expect(await bridge.dispatch('fm.ctrl', {'op': 'pause'}), {});
      expect(await bridge.dispatch('fm.stat', {}), {});
      bridge.recordPlayState({'playing': true, 'position': 12.5});
      expect(await bridge.dispatch('fm.stat', {}), {
        'playing': true,
        'position': 12.5,
      });
    });
  });

  group('fm.search / fm.history / fm.openSetting', () {
    test('fm.search pushes the global search page', () async {
      await bridge.dispatch('fm.search', {'query': '测试'});
      expect(fakeHost.pushed.single, isA<GlobalSearchPage>());
    });

    test('fm.history returns saved entries newest first', () async {
      await store.saveWatch(
        WatchEntry(
          drama: const Drama(
            id: 'hongguo:1',
            source: 'hongguo',
            title: '剧一',
          ),
          episode: 1,
          position: 10,
          duration: 100,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      );
      await store.saveWatch(
        WatchEntry(
          drama: const Drama(
            id: 'hongguo:2',
            source: 'hongguo',
            title: '剧二',
          ),
          episode: 2,
          position: 20,
          duration: 100,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
        ),
      );
      final history =
          await bridge.dispatch('fm.history', {}) as List<Map<String, dynamic>>;
      expect(history, hasLength(2));
      expect(history.first['finished'], isFalse);
      expect(
        (history.first['drama'] as Map<String, dynamic>)['title'],
        '剧二',
      );
    });

    test('fm.openSetting pushes the settings screen', () async {
      await bridge.dispatch('fm.openSetting', {});
      expect(fakeHost.pushed.single, isA<SettingsScreen>());
    });
  });

  group('fm.openLive / fm.openKeep', () {
    test('unwired entries reject with unsupported', () async {
      expect(
        bridge.dispatch('fm.openLive', {}),
        throwsA(
          isA<HtmlBridgeError>().having((e) => e.code, 'code', 'unsupported'),
        ),
      );
      expect(
        bridge.dispatch('fm.openKeep', {}),
        throwsA(
          isA<HtmlBridgeError>().having((e) => e.code, 'code', 'unsupported'),
        ),
      );
    });

    test('wired callbacks report opened', () async {
      bridge = HtmlBridge(
        siteKey: 'html:demo',
        siteName: '演示站',
        repository: FixtureRepository(),
        store: store,
        host: fakeHost.build(onOpenLive: (_) async => true),
        cache: cache,
        sendToPage: sink.call,
        gatewayPort: 18099,
      );
      expect(await bridge.dispatch('fm.openLive', {}), {'opened': true});
    });

    test('openLive success exits the host page, openKeep does not', () async {
      bridge = HtmlBridge(
        siteKey: 'html:demo',
        siteName: '演示站',
        repository: FixtureRepository(),
        store: store,
        host: fakeHost.build(
          onOpenLive: (_) async => true,
          onOpenKeep: (_) async => true,
        ),
        cache: cache,
        sendToPage: sink.call,
        gatewayPort: 18099,
      );
      await bridge.dispatch('fm.openKeep', {});
      expect(fakeHost.exited, 0);
      await bridge.dispatch('fm.openLive', {});
      expect(fakeHost.exited, 1);
    });

    test('openLive returning false does not exit', () async {
      bridge = HtmlBridge(
        siteKey: 'html:demo',
        siteName: '演示站',
        repository: FixtureRepository(),
        store: store,
        host: fakeHost.build(onOpenLive: (_) async => false),
        cache: cache,
        sendToPage: sink.call,
        gatewayPort: 18099,
      );
      expect(await bridge.dispatch('fm.openLive', {}), {'opened': false});
      expect(fakeHost.exited, 0);
    });
  });

  group('fm.back / fm.reload / fm.preloadArtwork', () {
    test('fm.back goes back when history exists, else pops', () async {
      fakeHost.canGoBackValue = true;
      expect(await bridge.dispatch('fm.back', {}), {'navigated': true});
      expect(fakeHost.wentBack, 1);
      fakeHost.canGoBackValue = false;
      expect(await bridge.dispatch('fm.back', {}), {'navigated': false});
      expect(fakeHost.popped, 1);
    });

    test('fm.reload calls the host reload', () async {
      await bridge.dispatch('fm.reload', {});
      expect(fakeHost.reloaded, 1);
    });

    test('fm.preloadArtwork caps at 20 urls', () async {
      final result = await bridge.dispatch('fm.preloadArtwork', {
        'urls': [for (var i = 0; i < 25; i++) 'https://cdn.example.com/$i.jpg'],
      }) as Map<String, dynamic>;
      expect(result['count'], 20);
      expect(fakeHost.precached, hasLength(20));
    });
  });

  group('fm.pan', () {
    test('magnet links toast and reject, never play', () async {
      expect(
        bridge.dispatch('fm.pan.play', {
          'url': 'magnet:?xt=urn:btih:abcdef',
        }),
        throwsA(
          isA<HtmlBridgeError>().having((e) => e.code, 'code', 'unsupported'),
        ),
      );
      expect(fakeHost.toasts, ['磁力/电驴链接暂不支持播放']);
      expect(fakeHost.pushed, isEmpty);
    });

    test('netdisk share links reject', () async {
      expect(
        bridge.dispatch('fm.pan.play', {
          'url': 'https://pan.baidu.com/s/abc',
        }),
        throwsA(
          isA<HtmlBridgeError>().having((e) => e.code, 'code', 'unsupported'),
        ),
      );
    });

    test('http media plays through the normal path', () async {
      await bridge.dispatch('fm.pan.play', {
        'url': 'https://cdn.example.com/movie.mp4',
      });
      expect(fakeHost.pushed.single, isA<HaikuoPlayPage>());
    });

    test('fm.pan.check is unsupported in v1', () async {
      expect(
        bridge.dispatch('fm.pan.check', {}),
        throwsA(
          isA<HtmlBridgeError>().having((e) => e.code, 'code', 'unsupported'),
        ),
      );
    });
  });

  group('fm.ext / fm.ui / events', () {
    test('fm.ext.log records into the ring buffer', () async {
      await bridge.dispatch('fm.ext.log', {'message': 'hello ext'});
      expect(bridge.extLog, ['hello ext']);
    });

    test('fm.ext.toast shows a toast', () async {
      await bridge.dispatch('fm.ext.toast', {'message': 'hi'});
      expect(fakeHost.toasts, ['hi']);
    });

    test('fm.ui chrome methods are unsupported, viewport is real', () async {
      expect(
        bridge.dispatch('fm.ui.setChrome', {}),
        throwsA(
          isA<HtmlBridgeError>().having((e) => e.code, 'code', 'unsupported'),
        ),
      );
      expect(
        bridge.dispatch('fm.ui.restoreChrome', {}),
        throwsA(
          isA<HtmlBridgeError>().having((e) => e.code, 'code', 'unsupported'),
        ),
      );
      expect(
        await bridge.dispatch('fm.ui.getViewport', {}),
        {'width': 390, 'height': 844, 'pixelRatio': 3.0},
      );
    });

    test('fm.ui.setChrome applies the normalized mode when wired', () async {
      bridge = HtmlBridge(
        siteKey: 'html:demo',
        siteName: '演示站',
        repository: FixtureRepository(),
        store: store,
        host: fakeHost.build(wireChrome: true),
        cache: cache,
        sendToPage: sink.call,
        gatewayPort: 18099,
      );
      expect(
        await bridge.dispatch('fm.ui.setChrome', {'mode': 'immersive'}),
        {'mode': 'immersive', 'chromeMode': 'immersive'},
      );
      expect(
        await bridge.dispatch('fm.ui.setChrome', {'mode': 'tv-full'}),
        {'mode': 'edge', 'chromeMode': 'edge'},
      );
      expect(fakeHost.chromeModes, ['immersive', 'edge']);
      expect(
        await bridge.dispatch('fm.ui.restoreChrome', {}),
        {'mode': 'normal', 'chromeMode': 'normal'},
      );
      expect(fakeHost.chromeRestored, 1);
    });

    test('fm.ui.setChrome with an unknown mode rejects bad_payload', () async {
      bridge = HtmlBridge(
        siteKey: 'html:demo',
        siteName: '演示站',
        repository: FixtureRepository(),
        store: store,
        host: fakeHost.build(wireChrome: true),
        cache: cache,
        sendToPage: sink.call,
        gatewayPort: 18099,
      );
      expect(
        bridge.dispatch('fm.ui.setChrome', {'mode': 'bogus'}),
        throwsA(
          isA<HtmlBridgeError>().having((e) => e.code, 'code', 'bad_payload'),
        ),
      );
      expect(fakeHost.chromeModes, isEmpty);
    });

    test('normalizeHtmlChromeMode maps TV modes to phone modes', () {
      expect(normalizeHtmlChromeMode('normal'), 'normal');
      expect(normalizeHtmlChromeMode('tv-normal'), 'normal');
      expect(normalizeHtmlChromeMode('tv-overlay'), 'normal');
      expect(normalizeHtmlChromeMode('edge'), 'edge');
      expect(normalizeHtmlChromeMode('tv-full'), 'edge');
      expect(normalizeHtmlChromeMode('tv-toolbar-hidden'), 'edge');
      expect(normalizeHtmlChromeMode('immersive'), 'immersive');
      expect(normalizeHtmlChromeMode('bogus'), isNull);
      expect(normalizeHtmlChromeMode(''), isNull);
    });

    test('fm._urlchange tracks the current url', () async {
      await bridge.dispatch('fm._urlchange', {
        'url': 'https://site.example.com/page2',
      });
      expect(bridge.currentUrl, 'https://site.example.com/page2');
    });

    test('fm._exterror dispatches a page event', () async {
      await bridge.dispatch('fm._exterror', {
        'id': 'ext1',
        'message': 'boom',
      });
      expect(
        sink.scripts.any((script) => script.contains('fmexterror')),
        isTrue,
      );
    });
  });
}
