// 海阔瓦片真图标：data: 图标解码、favicon 推导、编解码 host 提取。
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_codec.dart';
import 'package:moyi/miniapp/haikuo/haikuo_program.dart';

const _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  group('haikuoDataIconBytes', () {
    test('合法 data: PNG 解出字节', () {
      final bytes = haikuoDataIconBytes(
        'data:image/png;base64,$_tinyPngBase64',
      );
      expect(bytes, isNotNull);
      expect(bytes!.length, greaterThan(0));
      // PNG 魔数。
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('http 图标 / 空串 / 非图片 data: 一律 null', () {
      expect(haikuoDataIconBytes('https://x.test/i.png'), isNull);
      expect(haikuoDataIconBytes(''), isNull);
      expect(haikuoDataIconBytes('data:text/plain;base64,eA=='), isNull);
    });

    test('坏 base64 不抛错、返回 null', () {
      expect(haikuoDataIconBytes('data:image/png;base64,!!!'), isNull);
      expect(haikuoDataIconBytes('data:image/png;base64'), isNull);
    });
  });

  group('haikuoFaviconUrl', () {
    HaikuoProgram program({String host = '', String url = ''}) =>
        HaikuoProgram(id: 't', name: '测试', host: host, url: url);

    test('host 带路径取 origin', () {
      expect(
        haikuoFaviconUrl(program(host: 'https://example.com/x/y')),
        'https://example.com/favicon.ico',
      );
    });

    test('裸域名默认 https', () {
      expect(
        haikuoFaviconUrl(program(host: 'example.com')),
        'https://example.com/favicon.ico',
      );
    });

    test('host 带端口保留端口', () {
      expect(
        haikuoFaviconUrl(program(host: 'http://a.test:8080/p')),
        'http://a.test:8080/favicon.ico',
      );
    });

    test('host 为空时从入口链接里嵌的真实地址取', () {
      expect(
        haikuoFaviconUrl(
          program(url: 'hiker://empty##https://missav.live/dm247/cn'),
        ),
        'https://missav.live/favicon.ico',
      );
    });

    test('host 优先于入口链接', () {
      expect(
        haikuoFaviconUrl(
          program(
            host: 'https://host.test/',
            url: 'hiker://empty##https://other.test/x',
          ),
        ),
        'https://host.test/favicon.ico',
      );
    });

    test('推导不出或非 http(s) 时 null，绝不编地址', () {
      expect(haikuoFaviconUrl(program()), isNull);
      expect(haikuoFaviconUrl(program(host: 'hiker://empty##fypage')), isNull);
      expect(haikuoFaviconUrl(program(host: 'ftp://x.test/')), isNull);
      expect(haikuoFaviconUrl(program(url: 'hiker://empty##fypage')), isNull);
    });
  });

  group('编解码 host 提取', () {
    test('规则 JSON 的 host 字段进 program.host', () {
      final programs = HaikuoCodec.parseJsonText('''
        {
          "title": "测试规则",
          "host": "https://rules.test/",
          "url": "hiker://empty##fypage",
          "find_rule": "body",
          "col_type": "movie_1"
        }
      ''');
      expect(programs, hasLength(1));
      expect(programs.first.host, 'https://rules.test/');
      expect(
        haikuoFaviconUrl(programs.first),
        'https://rules.test/favicon.ico',
      );
    });

    test('无 host 字段时 host 为空、favicon 从 url 推导', () {
      final programs = HaikuoCodec.parseJsonText('''
        {
          "title": "测试规则",
          "url": "hiker://empty##https://site.test/list##fypage",
          "find_rule": "body",
          "col_type": "movie_1"
        }
      ''');
      expect(programs, hasLength(1));
      expect(programs.first.host, '');
      expect(
        haikuoFaviconUrl(programs.first),
        'https://site.test/favicon.ico',
      );
    });

    test('host 字段随 toJson/fromJson 往返', () {
      const program = HaikuoProgram(
        id: 't',
        name: '测试',
        host: 'https://round.test/',
      );
      final restored = HaikuoProgram.fromJson(program.toJson());
      expect(restored.host, 'https://round.test/');
      expect(program.copyWith().host, 'https://round.test/');
    });
  });
}
