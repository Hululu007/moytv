// fm.nvku 桥（合并演员库页的本地女优库兜底）单元测试。
// 不碰真 sqlite（flutter test 无桌面实现）：注入假查询函数，
// 按 SQL 特征回固定行，断言协议形态、参数化与硬线排除。
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/html_host/html_nvku.dart';

class _FakeDb {
  final tables = {
    'videos',
    'video_play_urls',
    'video_actress',
    'actresses',
    'video_tag',
    'video_category',
    'video_ranking',
    'index_categories',
    'tags',
  };
  final calls = <(String, List<Object?>?)>[];

  Map<String, Object?> _videoRow(String id) => {
    'vodId': id,
    'title': '作品$id',
    'pic': 'https://v.hersav.me/images/av/x.jpg',
    'play': 'https://v.hersav.me/h/h.m3u8',
    'date': '2024-01-01',
    'typeName': '成人影片',
    'actress': '演员甲',
  };

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    calls.add((sql, args));
    if (sql.contains('sqlite_master')) {
      return [for (final t in tables) {'name': t}];
    }
    if (sql.contains('FROM video_ranking')) {
      return [_videoRow('rank-001')];
    }
    if (sql.contains("category_type = 'tag'")) {
      return [
        {'name': '标签甲', 'cnt': 7},
      ];
    }
    if (sql.contains('FROM actresses a')) {
      return [
        {'name': '演员甲', 'avatar': 'https://v.hersav.me/actress/a.jpg', 'cnt': 42},
      ];
    }
    if (sql.contains('FROM video_play_urls')) {
      return [
        {'play_url': 'https://v.hersav.me/h/h.m3u8'},
        {'play_url': 'https://v.hersav.me/h2/h2.m3u8'},
      ];
    }
    if (sql.contains('SELECT a.name AS name FROM video_actress')) {
      return [
        {'name': '演员甲'},
      ];
    }
    if (sql.contains('SELECT tag_name AS name FROM video_tag')) {
      return [
        {'name': '标签甲'},
      ];
    }
    if (sql.contains('FROM videos v')) {
      if (args != null && args.contains('nope-000')) return [];
      return [_videoRow('mvsd-546')];
    }
    return [];
  }
}

HtmlNvkuService _service(_FakeDb db) =>
    HtmlNvkuService(opener: () async => db.query);

void main() {
  group('fm.nvku 协议', () {
    test('list latest：回 items 且字段齐', () async {
      final db = _FakeDb();
      final r = await _service(db).handle({'op': 'list', 'kind': 'latest'});
      expect(r['ok'], isTrue);
      final items = r['items'] as List;
      expect(items, hasLength(1));
      final item = items.first as Map;
      expect(item['vodId'], 'mvsd-546');
      expect(item['play'], startsWith('https://'));
      expect(item['actress'], '演员甲');
    });

    test('list latest 带厂牌前缀：LIKE 参数是前缀模式', () async {
      final db = _FakeDb();
      await _service(db).handle({'op': 'list', 'kind': 'latest', 'q': 'SSIS'});
      final listCall = db.calls.lastWhere((c) => c.$1.contains('FROM videos v'));
      expect(listCall.$2, contains('ssis%'));
    });

    test('list 查询带硬线类型排除（参数里含被排除类型名）', () async {
      final db = _FakeDb();
      await _service(db).handle({'op': 'list', 'kind': 'latest'});
      final listCall = db.calls.lastWhere((c) => c.$1.contains('FROM videos v'));
      expect(listCall.$1, contains('type_name NOT IN'));
      expect(listCall.$2, contains('少女萝莉'));
    });

    test('list rank：走 video_ranking 关联', () async {
      final db = _FakeDb();
      final r = await _service(db).handle({'op': 'list', 'kind': 'rank'});
      expect(r['ok'], isTrue);
      expect((r['items'] as List).first['vodId'], 'rank-001');
    });

    test('search：空词回空、非空走标题/番号 LIKE', () async {
      final db = _FakeDb();
      final empty = await _service(db).handle({'op': 'search', 'q': '  '});
      expect(empty['ok'], isTrue);
      expect(empty['items'], isEmpty);
      final r = await _service(db).handle({'op': 'search', 'q': 'mvsd'});
      expect((r['items'] as List), hasLength(1));
    });

    test('works：按演员与按标签都回 items', () async {
      final db = _FakeDb();
      final byActress = await _service(db).handle({
        'op': 'works',
        'actress': '演员甲',
      });
      expect((byActress['items'] as List), hasLength(1));
      final byTag = await _service(db).handle({'op': 'works', 'tag': '标签甲'});
      expect((byTag['items'] as List), hasLength(1));
      final bad = await _service(db).handle({'op': 'works'});
      expect(bad['ok'], isFalse);
    });

    test('actresses：回名/头像/计数', () async {
      final db = _FakeDb();
      final r = await _service(db).handle({'op': 'actresses'});
      expect(r['ok'], isTrue);
      final list = r['actresses'] as List;
      expect(list.first['name'], '演员甲');
      expect(list.first['count'], 42);
    });

    test('tags：走 index_categories 且排除硬线名', () async {
      final db = _FakeDb();
      final r = await _service(db).handle({'op': 'tags'});
      expect(r['ok'], isTrue);
      expect((r['tags'] as List).first['name'], '标签甲');
      final tagCall = db.calls.lastWhere(
        (c) => c.$1.contains("category_type = 'tag'"),
      );
      expect(tagCall.$2, contains('少女萝莉'));
    });

    test('detail：播放地址去重合并、演员/标签/相关齐', () async {
      final db = _FakeDb();
      final r = await _service(db).handle({'op': 'detail', 'vodId': 'MVSD-546'});
      expect(r['ok'], isTrue);
      final item = r['item'] as Map;
      expect(item['vodId'], 'mvsd-546');
      final playUrls = item['playUrls'] as List;
      expect(playUrls.toSet(), hasLength(playUrls.length)); // 无重复
      expect(playUrls, contains('https://v.hersav.me/h2/h2.m3u8'));
      expect(item['actresses'], ['演员甲']);
      expect(item['tags'], ['标签甲']);
      expect((item['related'] as List), isNotEmpty);
    });

    test('detail：库里没有回 ok:false', () async {
      final db = _FakeDb();
      final r = await _service(db).handle({'op': 'detail', 'vodId': 'nope-000'});
      expect(r['ok'], isFalse);
    });

    test('库未导入（opener 回 null）：ok:false 且说明未导入', () async {
      final service = HtmlNvkuService(opener: () async => null);
      final r = await service.handle({'op': 'list', 'kind': 'latest'});
      expect(r['ok'], isFalse);
      expect(r['error'], contains('尚未导入'));
    });

    test('未知 op 回 ok:false', () async {
      final db = _FakeDb();
      final r = await _service(db).handle({'op': 'bogus'});
      expect(r['ok'], isFalse);
    });
  });
}
