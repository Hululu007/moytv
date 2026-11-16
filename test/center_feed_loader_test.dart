// 中间播放键全屏流取数器：固定红果 + 随机可见成人推荐 + 回落。
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/center_feed_loader.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/feed_playability.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

Drama _video(String source, String id) => Drama(
  id: '$source:$id',
  source: source,
  title: '$source 剧 $id',
  cover: 'https://x.test/$source-$id.jpg',
  episodes: 3,
);

class _FakeRepository extends AppRepository {
  _FakeRepository({
    required this.pages,
    this.categoriesBySource = const {},
    this.failCategories = false,
    this.failSources = const {},
  });

  final Map<String, List<Drama>> pages;
  final Map<String, List<CatalogCategory>> categoriesBySource;
  final bool failCategories;
  final Set<String> failSources;
  final catalogRequests = <String>[];
  final catalogCategories = <String>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      CatalogPage(const []);

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      CatalogPage(const []);

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => drama.cover;

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    if (failCategories) throw AppFailure('分类失败');
    return categoriesBySource[source] ?? const [CatalogCategory.all];
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    catalogRequests.add(source);
    catalogCategories.add(category);
    if (failSources.contains(source)) throw AppFailure('取目录失败');
    return CatalogPage(pages[source] ?? const []);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, [
    Episode({'id': '1', 'title': '第1集', 'currentEpisode': 1}, 1),
  ]);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    bool adBlock = true,
    int quality = 0,
    int route = 0,
  }) async => const PlaybackPlan(url: 'https://x.test/a.m3u8');

  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async =>
      throw AppFailure('没有备用线路');

  @override
  Future<void> cancelPlayback() async {}

  @override
  Future<void> release(String session) async {}
}

/// 全通过验播器：取流验真一律回可播（探针回 m3u8 清单头）。
FeedPlayabilityVerifier _passingVerifier(_FakeRepository repository) =>
    FeedPlayabilityVerifier(
      detailOf: repository.detail,
      resolveOf: repository.resolve,
      fetchHead: (_, _, _) async => FeedProbeResponse(
        statusCode: 200,
        headers: {'content-type': 'application/vnd.apple.mpegurl'},
        headBytes: utf8.encode('#EXTM3U\n#EXT-X-VERSION:3'),
      ),
    );

/// 全不通过验播器：探针一律 404。
FeedPlayabilityVerifier _rejectingVerifier(_FakeRepository repository) =>
    FeedPlayabilityVerifier(
      detailOf: repository.detail,
      resolveOf: repository.resolve,
      fetchHead: (_, _, _) async => const FeedProbeResponse(
        statusCode: 404,
        headers: {},
        headBytes: [],
      ),
    );

/// 测试用自定义站源：默认测试环境内置站表只有红果（ALL_SOURCES
/// 未开），成人站一律走自定义源注入，与环境无关。
List<Map<String, String>> _customSites({
  bool adult1 = true,
  bool adult2 = true,
  bool plain = true,
}) => [
  if (adult1)
    {'id': 'custom:adult1', 'name': '🔞成人站A', 'base': 'https://a1.test'},
  if (adult2)
    {'id': 'custom:adult2', 'name': '🔞成人站B', 'base': 'https://a2.test'},
  if (plain)
    {'id': 'custom:plain', 'name': '普通站', 'base': 'https://p.test'},
];

