import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/whos_local_library.dart';

void main() {
  List<Map<String, Object?>> rows() => [
    {
      'vod_name': 'A 女优 作品一',
      'vod_code': 'sdam-186',
      'vod_pic': 'https://v.hersav.me/images/av/a.jpg',
      'vod_play_url': r'正片$https://v.hersav.me/a.m3u8',
      'vod_area': '日本',
      'vod_year': '2024',
      'vod_id': 'sdam-186',
    },
    {
      'vod_name': 'B 女优 作品二',
      'vod_code': 'sdam-190',
      'vod_pic': 'https://v.hersav.me/images/av/b.jpg',
      'vod_play_url': r'正片$https://v.hersav.me/b.m3u8',
      'vod_id': 'sdam-190',
    },
    {
      'vod_name': '未知厂牌作品',
      'vod_code': 'xyz-001',
      'vod_pic': 'https://v.hersav.me/images/av/c.jpg',
      'vod_play_url': r'正片$https://v.hersav.me/c.m3u8',
      'vod_id': 'xyz-001',
    },
    {
      'vod_name': 'FC2 作品',
      'vod_code': 'fc2ppv-4913308',
      'vod_pic': 'https://v.hersav.me/images/av/d.jpg',
      'vod_play_url': r'正片$https://v.hersav.me/d.m3u8',
      'vod_id': 'fc2ppv-4913308',
    },
  ];

  WhosLocalLibrary library() =>
      WhosLocalLibrary.fromWorks(WhosLocalLibrary.parseWorks(jsonEncode(rows())));

  group('厂牌识别', () {
    test('番号前缀当前缀', () {
      expect(WhosLocalWork.brandOfCode('sdam-186'), 'sdam');
      expect(WhosLocalWork.brandOfCode('FC2PPV-4913308'), 'fc2ppv');
      expect(WhosLocalWork.brandOfCode('ssis-001-uncensored-leak'), 'ssis');
    });

    test('没有厂牌的行返回空', () {
      expect(WhosLocalWork.brandOfCode(''), '');
      expect(WhosLocalWork.brandOfCode('123456-789'), '');
    });

    test('展示名有中文/大写表', () {
      expect(whosBrandLabel('fc2ppv'), 'FC2');
      expect(whosBrandLabel('sdam'), 'SDAM');
      expect(whosBrandLabel('zzz'), 'ZZZ');
    });
  });

  group('解析', () {
    test('vod_* 键与播放地址拆分', () {
      final works = WhosLocalLibrary.parseWorks(jsonEncode(rows()));
      expect(works.length, 4);
      expect(works.first.id, 'sdam-186');
      expect(works.first.playUrl, 'https://v.hersav.me/a.m3u8');
      expect(works.first.playable, isTrue);
      expect(works.first.brand, 'sdam');
    });

    test('多集播放地址取第一条', () {
      final works = WhosLocalLibrary.parseWorks(
        jsonEncode([
          {
            'name': '多集',
            'code': 'abc-001',
            'play_url': r'第1集$https://e.com/1.m3u8#第2集$https://e.com/2.m3u8',
          },
        ]),
      );
      expect(works.single.playUrl, 'https://e.com/1.m3u8');
    });

    test('大表里只收 whos 来源的行', () {
      final works = WhosLocalLibrary.parseWorks(
        jsonEncode([
          {
            'vod_name': 'whos 行',
            'vod_code': 'a-1',
            'vod_play_from': 'whos',
            'vod_pic': 'https://e.com/a.jpg',
          },
          {
            'vod_name': '别的站',
            'vod_code': 'b-2',
            'vod_play_from': 'mjv',
            'vod_pic': 'https://e.com/b.jpg',
          },
        ]),
        origin: 'local-mjv',
      );
      expect(works.length, 1);
      expect(works.single.code, 'a-1');
    });

    test('标题能反推番号', () {
      final works = WhosLocalLibrary.parseWorks(
        jsonEncode([
          {'vod_name': 'SSIS-123 某作品', 'vod_pic': 'https://e.com/x.jpg'},
        ]),
      );
      expect(works.single.code, 'ssis-123');
      expect(works.single.brand, 'ssis');
    });

    test('没有标题也没有番号的行丢掉', () {
      expect(WhosLocalLibrary.parseWorks(jsonEncode([{'vod_pic': 'x'}])), isEmpty);
    });

    test('坏 json 不抛', () {
      expect(WhosLocalLibrary.parseWorks('not json'), isEmpty);
    });
  });

  group('分类与分页', () {
    test('全部与分类计数', () {
      final lib = library();
      expect(lib.count, 4);
      expect(lib.countFor(), 4);
      expect(lib.countFor(category: whosLocalNewCategory), 4);
      expect(lib.countFor(category: 'brand:sdam'), 2);
    });

    test('厂牌分页逐页不重不漏', () {
      final lib = library();
      final first = lib.page(category: 'brand:sdam', page: 1, pageSize: 1);
      final second = lib.page(category: 'brand:sdam', page: 2, pageSize: 1);
      expect(first.single.id, isNot(second.single.id));
      expect(lib.page(category: 'brand:sdam', page: 3, pageSize: 1), isEmpty);
    });

    test('关键词多词与番号搜索', () {
      final lib = library();
      expect(lib.countFor(query: 'sdam'), 2);
      expect(lib.countFor(query: 'sdam 186'), 1);
      expect(lib.countFor(query: '都不匹配'), 0);
    });

    test('分类内搜索', () {
      final lib = library();
      expect(lib.countFor(category: 'brand:sdam', query: '190'), 1);
    });

    test('分类清单带最新/排行/厂牌', () {
      final lib = library();
      final cats = lib.categories();
      final ids = cats.map((c) => c.id).toList();
      expect(ids.first, whosLocalNewCategory);
      expect(ids[1], whosLocalRankCategory);
      expect(ids.contains('brand:sdam'), isTrue);
    });

    test('只有一条的厂牌不进分类栏', () {
      final lib = WhosLocalLibrary.fromWorks(
        WhosLocalLibrary.parseWorks(
          jsonEncode([
            {'vod_name': 'a', 'vod_code': 'tiny-1', 'vod_pic': 'https://e.com/1.jpg'},
            {'vod_name': 'b', 'vod_code': 'ok-1', 'vod_pic': 'https://e.com/2.jpg'},
            {'vod_name': 'c', 'vod_code': 'ok-2', 'vod_pic': 'https://e.com/3.jpg'},
            {'vod_name': 'd', 'vod_code': 'ok-3', 'vod_pic': 'https://e.com/4.jpg'},
          ]),
        ),
      );
      final brands = lib.brandFacets().map((f) => f.brand).toList();
      expect(brands.contains('ok'), isTrue);
      expect(brands.contains('tiny'), isFalse);
    });
  });

  group('取条', () {
    test('按番号或 id 取', () {
      final lib = library();
      expect(lib.byId('sdam-186')?.title, 'A 女优 作品一');
      expect(lib.byId('SDAM-190')?.title, 'B 女优 作品二');
      expect(lib.byId('nope'), isNull);
      expect(lib.byId(''), isNull);
    });
  });
}
