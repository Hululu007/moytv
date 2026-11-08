import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/imported_site_record.dart';
import 'package:moyi/models.dart';
import 'package:moyi/py_contract.dart';

void main() {
  test('plan header string json fallback', () {
    final plan = PyContract.planFromResult({
      'url': 'https://play.test/1.m3u8',
      'header': '{"User-Agent": "UA1", "Referer": "https://site.test/"}',
    });
    expect(plan.headers['User-Agent'], 'UA1');
    expect(plan.headers['Referer'], 'https://site.test/');
  });

  test('plan header list of pairs fallback', () {
    final plan = PyContract.planFromResult({
      'url': 'https://play.test/1.m3u8',
      'header': [
        ['User-Agent', 'UA2'],
        {'key': 'Referer', 'value': 'https://site.test/'},
      ],
    });
    expect(plan.headers['User-Agent'], 'UA2');
    expect(plan.headers['Referer'], 'https://site.test/');
  });

  test('plan header invalid string does not crash', () {
    final plan = PyContract.planFromResult({
      'url': 'https://play.test/1.m3u8',
      'header': 'not json',
    });
    expect(plan.headers, isEmpty);
    expect(plan.url, 'https://play.test/1.m3u8');
  });

  test('plan withHeaders keeps url and replaces headers', () {
    const plan = PlaybackPlan(
      url: 'https://play.test/1.m3u8',
      headers: {'User-Agent': 'OldUA'},
    );
    final merged = plan.withHeaders({
      'User-Agent': 'OldUA',
      'Referer': 'https://site.test/',
    });
    expect(merged.url, 'https://play.test/1.m3u8');
    expect(merged.headers['User-Agent'], 'OldUA');
    expect(merged.headers['Referer'], 'https://site.test/');
  });

  test('plan playUrl fallback', () {
    final plan = PyContract.planFromResult({
      'url': '',
      'playUrl': 'https://play.test/only-play-url.m3u8',
    });
    expect(plan.url, 'https://play.test/only-play-url.m3u8');
    final empty = PyContract.planFromResult({'url': '', 'playUrl': ''});
    expect(empty.url, isEmpty);
  });

  test('filters from home and category mapping', () {
    final home = {
      'class': [
        {'type_id': 'movie', 'type_name': '电影'},
      ],
      'filters': {
        'movie': [
          {
            'key': 'area',
            'name': '地区',
            'value': [
              {'n': '全部', 'v': ''},
              {'n': '大陆', 'v': '大陆'},
            ],
          },
        ],
      },
    };
    final filters = PyContract.filtersFromHome(home);
    expect(filters['movie'], isNotNull);
    final groups = PyContract.filterGroupsForCategory(filters, 'movie');
    expect(groups.length, 1);
    expect(groups.first.key, 'area');
    expect(groups.first.name, '地区');
    expect(groups.first.options.length, 2);
    expect(groups.first.options[0].id, '');
    expect(groups.first.options[1].id, '大陆');
    expect(groups.first.options[1].name, '大陆');
    expect(PyContract.filterGroupsForCategory(filters, 'other'), isEmpty);
    expect(PyContract.filtersFromHome({'class': []}), isEmpty);
  });

  test('imported record ext round trip', () {
    const record = ImportedSiteRecord(
      id: 'py_x',
      name: 'X站',
      type: ImportedSiteRecord.typePy,
      fileName: 'x.py',
      contentHash: 'h',
      ext: 'https://host.test',
    );
    final restored = ImportedSiteRecord.fromJson(record.toJson());
    expect(restored.ext, 'https://host.test');
    expect(restored.asSite.importExt, 'https://host.test');
    final empty = ImportedSiteRecord.fromJson({
      'id': 'py_y',
      'name': 'Y站',
      'type': 'py',
      'fileName': 'y.py',
      'contentHash': 'h',
    });
    expect(empty.ext, '');
    expect(empty.copyWith(name: 'Z站').ext, '');
    expect(empty.copyWith(ext: 'e').ext, 'e');
  });
}
