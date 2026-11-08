import 'package:flutter_test/flutter_test.dart';

import 'package:moyi/content_legado.dart';
import 'package:moyi/core_bridge.dart';

const _valid = '''
{"bookSourceName":"T","bookSourceUrl":"https://x.example","searchUrl":"https://x.example/s?k={{key}}","ruleSearch":{"bookList":"div.item"},"ruleBookInfo":{"tocUrl":""},"ruleToc":{"tocList":"dd a"},"ruleContent":{"content":"div#content@text"}}
''';

void main() {
  test('valid json passes', () {
    final info = validateLegadoJson(_valid);
    expect(info.name, 'T');
    expect(info.url, 'https://x.example');
    expect(info.type, 0);
  });

  test('bad json fails', () {
    expect(() => validateLegadoJson('{bad'), throwsFormatException);
    expect(() => validateLegadoJson(''), throwsFormatException);
    expect(() => validateLegadoJson('[]'), throwsFormatException);
  });

  test('missing fields fail', () {
    expect(
      () => validateLegadoJson('{"bookSourceName":"T"}'),
      throwsFormatException,
    );
    expect(
      () => validateLegadoJson(
        '{"bookSourceName":"T","bookSourceUrl":"https://x.example"}',
      ),
      throwsFormatException,
    );
    expect(
      () => validateLegadoJson(
        '{"bookSourceName":"T","bookSourceUrl":"https://x.example","searchUrl":"https://x.example/s","ruleSearch":{},"ruleBookInfo":{},"ruleToc":{},"ruleContent":{}}',
      ),
      throwsFormatException,
    );
  });

  test('login source fails', () {
    expect(
      () => validateLegadoJson(
        '{"bookSourceName":"T","bookSourceUrl":"https://x.example","searchUrl":"https://x.example/s","loginUrl":"https://x.example/login","ruleSearch":{"bookList":"x"},"ruleBookInfo":{"tocUrl":""},"ruleToc":{"tocList":"x"},"ruleContent":{"content":"x"}}',
      ),
      throwsFormatException,
    );
  });

  test('non novel type fails', () {
    expect(
      () => validateLegadoJson(
        '{"bookSourceName":"T","bookSourceUrl":"https://x.example","searchUrl":"https://x.example/s","bookSourceType":1,"ruleSearch":{"bookList":"x"},"ruleBookInfo":{"tocUrl":""},"ruleToc":{"tocList":"x"},"ruleContent":{"content":"x"}}',
      ),
      throwsFormatException,
    );
  });

  test('books mapping skips empty rows', () {
    final books = legadoBooks([
      {'title': 'A', 'author': 'Au', 'url': '/a', 'intro': 'I'},
      {'title': '', 'url': ''},
      {'title': '', 'url': '/b'},
    ]);
    expect(books.length, 2);
    expect(books.first.title, 'A');
    expect(books.first.author, 'Au');
    expect(books[1].title, '/b');
  });

  test('chapters and categories mapping', () {
    final chapters = legadoChapters([
      {'title': 'C1', 'url': '/c1'},
      {'title': '', 'url': ''},
    ]);
    expect(chapters.length, 1);
    expect(chapters.first.id, '/c1');
    final categories = legadoCategories([
      {'title': '玄幻', 'url': '/c/1-{{page}}.html'},
    ]);
    expect(categories.length, 1);
    expect(categories.first.id, '/c/1-{{page}}.html');
    expect(legadoCategories(null), isEmpty);
  });

  test('content text and novel url', () {
    expect(legadoContentText({'content': '正文'}), '正文');
    expect(
      () => legadoContentText({'content': ''}),
      throwsA(isA<AppFailure>()),
    );
    expect(
      () => legadoContentText({'content': '', 'images': [{'url': 'x'}]}),
      throwsA(isA<AppFailure>()),
    );
    final url = legadoNovelUrl('T', '正文');
    expect(url.startsWith('novel://'), isTrue);
    expect(url.contains('正文'), isTrue);
  });

  test('comic type passes', () {
    final info = validateLegadoJson(
      '{"bookSourceName":"C","bookSourceUrl":"https://x.example","searchUrl":"https://x.example/s","bookSourceType":2,"ruleSearch":{"bookList":"x"},"ruleBookInfo":{"tocUrl":""},"ruleToc":{"tocList":"x"},"ruleContent":{"content":"x"}}',
    );
    expect(info.type, 2);
  });

  test('unsupported type fails', () {
    expect(
      () => validateLegadoJson(
        '{"bookSourceName":"T","bookSourceUrl":"https://x.example","searchUrl":"https://x.example/s","bookSourceType":3,"ruleSearch":{"bookList":"x"},"ruleBookInfo":{"tocUrl":""},"ruleToc":{"tocList":"x"},"ruleContent":{"content":"x"}}',
      ),
      throwsFormatException,
    );
  });

  test('comic pages mapping', () {
    final fromString = legadoPages({
      'content': '',
      'images':
          '[{"url":"https://a.example/1.jpg"},{"url":"https://a.example/2.jpg"}]',
    });
    expect(fromString, [
      'https://a.example/1.jpg',
      'https://a.example/2.jpg',
    ]);
    final fromList = legadoPages({
      'content': '',
      'images': [
        {'url': 'https://a.example/3.jpg'},
        'https://a.example/4.jpg',
        {'url': ''},
      ],
    });
    expect(fromList, ['https://a.example/3.jpg', 'https://a.example/4.jpg']);
    expect(legadoPages({'content': '正文'}), isEmpty);
    expect(legadoPages(null), isEmpty);
    expect(
      legadoPicsUrl(['https://a.example/1.jpg', 'https://a.example/2.jpg']),
      'pics://https://a.example/1.jpg&&https://a.example/2.jpg',
    );
  });
}
