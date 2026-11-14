import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/lan_web/stream_gateway.dart';
import 'package:moyi/models.dart';

void main() {
  group('rewriteM3u8', () {
    String proxy(Uri absolute) =>
        'http://gw/stream?url=${Uri.encodeComponent(absolute.toString())}';

    test('裸分片行解析成绝对地址后包进网关', () {
      const playlist =
          '#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:10.0,\nseg1.ts\n#EXTINF:10.0,\nseg2.ts\n';
      final out = rewriteM3u8(
        playlist,
        Uri.parse('https://cdn.example.com/v/a.m3u8'),
        proxy,
      );
      expect(out, contains('url=https%3A%2F%2Fcdn.example.com%2Fv%2Fseg1.ts'));
      expect(out, contains('url=https%3A%2F%2Fcdn.example.com%2Fv%2Fseg2.ts'));
      expect(out, contains('#EXTM3U'));
    });

    test('URI="..." 属性重写（KEY/MAP/MEDIA）', () {
      const playlist =
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:10.0,\nseg.ts\n';
      final out = rewriteM3u8(
        playlist,
        Uri.parse('https://cdn.example.com/v/a.m3u8'),
        proxy,
      );
      expect(
        out,
        contains(
          'URI="http://gw/stream?url=https%3A%2F%2Fcdn.example.com%2Fv%2Fkey.bin"',
        ),
      );
      expect(
        out,
        contains(
          'URI="http://gw/stream?url=https%3A%2F%2Fcdn.example.com%2Fv%2Finit.mp4"',
        ),
      );
    });

    test('变体列表的码率行也重写', () {
      const playlist =
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=4000000\nhigh.m3u8\n';
      final out = rewriteM3u8(
        playlist,
        Uri.parse('https://cdn.example.com/master.m3u8'),
        proxy,
      );
      expect(out, contains('low.m3u8'));
      expect(out, contains('http://gw/stream?url='));
    });

    test('绝对地址按原样解析', () {
      const playlist =
          '#EXTM3U\n#EXTINF:10.0,\nhttps://other.example.com/seg.ts\n';
      final out = rewriteM3u8(
        playlist,
        Uri.parse('https://cdn.example.com/v/a.m3u8'),
        proxy,
      );
      expect(out, contains('other.example.com%2Fseg.ts'));
    });

    test('CRLF 行尾不污染地址', () {
      const playlist = '#EXTM3U\r\n#EXTINF:10.0,\r\nseg1.ts\r\n';
      final out = rewriteM3u8(
        playlist,
        Uri.parse('https://cdn.example.com/v/a.m3u8'),
        proxy,
      );
      expect(out, isNot(contains('%0D')));
      expect(out, contains('seg1.ts'));
    });

    test('空 URI 属性不动', () {
      const playlist = '#EXTM3U\n#EXT-X-KEY:METHOD=NONE,URI=""\n';
      final out = rewriteM3u8(
        playlist,
        Uri.parse('https://cdn.example.com/a.m3u8'),
        proxy,
      );
      expect(out, contains('URI=""'));
    });
  });

  group('广告分片识别与剔除', () {
    test('广告域名命中', () {
      expect(
        isAdSegmentUri('https://pagead2.googlesyndication.com/seg.ts'),
        isTrue,
      );
      expect(isAdSegmentUri('https://cdn.doubleclick.net/ad.ts'), isTrue);
      expect(isAdSegmentUri('https://a.amazonsystem.com/x.ts'), isFalse);
      expect(isAdSegmentUri('https://amazon-adsystem.com/x.ts'), isTrue);
    });

    test('路径广告段命中', () {
      expect(isAdSegmentUri('seg/preroll_01.ts'), isTrue);
      expect(isAdSegmentUri('https://cdn.example.com/ads/seg.ts'), isTrue);
      expect(isAdSegmentUri('https://cdn.example.com/midroll.ts'), isTrue);
      expect(isAdSegmentUri('https://cdn.example.com/v/seg1.ts'), isFalse);
    });

    test('剔除分片行与前一行 EXTINF，保留 DISCONTINUITY', () {
      const playlist =
          '#EXTM3U\n#EXTINF:10.0,\nseg1.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:10.0,\nhttps://cdn.example.com/ads/ad1.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:10.0,\nseg2.ts\n';
      final result = stripAdSegments(playlist);
      expect(result.dropped, 1);
      expect(result.playlist, isNot(contains('ads/ad1.ts')));
      expect(result.playlist, contains('seg1.ts'));
      expect(result.playlist, contains('seg2.ts'));
      expect('#EXT-X-DISCONTINUITY'.allMatches(result.playlist).length, 2);
      expect('#EXTINF'.allMatches(result.playlist).length, 2);
    });

    test('无广告时原样', () {
      const playlist = '#EXTM3U\n#EXTINF:10.0,\nseg1.ts\n';
      final result = stripAdSegments(playlist);
      expect(result.dropped, 0);
      expect(result.playlist, playlist);
    });
  });

  group('gatewayHeadersFor', () {
    test('缺 Referer 补目标源站，缺 UA 补浏览器 UA', () {
      final headers = gatewayHeadersFor(
        Uri.parse('https://cdn.example.com/v/a.m3u8'),
        {},
      );
      expect(headers['Referer'], 'https://cdn.example.com/');
      expect(headers['User-Agent'], gatewayUserAgent);
    });

    test('已有的头不动', () {
      final headers = gatewayHeadersFor(
        Uri.parse('https://cdn.example.com/v/a.m3u8'),
        {'Referer': 'https://site.example/', 'User-Agent': 'Custom/1.0'},
      );
      expect(headers['Referer'], 'https://site.example/');
      expect(headers['User-Agent'], 'Custom/1.0');
    });

    test('小写键名也认', () {
      final headers = gatewayHeadersFor(
        Uri.parse('https://cdn.example.com/v/a.m3u8'),
        {'referer': 'https://site.example/'},
      );
      expect(headers['referer'], 'https://site.example/');
      expect(headers.containsKey('Referer'), isFalse);
    });
  });

  group('shouldGatewayRewrite', () {
    PlaybackPlan plan({required String url, String decryptionKey = ''}) =>
        PlaybackPlan(url: url, decryptionKey: decryptionKey);

    test('http(s) 直链改写', () {
      expect(
        shouldGatewayRewrite(plan(url: 'https://cdn.example.com/a.mp4')),
        isTrue,
      );
      expect(
        shouldGatewayRewrite(plan(url: 'http://cdn.example.com/a.m3u8')),
        isTrue,
      );
    });

    test('解密计划不改写', () {
      expect(
        shouldGatewayRewrite(
          plan(
            url: 'https://cdn.example.com/a.m3u8',
            decryptionKey: '00112233445566778899aabbccddeeff',
          ),
        ),
        isFalse,
      );
    });

    test('回环地址不改写（避免自己代理自己）', () {
      expect(
        shouldGatewayRewrite(plan(url: 'http://127.0.0.1:8999/stream?url=x')),
        isFalse,
      );
      expect(
        shouldGatewayRewrite(plan(url: 'http://localhost:8080/x.mp4')),
        isFalse,
      );
    });

    test('非视频协议不改写', () {
      expect(shouldGatewayRewrite(plan(url: 'novel://{"title":"x"}')), isFalse);
      expect(
        shouldGatewayRewrite(plan(url: 'pics://https://cdn.example.com/a.jpg')),
        isFalse,
      );
      expect(
        shouldGatewayRewrite(plan(url: 'magnet:?xt=urn:btih:abc')),
        isFalse,
      );
      expect(shouldGatewayRewrite(plan(url: 'file:///sdcard/a.mp4')), isFalse);
    });

    test('内置 m3u 实测地址形状经网关（浏览器侧跨域已覆盖）', () {
      // 地址取自 assets/live/m3u/01_zhubo.m3u 首条：浏览器里播时
      // 经 /stream 代理，网关回 CORS 头（见 stream_gateway.dart），
      // 浏览器不受源站跨域限制；应用内原生播放器本来就不受 CORS 限制。
      const m3uUrl = 'https://thm3u8.vip/20260414/itpvwYPq/index.m3u8';
      expect(shouldGatewayRewrite(plan(url: m3uUrl)), isTrue);
      final gateway = buildGatewayUrl('http://192.168.1.2:8999', m3uUrl, {
        'Referer': 'https://thm3u8.vip/',
        'User-Agent': 'Mozilla/5.0',
      });
      final parsed = Uri.parse(gateway);
      expect(parsed.path, '/stream');
      expect(parsed.queryParameters['url'], m3uUrl);
      final headers =
          jsonDecode(
                utf8.decode(
                  base64Url.decode(parsed.queryParameters['headers']!),
                ),
              )
              as Map<String, dynamic>;
      expect(headers['Referer'], 'https://thm3u8.vip/');
    });
  });

  group('buildGatewayUrl', () {
    test('往返：url 与 headers 参数可解回', () {
      final url = buildGatewayUrl(
        'http://127.0.0.1:8999',
        'https://cdn.example.com/a.mp4?x=1&y=2',
        {'Referer': 'https://site.example/', 'Cookie': 'a=b'},
      );
      final uri = Uri.parse(url);
      expect(uri.path, '/stream');
      expect(
        uri.queryParameters['url'],
        'https://cdn.example.com/a.mp4?x=1&y=2',
      );
      final headersJson = utf8.decode(
        base64Url.decode(uri.queryParameters['headers']!),
      );
      expect(jsonDecode(headersJson), {
        'Referer': 'https://site.example/',
        'Cookie': 'a=b',
      });
    });

    test('空 headers 不带参数', () {
      final url = buildGatewayUrl(
        'http://127.0.0.1:8999',
        'https://cdn.example.com/a.mp4',
        {},
      );
      expect(Uri.parse(url).queryParameters.containsKey('headers'), isFalse);
    });
  });

  group('isLoopbackHost', () {
    test('回环判定', () {
      expect(isLoopbackHost('127.0.0.1'), isTrue);
      expect(isLoopbackHost('127.1.2.3'), isTrue);
      expect(isLoopbackHost('localhost'), isTrue);
      expect(isLoopbackHost('LOCALHOST'), isTrue);
      expect(isLoopbackHost('::1'), isTrue);
      expect(isLoopbackHost('192.168.1.2'), isFalse);
      expect(isLoopbackHost('cdn.example.com'), isFalse);
    });
  });

  group('LanStreamProxy 端到端（本机上游）', () {
    late HttpServer upstream;
    late HttpServer gateway;
    late LanStreamProxy proxy;
    late HttpClient client;
    var lastUpstreamHeaders = <String, String>{};

    setUp(() async {
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        lastUpstreamHeaders = {};
        request.headers.forEach((name, values) {
          lastUpstreamHeaders[name] = values.join(',');
        });
        final path = request.uri.path;
        if (path == '/video.mp4') {
          final bytes = List<int>.generate(100, (i) => i);
          final range = request.headers.value(HttpHeaders.rangeHeader);
          if (range != null && range.startsWith('bytes=')) {
            final start = int.parse(range.substring(6).split('-').first);
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-99/100',
            );
            request.response.headers.set(
              HttpHeaders.acceptRangesHeader,
              'bytes',
            );
            request.response.add(bytes.sublist(start));
          } else {
            request.response.headers.set(
              HttpHeaders.acceptRangesHeader,
              'bytes',
            );
            request.response.add(bytes);
          }
          await request.response.close();
          return;
        }
        if (path == '/list.m3u8') {
          request.response.headers.contentType = ContentType(
            'application',
            'x-mpegURL',
          );
          request.response.write(
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:10.0,\nseg1.ts\n#EXTINF:10.0,\nhttps://cdn.example.com/ads/ad.ts\n#EXTINF:10.0,\nseg2.ts\n',
          );
          await request.response.close();
          return;
        }
        if (path == '/hop1') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/video.mp4',
          );
          await request.response.close();
          return;
        }
        if (path == '/loop') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader, '/loop');
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
      proxy = LanStreamProxy();
      gateway = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      gateway.listen((request) async {
        // /proxy 路由直通 proxyTarget（回环上游，handle() 的 SSRF 拦截
        // 会挡住本机测试地址，所以端到端走 proxyTarget；handle() 的
        // 拦截行为在下面单独测）。
        if (request.uri.path == '/proxy') {
          final target = Uri.parse(
            'http://127.0.0.1:${upstream.port}${request.uri.queryParameters['p']}',
          );
          await proxy.proxyTarget(request, target, const {});
          return;
        }
        await proxy.handle(request);
      });
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      proxy.close();
      await gateway.close(force: true);
      await upstream.close(force: true);
    });

    Future<HttpClientResponse> get(
      String path, {
      Map<String, String>? headers,
      bool followRedirects = true,
    }) async {
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${gateway.port}$path'),
      );
      req.followRedirects = followRedirects;
      headers?.forEach(req.headers.set);
      return req.close();
    }

    test('Range 透传：206 与 Content-Range', () async {
      final response = await get(
        '/proxy?p=/video.mp4',
        headers: {'Range': 'bytes=10-'},
      );
      expect(response.statusCode, HttpStatus.partialContent);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 10-99/100',
      );
      final body = await response.fold<List<int>>(
        <int>[],
        (a, b) => a..addAll(b),
      );
      expect(body.length, 90);
      expect(body.first, 10);
    });

    test('CORS 头全量补齐', () async {
      final response = await get('/proxy?p=/video.mp4');
      expect(response.headers.value('access-control-allow-origin'), '*');
      expect(response.headers.value('access-control-allow-headers'), isNotNull);
      expect(
        response.headers.value('access-control-expose-headers'),
        isNotNull,
      );
      await response.drain<void>();
    });

    test('补头：上游收到 Referer 与 UA', () async {
      final response = await get('/proxy?p=/video.mp4');
      await response.drain<void>();
      expect(lastUpstreamHeaders['referer'], 'http://127.0.0.1/');
      expect(lastUpstreamHeaders['user-agent'], gatewayUserAgent);
    });

    test('m3u8 重写 + 广告分片剔除 + 剔除数响应头', () async {
      final response = await get('/proxy?p=/list.m3u8');
      final body = await response.transform(utf8.decoder).join();
      expect(response.headers.value('x-moyi-adsegments-dropped'), '1');
      expect(body, isNot(contains('ads/ad.ts')));
      expect(body, contains('/stream?url='));
      expect(body, contains('seg1.ts'));
      expect(body, contains('key.bin'));
    });

    test('302 跳转到回环地址时原样返回不跟随（防 SSRF）', () async {
      final response = await get('/proxy?p=/hop1', followRedirects: false);
      expect(response.statusCode, HttpStatus.found);
      expect(response.headers.value(HttpHeaders.locationHeader), '/video.mp4');
      await response.drain<void>();
    });

    test('302 自循环有上限、请求能结束', () async {
      final response = await get(
        '/proxy?p=/loop',
        followRedirects: false,
      ).timeout(const Duration(seconds: 10));
      expect(response.statusCode, HttpStatus.found);
      await response.drain<void>();
    });

    test('handle() 拦截回环目标（SSRF）', () async {
      final response = await get(
        '/stream?url=${Uri.encodeComponent('http://127.0.0.1:${upstream.port}/video.mp4')}',
      );
      expect(response.statusCode, HttpStatus.badRequest);
      await response.drain<void>();
    });

    test('handle() OPTIONS 返回 204 + CORS', () async {
      final req = await client.openUrl(
        'OPTIONS',
        Uri.parse(
          'http://127.0.0.1:${gateway.port}/stream?url=https://cdn.example.com/a.mp4',
        ),
      );
      final response = await req.close();
      expect(response.statusCode, HttpStatus.noContent);
      expect(response.headers.value('access-control-allow-origin'), '*');
      await response.drain<void>();
    });
  });
}
