// 女优作品卡片列表修复（2026-11-19）：
// ① 同步时取 MissAV 封面 + 按来源站写 coverSource；
// ② 补封面流式 + 番号路墙钟上限；
// ③ 点作品卡快路径直取详情进页；
// ④ 探活链总预算内收敛；
// ⑤ MissAV 女优 folder 详情画作品卡片网格（多部与单部都不退回选集）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_detail_page.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_play.dart';
import 'package:moyi/actress/actress_roster_sources.dart';
import 'package:moyi/actress/actress_search.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/crosssite_probe.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/feed_playability.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

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

const _missavSite = SourceSite(
  'jar:missav30:ZakaMissav',
  '🔞MissAV',
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
const _coverSite = SourceSite(
  'test-cover-a',
  '🔞测试站A',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);

void _registerCardsTestSites() {
  for (final site in [_missavSite, _otherSite, _coverSite]) {
    SourceSite.importedSites[site.id] = site;
  }
}

void _unregisterCardsTestSites() {
  for (final site in [_missavSite, _otherSite, _coverSite]) {
    SourceSite.importedSites.remove(site.id);
  }
}

Future<LocalStore> _makeCardsStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

/// 本批测试共用的假仓：详情/目录/搜索均可脚本化；封面返回空
/// （卡片形态不断言真图，只断言卡片与网格本身）。
class _CardsRepository extends FixtureRepository {
  Map<String, DramaDetail> detailsById = {};
  final detailIds = <String>[];
  Map<String, List<Drama>> catalogByCategory = {};
  var catalogFail = false;
  final catalogCategories = <String>[];
  Map<String, List<Drama>> searchByQuery = {};
  final searchQueries = <String>[];
  Duration searchDelay = Duration.zero;
  Set<String> delayedQueries = {};

  /// 流式搜索注入：不设时走默认实现（批回 searchAcross 再按站拆开）。
  Future<void> Function(
    List<String> sources,
    String query, {
    required void Function(String source, List<Drama> items) onSite,
    bool Function()? shouldStop,
  })?
  progressiveHandler;

  @override
  Future<void> searchAcrossProgressive(
    List<String> sources,
    String query, {
    required void Function(String source, List<Drama> items) onSite,
    bool Function()? shouldStop,
  }) async {
    final handler = progressiveHandler;
    if (handler != null) {
      return handler(sources, query, onSite: onSite, shouldStop: shouldStop);
    }
    return super.searchAcrossProgressive(
      sources,
      query,
      onSite: onSite,
      shouldStop: shouldStop,
    );
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    detailIds.add(drama.id);
    return detailsById[drama.id] ?? super.detail(drama);
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
    catalogCategories.add(category);
    if (catalogFail) throw AppFailure('合成目录失败');
    final items = catalogByCategory[category] ?? const [];
    return CatalogPage(items, hasMore: false, page: page);
  }

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    searchQueries.add(query);
    if (delayedQueries.contains(query)) {
      await Future.delayed(searchDelay);
    }
    return CatalogPage(searchByQuery[query] ?? const []);
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

/// resolve 永远不回的仓库（秒进测试用）：模拟竞速两路都被拖住，
/// 证明点卡开页不等竞速。返回一个永远不完成的 Future，超时计时器
/// 由调用方的 .timeout 负责。
class _NeverResolveRepository extends _CardsRepository {
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    bool adBlock = true,
    int quality = 0,
    int route = 0,
  }) {
    return Completer<PlaybackPlan>().future;
  }
}

DramaDetail _cardsDetailFor(String dramaId, String source, String title) =>
    DramaDetail(Drama(id: dramaId, source: source, title: title), [
      Episode({'id': '1', 'title': 'Full', 'flag': '线路1'}, 1),
    ]);

