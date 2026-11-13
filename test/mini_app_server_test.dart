import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:moyi/miniapp/mini_app_server.dart';
import 'package:moyi/miniapp/mini_app_sources.dart';

void main() {
  // 不初始化 TestWidgetsFlutterBinding：它会把 HttpClient 换成
  // mock（所有请求回 400），本文件要测真实的回环 HTTP 服务。
  late Directory root;
  late MiniAppServer server;
  late HttpClient client;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mini_app_server_test');
    await File('${root.path}/index.html').writeAsString(
      '<html><head></head><body>hi</body></html>',
    );
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
    await root.delete(recursive: true);
  });

  Future<MiniAppServer> startServer() async {
    server = await MiniAppServer.start(
      root: root,
      entry: 'index.html',
      sdkScript: 'window.__sdk=1;',
      basePort: 0,
      usedPorts: {},
      lanShare: false,
    );
    return server;
  }

  Future<HttpClientResponse> get(String path) async {
    final request = await client.getUrl(
      Uri.parse('${server.baseUrl}$path'),
    );
    return request.close();
  }

  String payloadFor(String source, Object? param) {
    return base64Url.encode(
      utf8.encode(jsonEncode({'source': source, 'param': param})),
    );
  }

  test('serves static files with the sdk injected', () async {
    await startServer();
    final response = await get('/index.html');
    expect(response.statusCode, 200);
    final body = await response.transform(utf8.decoder).join();
    expect(body, contains('window.__sdk=1;'));
    expect(body, contains('hi'));
  });

  test('pyproxy serves proxied image bytes with spider mime', () async {
    await startServer();
    final seen = <Map<String, dynamic>>[];
    server.proxyFetch = (source, param) async {
      seen.add({'source': source, 'param': param});
      return {
        'status': 200,
        'mime': 'image/jpeg',
        'bodyBase64': base64Encode([0xFF, 0xD8, 0xFF, 0xD9]),
        'headers': {'X-Test': 'yes'},
      };
    };
    final url = HostMiniAppSourceProvider.proxyImageUrl(
      server.baseUrl,
      'hghub',
      'proxy://do=py&siteKey=hghub&u=https%3A%2F%2Fcdn.example.com%2Fcover.jpg',
    );
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    expect(response.statusCode, 200);
    expect(response.headers.contentType?.mimeType, 'image/jpeg');
    expect(response.headers.value('X-Test'), 'yes');
    final bytes = await response.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    expect(bytes, [0xFF, 0xD8, 0xFF, 0xD9]);
    expect(seen.length, 1);
    expect(seen[0]['source'], 'hghub');
    expect(seen[0]['param'], {
      'do': 'py',
      'siteKey': 'hghub',
      'u': 'https://cdn.example.com/cover.jpg',
    });
  });

  test('pyproxy forwards spider status codes', () async {
    await startServer();
    server.proxyFetch = (_, _) async => {
      'status': 404,
      'mime': 'text/plain',
      'bodyBase64': '',
      'headers': {},
    };
    final response = await get('/pyproxy?d=${payloadFor('hghub', {'u': ''})}');
    expect(response.statusCode, 404);
  });

  test('pyproxy without a handler is 404', () async {
    await startServer();
    final response = await get('/pyproxy?d=${payloadFor('hghub', {'u': ''})}');
    expect(response.statusCode, 404);
  });

  test('pyproxy rejects missing and malformed payloads', () async {
    await startServer();
    server.proxyFetch = (_, _) async => {
      'status': 200,
      'mime': 'image/jpeg',
      'bodyBase64': '',
      'headers': {},
    };
    expect((await get('/pyproxy')).statusCode, 400);
    expect((await get('/pyproxy?d=!!!not-base64!!!')).statusCode, 400);
    final notJson = base64Url.encode(utf8.encode('plain text'));
    expect((await get('/pyproxy?d=$notJson')).statusCode, 400);
    final noSource = base64Url.encode(utf8.encode(jsonEncode({'param': {}})));
    expect((await get('/pyproxy?d=$noSource')).statusCode, 400);
  });

  test('pyproxy handler failure is 500', () async {
    await startServer();
    server.proxyFetch = (_, _) async => throw StateError('boom');
    final response = await get('/pyproxy?d=${payloadFor('hghub', {'u': ''})}');
    expect(response.statusCode, 500);
  });

  test('non-GET methods stay rejected', () async {
    await startServer();
    final request = await client.postUrl(Uri.parse('${server.baseUrl}/'));
    final response = await request.close();
    expect(response.statusCode, 405);
  });
}
