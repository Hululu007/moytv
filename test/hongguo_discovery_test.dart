import 'package:flutter_test/flutter_test.dart';

import 'package:moyi/core_bridge.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/models.dart';

void main() {
  group('试播回退 hongguoFirstPlayableEpisode', () {
    test('第 0 集失败→第 1 集播起来', () async {
      final tried = <int>[];
      final played = await hongguoFirstPlayableEpisode(
        episodeCount: 5,
        tryEpisode: (index) async {
          tried.add(index);
          return index == 1;
        },
      );
      expect(played, 1);
      expect(tried, [0, 1]);
    });

    test('第 0/1 集失败→第 2 集播起来', () async {
      final played = await hongguoFirstPlayableEpisode(
        episodeCount: 5,
        tryEpisode: (index) async => index == 2,
      );
      expect(played, 2);
    });

    test('都失败→返回 null（停住，不跳部）', () async {
      final tried = <int>[];
      final played = await hongguoFirstPlayableEpisode(
        episodeCount: 5,
        tryEpisode: (index) async {
          tried.add(index);
          return false;
        },
      );
      expect(played, isNull);
      // 单轮最多探 3 集，不把整部剧全探一遍。
      expect(tried, [0, 1, 2]);
    });

    test('第 0 集能播→只探一集', () async {
      final tried = <int>[];
      final played = await hongguoFirstPlayableEpisode(
        episodeCount: 5,
        tryEpisode: (index) async {
          tried.add(index);
          return true;
        },
      );
      expect(played, 0);
      expect(tried, [0]);
    });

    test('续播集从该集起探（startIndex）', () async {
      final tried = <int>[];
      final played = await hongguoFirstPlayableEpisode(
        episodeCount: 5,
        startIndex: 2,
        tryEpisode: (index) async {
          tried.add(index);
          return index == 3;
        },
      );
      expect(played, 3);
      expect(tried, [2, 3]);
    });

    test('集数不足 3 集时只探现有集', () async {
      final tried = <int>[];
      final played = await hongguoFirstPlayableEpisode(
        episodeCount: 2,
        tryEpisode: (index) async {
          tried.add(index);
          return false;
        },
      );
      expect(played, isNull);
      expect(tried, [0, 1]);
    });
  });

  group('试播重试两档延迟', () {
    test('延迟是 2 秒、5 秒两档', () {
      expect(hongguoTrialRetryDelays, [
        const Duration(seconds: 2),
        const Duration(seconds: 5),
      ]);
      expect(hongguoTrialMaxProbeEpisodes, 3);
    });
  });

  group('筛选请求体拼装 HongguoDiscoverySelection', () {
    test('8 组字段齐全，未选的组发空数组', () {
      final body = HongguoDiscoverySelection().requestBody();
      final selectItems = body['select_items'] as Map<String, dynamic>;
      expect(selectItems.keys.toSet(), hongguoDiscoveryLabels.keys.toSet());
      for (final key in hongguoDiscoveryLabels.keys) {
        expect(selectItems[key], isEmpty);
      }
      expect(body['offset'], 0);
      expect(body['limit'], 24);
      expect(body['need_selector_panel'], isTrue);
      expect(body['session_id'], '');
      expect(body['req_type'], 'default');
      expect(body['client_req_type'], 3);
      expect(body['filter_ids'], '');
      expect(body['req_scene'], 'default');
    });

    test('4 组旧值按服务端键拼装', () {
      final selection = HongguoDiscoverySelection({
        'genre': 'cate_1',
        'category_dim_theme': 'cate_19',
        'category_dim_role': 'cate_30',
        'category_dim_epoch': 'cate_40',
      });
      final selectItems =
          selection.requestBody()['select_items'] as Map<String, dynamic>;
      expect(selectItems['genre'], ['cate_1']);
      expect(selectItems['category_dim_theme'], ['cate_19']);
      expect(selectItems['category_dim_role'], ['cate_30']);
      expect(selectItems['category_dim_epoch'], ['cate_40']);
      // 其余 4 组仍在，只是空数组。
      expect(selectItems['sort'], isEmpty);
      expect(selectItems['gender'], isEmpty);
      expect(selectItems['online_time'], isEmpty);
      expect(selectItems['creation_status'], isEmpty);
    });

    test('游标页：offset/session/only_content，不再要筛选面板', () {
      const cursor = HongguoDiscoveryCursor(offset: 24, session: 's1');
      final body = HongguoDiscoverySelection({
        'genre': 'cate_1',
      }).requestBody(cursor: cursor);
      expect(body['offset'], 24);
      expect(body['session_id'], 's1');
      expect(body['req_type'], 'only_content');
      expect(body['need_selector_panel'], isFalse);
    });

    test('req_scene：漫剧/AI 剧走对应场景，其余默认', () {
      expect(
        HongguoDiscoverySelection({'genre': 'comic_series'}).reqScene,
        'comic_series',
      );
      expect(
        HongguoDiscoverySelection({'genre': 'ai_series'}).reqScene,
        'ai_series',
      );
      expect(
        HongguoDiscoverySelection({'genre': 'cate_1'}).reqScene,
        'default',
      );
      expect(HongguoDiscoverySelection().reqScene, 'default');
    });

    test('choose：切类型丢弃旧条件，空 id 清除该组，未知键不动', () {
      final base = HongguoDiscoverySelection({
        'genre': 'cate_1',
        'category_dim_theme': 'cate_19',
      });
      final switched = base.choose('genre', 'comic_series');
      expect(switched.values, {'genre': 'comic_series'});
      final cleared = base.choose('category_dim_theme', '');
      expect(cleared.values, {'genre': 'cate_1'});
      expect(base.choose('nope', 'x').values, base.values);
    });
  });

  group('筛选归一 hongguoNormalizeFilters', () {
    const nameToId = {
      'genre': {'悬疑': 'cate_1', '爱情': 'cate_2'},
      'category_dim_theme': {'系统': 'cate_19'},
      'category_dim_role': {'重生': 'cate_30'},
      'category_dim_epoch': {'民国': 'cate_40'},
    };

    test('旧 4 组中文值按展示名翻成服务端 id', () {
      final selection = hongguoNormalizeFilters({
        'cat': '悬疑',
        'topic': '系统',
        'background': '民国',
        'setting': '重生',
      }, nameToId);
      expect(selection.values, {
        'genre': 'cate_1',
        'category_dim_theme': 'cate_19',
        'category_dim_epoch': 'cate_40',
        'category_dim_role': 'cate_30',
      });
    });

    test('查不到的中文值丢弃，不发错值；服务端键直通', () {
      final selection = hongguoNormalizeFilters({
        'topic': '不存在的主题',
        'sort': 'hot_score',
        'gender': 'female',
        'bogus': 'x',
      }, nameToId);
      expect(selection.values, {'sort': 'hot_score', 'gender': 'female'});
    });

    test('漫剧分类无显式类型时用分类定 genre；显式类型优先', () {
      final fromCategory = hongguoNormalizeFilters(
        {'topic': '系统'},
        nameToId,
        category: 'comic_series',
      );
      expect(fromCategory.values['genre'], 'comic_series');
      final explicit = hongguoNormalizeFilters(
        {'cat': '悬疑'},
        nameToId,
        category: 'comic_series',
      );
      expect(explicit.values['genre'], 'cate_1');
      final real = hongguoNormalizeFilters(
        {'topic': '系统'},
        nameToId,
        category: 'short_play',
      );
      expect(real.values.containsKey('genre'), isFalse);
    });
  });

  group('桥接页解析 HongguoDiscoveryFilterPage', () {
    Map<String, dynamic> bridgeJson({
      bool hasMore = true,
      Map<String, dynamic>? nextCursor,
    }) => {
      'items': [
        {
          'seriesId': '77001',
          'title': '试播剧',
          'cover': 'https://example.test/cover.jpg',
          'desc': '简介',
          'badge': '共 30 集',
          'tags': '悬疑 · 系统',
        },
        {
          'seriesId': '',
          'title': '无编号跳过',
          'cover': '',
          'desc': '',
          'badge': '',
          'tags': '',
        },
      ],
      'groups': [
        {
          'type': 'genre',
          'label': '类型',
          'options': [
            {'id': 'cate_1', 'name': '悬疑'},
          ],
        },
        {
          'type': 'sort',
          'label': '排序',
          'options': [
            {'id': 'hot_score', 'name': '最热'},
          ],
        },
        {
          'type': 'empty_group',
          'label': '未知组',
          'options': [
            {'id': 'x', 'name': '无名'},
          ],
        },
      ],
      'hasMore': hasMore,
      'nextCursor': nextCursor ?? {'offset': 24, 'session': 's1'},
    };

    test('条目：id 带 hongguo: 前缀，集数从 badge 取，标签拆开', () {
      final page = HongguoDiscoveryFilterPage.fromBridgeJson(bridgeJson());
      expect(page.items.length, 1);
      final drama = page.items.first;
      expect(drama.id, 'hongguo:77001');
      expect(drama.source, 'hongguo');
      expect(drama.title, '试播剧');
      expect(drama.episodes, 30);
      expect(drama.tags, ['悬疑', '系统']);
      expect(page.hasMore, isTrue);
      expect(page.nextCursor?.offset, 24);
      expect(page.nextCursor?.session, 's1');
    });

    test('分组：旧组沿用旧键、选项 id 用展示名；新组用服务端键与 id', () {
      final page = HongguoDiscoveryFilterPage.fromBridgeJson(bridgeJson());
      expect(page.groups.length, 2);
      final genre = page.groups.firstWhere((group) => group.key == 'cat');
      expect(genre.name, '类型');
      expect(genre.options.single.id, '悬疑');
      expect(genre.options.single.name, '悬疑');
      final sort = page.groups.firstWhere((group) => group.key == 'sort');
      expect(sort.options.single.id, 'hot_score');
      expect(sort.options.single.name, '最热');
      // 翻译索引保留服务端 id。
      expect(page.nameToId['genre'], {'悬疑': 'cate_1'});
      expect(page.nameToId['sort'], {'最热': 'hot_score'});
    });

    test('服务端说有更多却没给可用游标时按无更多处理', () {
      final noCursor = HongguoDiscoveryFilterPage.fromBridgeJson(
        bridgeJson(nextCursor: {'offset': 0, 'session': ''}),
      );
      expect(noCursor.hasMore, isFalse);
      expect(noCursor.nextCursor, isNull);
      final noMore = HongguoDiscoveryFilterPage.fromBridgeJson(
        bridgeJson(hasMore: false),
      );
      expect(noMore.hasMore, isFalse);
    });
  });

  group('筛选会话 HongguoDiscoverySession（内存游标）', () {
    test('首页记下分组与游标；续页不覆盖分组，只更新游标', () {
      final session = HongguoDiscoverySession(
        fingerprint: 'short_play|topic=系统',
        selection: HongguoDiscoverySelection({
          'category_dim_theme': 'cate_19',
        }),
      );
      final first = HongguoDiscoveryFilterPage(
        items: const [],
        groups: [
          const CatalogFilterGroup('topic', '主题', [
            CatalogFilterOption('系统', '系统'),
          ]),
        ],
        hasMore: true,
        nextCursor: const HongguoDiscoveryCursor(offset: 24, session: 's1'),
        nameToId: const {},
      );
      session.applyPage(first, first: true);
      expect(session.groups.single.key, 'topic');
      expect(session.nextCursor?.offset, 24);
      expect(session.hasMore, isTrue);

      final second = HongguoDiscoveryFilterPage(
        items: const [],
        groups: const [],
        hasMore: false,
        nextCursor: null,
        nameToId: const {},
      );
      session.applyPage(second);
      expect(session.groups.single.key, 'topic');
      expect(session.hasMore, isFalse);
      expect(session.nextCursor, isNull);
    });

    test('换筛选项指纹就变，旧游标不复用', () {
      final a = HongguoDiscoverySelection({
        'category_dim_theme': 'cate_19',
      }).fingerprint;
      final b = HongguoDiscoverySelection({
        'category_dim_theme': 'cate_20',
      }).fingerprint;
      expect(a, isNot(equals(b)));
      expect(
        HongguoDiscoverySelection({'sort': 'hot_score'}).fingerprint,
        'sort=hot_score',
      );
    });

    test('游标续页：第二页请求体带首页游标', () {
      final selection = HongguoDiscoverySelection({
        'category_dim_theme': 'cate_19',
      });
      const cursor = HongguoDiscoveryCursor(offset: 24, session: 's1');
      final body = selection.requestBody(cursor: cursor);
      expect(body['offset'], 24);
      expect(body['session_id'], 's1');
      expect(body['req_type'], 'only_content');
      final selectItems = body['select_items'] as Map<String, dynamic>;
      expect(selectItems['category_dim_theme'], ['cate_19']);
    });
  });
}
