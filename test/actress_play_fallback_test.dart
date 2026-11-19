import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_detail_page.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_play.dart';
import 'package:moyi/actress/actress_search.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/crosssite_probe.dart';
import 'package:moyi/detail_screen.dart';
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
    return const PlaybackPlan(url: 'https://example.test/synthetic.mp4');
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
          (call) =>
              call.query != '测试演员' && !isFallbackCall(call.sources),
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
        if (details
            .toString()
            .contains('ListTile background color or ink splashes')) {
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
      Map<String, CrossSiteProbeResult> results,
    ) async {
      final person = await seedPerson();
      await tester.pumpWidget(
        MaterialApp(
          home: ActressDetailPage(
            localId: person.localId,
            repository: repository,
            store: store,
            database: db,
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

    testWidgets('全部无源：报暂无可播片源，不进详情页', (tester) async {
      await pumpDetailPage(tester, const {});
      await tester.tap(find.byType(DramaTile).first);
      await tester.pumpAndSettle();
      expect(find.text('暂无可播片源'), findsOneWidget);
      expect(find.byType(DetailScreen), findsNothing);
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
