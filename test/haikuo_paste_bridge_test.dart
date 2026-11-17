import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moyi/miniapp/haikuo/haikuo_cloud6.dart';
import 'package:moyi/miniapp/haikuo/haikuo_paste_bridge.dart';
import 'package:moyi/miniapp/haikuo/haikuo_program.dart';

/// E109 云剪贴板桥：上传/取数一律假传输，不联网。
void main() {
  group('pasteNameIsCloud6', () {
    test('空/缺省/云6写法都认云 6', () {
      expect(pasteNameIsCloud6(null), isTrue);
      expect(pasteNameIsCloud6(''), isTrue);
      expect(pasteNameIsCloud6('   '), isTrue);
      expect(pasteNameIsCloud6('6'), isTrue);
      expect(pasteNameIsCloud6('云6'), isTrue);
      expect(pasteNameIsCloud6('云剪贴板6'), isTrue);
      expect(pasteNameIsCloud6('云剪贴板 6'), isTrue);
    });

    test('其它号云一律不认', () {
      for (final name in ['云剪贴板1', '云剪贴板2', '云1', '云剪贴板10', 'HIKER']) {
        expect(pasteNameIsCloud6(name), isFalse, reason: name);
      }
    });
  });

  group('pasteFetchUrl', () {
    test('云 6 短码拼 getContent 地址，@密码原样带上', () {
      expect(
        pasteFetchUrl('云6oooole/xxxxxx/ibjcvgj9yq2mjhpp@vqSHNl'),
        'https://pasteme.tyrantg.com/api/getContent/ibjcvgj9yq2mjhpp@vqSHNl',
      );
    });

    test('pasteme 完整链接旧形态取最后一段', () {
      expect(
        pasteFetchUrl('https://pasteme.tyrantg.com/xxxxxx/abc123'),
        'https://pasteme.tyrantg.com/api/getContent/abc123',
      );
      expect(
        pasteFetchUrl('https://pasteme.tyrantg.com/abc123?x=1'),
        'https://pasteme.tyrantg.com/api/getContent/abc123',
      );
    });

    test('非 6 号云抛错、明示地址未公开', () {
      expect(
        () => pasteFetchUrl('云1oooole/xxxxxx/abc123'),
        throwsA(
          isA<HaikuoFormatException>().having(
            (e) => e.message,
            'message',
            contains('云剪贴板1'),
          ),
        ),
      );
    });

    test('无法识别的地址抛错', () {
      expect(
        () => pasteFetchUrl('就是一段普通文本'),
        throwsA(isA<HaikuoFormatException>()),
      );
    });
  });

  group('handlePasteBridgeRequest', () {
    Future<HaikuoCloud6Upload> fakeUpload(String content) async {
      return const HaikuoCloud6Upload(path: 'abc123', password: 'pw9999');
    }

    Future<String> fakeFetch(String url) async {
      return '{"return_code":0,"data":"RESOLVED-PAYLOAD"}';
    }

    test('list 只回云剪贴板6', () async {
      final result = await handlePasteBridgeRequest(
        {'op': 'list'},
        upload: fakeUpload,
        fetchText: fakeFetch,
      );
      expect(result, {
        'ok': true,
        'result': ['云剪贴板6'],
      });
    });

    test('share 成功只回短码第一行', () async {
      var seenContent = '';
      final result = await handlePasteBridgeRequest(
        {'op': 'share', 'content': 'RULE-TEXT', 'paste': '云剪贴板6'},
        upload: (content) async {
          seenContent = content;
          return fakeUpload(content);
        },
        fetchText: fakeFetch,
      );
      expect(seenContent, 'RULE-TEXT');
      expect(result['ok'], isTrue);
      expect(result['result'], '云6oooole/xxxxxx/abc123@pw9999');
      expect('${result['result']}', isNot(contains('\n')));
    });

    test('share 空 paste 默认走云 6', () async {
      final result = await handlePasteBridgeRequest(
        {'op': 'share', 'content': 'RULE-TEXT', 'paste': ''},
        upload: fakeUpload,
        fetchText: fakeFetch,
      );
      expect(result['ok'], isTrue);
    });

    test('share 非 6 号云明示失败，绝不回落', () async {
      var uploadCalls = 0;
      final result = await handlePasteBridgeRequest(
        {'op': 'share', 'content': 'RULE-TEXT', 'paste': '云剪贴板1'},
        upload: (content) async {
          uploadCalls++;
          return fakeUpload(content);
        },
        fetchText: fakeFetch,
      );
      expect(result['ok'], isFalse);
      expect('${result['error']}', contains('云剪贴板1'));
      expect('${result['error']}', contains('仅支持云剪贴板 6'));
      expect(uploadCalls, 0);
    });

    test('share 空内容失败', () async {
      final result = await handlePasteBridgeRequest(
        {'op': 'share', 'content': '  ', 'paste': ''},
        upload: fakeUpload,
        fetchText: fakeFetch,
      );
      expect(result['ok'], isFalse);
    });

    test('parse 取回后回 data 原文', () async {
      var seenUrl = '';
      final result = await handlePasteBridgeRequest(
        {'op': 'parse', 'url': '云6oooole/xxxxxx/abc123@pw9999'},
        upload: fakeUpload,
        fetchText: (url) async {
          seenUrl = url;
          return fakeFetch(url);
        },
      );
      expect(seenUrl, 'https://pasteme.tyrantg.com/api/getContent/abc123@pw9999');
      expect(result, {'ok': true, 'result': 'RESOLVED-PAYLOAD'});
    });

    test('parse 旧形态完整链接也能取', () async {
      var seenUrl = '';
      final result = await handlePasteBridgeRequest(
        {'op': 'parse', 'url': 'https://pasteme.tyrantg.com/xxxxxx/abc123'},
        upload: fakeUpload,
        fetchText: (url) async {
          seenUrl = url;
          return fakeFetch(url);
        },
      );
      expect(seenUrl, 'https://pasteme.tyrantg.com/api/getContent/abc123');
      expect(result['ok'], isTrue);
    });

    test('parse 4001 密码错误原样报明', () async {
      final result = await handlePasteBridgeRequest(
        {'op': 'parse', 'url': '云6oooole/xxxxxx/abc123'},
        upload: fakeUpload,
        fetchText: (_) async => '{"return_code":4001,"message":"bad"}',
      );
      expect(result['ok'], isFalse);
      expect('${result['error']}', contains('密码不对'));
    });

    test('parse 无法识别的地址失败', () async {
      final result = await handlePasteBridgeRequest(
        {'op': 'parse', 'url': '普通文本'},
        upload: fakeUpload,
        fetchText: fakeFetch,
      );
      expect(result['ok'], isFalse);
      expect('${result['error']}', contains('无法识别'));
    });

    test('未知 op 失败', () async {
      final result = await handlePasteBridgeRequest(
        {'op': 'bogus'},
        upload: fakeUpload,
        fetchText: fakeFetch,
      );
      expect(result['ok'], isFalse);
    });
  });

  group('fetchPasteText', () {
    test('200 回正文', () async {
      final client = MockClient((_) async => http.Response('BODY', 200));
      expect(
        await fetchPasteText('https://pasteme.tyrantg.com/api/getContent/x', client: client),
        'BODY',
      );
    });

    test('非 200 抛错', () async {
      final client = MockClient((_) async => http.Response('', 500));
      await expectLater(
        fetchPasteText('https://pasteme.tyrantg.com/api/getContent/x', client: client),
        throwsA(isA<HaikuoFormatException>()),
      );
    });
  });
}
