import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/idj_contract.dart';
import 'package:moyi/models.dart';

void main() {
  const source = 'idj_mini';
  final base = Drama(
    id: '$source:123',
    source: source,
    sourceId: '123',
    title: '原标题',
    description: '原简介',
    cover: 'https://cover.test/a.jpg',
  );

  group('categoriesFromHome', () {
    test('读 home categories，前置「全部」，分类名原样保留', () {
      final categories = IdjContract.categoriesFromHome({
        'categories': [
          {'id': 'line:abc', 'name': '线路A'},
          {'id': 'tag:x', 'name': 'AI短剧'},
          {'id': 'chinese', 'name': '中文字幕'},
        ],
        'items': [],
        'hasMore': false,
      });
      expect(categories.length, 4);
      expect(categories.first.id, '');
      expect(categories.first.name, '全部');
      expect(categories[1].id, 'line:abc');
      expect(categories[1].name, '线路A');
      expect(categories[2].name, 'AI短剧');
      expect(categories[3].id, 'chinese');
    });

    test('home 里没有 categories 时只回「全部」，不编默认分类', () {
      final categories = IdjContract.categoriesFromHome({
        'items': [],
        'hasMore': false,
      });
      expect(categories, [CatalogCategory.all]);
    });
  });

  group('pageFromResult', () {
    test('{items, hasMore} → CatalogPage，字段按 RE 形状映射', () {
      final page = IdjContract.pageFromResult(source, {
        'items': [
          {
            'id': '123',
            'title': '剧A',
            'cover': 'https://cover.test/a.jpg',
            'duration': '12集',
            'remarks': '12集',
            'tags': ['短剧'],
          },
          {
            'id': '456',
            'title': '剧B',
            'cover': 'https://cover.test/b.jpg',
            'duration': '3:21',
            'remarks': '完结',
          },
        ],
        'hasMore': true,
      }, page: 1);
      expect(page.items.length, 2);
      expect(page.items.first.id, '$source:123');
      expect(page.items.first.sourceId, '123');
      expect(page.items.first.title, '剧A');
      expect(page.items.first.description, '12集');
      expect(page.items.first.cover, 'https://cover.test/a.jpg');
      expect(page.items.first.tags, ['短剧']);
      expect(page.items[1].description, '完结');
      expect(page.hasMore, isTrue);
      expect(page.page, 1);
    });

    test('hasMore 为假时不续页；page 参数原样透传', () {
      final page = IdjContract.pageFromResult(source, {
        'items': [],
        'hasMore': false,
      }, page: 2);
      expect(page.hasMore, isFalse);
      expect(page.page, 2);
    });

    test('items 超 500 条截断，不抛错', () {
      final page = IdjContract.pageFromResult(source, {
        'items': [
          for (var i = 0; i < 501; i++) {'id': '$i', 'title': '剧$i'},
        ],
        'hasMore': true,
      });
      expect(page.items.length, 500);
    });

    test('标题超 200 字截断', () {
      final page = IdjContract.pageFromResult(source, {
        'items': [
          {'id': '1', 'title': 'x' * 201},
        ],
        'hasMore': false,
      });
      expect(page.items.first.title.length, 200);
    });
  });

  group('detailFromResult', () {
    test('lines → 多线路 Episode：flag 是线路名、id 是分集键', () {
      final detail = IdjContract.detailFromResult(source, base, {
        'id': '123',
        'title': '剧A',
        'cover': 'https://cover.test/a.jpg',
        'desc': '剧情简介',
        'duration': '共 12 集',
        'tags': ['短剧', '甜宠'],
        'lines': [
          {
            'name': '线路1 · 1080P',
            'line': 'key1',
            'episodes': [
              {'id': 'key1|vid1', 'name': '正片 1080P'},
              {'id': 'key1|vid2', 'name': '正片 720P'},
            ],
          },
          {
            'name': '默认线路',
            'line': 'main',
            'episodes': [
              {'id': '123005', 'name': '第 5 集'},
            ],
          },
        ],
      });
      expect(detail.drama.title, '剧A');
      expect(detail.drama.description, '剧情简介');
      expect(detail.drama.cover, 'https://cover.test/a.jpg');
      expect(detail.episodes.length, 3);
      expect(detail.episodes[0].raw['id'], 'key1|vid1');
      expect(detail.episodes[0].raw['flag'], '线路1 · 1080P');
      expect(detail.episodes[0].title, '正片 1080P');
      expect(detail.episodes[2].raw['id'], '123005');
      expect(detail.episodes[2].raw['flag'], '默认线路');
      expect(detail.tags.map((tag) => tag.name), ['短剧', '甜宠']);
      expect(detail.warning, isEmpty);
    });

    test('lines 为空时 warning 非空、不抛错', () {
      final detail = IdjContract.detailFromResult(source, base, {
        'id': '123',
        'title': '剧A',
        'lines': [],
      });
      expect(detail.episodes, isEmpty);
      expect(detail.warning, isNotEmpty);
    });
  });

  group('planFromResult', () {
    test('streams[0] → PlaybackPlan：url + 头透传 + expiresAt', () {
      final plan = IdjContract.planFromResult({
        'streams': [
          {
            'url': 'https://cdn.test/x.m3u8',
            'format': 'hls',
            'headers': {'User-Agent': 'UA1', 'Referer': 'https://site.test/'},
            'name': '高清',
          },
        ],
        'expiresAt': 123456,
      });
      expect(plan.url, 'https://cdn.test/x.m3u8');
      expect(plan.headers['User-Agent'], 'UA1');
      expect(plan.headers['Referer'], 'https://site.test/');
      expect(plan.needsParse, isFalse);
      expect(plan.expiresAt, 123456);
    });

    test('空 streams 抛「插件没有返回可播放地址」', () {
      expect(
        () => IdjContract.planFromResult({'streams': []}),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'message',
            '插件没有返回可播放地址',
          ),
        ),
      );
    });

    test('不合法的流丢弃、取下一条合法流；全不合法才抛错', () {
      final plan = IdjContract.planFromResult({
        'streams': [
          {'url': 'http://cdn.test/a.m3u8', 'format': 'hls'},
          {'url': 'https://user:pass@cdn.test/b.m3u8', 'format': 'hls'},
          {'url': 'https://192.168.1.1/c.m3u8', 'format': 'hls'},
          {'url': 'https://cdn.test:8443/d.m3u8', 'format': 'hls'},
          {'url': 'https://cdn.test/e.m3u8', 'format': 'hls'},
        ],
      });
      expect(plan.url, 'https://cdn.test/e.m3u8');
      expect(
        () => IdjContract.planFromResult({
          'streams': [
            {'url': 'http://cdn.test/a.m3u8', 'format': 'hls'},
          ],
        }),
        throwsA(isA<AppFailure>()),
      );
    });

    test('media 白名单不符只记日志、不丢弃', () {
      final plan = IdjContract.planFromResult(
        {
          'streams': [
            {'url': 'https://other.test/x.m3u8', 'format': 'hls'},
          ],
        },
        mediaAllowlist: ['cdn.test'],
      );
      expect(plan.url, 'https://other.test/x.m3u8');
    });
  });
}
