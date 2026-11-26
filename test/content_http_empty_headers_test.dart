import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:moyi/content_http.dart';

/// 空值请求头的线上行为桩验（本机回环服务器抓请求头）：
/// - dart:io 显式把 UA 设成空串时，服务端收到的是空值；完全不设 UA
///   时 dart:io 会自带 `Dart/<版本> (dart:io)` 默认 UA——所以「发空 UA」
///   必须显式设空串，不能靠删头。
/// - ContentHttp 默认跳过空值头（既有行为）；preserveEmptyHeaders
///   打开后空值头照原样发（115 直链这条链专用）。
void main() {
  late HttpServer server;
  late Map<String, String?> seen;
  late ContentHttp client;

  setUp(() async {
    seen = {};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      seen['user-agent'] = request.headers.value('user-agent');
      seen['x-empty'] = request.headers.value('x-empty');
      seen['cookie'] = request.headers.value('cookie');
      request.response.write('ok');
      await request.response.close();
    });
    client = ContentHttp();
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
  });

  String url() => 'http://127.0.0.1:${server.port}/probe';

  test('默认：空值头被跳过，空 UA 显式设空串能发出去', () async {
    await client.getRaw(
      url(),
      headers: {'User-Agent': '', 'X-Empty': '', 'Cookie': 'a=b'},
    );
    expect(seen['user-agent'], '');
    expect(seen['x-empty'], isNull);
    expect(seen['cookie'], 'a=b');
  });

  test('默认：没传 UA 时补内容源默认 UA', () async {
    await client.getRaw(url(), headers: {'Cookie': 'a=b'});
    expect(seen['user-agent'], contentUserAgent);
  });

  test('preserveEmptyHeaders：空值头照原样发', () async {
    await client.getRaw(
      url(),
      headers: {'User-Agent': '', 'X-Empty': '', 'Cookie': 'a=b'},
      preserveEmptyHeaders: true,
    );
    expect(seen['user-agent'], '');
    expect(seen['x-empty'], '');
    expect(seen['cookie'], 'a=b');
  });

  test('preserveEmptyHeaders 对 getBytes 同样生效', () async {
    await client.getBytes(
      url(),
      headers: {'User-Agent': '', 'X-Empty': ''},
      preserveEmptyHeaders: true,
    );
    expect(seen['user-agent'], '');
    expect(seen['x-empty'], '');
  });

  test('getBytes 默认：空 UA 被默认 UA 顶掉（既有行为不变）', () async {
    await client.getBytes(url(), headers: {'User-Agent': '', 'X-Empty': ''});
    expect(seen['user-agent'], contentUserAgent);
    expect(seen['x-empty'], isNull);
  });

  test('package:http 通道（预解析/STRM 在用）不吞空 UA', () async {
    final c = http.Client();
    try {
      await c.get(
        Uri.parse(url()),
        headers: {'User-Agent': '', 'X-Empty': ''},
      );
    } finally {
      c.close();
    }
    expect(seen['user-agent'], '');
    expect(seen['x-empty'], '');
  });
}
