import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/html_host/html_gateway.dart';

void main() {
  group('gateway payload codec', () {
    test('round-trips through build and decode', () {
      final url = buildHtmlGatewayUrl(
        port: 18099,
        payload: {
          'url': 'https://cdn.example.com/a.m3u8',
          'headers': {'Referer': 'https://site.example.com/'},
          'referer': 'https://site.example.com/',
        },
      );
      final encoded = Uri.parse(url).queryParameters['d']!;
      final decoded = decodeHtmlGatewayPayload(encoded);
      expect(decoded?['url'], 'https://cdn.example.com/a.m3u8');
      expect(decoded?['headers'], {'Referer': 'https://site.example.com/'});
    });

    test('garbage payload decodes to null', () {
      expect(decodeHtmlGatewayPayload('!!!not-base64!!!'), isNull);
      expect(decodeHtmlGatewayPayload(''), isNull);
    });
  });

  group('handleHtmlGatewayRequest', () {
    late HttpServer upstream;
    late HttpServer gateway;
    late HttpClient client;
    var upstreamRange = '';
    var upstreamReferer = '';

    setUp(() async {
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        upstreamRange = request.headers.value('range') ?? '';
        upstreamReferer = request.headers.value('referer') ?? '';
        final body = utf8.encode('0123456789abcdef');
        final range = request.headers.value('range');
        if (range != null && range.startsWith('bytes=2-5')) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set('content-range', 'bytes 2-5/16');
          request.response.headers.set('content-type', 'video/mp2t');
          request.response.add(body.sublist(2, 6));
        } else {
          request.response.headers.set('content-type', 'text/plain');
          request.response.headers.set('x-private', 'must-not-forward');
          request.response.add(body);
        }
        await request.response.close();
      });
      gateway = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      gateway.listen((request) async {
        if (!await handleHtmlGatewayRequest(request)) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      });
      client = HttpClient();
    });

    tearDown(() async {
      client.close();
      await gateway.close(force: true);
      await upstream.close(force: true);
    });

    Future<HttpClientResponse> getGateway(
      String path, {
      Map<String, String> headers = const {},
    }) async {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${gateway.port}$path'),
      );
      headers.forEach(request.headers.set);
      return request.close();
    }

    test('forwards the body, whitelisted headers and CORS', () async {
      final gatewayUrl = buildHtmlGatewayUrl(
        port: gateway.port,
        payload: {'url': 'http://127.0.0.1:${upstream.port}/seg.ts'},
      );
      final response = await getGateway(Uri.parse(gatewayUrl).pathWithQuery());
      expect(response.statusCode, HttpStatus.ok);
      expect(
        response.headers.value('access-control-allow-origin'),
        '*',
      );
      expect(response.headers.value('content-type'), 'text/plain');
      expect(response.headers.value('x-private'), isNull);
      expect(await response.transform(utf8.decoder).join(), '0123456789abcdef');
    });

    test('forwards Range and keeps the 206 status and Content-Range', () async {
      final gatewayUrl = buildHtmlGatewayUrl(
        port: gateway.port,
        payload: {'url': 'http://127.0.0.1:${upstream.port}/seg.ts'},
      );
      final response = await getGateway(
        Uri.parse(gatewayUrl).pathWithQuery(),
        headers: const {'range': 'bytes=2-5'},
      );
      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers.value('content-range'), 'bytes 2-5/16');
      expect(upstreamRange, 'bytes=2-5');
      expect(await response.transform(utf8.decoder).join(), '2345');
    });

    test('forwards the payload referer upstream', () async {
      final gatewayUrl = buildHtmlGatewayUrl(
        port: gateway.port,
        payload: {
          'url': 'http://127.0.0.1:${upstream.port}/seg.ts',
          'referer': 'https://site.example.com/page',
        },
      );
      final response = await getGateway(Uri.parse(gatewayUrl).pathWithQuery());
      await response.drain<void>();
      expect(upstreamReferer, 'https://site.example.com/page');
    });

    test('non-gateway paths return false', () async {
      final response = await getGateway('/other');
      expect(response.statusCode, HttpStatus.notFound);
      await response.drain<void>();
    });

    test('bad payloads and non-http urls fail with 400', () async {
      final badPayload = await getGateway('/__res?d=!!!');
      expect(badPayload.statusCode, HttpStatus.badRequest);
      await badPayload.drain<void>();
      final badUrl = buildHtmlGatewayUrl(
        port: gateway.port,
        payload: {'url': 'ftp://example.com/x'},
      );
      final badResponse = await getGateway(Uri.parse(badUrl).pathWithQuery());
      expect(badResponse.statusCode, HttpStatus.badRequest);
      await badResponse.drain<void>();
    });

    test('OPTIONS preflight answers 204 with CORS', () async {
      final request = await client.openUrl(
        'OPTIONS',
        Uri.parse('http://127.0.0.1:${gateway.port}/__res'),
      );
      final response = await request.close();
      expect(response.statusCode, HttpStatus.noContent);
      expect(response.headers.value('access-control-allow-origin'), '*');
      await response.drain<void>();
    });
  });
}

extension on Uri {
  String pathWithQuery() => '$path${query.isEmpty ? '' : '?$query'}';
}
