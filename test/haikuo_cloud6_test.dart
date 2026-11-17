import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moyi/miniapp/haikuo/haikuo_cloud6.dart';
import 'package:moyi/miniapp/haikuo/haikuo_codec.dart';
import 'package:moyi/miniapp/haikuo/haikuo_program.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';

/// 云剪贴板 6 真上传：协议来源是实测探针
/// （~/workspace/pasteme_probe/FINDINGS.md，11 次真网往返验证）。
/// 本文件全部用假传输，不碰真网。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ruleBody =
      '{"title":"往返测试站","url":"hiker://empty##https://example.com",'
      '"find_rule":"js:\\nsetResult([]);"}';

  HaikuoProgram program() =>
      HaikuoProgram(id: 'roundtrip-test', name: '往返测试站', rawJson: ruleBody);

  /// 假 pasteme 服务：POST /api/create 发短码，GET /api/getContent/<码>
  /// 取回口令文本；密码不对报 4001（与真服务行为一致）。
  MockClient fakePasteme({
    required String path,
    required String password,
    required String storedContent,
    List<http.BaseRequest>? seen,
  }) {
    return MockClient((request) async {
      seen?.add(request);
      final uri = request.url;
      if (request.method == 'POST' && uri.path == '/api/create') {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'return_code': 0,
              'result_code': 'SUCCESS',
              'data': {'password': password, 'path': path},
              'message': '请求成功',
            }),
          ),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (request.method == 'GET' &&
          uri.pathSegments.length == 3 &&
          uri.pathSegments[0] == 'api' &&
          uri.pathSegments[1] == 'getContent') {
        final code = uri.pathSegments[2];
        if (code == '$path@$password') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'return_code': 0, 'data': storedContent})),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode({'return_code': 4001, 'message': '密码错误'})),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('', 500);
    });
  }

  group('分享文本格式', () {
    test('带密码时两行同形于用户示例', () {
      final text = buildCloud6ShareText(
        path: 'ibjcvgj9yq2mjhpp',
        password: 'vqSHNl',
        title: '🔞MissAV1',
      );
      expect(text, '云6oooole/xxxxxx/ibjcvgj9yq2mjhpp@vqSHNl\n小程序：🔞MissAV1');
    });

    test('无密码时不带 @ 后缀', () {
      final text = buildCloud6ShareText(
        path: 'abcdef0123456789',
        password: '',
        title: '某站',
      );
      expect(text, '云6oooole/xxxxxx/abcdef0123456789\n小程序：某站');
    });

    test('上传结果拼出的文本与纯函数一致', () {
      const upload = HaikuoCloud6Upload(path: 'p1', password: 'pw');
      expect(
        upload.shareText('站名'),
        buildCloud6ShareText(path: 'p1', password: 'pw', title: '站名'),
      );
    });
  });

  group('上传请求', () {
    test('POST 到 /api/create，body 带 content 与 auto_password=1', () async {
      final seen = <http.BaseRequest>[];
      final client = fakePasteme(
        path: 'chpehn5hud28bcmf',
        password: 'FygRf2',
        storedContent: 'x',
        seen: seen,
      );
      final code = HaikuoCodec.buildShareCode(program());
      final upload = await uploadCloud6ShareCode(code, client: client);
      expect(upload.path, 'chpehn5hud28bcmf');
      expect(upload.password, 'FygRf2');
      expect(seen, hasLength(1));
      final request = seen.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://pasteme.tyrantg.com/api/create');
      final body = jsonDecode((seen.single as http.Request).body);
      expect(body, {'content': code, 'auto_password': 1});
    });

    test('空内容直接抛错不发请求', () async {
      final seen = <http.BaseRequest>[];
      final client = fakePasteme(
        path: 'p',
        password: 'w',
        storedContent: 'x',
        seen: seen,
      );
      expect(
        () => uploadCloud6ShareCode('  ', client: client),
        throwsA(isA<HaikuoFormatException>()),
      );
      expect(seen, isEmpty);
    });

    test('业务失败（return_code 非 0）带服务端 message', () async {
      final client = MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(jsonEncode({'return_code': 4000, 'message': '参数错误'})),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      expect(
        () => uploadCloud6ShareCode('￥x￥', client: client),
        throwsA(
          isA<HaikuoFormatException>().having(
            (e) => e.message,
            'message',
            contains('参数错误'),
          ),
        ),
      );
    });

    test('HTTP 500 空 body 报传输失败', () async {
      final client = MockClient((_) async => http.Response('', 500));
      expect(
        () => uploadCloud6ShareCode('￥x￥', client: client),
        throwsA(
          isA<HaikuoFormatException>().having(
            (e) => e.message,
            'message',
            contains('HTTP 500'),
          ),
        ),
      );
    });

    test('空 body / 坏 JSON / 缺数据 / 缺短码都明说', () async {
      for (final body in <String>[
        '',
        'not json{',
        '{"return_code":0}',
        '{"return_code":0,"data":{}}',
      ]) {
        final client = MockClient((_) async => http.Response(body, 200));
        await expectLater(
          () => uploadCloud6ShareCode('￥x￥', client: client),
          throwsA(isA<HaikuoFormatException>()),
        );
      }
    });
  });

  group('取回侧 @ 密码', () {
    test('cloudApiUrl 保留 @密码原文，xxxxxx 前缀不进地址', () {
      final url = HaikuoCodec.cloudApiUrl(
        '云6oooole/xxxxxx/ibjcvgj9yq2mjhpp@vqSHNl\n小程序：🔞MissAV1',
      );
      expect(
        url,
        'https://pasteme.tyrantg.com/api/getContent/ibjcvgj9yq2mjhpp@vqSHNl',
      );
    });

    test('无 @ 的旧形态仍能取回', () {
      expect(
        HaikuoCodec.cloudApiUrl('云6oooole/xxxxxx/abcdef0123456789'),
        'https://pasteme.tyrantg.com/api/getContent/abcdef0123456789',
      );
    });

    test('云 5 仍报取回地址未公开', () {
      expect(
        () => HaikuoCodec.cloudApiUrl('云5oooole/xxxxxx/abc'),
        throwsA(
          isA<HaikuoFormatException>().having(
            (e) => e.message,
            'message',
            contains('云剪贴板5'),
          ),
        ),
      );
    });

    test('4001 报密码不对并提示含 @ 段完整复制', () {
      expect(
        () => HaikuoCodec.parseCloudApiResponse(
          '{"return_code":4001,"message":"x"}',
        ),
        throwsA(
          isA<HaikuoFormatException>().having(
            (e) => e.message,
            'message',
            contains('@'),
          ),
        ),
      );
    });

    test('正则扫描在两行文本里命中完整短码', () {
      final matches = HaikuoCodec.cloudCodeMatches(
        '云6oooole/xxxxxx/ibjcvgj9yq2mjhpp@vqSHNl\n小程序：🔞MissAV1',
      ).toList();
      expect(matches, hasLength(1));
      expect(matches.single.group(2), 'xxxxxx/ibjcvgj9yq2mjhpp@vqSHNl');
    });
  });

  group('往返：分享出去的文本能被自家导入链认回', () {
    test('上传 → 两行文本 → importText 落库', () async {
      final code = HaikuoCodec.buildShareCode(program());
      final client = fakePasteme(
        path: 'roundtrip0000001',
        password: 'R7tQ2z',
        storedContent: code,
      );
      final upload = await uploadCloud6ShareCode(code, client: client);
      final shareText = upload.shareText(program().name);
      expect(shareText, '云6oooole/xxxxxx/roundtrip0000001@R7tQ2z\n小程序：往返测试站');

      final dir = await Directory.systemTemp.createTemp('cloud6_roundtrip');
      addTearDown(() => dir.delete(recursive: true));
      final store = HaikuoStore(rootOverride: dir, httpClient: client);
      final result = await store.importText(shareText, origin: '云剪贴板6');
      expect(result.added, hasLength(1));
      final saved = await store.list();
      expect(saved, hasLength(1));
      expect(saved.single.name, '往返测试站');
      expect(saved.single.origin, '云剪贴板6');
    });

    test('密码被改动后取回报 4001，不落库', () async {
      final code = HaikuoCodec.buildShareCode(program());
      final client = fakePasteme(
        path: 'roundtrip0000001',
        password: 'R7tQ2z',
        storedContent: code,
      );
      final dir = await Directory.systemTemp.createTemp('cloud6_badpass');
      addTearDown(() => dir.delete(recursive: true));
      final store = HaikuoStore(rootOverride: dir, httpClient: client);
      await expectLater(
        () => store.importText(
          '云6oooole/xxxxxx/roundtrip0000001@WRONG1\n小程序：往返测试站',
        ),
        throwsA(isA<HaikuoFormatException>()),
      );
      expect(await store.list(), isEmpty);
    });
  });
}
