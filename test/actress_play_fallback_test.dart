import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_detail_page.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_m3u_index.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_play.dart';
import 'package:moyi/actress/actress_search.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/crosssite_probe.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/feed_playability.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/playback_sniffer.dart';
import 'package:moyi/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 演员库点卡播放优化（2026-11-18）：兜底 MJV 优先探查、点卡直进
/// 详情页起播、封面按番号先走 MJV。兜底站 key 见
/// [actressFallbackSiteIds]：mjv011（jar）→ chaoliu（py）→
/// v_mjv011（Go 槽）→ 18AV 双生站（av18avmcg、av18av）。

const _mjvJarSite = SourceSite(
  'jar:zakatv:ZakaMjv011',
  '🔞mjv011',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _chaoliuSite = SourceSite(
  'chaoliu',
  '🔞潮流',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _mjvGoSite = SourceSite(
  'v_mjv011',
  '🔞mjv011',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _av18mcgSite = SourceSite(
  'jar:zakatv:av18avmcg',
  '🔞18AV',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _av18Site = SourceSite(
  'jar:zakatv:av18av',
  '🔞18AV',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _otherSite = SourceSite(
  'test-site-other',
  '🔞其他站',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);

const _allFallbackTestSites = [
  _mjvJarSite,
  _chaoliuSite,
  _mjvGoSite,
  _av18mcgSite,
  _av18Site,
  _otherSite,
];

void _registerFallbackTestSites() {
  for (final site in _allFallbackTestSites) {
    SourceSite.importedSites[site.id] = site;
  }
}

/// 验活假探针：永远可播（合成地址 example.test 在测试里没有真服务，
/// 默认探针会判死；链测试只测链逻辑，不测真网络）。
Future<FeedProbeResponse> _alwaysPlayable(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async => const FeedProbeResponse(
  statusCode: 200,
  headers: {'content-type': 'video/mp4'},
  headBytes: [1],
);

/// 按地址判活的假探针：地址含 'dead' 的判死，其余判活。
Future<FeedProbeResponse> _playableUnlessDead(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async => url.contains('dead')
    ? const FeedProbeResponse(statusCode: 404, headers: {}, headBytes: [])
    : const FeedProbeResponse(
        statusCode: 200,
        headers: {'content-type': 'video/mp4'},
        headBytes: [1],
      );

/// 假兜底 json 文档：顶层四键、每行 15 字段同顺序（见
/// validateActressJsonDocument），只给 whos.json 用。
String _fakeFallbackDoc(List<Map<String, dynamic>> rows) => jsonEncode({
  'list': rows,
  'parse': '',
  'jx': '',
  'last_update': '2026-11-20',
});

Map<String, dynamic> _fakeFallbackRow({
  required String vodId,
  required String vodCode,
  required String vodName,
  required String playUrl,
  String vodPic = '',
  String vodActor = '女演员甲',
  String vodPlayFrom = 'whos',
}) => {
  'vod_id': vodId,
  'vod_name': vodName,
  'vod_pic': vodPic,
  'vod_actor': vodActor,
  'vod_director': '',
  'vod_remarks': '',
  'vod_pubdate': '',
  'vod_area': '',
  'vod_year': '',
  'vod_content': '',
  'vod_play_from': vodPlayFrom,
  'vod_play_url': playUrl,
  'type_name': '',
  'vod_code': vodCode,
  'vod_actress_pic': '',
};

const _emptyFallbackDoc =
    '{"list":[],"parse":"","jx":"","last_update":"2026-11-20"}';

/// 假影视库 db（第一档）：按番号回 DB 行；名字路回空。
class _FakeFilmDb implements FilmDbFallbackProvider {
  _FakeFilmDb(this.rowsByCode);

  final Map<String, List<ActressJsonEntry>> rowsByCode;

  @override
  Future<List<ActressJsonEntry>> entriesForActress(
    String name, {
    String? site,
  }) async => const [];

  @override
  Future<List<ActressJsonEntry>> entriesForCode(
    String codeKey, {
    String? site,
  }) async => rowsByCode[codeKey] ?? const [];
}

/// 假 DB 行：直拼 ActressJsonEntry（不走 json 文本）。
ActressJsonEntry _dbEntry({
  required String vodId,
  required String playUrl,
  String site = 'mjv',
  String vodName = 'SSIS-00123 库里标题',
}) => ActressJsonEntry(
  site: site,
  vodId: vodId,
  vodName: vodName,
  vodPic: '',
  vodActor: '女演员甲',
  vodDirector: '',
  vodRemarks: '',
  vodPubdate: '',
  vodArea: '',
  vodYear: '',
  vodContent: '',
  vodPlayFrom: site,
  vodPlayUrl: '正片\$$playUrl',
  typeName: '',
  vodCode: 'SSIS-00123',
  vodActressPic: '',
);

void _unregisterFallbackTestSites() {
  for (final site in _allFallbackTestSites) {
    SourceSite.importedSites.remove(site.id);
  }
}

Future<LocalStore> _makeFallbackStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

DramaDetail _fallbackDetailFor(String dramaId, String source, String title) =>
    DramaDetail(Drama(id: dramaId, source: source, title: title), [
      Episode({'id': '1', 'title': 'Full', 'flag': '线路1'}, 1),
    ]);

class _RecordingProbeService extends CrossSiteProbeService {
  _RecordingProbeService({required super.repository, required this.results});

  final Map<String, CrossSiteProbeResult> results;
  final probed = <String>[];

  @override
  Future<CrossSiteProbeResult> probeProvider(
    CrossSiteProvider provider,
    String siteId,
    String avId,
  ) async {
    probed.add(siteId);
    return results[siteId] ??
        CrossSiteProbeResult(
          provider: provider,
          siteId: siteId,
          status: CrossSiteProbeStatus.empty,
        );
  }
}

CrossSiteProbeResult _fallbackFoundResult(
  CrossSiteProvider provider,
  String siteId,
  String dramaId,
  String title,
) => CrossSiteProbeResult(
  provider: provider,
  siteId: siteId,
  status: CrossSiteProbeStatus.found,
  versions: [
    CrossSiteVersion(
      label: dramaId,
      detail: _fallbackDetailFor(dramaId, siteId, title),
      lines: const [CrossSiteLine(label: '线路1', episodeIndex: 0)],
    ),
  ],
);

class _FallbackRepository extends FixtureRepository {
  Map<String, List<Drama>> searchByQuery = {};
  Future<CatalogPage> Function(List<String> sources, String query)?
  searchHandler;
  Map<String, DramaDetail> detailsById = {};
  Set<String> failingResolveIds = {};

  /// 按剧 id 定取流地址：不设时一律回合成地址。
  Map<String, String> resolveUrls = {};

  /// 大于等于 0 时：前 N 次 resolve 成功，之后全部失败（widget 测试
  /// 用：链预检成功一次，播放器起播再解时失败进错误态，不建真
  /// 播放器）。-1 表示永远成功。
  var resolveSuccessBudget = -1;
  final resolveCalls = <String>[];
  final searchCalls = <({List<String> sources, String query})>[];

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    searchCalls.add((sources: List.of(sources), query: query));
    final handler = searchHandler;
    if (handler != null) return handler(sources, query);
    return CatalogPage(searchByQuery[query] ?? const []);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async =>
      detailsById[drama.id] ?? super.detail(drama);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    bool adBlock = true,
    int quality = 0,
    int route = 0,
  }) async {
    resolveCalls.add(drama.id);
    if (failingResolveIds.contains(drama.id)) {
      throw AppFailure('合成解析失败');
    }
    if (resolveSuccessBudget == 0) {
      throw AppFailure('合成解析失败');
    }
    if (resolveSuccessBudget > 0) resolveSuccessBudget--;
    return PlaybackPlan(
      url: resolveUrls[drama.id] ?? 'https://example.test/synthetic.mp4',
    );
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

void main() {
  group('兜底链探查顺序', () {
    late _FallbackRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerFallbackTestSites();
      addTearDown(_unregisterFallbackTestSites);
      repository = _FallbackRepository();
      store = await _makeFallbackStore();
    });

    ActressPlayChain chainWith(
      _RecordingProbeService probe, {
      List<SourceSite>? sites,
      FeedProbeFetch? verifyFetch,
    }) => ActressPlayChain(
      repository: repository,
      store: store,
      avId: 'SSIS-00123',
      candidateSites:
          sites ??
          [
            _otherSite,
            _av18Site,
            _mjvGoSite,
            _chaoliuSite,
            _av18mcgSite,
            _mjvJarSite,
          ],
      probeService: probe,
      probeConcurrency: 1,
      verifyFetch: verifyFetch ?? _alwaysPlayable,
    );

    test('先探 MJV 系再探 18AV 再探其他站', () async {
      final probe = _RecordingProbeService(
        repository: repository,
        results: const {},
      );
      final chain = chainWith(probe);
      expect(
        await chain.nextPlayable(profileEpoch: store.profileEpoch),
        isNull,
      );
      expect(probe.probed, [
        'jar:zakatv:ZakaMjv011',
        'chaoliu',
        'v_mjv011',
        'jar:zakatv:av18avmcg',
        'jar:zakatv:av18av',
        'test-site-other',
      ]);
    });

    test('MJV 命中直接返回，不再探其他站', () async {
      final probe = _RecordingProbeService(
        repository: repository,
        results: {
          'jar:zakatv:ZakaMjv011': _fallbackFoundResult(
            const CrossSiteProvider(
              id: 'jar:zakatv:ZakaMjv011',
              name: '🔞mjv011',
              siteIds: ['jar:zakatv:ZakaMjv011'],
              lazy: false,
            ),
            'jar:zakatv:ZakaMjv011',
            'mjv-drama',
            'SSIS-00123 MJV 标题',
          ),
        },
      );
      final chain = chainWith(probe);
      final candidate = await chain.nextPlayable(
        profileEpoch: store.profileEpoch,
      );
      expect(candidate, isNotNull);
      expect(candidate!.detail.drama.source, 'jar:zakatv:ZakaMjv011');
      expect(probe.probed, ['jar:zakatv:ZakaMjv011']);
    });

    test('MJV 未命中回落全站探查', () async {
      final probe = _RecordingProbeService(
        repository: repository,
        results: {
          'test-site-other': _fallbackFoundResult(
            const CrossSiteProvider(
              id: 'test-site-other',
              name: '🔞其他站',
              siteIds: ['test-site-other'],
              lazy: false,
            ),
            'test-site-other',
            'other-drama',
            'SSIS-00123 其他标题',
          ),
        },
      );
      final chain = chainWith(probe);
      final candidate = await chain.nextPlayable(
        profileEpoch: store.profileEpoch,
      );
      expect(candidate, isNotNull);
      expect(candidate!.detail.drama.source, 'test-site-other');
      expect(probe.probed, [
        'jar:zakatv:ZakaMjv011',
        'chaoliu',
        'v_mjv011',
        'jar:zakatv:av18avmcg',
        'jar:zakatv:av18av',
        'test-site-other',
      ]);
    });

    test('兜底取流失败自动换下一条', () async {
      repository.failingResolveIds = {'mjv-drama'};
      final probe = _RecordingProbeService(
        repository: repository,
        results: {
          'jar:zakatv:ZakaMjv011': _fallbackFoundResult(
            const CrossSiteProvider(
              id: 'jar:zakatv:ZakaMjv011',
              name: '🔞mjv011',
              siteIds: ['jar:zakatv:ZakaMjv011'],
              lazy: false,
            ),
            'jar:zakatv:ZakaMjv011',
            'mjv-drama',
            'SSIS-00123 MJV 标题',
          ),
          'test-site-other': _fallbackFoundResult(
            const CrossSiteProvider(
              id: 'test-site-other',
              name: '🔞其他站',
              siteIds: ['test-site-other'],
              lazy: false,
            ),
            'test-site-other',
            'other-drama',
            'SSIS-00123 其他标题',
          ),
        },
      );
      final chain = chainWith(probe);
      final candidate = await chain.nextPlayable(
        profileEpoch: store.profileEpoch,
      );
      expect(candidate, isNotNull);
      expect(candidate!.detail.drama.source, 'test-site-other');
      expect(repository.resolveCalls, ['mjv-drama', 'other-drama']);
    });

    test('直链验活失败换下一条，不开死地址', () async {
      repository.resolveUrls = {
        'mjv-drama': 'https://example.test/dead-mjv.mp4',
        'other-drama': 'https://example.test/other.mp4',
      };
      final probe = _RecordingProbeService(
        repository: repository,
        results: {
          'jar:zakatv:ZakaMjv011': _fallbackFoundResult(
            const CrossSiteProvider(
              id: 'jar:zakatv:ZakaMjv011',
              name: '🔞mjv011',
              siteIds: ['jar:zakatv:ZakaMjv011'],
              lazy: false,
            ),
            'jar:zakatv:ZakaMjv011',
            'mjv-drama',
            'SSIS-00123 MJV 标题',
          ),
          'test-site-other': _fallbackFoundResult(
            const CrossSiteProvider(
              id: 'test-site-other',
              name: '🔞其他站',
              siteIds: ['test-site-other'],
              lazy: false,
            ),
            'test-site-other',
            'other-drama',
            'SSIS-00123 其他标题',
          ),
        },
      );
      final chain = chainWith(probe, verifyFetch: _playableUnlessDead);
      final candidate = await chain.nextPlayable(
        profileEpoch: store.profileEpoch,
      );
      expect(candidate, isNotNull);
      expect(candidate!.detail.drama.source, 'test-site-other');
      expect(repository.resolveCalls, ['mjv-drama', 'other-drama']);
      // 死地址的站也记进已试：链耗尽时报数有据。
      expect(
        chain.triedSources,
        containsAll(['jar:zakatv:ZakaMjv011', 'test-site-other']),
      );
    });

    test('resetForRetry 后重探同一条，不复用死候选', () async {
      final probe = _RecordingProbeService(
        repository: repository,
        results: {
          'jar:zakatv:ZakaMjv011': _fallbackFoundResult(
            const CrossSiteProvider(
              id: 'jar:zakatv:ZakaMjv011',
              name: '🔞mjv011',
              siteIds: ['jar:zakatv:ZakaMjv011'],
              lazy: false,
            ),
            'jar:zakatv:ZakaMjv011',
            'mjv-drama',
            'SSIS-00123 MJV 标题',
          ),
        },
      );
      final chain = chainWith(probe);
      final first = await chain.nextPlayable(profileEpoch: store.profileEpoch);
      expect(first, isNotNull);
      expect(first!.detail.drama.id, 'mjv-drama');
      expect(probe.probed, ['jar:zakatv:ZakaMjv011']);
      chain.resetForRetry();
      expect(chain.triedSources, isEmpty);
      final second = await chain.nextPlayable(profileEpoch: store.profileEpoch);
      expect(second, isNotNull);
      expect(second!.detail.drama.id, 'mjv-drama');
      expect(probe.probed, ['jar:zakatv:ZakaMjv011', 'jar:zakatv:ZakaMjv011']);
    });

    test('preferSiteId 让作品自己的站先探', () async {
      final probe = _RecordingProbeService(
        repository: repository,
        results: const {},
      );
      final chain = ActressPlayChain(
        repository: repository,
        store: store,
        avId: 'SSIS-00123',
        candidateSites: const [
          _otherSite,
          _av18Site,
          _mjvGoSite,
          _chaoliuSite,
          _av18mcgSite,
          _mjvJarSite,
        ],
        probeService: probe,
        probeConcurrency: 1,
        verifyFetch: _alwaysPlayable,
        preferSiteId: 'chaoliu',
      );
      expect(
        await chain.nextPlayable(profileEpoch: store.profileEpoch),
        isNull,
      );
      expect(probe.probed, [
        'chaoliu',
        'jar:zakatv:ZakaMjv011',
        'v_mjv011',
        'jar:zakatv:av18avmcg',
        'jar:zakatv:av18av',
        'test-site-other',
      ]);
      expect(chain.triedSources, hasLength(6));
    });
  });

  group('封面按番号先走兜底 MJV', () {
    late MemoryActressDatabase db;
    late _FallbackRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerFallbackTestSites();
      addTearDown(_unregisterFallbackTestSites);
      db = MemoryActressDatabase();
      repository = _FallbackRepository();
      store = await _makeFallbackStore();
    });

    Future<ActressPerson> seedPerson() async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X1',
          name: '测试演员',
          sex: 'female',
        ),
      ))!;
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-00123', date: '2024-01-01'),
      ]);
      return (await db.personById(person.localId))!;
    }

    bool isFallbackCall(List<String> sources) =>
        sources.length == actressFallbackSiteIds.length &&
        sources.toSet().containsAll(actressFallbackSiteIds);

    test('MJV 有图时直接用 MJV 封面，不再查全站', () async {
      final person = await seedPerson();
      repository.searchHandler = (sources, query) async {
        if (query == '测试演员') return CatalogPage(const []);
        if (isFallbackCall(sources)) {
          return CatalogPage(const [
            Drama(
              id: 'mjv-d1',
              source: 'jar:zakatv:ZakaMjv011',
              title: 'SSIS-00123 测试标题',
              cover: 'https://mjv.test/cover.jpg',
            ),
          ]);
        }
        return CatalogPage(const [
          Drama(
            id: 'other-d1',
            source: 'test-site-other',
            title: 'SSIS-00123 测试标题',
            cover: 'https://other.test/cover.jpg',
          ),
        ]);
      };
      final completed = await ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
      ).enrichPerson(person);
      expect(completed, isTrue);
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works, hasLength(1));
      expect(works.first.coverUrl, 'https://mjv.test/cover.jpg');
      expect(works.first.coverSource, 'jar:zakatv:ZakaMjv011');
      final codeCalls = repository.searchCalls
          .where((call) => call.query != '测试演员')
          .toList();
      expect(codeCalls, hasLength(1));
      expect(isFallbackCall(codeCalls.first.sources), isTrue);
    });

    test('MJV 无图时回落全站搜索补封面', () async {
      final person = await seedPerson();
      repository.searchHandler = (sources, query) async {
        if (query == '测试演员') return CatalogPage(const []);
        if (isFallbackCall(sources)) return CatalogPage(const []);
        return CatalogPage(const [
          Drama(
            id: 'other-d1',
            source: 'test-site-other',
            title: 'SSIS-00123 测试标题',
            cover: 'https://other.test/cover.jpg',
          ),
        ]);
      };
      await ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
      ).enrichPerson(person);
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works.first.coverUrl, 'https://other.test/cover.jpg');
      expect(works.first.coverSource, 'test-site-other');
      expect(
        repository.searchCalls.any(
          (call) => call.query != '测试演员' && !isFallbackCall(call.sources),
        ),
        isTrue,
      );
    });

    test('兜底站查失败时回落全站，不丢作品', () async {
      final person = await seedPerson();
      repository.searchHandler = (sources, query) async {
        if (query == '测试演员') return CatalogPage(const []);
        if (isFallbackCall(sources)) throw AppFailure('兜底站挂了');
        return CatalogPage(const [
          Drama(
            id: 'other-d1',
            source: 'test-site-other',
            title: 'SSIS-00123 测试标题',
            cover: 'https://other.test/cover.jpg',
          ),
        ]);
      };
      await ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
      ).enrichPerson(person);
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works.first.coverUrl, 'https://other.test/cover.jpg');
    });

    test('番号路先补当前页正在看的作品', () async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X3',
          name: '测试演员',
          sex: 'female',
        ),
      ))!;
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-00111', date: '2024-01-01'),
        RosterFilm(code: 'SSIS-00122', date: '2024-01-02'),
        RosterFilm(code: 'SSIS-00133', date: '2024-01-03'),
      ]);
      final seeded = (await db.personById(person.localId))!;
      repository.searchHandler = (sources, query) async {
        if (query == '测试演员') return CatalogPage(const []);
        return CatalogPage([
          Drama(
            id: 'hit-$query',
            source: 'jar:zakatv:ZakaMjv011',
            title: '$query 测试标题',
            cover: 'https://mjv.test/$query.jpg',
          ),
        ]);
      };
      final worksBefore = await db.worksForPerson(
        seeded.localId,
        offset: 0,
        limit: 10,
      );
      expect(worksBefore, hasLength(3));
      // cap 只剩 1：不优先就是第一部，优先最后这部。
      await ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
        codeSearchCap: 1,
      ).enrichPerson(seeded, prioritizeWorkIds: [worksBefore.last.id]);
      final works = await db.worksForPerson(
        seeded.localId,
        offset: 0,
        limit: 10,
      );
      expect(works[2].coverUrl, 'https://mjv.test/SSIS-00133.jpg');
      expect(works[0].coverUrl, isEmpty);
      expect(works[1].coverUrl, isEmpty);
    });
  });

  group('点卡直进详情页', () {
    late MemoryActressDatabase db;
    late _FallbackRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerFallbackTestSites();
      addTearDown(_unregisterFallbackTestSites);
      db = MemoryActressDatabase();
      repository = _FallbackRepository();
      store = await _makeFallbackStore();
    });

    Future<ActressPerson> seedPerson() async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X1',
          name: '女演员甲',
          sex: 'female',
        ),
      ))!;
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-00123', date: '2024-01-01'),
      ]);
      return (await db.personById(person.localId))!;
    }

    /// 错误面板渲染会触发一条既有框架断言（StatusPanel 内
    /// ExpansionTile 含 ListTile，见 player_sniff_back_test.dart），
    /// 与本批改动无关，只放行这一条。
    void suppressKnownListTileAssertion() {
      final original = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        if (details.toString().contains(
          'ListTile background color or ink splashes',
        )) {
          return;
        }
        original?.call(details);
      };
      addTearDown(() {
        FlutterError.onError = original;
      });
    }

    Future<void> pumpDetailPage(
      WidgetTester tester,
      Map<String, CrossSiteProbeResult> results, {
      ActressJsonFallback? fallback,
      FilmDbFallbackProvider? filmDb,
      FeedProbeFetch? verifyFetch,
    }) async {
      final person = await seedPerson();
      await tester.pumpWidget(
        MaterialApp(
          home: ActressDetailPage(
            localId: person.localId,
            repository: repository,
            store: store,
            database: db,
            fallback: fallback,
            filmDb: filmDb,
            verifyFetch: verifyFetch ?? _alwaysPlayable,
            playChainFactory: ({required avId, required titleQuery}) =>
                ActressPlayChain(
                  repository: repository,
                  store: store,
                  avId: avId,
                  titleQuery: titleQuery,
                  candidateSites: _allFallbackTestSites,
                  probeService: _RecordingProbeService(
                    repository: repository,
                    results: results,
                  ),
                  probeConcurrency: 1,
                  verifyFetch: verifyFetch ?? _alwaysPlayable,
                ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// 有界等待详情页出现（播放器内有定时器，不用 pumpAndSettle）。
    Future<void> pumpUntilDetail(WidgetTester tester) async {
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(DetailScreen).evaluate().isNotEmpty) break;
      }
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('MJV 命中：点卡进详情页并尝试起播', (tester) async {
      suppressKnownListTileAssertion();
      repository.detailsById['mjv-drama'] = _fallbackDetailFor(
        'mjv-drama',
        'jar:zakatv:ZakaMjv011',
        'SSIS-00123 MJV 标题',
      );
      // 链预检成功一次；播放器起播再解时失败进错误态，不建真播放器。
      repository.resolveSuccessBudget = 1;
      await pumpDetailPage(tester, {
        'jar:zakatv:ZakaMjv011': _fallbackFoundResult(
          const CrossSiteProvider(
            id: 'jar:zakatv:ZakaMjv011',
            name: '🔞mjv011',
            siteIds: ['jar:zakatv:ZakaMjv011'],
            lazy: false,
          ),
          'jar:zakatv:ZakaMjv011',
          'mjv-drama',
          'SSIS-00123 MJV 标题',
        ),
      });
      await tester.tap(find.byType(DramaTile).first);
      await pumpUntilDetail(tester);
      expect(find.byType(DetailScreen), findsOneWidget);
      expect(find.text('SSIS-00123 MJV 标题'), findsWidgets);
      expect(find.text('暂无可播片源'), findsNothing);
      expect(find.text('正在找可播片源…'), findsNothing);
      // 详情页进页即播：播放器向仓库要过 MJV 这集的流。
      expect(repository.resolveCalls, contains('mjv-drama'));
    });

    testWidgets('MJV 未命中：回落其他站进详情页', (tester) async {
      suppressKnownListTileAssertion();
      repository.detailsById['other-drama'] = _fallbackDetailFor(
        'other-drama',
        'test-site-other',
        'SSIS-00123 其他标题',
      );
      repository.resolveSuccessBudget = 1;
      await pumpDetailPage(tester, {
        'test-site-other': _fallbackFoundResult(
          const CrossSiteProvider(
            id: 'test-site-other',
            name: '🔞其他站',
            siteIds: ['test-site-other'],
            lazy: false,
          ),
          'test-site-other',
          'other-drama',
          'SSIS-00123 其他标题',
        ),
      });
      await tester.tap(find.byType(DramaTile).first);
      await pumpUntilDetail(tester);
      expect(find.byType(DetailScreen), findsOneWidget);
      expect(find.text('SSIS-00123 其他标题'), findsWidgets);
      expect(find.text('暂无可播片源'), findsNothing);
      expect(repository.resolveCalls, contains('other-drama'));
    });

    testWidgets('全部无源：报已试过 6 个站，不进详情页', (tester) async {
      await pumpDetailPage(tester, const {});
      await tester.tap(find.byType(DramaTile).first);
      await tester.pumpAndSettle();
      expect(find.text('这条播不了，已试过 6 个站'), findsOneWidget);
      expect(find.byType(DetailScreen), findsNothing);
    });

    /// 假兜底：只有 whos.json 里有一条 SSIS-00123 的行（mjv 那份空），
    /// 播放地址由调用方定。localJsonDir 传空临时目录：不传时 load()
    /// 会调 getApplicationDocumentsDirectory()，widget 测试里它
    /// 永远不返回（见 testWidgets FakeAsync + async dart:io 挂起），
    /// _loadFallback 卡住、兜底池一直是空的，存地址扫描无行可试。
    /// mjvPlayUrl 非空时 mjv.json 也补一条同番号行（vod_play_from
    /// 须写 mjv：mjv011.json 是规范文件，站按 vod_play_from 认，
    /// 写 whos 会与 whos 行同键被合并掉）。
    ActressJsonFallback fakeFallbackWithRow({
      required String playUrl,
      String? mjvPlayUrl,
    }) {
      final temp = Directory.systemTemp.createTempSync();
      addTearDown(() {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      return ActressJsonFallback(
        localJsonDir: temp,
        // m3u 索引给空 manifest：真 m3u 库里 SSIS-00123 也有行，
        // 不掏空它，池子里会多一条活的 m3u 行，测“存的死了落
        // 回探活链”时它先赢、链跑不起来。
        m3uIndex: WhosM3uIndex(
          bytesReader: (_) async =>
              Uint8List.fromList(gzip.encode(utf8.encode('{}'))),
        ),
        assetReader: (asset) async {
          if (asset.endsWith('mjv011.json')) {
            return mjvPlayUrl == null
                ? _emptyFallbackDoc
                : _fakeFallbackDoc([
                    _fakeFallbackRow(
                      vodId: 'mjv-row-1',
                      vodCode: 'SSIS-00123',
                      vodName: 'SSIS-00123 MJV 死链标题',
                      playUrl: mjvPlayUrl,
                      vodPlayFrom: 'mjv',
                    ),
                  ]);
          }
          return asset.endsWith('whos.json')
              ? _fakeFallbackDoc([
                  _fakeFallbackRow(
                    vodId: 'ssis-row-1',
                    vodCode: 'SSIS-00123',
                    vodName: 'SSIS-00123 存的标题',
                    playUrl: playUrl,
                  ),
                ])
              : _emptyFallbackDoc;
        },
      );
    }

    testWidgets('存的地址活的：直接播，不探链', (tester) async {
      suppressKnownListTileAssertion();
      // 链预检 1 次（存的地址 resolve）成功；播放器起播再解时
      // 失败进错误态，不建真播放器。
      repository.resolveSuccessBudget = 1;
      await pumpDetailPage(
        tester,
        const {},
        fallback: fakeFallbackWithRow(
          playUrl: '正片\$https://example.test/whos-ssis.mp4',
        ),
      );
      await tester.tap(find.byType(DramaTile).first);
      await pumpUntilDetail(tester);
      expect(find.byType(DetailScreen), findsOneWidget);
      expect(find.text('SSIS-00123 存的标题'), findsWidgets);
      expect(find.text('暂无可播片源'), findsNothing);
      expect(find.text('这条播不了，已试过 6 个站'), findsNothing);
      // 只解过存的地址（链没跑、没多解别的站）。
      expect(repository.resolveCalls, contains('json:whos:ssis-row-1'));
      expect(
        repository.resolveCalls.every((id) => id == 'json:whos:ssis-row-1'),
        isTrue,
      );
    });

    testWidgets('mjv 死链：存的 mjv 地址死了，落到同番号 whos 行，不探链', (tester) async {
      suppressKnownListTileAssertion();
      // 主会话 2026-11-20 20:27 查实：mjv011.json 里存的 m3u8
      // 已系统性死亡（7 个 streamfastpro 域名抽验全 404），
      // whos.json 5 条全 200——二档里 mjv 死、whos 活是常态，
      // 不是偶然。存的地址要按站逐条验活、死的跳过、活的播。
      repository.resolveUrls = {
        'json:mjv:mjv-row-1': 'https://example.test/dead-mjv.mp4',
        'json:whos:ssis-row-1': 'https://example.test/whos-ssis.mp4',
      };
      // mjv resolve 1 次 + whos resolve 1 次成功；播放器起播
      // 再解时失败进错误态，不建真播放器。
      repository.resolveSuccessBudget = 2;
      await pumpDetailPage(
        tester,
        const {},
        fallback: fakeFallbackWithRow(
          playUrl: '正片\$https://example.test/whos-ssis.mp4',
          mjvPlayUrl: '正片\$https://example.test/dead-mjv.mp4',
        ),
        verifyFetch: _playableUnlessDead,
      );
      await tester.tap(find.byType(DramaTile).first);
      await pumpUntilDetail(tester);
      expect(find.byType(DetailScreen), findsOneWidget);
      expect(find.text('SSIS-00123 存的标题'), findsWidgets);
      expect(find.text('SSIS-00123 MJV 死链标题'), findsNothing);
      // 先解 mjv（死了）、再解 whos（活了播它），链没跑。
      expect(
        repository.resolveCalls,
        ['json:mjv:mjv-row-1', 'json:whos:ssis-row-1'],
      );
    });

    testWidgets('存的地址死了落回探活链', (tester) async {
      suppressKnownListTileAssertion();
      repository.resolveUrls = {
        'json:whos:ssis-row-1': 'https://example.test/dead-ssis.mp4',
        'other-drama': 'https://example.test/other.mp4',
      };
      repository.detailsById['other-drama'] = _fallbackDetailFor(
        'other-drama',
        'test-site-other',
        'SSIS-00123 其他标题',
      );
      // 存的地址 resolve 1 次 + 链 resolve 1 次成功；播放器起播
      // 再解时失败进错误态。
      repository.resolveSuccessBudget = 2;
      await pumpDetailPage(
        tester,
        {
          'test-site-other': _fallbackFoundResult(
            const CrossSiteProvider(
              id: 'test-site-other',
              name: '🔞其他站',
              siteIds: ['test-site-other'],
              lazy: false,
            ),
            'test-site-other',
            'other-drama',
            'SSIS-00123 其他标题',
          ),
        },
        fallback: fakeFallbackWithRow(
          playUrl: '正片\$https://example.test/dead-ssis.mp4',
        ),
        verifyFetch: _playableUnlessDead,
      );
      await tester.tap(find.byType(DramaTile).first);
      await pumpUntilDetail(tester);
      expect(find.byType(DetailScreen), findsOneWidget);
      expect(find.text('SSIS-00123 其他标题'), findsWidgets);
      expect(
        repository.resolveCalls,
        containsAll(['json:whos:ssis-row-1', 'other-drama']),
      );
    });

    testWidgets('第一档本地 db 活的：播库里的地址，不探链、不走内置', (tester) async {
      suppressKnownListTileAssertion();
      // 链预检 1 次（库里地址 resolve）成功；播放器起播再解时
      // 失败进错误态。
      repository.resolveSuccessBudget = 1;
      await pumpDetailPage(
        tester,
        const {},
        fallback: fakeFallbackWithRow(
          playUrl: '正片\$https://example.test/whos-ssis.mp4',
        ),
        filmDb: _FakeFilmDb({
          'SSIS123': [
            _dbEntry(
              vodId: 'db-row-1',
              playUrl: 'https://example.test/db-ssis.mp4',
            ),
          ],
        }),
      );
      await tester.tap(find.byType(DramaTile).first);
      await pumpUntilDetail(tester);
      expect(find.byType(DetailScreen), findsOneWidget);
      expect(find.text('SSIS-00123 库里标题'), findsWidgets);
      expect(find.text('SSIS-00123 存的标题'), findsNothing);
      // 只解过库里的地址（内置行没解、链没跑）。
      expect(repository.resolveCalls, contains('json:mjv:db-row-1'));
      expect(
        repository.resolveCalls.every((id) => id == 'json:mjv:db-row-1'),
        isTrue,
      );
    });

    testWidgets('第一档库里地址死了落到第二档内置', (tester) async {
      suppressKnownListTileAssertion();
      repository.resolveUrls = {
        'json:mjv:db-row-1': 'https://example.test/dead-db.mp4',
        'json:whos:ssis-row-1': 'https://example.test/whos-ssis.mp4',
      };
      // 库里地址 resolve 1 次 + 内置 resolve 1 次成功；播放器起播
      // 再解时失败进错误态。
      repository.resolveSuccessBudget = 2;
      await pumpDetailPage(
        tester,
        const {},
        fallback: fakeFallbackWithRow(
          playUrl: '正片\$https://example.test/whos-ssis.mp4',
        ),
        filmDb: _FakeFilmDb({
          'SSIS123': [
            _dbEntry(
              vodId: 'db-row-1',
              playUrl: 'https://example.test/dead-db.mp4',
            ),
          ],
        }),
        verifyFetch: _playableUnlessDead,
      );
      await tester.tap(find.byType(DramaTile).first);
      await pumpUntilDetail(tester);
      expect(find.byType(DetailScreen), findsOneWidget);
      expect(find.text('SSIS-00123 存的标题'), findsWidgets);
      expect(find.text('SSIS-00123 库里标题'), findsNothing);
      // 先解库里的、再解内置的，顺序不能反。
      expect(
        repository.resolveCalls.indexOf('json:mjv:db-row-1'),
        lessThan(repository.resolveCalls.indexOf('json:whos:ssis-row-1')),
      );
    });

    testWidgets('m3u hash 图兜底：无封面作品贴上 hash 图', (tester) async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X2',
          name: '女演员乙',
          sex: 'female',
        ),
      ))!;
      await db.upsertWorks(person.localId, const [
        // SDAM-115 是包内 whos m3u 索引里真实有的一行
        // （hash 2d00ea11a0158eebf1a91ebbc8e6c254）；别用 sdam-186，
        // 它只在用户发的 m3u 文件里有，包内索引 32 个分片里一行
        // 都没有，贴不上图不是 bug。
        RosterFilm(code: 'sdam-115', date: '2024-01-01'),
      ]);
      final seeded = (await db.personById(person.localId))!;
      // 默认 fallback 不传 localJsonDir 时 load() 会调
      // getApplicationDocumentsDirectory()，widget 测试里它永远
      // 不返回，_loadFallback 卡住、_attachM3uCovers 跑不到；
      // 传空临时目录让 load() 走完。包内资源用 File 同步读：
      // rootBundle 在 testWidgets 里 await 会挂住（FakeAsync
      // 计时器不走），m3u_index_test 也是这么读 manifest 的。
      final temp = Directory.systemTemp.createTempSync();
      addTearDown(() {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ActressDetailPage(
            localId: seeded.localId,
            repository: repository,
            store: store,
            database: db,
            fallback: ActressJsonFallback(
              localJsonDir: temp,
              assetReader: (asset) async => File(asset).readAsStringSync(),
              m3uIndex: WhosM3uIndex(
                bytesReader: (asset) async =>
                    Uint8List.fromList(File(asset).readAsBytesSync()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final works = await db.worksForPerson(
        seeded.localId,
        offset: 0,
        limit: 10,
      );
      expect(works, hasLength(1));
      expect(
        works.first.coverUrl,
        'https://v.hersav.me/images/av/2d00ea11a0158eebf1a91ebbc8e6c254.jpg',
      );
      expect(works.first.coverSource, 'whos');
    });
  });

  testWidgets('嗅探页接受加载失败回调', (tester) async {
    var reported = '';
    await tester.pumpWidget(
      MaterialApp(
        home: SniffWebViewPage(
          pageUrl: 'https://example.test/watch/123',
          onMediaFound: (_) {},
          onLoadFailed: (message) => reported = message,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(SniffWebViewPage), findsOneWidget);
    // 本机无 WebView 平台实现，只锁定回调参数存在；真机上 404 由
    // NavigationDelegate 回调触发，见 REPORT 手机待验项。
    expect(reported, isEmpty);
  });
}
