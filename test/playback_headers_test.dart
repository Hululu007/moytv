import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/playback_headers.dart';

void main() {
  group('mpv 空 UA 翻译', () {
    test('空 UA 翻译成字面量 User-Agent;，其余头照常拼字段', () {
      final fields = mpvHttpHeaderFields({
        'User-Agent': '',
        'Cookie': 'abcdef=0123456789',
        'Referer': 'https://example.com/',
      });
      expect(fields, [
        'User-Agent;',
        'Cookie: abcdef=0123456789',
        'Referer: https://example.com/',
      ]);
    });

    test('UA 键大小写不敏感', () {
      expect(planHasEmptyUserAgent({'user-agent': ''}), isTrue);
      expect(mpvHttpHeaderFields({'user-agent': ''}), ['User-Agent;']);
    });

    test('只有空 UA 时字段表只有一条', () {
      expect(mpvHttpHeaderFields({'User-Agent': ''}), ['User-Agent;']);
    });

    test('非空 UA 不翻译（走 media_kit 原生通道）', () {
      expect(planHasEmptyUserAgent({'User-Agent': 'Mozilla/5.0'}), isFalse);
      expect(mpvHttpHeaderFields({'User-Agent': 'Mozilla/5.0'}), isNull);
    });

    test('没有 UA 时不翻译', () {
      expect(planHasEmptyUserAgent({'Cookie': 'a=b'}), isFalse);
      expect(mpvHttpHeaderFields({'Cookie': 'a=b'}), isNull);
      expect(mpvHttpHeaderFields(const {}), isNull);
    });

    test('属性值拼法：逗号分隔，值里的逗号与反斜杠转义', () {
      expect(
        mpvHeaderFieldsPropertyValue(['User-Agent;', 'Cookie: a=b,c=d']),
        r'User-Agent;,Cookie: a=b\,c=d',
      );
      expect(
        mpvHeaderFieldsPropertyValue([r'X-A: p\q']),
        r'X-A: p\\q',
      );
    });
  });
}
