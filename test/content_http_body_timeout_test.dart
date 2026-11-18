import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/content_http.dart';
import 'package:moyi/core_bridge.dart';

/// 正文读取空闲超时桩验：响应头到了、正文半路停住时，读取循环必须在
/// timeout 内抛超时错，不能永远挂起（女优同步作品阶段曾因此冻结）。

/// 只发一块数据就静默、永不关流的桩。
Future<HttpServer> _stallServer({int statusCode = 200}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    response.bufferOutput = false; // 默认会攒到关流才发，桩必须关缓冲才真“先发后停”。
    response.statusCode = statusCode;
    response.write('x');
    await response.flush();
    // 故意永不 close：模拟正文半路停住。
    await Completer<void>().future;
  });
  return server;
}

/// 每 200ms 发一块、共 5 块后正常关流的细流桩。
Future<HttpServer> _trickleServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    response.bufferOutput = false; // 默认会攒到关流才发，桩必须关缓冲才真“细流”。
    for (var i = 0; i < 5; i++) {
      response.write('a');
      await response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await response.close();
  });
  return server;
}

String _url(HttpServer server) =>
    'http://127.0.0.1:${server.port}/stall';

/// 断言 [run] 在约 1 倍 timeout 后抛“连接超时”的 AppFailure，且不晚于 3 秒。
/// 外层 5 秒总兜底：若修复缺失导致挂起，测试 5 秒即失败而不是等默认超时。
Future<void> _expectBodyTimeout(Future<void> Function() run) async {
  final stopwatch = Stopwatch()..start();
  try {
    await run().timeout(const Duration(seconds: 5));
    fail('应当抛超时错');
  } on AppFailure catch (e) {
    stopwatch.stop();
    expect(e.message, contains('连接超时'));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
  }
}

void main() {
  late ContentHttp client;
  late HttpServer server;

  tearDown(() async {
    client.close();
    await server.close(force: true);
  });

  test('getRaw：正文静默时 1 秒超时抛错，不挂起', () async {
    client = ContentHttp();
    server = await _stallServer();
    await _expectBodyTimeout(
      () async => client.getRaw(_url(server), timeout: const Duration(seconds: 1)),
    );
  });

  test('getRaw：细流（200ms 一块）正常读完，不被超时掐断', () async {
    client = ContentHttp();
    server = await _trickleServer();
    final response = await client
        .getRaw(_url(server), timeout: const Duration(seconds: 1))
        .timeout(const Duration(seconds: 5));
    expect(response.statusCode, 200);
    expect(String.fromCharCodes(response.bodyBytes), 'aaaaa');
  });

  test('fetchDecoded：正文静默时 1 秒超时抛错', () async {
    client = ContentHttp();
    server = await _stallServer();
    await _expectBodyTimeout(
      () async => client.fetchDecoded(
        _url(server),
        timeout: const Duration(seconds: 1),
      ),
    );
  });

  test('get（_send）：正文静默时 1 秒超时抛错', () async {
    client = ContentHttp();
    server = await _stallServer();
    await _expectBodyTimeout(
      () async => client.get(_url(server), timeout: const Duration(seconds: 1)),
    );
  });

  test('postForm（_send POST）：正文静默时 1 秒超时抛错', () async {
    client = ContentHttp();
    server = await _stallServer();
    await _expectBodyTimeout(
      () async => client.postForm(
        _url(server),
        const {'k': 'v'},
        timeout: const Duration(seconds: 1),
      ),
    );
  });

  test('getBytes：正文静默时 1 秒超时抛错', () async {
    client = ContentHttp();
    server = await _stallServer();
    await _expectBodyTimeout(
      () async =>
          client.getBytes(_url(server), timeout: const Duration(seconds: 1)),
    );
  });

  test('postJson：正文静默时 1 秒超时抛错', () async {
    client = ContentHttp();
    server = await _stallServer();
    await _expectBodyTimeout(
      () async => client.postJson(
        _url(server),
        const {'k': 'v'},
        timeout: const Duration(seconds: 1),
      ),
    );
  });

  test('get：非 200 且正文静默时排空同样超时抛错，不挂起', () async {
    client = ContentHttp();
    server = await _stallServer(statusCode: 500);
    await _expectBodyTimeout(
      () async => client.get(_url(server), timeout: const Duration(seconds: 1)),
    );
  });
}
