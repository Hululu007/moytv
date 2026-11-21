import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moyi/live_subtitle_translator.dart';

void main() {
  test('LibreTranslate 正常翻译：POST /translate，取 translatedText', () async {
    var sawRequest = false;
    final client = MockClient((request) async {
      sawRequest = true;
      expect(request.url.path, '/translate');
      expect(request.headers['Content-Type'], contains('application/json'));
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['q'], 'こんにちは');
      expect(body['source'], 'ja');
      expect(body['target'], 'zh');
      return http.Response(
        jsonEncode({'translatedText': '你好'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final translator = LibreTranslateTranslator(
      baseUrl: 'http://127.0.0.1:5000/',
      client: client,
    );
    expect(
      await translator.translate('こんにちは', source: 'ja', target: 'zh'),
      '你好',
    );
    expect(sawRequest, isTrue);
  });

  test('服务器 500 抛翻译异常', () async {
    final client = MockClient(
      (_) async => http.Response('error', 500),
    );
    final translator = LibreTranslateTranslator(
      baseUrl: 'http://127.0.0.1:5000',
      client: client,
    );
    await expectLater(
      translator.translate('テスト', source: 'ja', target: 'zh'),
      throwsA(isA<LiveSubtitleTranslationException>()),
    );
  });

  test('返回格式不对抛翻译异常', () async {
    final client = MockClient(
      (_) async => http.Response(jsonEncode({'nope': 1}), 200),
    );
    final translator = LibreTranslateTranslator(
      baseUrl: 'http://127.0.0.1:5000',
      client: client,
    );
    await expectLater(
      translator.translate('テスト', source: 'ja', target: 'zh'),
      throwsA(isA<LiveSubtitleTranslationException>()),
    );
  });

  test('地址为空抛翻译异常（不静默吞掉）', () async {
    final translator = LibreTranslateTranslator(baseUrl: '');
    await expectLater(
      translator.translate('テスト', source: 'ja', target: 'zh'),
      throwsA(isA<LiveSubtitleTranslationException>()),
    );
  });

  test('空文本返回 null（不发请求）', () async {
    var sawRequest = false;
    final client = MockClient((_) async {
      sawRequest = true;
      return http.Response('{}', 200);
    });
    final translator = LibreTranslateTranslator(
      baseUrl: 'http://127.0.0.1:5000',
      client: client,
    );
    expect(await translator.translate('   ', source: 'ja', target: 'zh'), isNull);
    expect(sawRequest, isFalse);
  });

  test('真 HTTP 往返：本地 /translate 服务，请求格式与解析都走实网', () async {
    // 本地起一个只认 /translate 的真 HTTP 服务，翻译器用默认的
    // 真 http.Client 去调它：验证请求体格式与响应解析，不只验 Mock。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      expect(request.uri.path, '/translate');
      expect(body['source'], 'ja');
      expect(body['target'], 'zh');
      expect(body['format'], 'text');
      final reply = jsonEncode({'translatedText': '[ZH]${body['q']}'});
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(reply);
      await request.response.close();
    });
    final translator = LibreTranslateTranslator(
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
    expect(
      await translator.translate('テスト', source: 'ja', target: 'zh'),
      '[ZH]テスト',
    );
  });
}
