import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:moyi/models.dart';
import 'package:moyi/playback_redirect.dart';

void main() {
  group('resolvePlaybackRedirects', () {
    late HttpServer server;
    late String base;
    final seenHeaders = <String, Map<String, String>>{};
    var hits = 0;

    setUp(() async {
      seenHeaders.clear();
      hits = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        hits++;
        final path = request.uri.path;
        final captured = <String, String>{};
        request.headers.forEach((name, values) {
          captured[name] = values.join(', ');
        });
        seenHeaders[path] = captured;
        Future<void> redirect(String location, {String? setCookie}) async {
          request.response.statusCode = 302;
          request.response.headers.set('location', location);
          if (setCookie != null) {
            request.response.headers.set('set-cookie', setCookie);
          }
          await request.response.close();
        }

        switch (path) {
          case '/one':
            await redirect('$base/final');
          case '/a':
            await redirect('$base/b');
          case '/b':
            await redirect('$base/a');
          case '/chain0':
          case '/chain1':
          case '/chain2':
          case '/chain3':
          case '/chain4':
          case '/chain5':
          case '/chain6':
          case '/chain7':
            final n = int.parse(path.substring('/chain'.length));
            await redirect('$base/chain${n + 1}');
          case '/chain8':
            request.response.statusCode = 200;
            request.response.write('done');
            await request.response.close();
          case '/cookie1':
            await redirect('$base/cookie2', setCookie: 'session=abc; Path=/');
          case '/cookie2':
            request.response.statusCode = 200;
            request.response.write('ok');
            await request.response.close();
          case '/slow':
            await Future<void>.delayed(const Duration(seconds: 5));
            request.response.statusCode = 200;
            await request.response.close();
          case '/missing':
            request.response.statusCode = 404;
            await request.response.close();
          default:
            request.response.statusCode = 200;
            request.response.write('final');
            await request.response.close();
        }
      });
      addTearDown(() => server.close(force: true));
    });

    test('单跳 302 到最终地址', () async {
      final resolved = await resolvePlaybackRedirects('$base/one', const {
        'Referer': 'https://src.test/',
      }, client: http.Client());
      expect(resolved.url, '$base/final');
      expect(resolved.headers['Referer'], 'https://src.test/');
      expect(
        resolved.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('range')),
      );
    });

    test('多跳 302 跟到最终地址', () async {
      final resolved = await resolvePlaybackRedirects(
        '$base/chain0',
        const {},
        client: http.Client(),
        maxHops: 10,
      );
      expect(resolved.url, '$base/chain8');
      expect(hits, 9);
    });

    test('跳数用尽返回最后一次 Location，不死跟', () async {
      final resolved = await resolvePlaybackRedirects(
        '$base/chain0',
        const {},
        client: http.Client(),
        maxHops: 5,
      );
      expect(resolved.url, '$base/chain6');
      expect(hits, 6);
    });

    test('循环跳转返回原始地址', () async {
      final resolved = await resolvePlaybackRedirects(
        '$base/a',
        const {},
        client: http.Client(),
      );
      expect(resolved.url, '$base/a');
      expect(hits, 2);
    });

    test('每跳都透传原始头', () async {
      await resolvePlaybackRedirects(
        '$base/chain0',
        const {'Referer': 'https://src.test/', 'User-Agent': 'UA-1'},
        client: http.Client(),
        maxHops: 10,
      );
      for (var i = 0; i <= 8; i++) {
        final headers = seenHeaders['/chain$i']!;
        expect(headers['referer'], 'https://src.test/');
        expect(headers['user-agent'], 'UA-1');
        expect(headers['range'], 'bytes=0-0');
      }
    });

    test('沿途 set-cookie 合并进最终头', () async {
      final resolved = await resolvePlaybackRedirects('$base/cookie1', const {
        'Cookie': 'uid=1',
      }, client: http.Client());
      expect(resolved.url, '$base/cookie2');
      expect(resolved.headers['Cookie'], contains('uid=1'));
      expect(resolved.headers['Cookie'], contains('session=abc'));
      // 第二跳的请求已带上合并后的 Cookie。
      expect(seenHeaders['/cookie2']!['cookie'], contains('session=abc'));
    });

    test('200/404 不跳转，返回当前地址', () async {
      final ok = await resolvePlaybackRedirects(
        '$base/final',
        const {},
        client: http.Client(),
      );
      expect(ok.url, '$base/final');
      final missing = await resolvePlaybackRedirects(
        '$base/missing',
        const {},
        client: http.Client(),
      );
      expect(missing.url, '$base/missing');
    });

    test('连接失败返回原始地址', () async {
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadUrl = 'http://127.0.0.1:${dead.port}/x';
      await dead.close(force: true);
      final resolved = await resolvePlaybackRedirects(deadUrl, const {
        'Referer': 'https://src.test/',
      }, client: http.Client());
      expect(resolved.url, deadUrl);
      expect(resolved.headers['Referer'], 'https://src.test/');
    });

    test('超时返回原始地址且不拖过总时限', () async {
      final stopwatch = Stopwatch()..start();
      final resolved = await resolvePlaybackRedirects(
        '$base/slow',
        const {},
        client: http.Client(),
        totalTimeout: const Duration(milliseconds: 300),
      );
      stopwatch.stop();
      expect(resolved.url, '$base/slow');
      expect(stopwatch.elapsedMilliseconds, lessThan(3000));
    });
  });

  group('shouldPreResolveRedirects', () {
    test('只对 http(s) 直链预解析', () {
      expect(
        shouldPreResolveRedirects(
          const PlaybackPlan(url: 'https://cdn.test/a.m3u8'),
        ),
        isTrue,
      );
      expect(
        shouldPreResolveRedirects(
          const PlaybackPlan(url: 'http://cdn.test/a.mp4'),
        ),
        isTrue,
      );
      expect(
        shouldPreResolveRedirects(const PlaybackPlan(url: 'novel://x')),
        isFalse,
      );
      expect(
        shouldPreResolveRedirects(
          const PlaybackPlan(url: 'https://cdn.test/a.m3u8', local: true),
        ),
        isFalse,
      );
      expect(
        shouldPreResolveRedirects(
          const PlaybackPlan(
            url: 'https://cdn.test/a.m3u8',
            decryptionKey: 'k',
          ),
        ),
        isFalse,
      );
      expect(
        shouldPreResolveRedirects(
          const PlaybackPlan(url: 'http://127.0.0.1:8999/stream'),
        ),
        isFalse,
      );
      expect(shouldPreResolveRedirects(const PlaybackPlan(url: '')), isFalse);
    });
  });
}
