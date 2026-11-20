import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_search.dart';
import 'package:moyi/crosssite_probe.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 女优库补封面中毒标记回归（2026-11-18 用户实报：友田真希人物页
/// 1276 部作品全无封面，同步条正在跑时打开过一次即被记成“已补过”）。
///
/// 旧行为：作品为空的一轮返回 true（已完成）→ 详情页记 enrichedAt；
/// enrichedAt 非空即永久跳过 → 作品同步进来后也再也不补封面。
/// 新行为：空作品轮返回 false（不算完成）；已记 enrichedAt 但仍有
/// 无封面作品时重新补；全部有封面时才跳过。
/// 2026-11-20 用户令补充（没有也要爬取新增）：零作品的人也照常跑
/// 名字路搜全站，搜到就新增进库；搜不到仍返回 false、不记 enrichedAt。
/// 本文件首个测试按新口径改：第一轮按名搜索（有一次名字查询），
/// 搜不到不算完成。

const _coverSiteA = SourceSite(
  'test-cover-a',
  '🔞测试站A',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _coverSiteB = SourceSite(
  'test-cover-b',
  '测试站B',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);

void _registerCoverSites() {
  for (final site in [_coverSiteA, _coverSiteB]) {
    SourceSite.importedSites[site.id] = site;
  }
}

void _unregisterCoverSites() {
  for (final site in [_coverSiteA, _coverSiteB]) {
    SourceSite.importedSites.remove(site.id);
  }
}

class _CoverScriptedRepository extends FixtureRepository {
  Map<String, List<Drama>> searchByQuery = {};
  final searchQueries = <String>[];

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    searchQueries.add(query);
    return CatalogPage(searchByQuery[query] ?? const []);
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

/// JavMenu 搜索命中的真实标题形态（用户截图 ROE-568 的标题原样节选）。
const _javmenuTitle =
    'ROE-568 新版破解 16年間マグロだと思ってた妻は… 不貞性交で痙攣ぶっ飛びウオ絶頂し失神するまでイキ続けていた件。 友田真希 免费AV在线看';

void main() {
  group('补封面中毒标记', () {
    late MemoryActressDatabase db;
    late _CoverScriptedRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerCoverSites();
      addTearDown(_unregisterCoverSites);
      db = MemoryActressDatabase();
      repository = _CoverScriptedRepository();
      SharedPreferences.setMockInitialValues({});
      store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
    });

    Future<ActressPerson> seedPerson({bool withWorks = true}) async {
      final person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'TOMODA',
          name: '友田真希',
          sex: 'female',
        ),
      ))!;
      if (withWorks) {
        await db.upsertWorks(person.localId, const [
          RosterFilm(code: 'ROE-568', date: '2026-10-27'),
          RosterFilm(code: 'ACHJ-103', date: '2026-10-13'),
        ]);
      }
      return (await db.personById(person.localId))!;
    }

    ActressEnrichment enrichment() =>
        ActressEnrichment(repository: repository, store: store, db: db);

    test('先 0 作品打开不算完成，作品进来后下次打开补上封面', () async {
      // 第一轮：同步还没跑到此人，作品为空；按新口径照常按名搜全站，
      // 搜不到不算完成（返回 false），调用方不得记 enrichedAt。
      final empty = await seedPerson(withWorks: false);
      final first = await enrichment().enrichPerson(empty);
      expect(first, isFalse);
      expect(repository.searchQueries, contains('友田真希'));
      // 调用方只在 completed 时记 enrichedAt：本轮不得记。
      final stillFresh = (await db.personById(empty.localId))!;
      expect(stillFresh.enrichedAt, isNull);

      // 作品同步进来；第二轮按番号搜到 JavMenu 形态标题，附上封面。
      await db.upsertWorks(empty.localId, const [
        RosterFilm(code: 'ROE-568', date: '2026-10-27'),
      ]);
      repository.searchByQuery = {
        'ROE-568': [
          const Drama(
            id: 'javmenu:roe568',
            source: 'test-cover-a',
            title: _javmenuTitle,
            cover: 'https://cover/roe568.jpg',
          ),
        ],
      };
      final person = (await db.personById(empty.localId))!;
      final second = await enrichment().enrichPerson(person);
      expect(second, isTrue);
      expect(repository.searchQueries, contains('ROE-568'));
      final works = await db.worksForPerson(
        empty.localId,
        offset: 0,
        limit: 10,
      );
      expect(works, hasLength(1));
      expect(works.single.hasCover, isTrue);
      expect(works.single.coverUrl, 'https://cover/roe568.jpg');
    });

    test('已中毒的人（enrichedAt 已记但无封面）重新补', () async {
      final person = await seedPerson();
      // 模拟旧版中毒：打开时作品为空被记了 enrichedAt，作品后进来。
      await db.markEnriched(person.localId);
      final poisoned = (await db.personById(person.localId))!;
      expect(poisoned.enrichedAt, isNotNull);

      repository.searchByQuery = {
        'ROE-568': [
          const Drama(
            id: 'javmenu:roe568',
            source: 'test-cover-a',
            title: _javmenuTitle,
            cover: 'https://cover/roe568.jpg',
          ),
        ],
        'ACHJ-103': [
          const Drama(
            id: 'missav:achj103',
            source: 'test-cover-b',
            title: 'ACHJ-103 友田真希',
            cover: 'https://cover/achj103.jpg',
          ),
        ],
      };
      final completed = await enrichment().enrichPerson(poisoned);
      expect(completed, isTrue);
      expect(repository.searchQueries, containsAll(['ROE-568', 'ACHJ-103']));
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works.every((w) => w.hasCover), isTrue);
    });

    test('已补过且全部有封面时跳过，不再搜索', () async {
      final person = await seedPerson();
      repository.searchByQuery = {
        'ROE-568': [
          const Drama(
            id: 'javmenu:roe568',
            source: 'test-cover-a',
            title: _javmenuTitle,
            cover: 'https://cover/roe568.jpg',
          ),
        ],
        'ACHJ-103': [
          const Drama(
            id: 'missav:achj103',
            source: 'test-cover-b',
            title: 'ACHJ-103 友田真希',
            cover: 'https://cover/achj103.jpg',
          ),
        ],
      };
      expect(await enrichment().enrichPerson(person), isTrue);
      final queriesAfterFirst = repository.searchQueries.length;
      expect(queriesAfterFirst, greaterThan(0));
      await db.markEnriched(person.localId);
      final fresh = (await db.personById(person.localId))!;
      expect(await enrichment().enrichPerson(fresh), isTrue);
      expect(repository.searchQueries.length, queriesAfterFirst);
    });

    test('名字路用真实标题形态对上番号并附封面', () async {
      final person = await seedPerson();
      repository.searchByQuery = {
        '友田真希': [
          const Drama(
            id: 'javmenu:roe568',
            source: 'test-cover-a',
            title: _javmenuTitle,
            cover: 'https://cover/roe568.jpg',
          ),
        ],
      };
      await enrichment().enrichPerson(person);
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      final roe = works.firstWhere((w) => w.codeKey == 'ROE568');
      expect(roe.hasCover, isTrue);
      expect(roe.coverUrl, 'https://cover/roe568.jpg');
      // 名字路只附已有行，不新增第二张 ROE-568 卡。
      expect(works.where((w) => w.codeKey == 'ROE568'), hasLength(1));
    });
  });

  group('番号对上逻辑（真实标题形态）', () {
    test('extractAvId 认 JavMenu 标题头的番号', () {
      expect(extractAvId(title: _javmenuTitle), 'ROE-568');
    });

    test('extractAvId 认标题中段的番号', () {
      expect(extractAvId(title: '友田真希 ROE-568 无码破解版在线播放'), 'ROE-568');
      expect(extractAvId(title: '[JUVR-281] 友田真希'), 'JUVR-281');
    });

    test('crossSiteHitMatches 去分隔符包含比对', () {
      expect(
        crossSiteHitMatches(title: _javmenuTitle, id: '', avId: 'ROE-568'),
        isTrue,
      );
      expect(
        crossSiteHitMatches(title: 'roe568 无码版', id: '', avId: 'ROE-568'),
        isTrue,
      );
      expect(
        crossSiteHitMatches(title: 'ROE-549 另一部', id: '', avId: 'ROE-568'),
        isFalse,
      );
    });
  });
}