Future<LocalStore> _store({
  List<String> hiddenIds = const [],
  List<Map<String, String>> customSites = const [],
}) async {
  SharedPreferences.setMockInitialValues({
    'hiddenSites': jsonEncode(hiddenIds),
    'customSources': jsonEncode(customSites),
  });
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

void main() {
  test('只取红果目录，分类透传', () async {
    final repository = _FakeRepository(
      pages: {
        'hongguo': List.generate(5, (i) => _video('hongguo', '$i')),
      },
      categoriesBySource: {
        'hongguo': const [
          CatalogCategory.all,
          CatalogCategory('rec', '推荐'),
        ],
      },
    );
    final store = await _store();
    final loader = CenterFeedLoader(
      repository: repository,
      store: store,
      random: Random(1),
    );
    final data = await loader.load('rec');
    expect(data.dramas.map((d) => d.source).toSet(), {'hongguo'});
    expect(data.dramas, hasLength(5));
    expect(
      data.categories.map((c) => c.id).toList(),
      ['rec'],
      reason: '“全部”由屏自己画，加载器去掉重复的 all 条目',
    );
    expect(repository.catalogRequests.first, 'hongguo');
    expect(repository.catalogCategories.first, 'rec');
  });

  test('文件夹分类不进流分类行', () async {
    final repository = _FakeRepository(
      pages: {
        'hongguo': [_video('hongguo', '0')],
      },
      categoriesBySource: {
        'hongguo': const [
          CatalogCategory('flat', '平面'),
          CatalogCategory('dir', '文件夹', kind: 'folder'),
        ],
      },
    );
    final loader = CenterFeedLoader(
      repository: repository,
      store: await _store(),
      random: Random(1),
    );
    final data = await loader.load('');
    expect(data.categories.map((c) => c.id).toList(), ['flat']);
  });

  test('分类取不到时分类为空，目录照常', () async {
    final repository = _FakeRepository(
      pages: {
        'hongguo': [_video('hongguo', '0')],
      },
      failCategories: true,
    );
    final loader = CenterFeedLoader(
      repository: repository,
      store: await _store(),
      random: Random(1),
    );
    final data = await loader.load('');
    expect(data.categories, isEmpty);
    expect(data.dramas, hasLength(1));
  });

  test('红果目录取不到抛错（屏内重试）', () async {
    final repository = _FakeRepository(
      pages: const {},
      failSources: const {'hongguo'},
    );
    final loader = CenterFeedLoader(
      repository: repository,
      store: await _store(),
      random: Random(1),
    );
    await expectLater(loader.load(''), throwsA(isA<AppFailure>()));
  });

  test('红果目录为空时不拿成人内容顶替', () async {
    final store = await _store(customSites: _customSites());
    final pages = <String, List<Drama>>{
      'custom:adult1': [_video('custom:adult1', '0')],
      'custom:adult2': [_video('custom:adult2', '0')],
    };
    final repository = _FakeRepository(pages: pages);
    final loader = CenterFeedLoader(
      repository: repository,
      store: store,
      random: Random(1),
    );
    final data = await loader.load('');
    expect(data.dramas, isEmpty);
    expect(
      repository.catalogRequests,
      ['hongguo'],
      reason: '红果为空直接返回，不拉成人站',
    );
  });

  test('可见成人站内容验播通过后混入，隐藏站与非成人站不参与', () async {
    // 与环境无关：ALL_SOURCES 开时内置站表很大，随机抽样几乎抽不到
    // 自定义成人站；先把内置站全藏起来，只留红果 + 自定义站。
    final builtinHidden = SourceSite.values
        .map((site) => site.id)
        .where((id) => id != 'hongguo')
        .toList();
    final store = await _store(
      hiddenIds: ['custom:adult2', ...builtinHidden],
      customSites: _customSites(),
    );
    final pages = <String, List<Drama>>{
      'hongguo': List.generate(10, (i) => _video('hongguo', '$i')),
      'custom:adult1': List.generate(8, (i) => _video('custom:adult1', '$i')),
      'custom:adult2': List.generate(8, (i) => _video('custom:adult2', '$i')),
      'custom:plain': List.generate(8, (i) => _video('custom:plain', '$i')),
    };
    final repository = _FakeRepository(pages: pages);
    final loader = CenterFeedLoader(
      repository: repository,
      store: store,
      verifier: _passingVerifier(repository),
      random: Random(7),
    );
    final data = await loader.load('');
    expect(data.dramas.length, greaterThan(10));
    expect(
      data.dramas.any((d) => d.source == 'custom:adult1'),
      isTrue,
    );
    expect(
      data.dramas.any((d) => d.source == 'custom:adult2'),
      isFalse,
      reason: '隐藏的成人站不参与',
    );
    expect(
      data.dramas.any((d) => d.source == 'custom:plain'),
      isFalse,
      reason: '非成人站不参与混排',
    );
    // 只拉过红果与可见成人站。
    expect(repository.catalogRequests, ['hongguo', 'custom:adult1']);
    // 红果原顺序保留。
    final hongguoOrder = data.dramas
        .where((d) => d.source == 'hongguo')
        .map((d) => d.id)
        .toList();
    expect(hongguoOrder, List.generate(10, (i) => 'hongguo:$i'));
  });

  test('成人站取不到/验不过时回落纯红果', () async {
    final store = await _store(customSites: _customSites());
    final pages = <String, List<Drama>>{
      'hongguo': List.generate(6, (i) => _video('hongguo', '$i')),
      'custom:adult1': [_video('custom:adult1', '0')],
      'custom:adult2': [_video('custom:adult2', '0')],
    };
    final repository = _FakeRepository(
      pages: pages,
      failSources: const {'custom:adult1', 'custom:adult2'},
    );
    final loader = CenterFeedLoader(
      repository: repository,
      store: store,
      verifier: _passingVerifier(repository),
      random: Random(1),
    );
    final data = await loader.load('');
    expect(data.dramas.map((d) => d.source).toSet(), {'hongguo'});
    expect(data.dramas, hasLength(6));

    // 验播全不过也回落纯红果。
    final repository2 = _FakeRepository(pages: pages);
    final loader2 = CenterFeedLoader(
      repository: repository2,
      store: store,
      verifier: _rejectingVerifier(repository2),
      random: Random(1),
    );
    final data2 = await loader2.load('');
    expect(data2.dramas.map((d) => d.source).toSet(), {'hongguo'});
    expect(data2.dramas, hasLength(6));
  });

  test('非 video 条目不进流', () async {
    final repository = _FakeRepository(
      pages: {
        'hongguo': [
          _video('hongguo', '0'),
          const Drama(
            id: 'hongguo:folder',
            source: 'hongguo',
            title: '文件夹',
            kind: 'folder',
          ),
        ],
      },
    );
    final loader = CenterFeedLoader(
      repository: repository,
      store: await _store(),
      random: Random(1),
    );
    final data = await loader.load('');
    expect(data.dramas.map((d) => d.id).toList(), ['hongguo:0']);
  });
}