/// 假影视库 db：按番号回库里行（2026-11-22 只走数据库：点卡只试
/// 这些行，不再走封面站记下的详情 id、也不跨站探活）。
class _CardsFilmDb implements FilmDbFallbackProvider {
  _CardsFilmDb(this.rowsByCode);

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

void main() {
  group('同步时取 MissAV 封面', () {
    test('parseMissavFilms 取出封面与详情地址', () {
      const html = '''
<div class="grid relative">
  <a href="/dm16/cn/ssis00123"><img class="lozad" alt="SSIS-00123 测试标题" data-src="https://cdn.example.com/cover1.jpg"></a>
</div>
<div class="grid relative">
  <a href="/dm16/cn/abw00456"><img class="lozad" alt="ABW-456 另一部" src="https://cdn.example.com/cover2.jpg"></a>
</div>
<div class="grid relative">
  <a href="/dm16/cn/fc2ppv7890123"><img class="lozad" alt="FC2-PPV-7890123 第三部" data-srcset="https://cdn.example.com/cover3.jpg 100w, https://cdn.example.com/cover3b.jpg 200w"></a>
</div>
<div class="grid relative">
  <a href="/dm16/cn/nocover"><img class="lozad" alt="SSIS-00999 无图的一部"></a>
</div>
''';
      final films = parseMissavFilms(html);
      expect(films, hasLength(4));
      expect(films[0].code, 'SSIS-00123');
      expect(films[0].coverUrl, 'https://cdn.example.com/cover1.jpg');
      expect(films[0].detailUrl, '/dm16/cn/ssis00123');
      // src 回落。
      expect(films[1].coverUrl, 'https://cdn.example.com/cover2.jpg');
      expect(films[1].detailUrl, '/dm16/cn/abw00456');
      // data-srcset 只取首个地址。
      expect(films[2].coverUrl, 'https://cdn.example.com/cover3.jpg');
      expect(films[2].detailUrl, '/dm16/cn/fc2ppv7890123');
      // 无图地址时两字段为空，不影响标题与番号。
      expect(films[3].code, 'SSIS-00999');
      expect(films[3].coverUrl, isEmpty);
      expect(films[3].detailUrl, '/dm16/cn/nocover');
    });

    test('upsertWorks 按来源站写封面：MissAV 有封面、whos 语义不变', () async {
      final db = MemoryActressDatabase();
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.missav,
          sourceId: '/dm16/cn/actresses/x',
          name: '测试女优',
        ),
      ))!;
      final id = person.localId;
      await db.upsertWorks(id, const [
        RosterFilm(
          code: 'SSIS-00123',
          coverUrl: 'https://cdn.example.com/c1.jpg',
          detailUrl: '/dm16/cn/ssis00123',
        ),
        RosterFilm(code: 'SSIS-00124'),
      ], coverSource: actressRosterCoverSource(ActressRosterSourceId.missav));
      var works = await db.worksForPerson(id, offset: 0, limit: 100);
      final missav = works.firstWhere((w) => w.codeDisplay == 'SSIS-00123');
      expect(missav.hasCover, isTrue);
      expect(missav.coverSource, 'jar:missav30:ZakaMissav');
      expect(missav.coverDramaId, '/dm16/cn/ssis00123');
      expect(missav.coverUrl, 'https://cdn.example.com/c1.jpg');
      // whos 默认：不传来源参数仍记 whos；无封面的仍全空。
      await db.upsertWorks(id, const [
        RosterFilm(
          code: 'MIAD-854',
          coverUrl: 'https://cdn.example.com/c.jpg',
          detailUrl: '/videos/miad-854',
        ),
        RosterFilm(code: 'MIAD-855'),
      ]);
      works = await db.worksForPerson(id, offset: 0, limit: 100);
      final whos = works.firstWhere((w) => w.codeDisplay == 'MIAD-854');
      expect(whos.coverSource, 'whos');
      expect(whos.hasCover, isTrue);
      final plain = works.firstWhere((w) => w.codeDisplay == 'MIAD-855');
      expect(plain.hasCover, isFalse);
      // 来源站为空：有封面地址也不认站源、不写封面。
      await db.upsertWorks(id, const [
        RosterFilm(
          code: 'ABC-999',
          coverUrl: 'https://cdn.example.com/c9.jpg',
          detailUrl: '/x',
        ),
      ], coverSource: '');
      works = await db.worksForPerson(id, offset: 0, limit: 100);
      final dropped = works.firstWhere((w) => w.codeDisplay == 'ABC-999');
      expect(dropped.hasCover, isFalse);
      expect(dropped.coverSource, isEmpty);
    });
  });

  group('补封面提速', () {
    late MemoryActressDatabase db;
    late _CardsRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerCardsTestSites();
      addTearDown(_unregisterCardsTestSites);
      db = MemoryActressDatabase();
      repository = _CardsRepository();
      store = await _makeCardsStore();
    });

    Future<ActressPerson> seedPersonWithWorks(List<RosterFilm> films) async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X1',
          name: '测试女优',
          sex: 'female',
        ),
      ))!;
      await db.upsertWorks(person.localId, films);
      return (await db.personById(person.localId))!;
    }

    test('名字路流式：首站结果一到就贴封面，不等整轮', () async {
      final person = await seedPersonWithWorks(const [
        RosterFilm(code: 'SSIS-00123', date: '2024-01-01'),
        RosterFilm(code: 'ABW-00456', date: '2024-01-02'),
      ]);
      // 假流式：先报 A 站命中，停 50ms 后再报 B 站；断言 A 站
      // 的封面在 B 站到达前已经落库。
      var attachedAfterFirstSite = false;
      repository.progressiveHandler =
          (sources, query, {required onSite, shouldStop}) async {
            onSite('test-cover-a', [
              const Drama(
                id: 'a-ssis',
                source: 'test-cover-a',
                title: 'SSIS-00123 测试标题',
                cover: 'https://cover/a.jpg',
              ),
            ]);
            await Future.delayed(const Duration(milliseconds: 50));
            final works = await db.worksForPerson(
              person.localId,
              offset: 0,
              limit: 100,
            );
            attachedAfterFirstSite = works
                .firstWhere((w) => w.codeDisplay == 'SSIS-00123')
                .hasCover;
            onSite('test-cover-a', [
              const Drama(
                id: 'a-abw',
                source: 'test-cover-a',
                title: 'ABW-00456 测试标题',
                cover: 'https://cover/b.jpg',
              ),
            ]);
          };
      final completed = await ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
      ).enrichPerson(person);
      expect(completed, isTrue);
      expect(attachedAfterFirstSite, isTrue);
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 100,
      );
      expect(
        works.firstWhere((w) => w.codeDisplay == 'ABW-00456').hasCover,
        isTrue,
      );
    });

    test('番号路墙钟上限：超时不再起跑新作品，本轮记未完成', () async {
      final films = [
        for (var i = 0; i < 12; i++)
          RosterFilm(code: 'SSIS-00${100 + i}', date: '2024-01-01'),
      ];
      final person = await seedPersonWithWorks(films);
      // 名字路无命中（搜不到），番号路每部作品搜一次、每次 2 秒
      // （兜底站一段 + 全站一段）；并发 6、墙钟上限 500ms：
      // 第一批 6 部跑完即停，剩下 6 部不再起跑，本轮返回未完成。
      repository.searchDelay = const Duration(seconds: 2);
      repository.delayedQueries = {for (final film in films) film.code};
      final enrichment = ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
        codeRoundBudget: const Duration(milliseconds: 500),
      );
      final stopwatch = Stopwatch()..start();
      final completed = await enrichment.enrichPerson(person);
      stopwatch.stop();
      expect(completed, isFalse);
      // 12 部里只起跑了第一批 6 部（去重后的番号查询数）；
      // 兜底站与全站两段搜索会让同一番号出现两次，不按调用次数计。
      final codeQueries = repository.searchQueries
          .where((q) => q.startsWith('SSIS-'))
          .toSet();
      expect(codeQueries.length, 6);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
    });
  });

  group('点作品卡快路径', () {
    late MemoryActressDatabase db;
    late _CardsRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerCardsTestSites();
      addTearDown(_unregisterCardsTestSites);
      db = MemoryActressDatabase();
      repository = _CardsRepository();
      store = await _makeCardsStore();
    });

    testWidgets('有封面的作品点卡走库里地址进详情页播，不弹找片遮罩', (tester) async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X1',
          name: '女演员甲',
          sex: 'female',
        ),
      ))!;
      await db.upsertWorks(person.localId, const [
        RosterFilm(
          code: 'SSIS-00123',
          coverUrl: 'https://cover/x.jpg',
          detailUrl: 'other-drama',
        ),
      ], coverSource: 'test-site-other');
      // 2026-11-22 只走数据库：点卡只试库里这行（番号 SSIS-00123
      // 的直链），不再走封面站记下的详情 id、也不建探活链；库里
      // 行的剧 id 是 toDramaDetail 拼出的 'json:站:vodId'，详情
      // 仓按这个 id 备好详情。
      repository.detailsById['json:test-site-other:other-drama'] =
          _cardsDetailFor(
            'json:test-site-other:other-drama',
            'test-site-other',
            'SSIS-00123 其他标题',
          );
      await tester.pumpWidget(
        MaterialApp(
          home: ActressDetailPage(
            localId: person.localId,
            repository: repository,
            store: store,
            database: db,
            filmDb: _CardsFilmDb({
              'SSIS123': [
                ActressJsonEntry(
                  site: 'test-site-other',
                  vodId: 'other-drama',
                  vodName: 'SSIS-00123 其他标题',
                  vodPic: '',
                  vodActor: '女演员甲',
                  vodDirector: '',
                  vodRemarks: '',
                  vodPubdate: '',
                  vodArea: '',
                  vodYear: '',
                  vodContent: '',
                  vodPlayFrom: 'test-site-other',
                  vodPlayUrl: '正片\$https://example.test/other.mp4',
                  typeName: '',
                  vodCode: 'SSIS-00123',
                  vodActressPic: '',
                ),
              ],
            }),
            verifyFetch: _alwaysPlayable,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DramaTile).first);
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(DetailScreen).evaluate().isNotEmpty) break;
      }
      expect(find.byType(DetailScreen), findsOneWidget);
      expect(find.text('SSIS-00123 其他标题'), findsWidgets);
      expect(find.text('正在找可播片源…'), findsNothing);
      expect(find.text('暂无可播片源'), findsNothing);
      // 点卡走的是库里那行：详情页向仓库要过库里行的剧。
      expect(
        repository.detailIds,
        contains('json:test-site-other:other-drama'),
      );
    });

    testWidgets('点卡秒进：竞速 resolve 永远不回，详情页仍在 1 秒内打开', (tester) async {
      // 2026-11-24 秒进改法：点卡即推详情页播首条库地址，不等竞速。
      // resolve 永远不回，模拟竞速两路都被拖住——旧流程要等 resolve
      // 8 秒超时 × 3 条（约 24 秒）才开页；新流程点卡即开页。
      repository = _NeverResolveRepository();
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'X1',
          name: '女演员甲',
          sex: 'female',
        ),
      ))!;
      await db.upsertWorks(person.localId, const [
        RosterFilm(
          code: 'SSIS-00123',
          coverUrl: 'https://cover/x.jpg',
          detailUrl: 'other-drama',
        ),
      ], coverSource: 'test-site-other');
      repository.detailsById['json:test-site-other:other-drama'] =
          _cardsDetailFor(
            'json:test-site-other:other-drama',
            'test-site-other',
            'SSIS-00123 其他标题',
          );
      await tester.pumpWidget(
        MaterialApp(
          home: ActressDetailPage(
            localId: person.localId,
            repository: repository,
            store: store,
            database: db,
            filmDb: _CardsFilmDb({
              'SSIS123': [
                ActressJsonEntry(
                  site: 'test-site-other',
                  vodId: 'other-drama',
                  vodName: 'SSIS-00123 其他标题',
                  vodPic: '',
                  vodActor: '女演员甲',
                  vodDirector: '',
                  vodRemarks: '',
                  vodPubdate: '',
                  vodArea: '',
                  vodYear: '',
                  vodContent: '',
                  vodPlayFrom: 'test-site-other',
                  vodPlayUrl: '正片\$https://example.test/other.mp4',
                  typeName: '',
                  vodCode: 'SSIS-00123',
                  vodActressPic: '',
                ),
              ],
            }),
            verifyFetch: _alwaysPlayable,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DramaTile).first);
      // 只 pump 1 秒（10 × 100ms）：旧流程此时竞速还在等 resolve
      // 超时，详情页不可能出现；新流程点卡即推页，1 秒内必出现。
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(DetailScreen).evaluate().isNotEmpty) break;
      }
      expect(find.byType(DetailScreen), findsOneWidget);
      expect(find.text('SSIS-00123 其他标题'), findsWidgets);
      // 收尾：把后台竞速的超时计时器都放完（resolve 8 秒 × 3 条
      // + MissAV 30 秒），否则 FakeAsync 里还有挂起的 Timer，
      // 测试框架在树 dispose 时会报 Timer pending。
      await tester.pump(const Duration(seconds: 60));
    });
  });

  group('探活链总预算', () {
    late _CardsRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerCardsTestSites();
      addTearDown(_unregisterCardsTestSites);
      repository = _CardsRepository();
      store = await _makeCardsStore();
    });

    test('慢站不拖过总预算：预算耗尽即判无源，剩下站不再起跑', () async {
      final sites = [
        for (var i = 0; i < 18; i++)
          SourceSite(
            'test-site-$i',
            '🔞测试站$i',
            '测试站',
            section: SourceSite.sectionVideo,
            origin: SourceSite.originImport,
          ),
      ];
      for (final site in sites) {
        SourceSite.importedSites[site.id] = site;
      }
      addTearDown(() {
        for (final site in sites) {
          SourceSite.importedSites.remove(site.id);
        }
      });
      final probe = _SlowProbeService(
        repository: repository,
        delay: const Duration(milliseconds: 300),
      );
      final chain = ActressPlayChain(
        repository: repository,
        store: store,
        avId: 'SSIS-00123',
        candidateSites: sites,
        probeService: probe,
        probeConcurrency: 6,
        totalBudget: const Duration(milliseconds: 400),
        verifyFetch: _alwaysPlayable,
      );
      final stopwatch = Stopwatch()..start();
      final candidate = await chain.nextPlayable(
        profileEpoch: store.profileEpoch,
      );
      stopwatch.stop();
      expect(candidate, isNull);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      // 18 站没探完：预算耗尽后剩下的站不再起跑。
      expect(probe.probed.length, lessThan(18));
      expect(probe.probed.length, greaterThan(0));
    });
  });

  group('MissAV folder 详情画作品卡片网格', () {
    late _CardsRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerCardsTestSites();
      addTearDown(_unregisterCardsTestSites);
      repository = _CardsRepository();
      store = await _makeCardsStore();
    });

    const folderDrama = Drama(
      id: 'folder-actress-1',
      source: 'jar:missav30:ZakaMissav',
      title: '测试女优',
      tags: ['folder'],
    );

    Future<void> pumpFolderDetail(
      WidgetTester tester, {
      required List<Drama> items,
      bool failCatalog = false,
    }) async {
      repository.detailsById['folder-actress-1'] = DramaDetail(folderDrama, [
        Episode({'id': '1', 'title': '第1集', 'currentEpisode': 1}, 1),
      ]);
      repository.catalogByCategory = {'folder-actress-1': items};
      repository.catalogFail = failCatalog;
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: DetailScreen(
            drama: folderDrama,
            repository: repository,
            store: store,
          ),
        ),
      );
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byKey(const ValueKey('folder-grid')).evaluate().isNotEmpty ||
            find.text('选集 · 1 集').evaluate().isNotEmpty) {
          break;
        }
      }
      await tester.pump(const Duration(milliseconds: 100));
    }

    List<Drama> folderItems(int count) => [
      for (var i = 1; i <= count; i++)
        Drama(
          id: 'folder-item-$i',
          source: 'jar:missav30:ZakaMissav',
          title: '作品$i',
          cover: 'https://cdn.example.com/item$i.jpg',
        ),
    ];

    testWidgets('多部作品画卡片网格，卡片数与目录一致、不画选集', (tester) async {
      await pumpFolderDetail(tester, items: folderItems(5));
      expect(find.byKey(const ValueKey('folder-grid')), findsOneWidget);
      for (var i = 1; i <= 5; i++) {
        expect(find.byKey(ValueKey('folder-folder-item-$i')), findsOneWidget);
      }
      expect(find.text('选集 · 1 集'), findsNothing);
      // 目录以 folder 的 id 作 category 调用。
      expect(repository.catalogCategories, contains('folder-actress-1'));
    });

    testWidgets('只有 1 部作品也不退回选集形态', (tester) async {
      await pumpFolderDetail(tester, items: folderItems(1));
      expect(find.byKey(const ValueKey('folder-grid')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('folder-folder-item-1')),
        findsOneWidget,
      );
      expect(find.text('选集 · 1 集'), findsNothing);
      expect(find.text('加载更多'), findsNothing);
    });

    testWidgets('目录失败退回选集 UI 并提示重试，重试后出网格', (tester) async {
      await pumpFolderDetail(tester, items: folderItems(3), failCatalog: true);
      expect(find.text('选集 · 1 集'), findsOneWidget);
      expect(find.text('作品列表加载失败，已显示选集'), findsOneWidget);
      repository.catalogFail = false;
      await tester.tap(find.byKey(const ValueKey('folder-retry')));
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byKey(const ValueKey('folder-grid')).evaluate().isNotEmpty) {
          break;
        }
      }
      expect(find.byKey(const ValueKey('folder-grid')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('folder-folder-item-3')),
        findsOneWidget,
      );
      expect(find.text('选集 · 1 集'), findsNothing);
    });
  });
}

/// 慢探活假服务：每站固定延迟后回空（无源），记录起跑过的站。
class _SlowProbeService extends CrossSiteProbeService {
  _SlowProbeService({required super.repository, required this.delay});

  final Duration delay;
  final probed = <String>[];

  @override
  Future<CrossSiteProbeResult> probeProvider(
    CrossSiteProvider provider,
    String siteId,
    String avId,
  ) async {
    probed.add(siteId);
    await Future.delayed(delay);
    return CrossSiteProbeResult(
      provider: provider,
      siteId: siteId,
      status: CrossSiteProbeStatus.empty,
    );
  }
}
