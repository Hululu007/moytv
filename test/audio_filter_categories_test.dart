import 'package:moyi/content_py.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses hongguo audio acat filter values as categories', () {
    final categories = parsePyFilterCategories({
      'filters': {
        'audio': [
          {
            'key': 'acat',
            'name': '分类',
            'value': [
              {'n': '全部', 'v': ''},
              {'n': '言情', 'v': '言情'},
              {'n': '玄幻', 'v': '玄幻'},
            ],
          },
        ],
      },
    }, 'audio', 'acat');
    expect(
      categories.map((c) => (c.id, c.name)).toList(),
      [('', '全部'), ('言情', '言情'), ('玄幻', '玄幻')],
    );
  });

  test('ignores other filter groups and empty values', () {
    expect(
      parsePyFilterCategories({
        'filters': {
          'audio': [
            {
              'key': 'other',
              'name': '其他',
              'value': [
                {'n': '甲', 'v': '甲'},
              ],
            },
            {
              'key': 'acat',
              'name': '分类',
              'value': [
                {'n': '全部', 'v': ''},
              ],
            },
          ],
        },
      }, 'audio', 'acat'),
      isEmpty,
    );
    expect(parsePyFilterCategories({}, 'audio', 'acat'), isEmpty);
  });
}
