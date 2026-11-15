import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/tvbox_config.dart';

void main() {
  late HttpServer server;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/config.json') {
        request.response.write('{"sites": []}');
        await request.response.close();
      } else if (request.uri.path == '/slow') {
        request.response.write('{"sites":');
        await request.response.flush();
        await Future<void>.delayed(const Duration(seconds: 2));
        request.response.write(' []}');
        await request.response.close();
      } else if (request.uri.path == '/big') {
        request.response.add(List<int>.filled((16 << 20) + 1, 65));
        await request.response.close();
      } else if (request.uri.path == '/bytes') {
        request.response.add([1, 2, 3]);
        await request.response.close();
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    });
  });

  tearDown(() async => server.close(force: true));

  String url(String path) =>
      'http://${server.address.host}:${server.port}$path';

  test('fetchText 正常拉取并解码', () async {
    final text = await TvBoxImporter.fetchText(url('/config.json'));
    expect(jsonDecode(text), {'sites': []});
  });

  test('fetchText 慢速滴漏读取超时', () async {
    await expectLater(
      TvBoxImporter.fetchText(
        url('/slow'),
        bodyTimeout: const Duration(milliseconds: 200),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('fetchText 超大内容报格式错', () async {
    await expectLater(
      TvBoxImporter.fetchText(url('/big')),
      throwsA(isA<FormatException>()),
    );
  });

  test('fetchText 非 2xx 报格式错', () async {
    await expectLater(
      TvBoxImporter.fetchText(url('/missing')),
      throwsA(isA<FormatException>()),
    );
  });

  test('fetchBytes 正常拉取字节', () async {
    final bytes = await TvBoxImporter.fetchBytes(url('/bytes'));
    expect(bytes, [1, 2, 3]);
  });

  test('fetchBytes 慢速滴漏读取超时', () async {
    await expectLater(
      TvBoxImporter.fetchBytes(
        url('/slow'),
        bodyTimeout: const Duration(milliseconds: 200),
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
