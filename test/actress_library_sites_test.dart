// 女优库站源扩展（2026-11-20 用户令）：筛选进片库全部可见视频站
// （黑颜在内、游戏站 yikm 不在内）、通用站现爬、默认 50 页、本地
// 存储随爬取增长无死上限、零作品的人也覆盖。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_m3u_index.dart';
import 'package:moyi/actress/actress_search.dart';
import 'package:moyi/actress/actress_stacking.dart';
import 'package:moyi/builtin_py_sites.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _heiyanSite = SourceSite(
  'heiyan',
  '🔞黑颜禁播',
  '内置 py · heiyan',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originBuiltin,
  importType: 'py',
);
const _dramaSite = SourceSite(
  'drama-site',
  '短剧站',
  '短剧',
  section: SourceSite.sectionDrama,
  origin: SourceSite.originImport,
);
const _cloudSite = SourceSite(
  'cloud:pan',
  '网盘站',
  '网盘',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _hiddenSite = SourceSite(
  'hidden-video',
  '被隐藏的视频站',
  '视频',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _mjvSite = SourceSite(
  'mjv',
  'mjv',
  'mjv',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _chaoliuSite = SourceSite(
  'chaoliu',
  'chaoliu',
  '潮流',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);

void _registerLibrarySites() {
  for (final site in [
    _heiyanSite,
    _dramaSite,
    _cloudSite,
    _hiddenSite,
    _mjvSite,
    _chaoliuSite,
  ]) {
    SourceSite.importedSites[site.id] = site;
  }
}

void _unregisterLibrarySites() {
  for (final id in [
    'heiyan',
    'drama-site',
    'cloud:pan',
    'hidden-video',
    'mjv',
    'chaoliu',
  ]) {
    SourceSite.importedSites.remove(id);
  }
}

/// 假 m3u 索引：只回固定的一条 whos 行。
class _FakeM3uIndex extends WhosM3uIndex {
  @override
  Future<List<ActressJsonEntry>> entriesForActress(String name) async => [
    ActressJsonEntry(
      site: 'whos',
      vodId: 'm3u-1',
      vodName: 'm3u 作品',
      vodPic: '',
      vodActor: name,
      vodDirector: '',
      vodRemarks: '高清',
      vodPubdate: '',
      vodArea: '',
      vodYear: '',
      vodContent: '',
      vodPlayFrom: 'whos',
      vodPlayUrl: '正片\$https://m3u/1.m3u8',
      typeName: '日本AV',
      vodCode: 'M3U-001',
      vodActressPic: '',
    ),
  ];

  @override
  Future<List<ActressJsonEntry>> entriesForCode(String codeKey) async =>
      entriesForActress('');
}

Map<String, dynamic> _localRow({
  required String vodId,
  required String code,
  required String actor,
}) => ActressJsonEntry(
  site: 'heiyan',
  vodId: vodId,
  vodName: '测试作品 $code',
  vodPic: 'https://x/$vodId.jpg',
  vodActor: actor,
  vodDirector: '',
  vodRemarks: '高清',
  vodPubdate: '2026-01-01',
  vodArea: '日本',
  vodYear: '2026',
  vodContent: '<p>测试作品 $code</p>',
  vodPlayFrom: 'heiyan',
  vodPlayUrl: '正片\$https://x/$vodId.m3u8',
  typeName: '黑颜分类',
  vodCode: code,
  vodActressPic: '',
).toRow();

void main() {
  group('站点筛选选项', () {
    late LocalStore store;

    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      store = LocalStore(await SharedPreferences.getInstance());
    });

    setUp(() {
      _registerLibrarySites();
      addTearDown(_unregisterLibrarySites);
    });

    test('选项含黑颜、不含非视频/网盘/被隐藏站、不重复 mjv/whos', () async {
      await store.setSiteVisible('hidden-video', false);
      addTearDown(() async {
        await store.setSiteVisible('hidden-video', true);
      });
      final options = actressSiteFilterOptions(store);
      expect(options.take(3).map((o) => o.siteId).toList(), [
        'all',
        'mjv',
        'whos',
      ]);
      final ids = options.map((o) => o.siteId).toList();
      expect(ids, contains('heiyan'));
      expect(
        options.firstWhere((o) => o.siteId == 'heiyan').label,
        '🔞黑颜禁播',
      );
      expect(ids, isNot(contains('drama-site')));
      expect(ids, isNot(contains('cloud:pan')));
      expect(ids, isNot(contains('hidden-video')));
      expect(ids, isNot(contains('chaoliu')));
      expect(ids.where((id) => id == 'mjv'), hasLength(1));
      expect(ids.where((id) => id == 'whos'), hasLength(1));
    });

    test('叠加搜索站源含黑颜', () {
      expect(actressSearchSiteIds(store), contains('heiyan'));
    });

    test('yikm 不在内置登记里（游戏不进站点）', () {
      expect(BuiltinPySites.entryFor('yikm'), isNull);
      expect(
        BuiltinPySites.entries.any((e) => e.siteId == 'yikm'),
        isFalse,
      );
    });

    test('兜底卡点播按站取蜘蛛：mjv/whos 走潮流、片库站走本站', () {
      expect(ActressJsonFallback.spiderIdForSite('mjv'), 'chaoliu');
      expect(ActressJsonFallback.spiderIdForSite('whos'), 'chaoliu');
      expect(ActressJsonFallback.spiderIdForSite('heiyan'), 'heiyan');
    });
  });

  group('兜底加载器读本地片库站 JSON', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync();
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    Future<ActressJsonFallback> loadWithLocalHeiyan() async {
      final dir = Directory('${temp.path}/actress_json')
        ..createSync(recursive: true);
      File('${dir.path}/heiyan.json').writeAsStringSync(
        jsonEncode({
          'list': [
            _localRow(vodId: 'h1', code: 'HEY-001', actor: '测试演员'),
            _localRow(vodId: 'h2', code: 'HEY-002', actor: '测试演员'),
          ],
          'parse': 0,
          'jx': 0,
          'last_update': '2026-11-20T00:00:00',
        }),
      );
      final fallback = ActressJsonFallback(
        assetReader: (asset) async => jsonEncode({
          'list': <Map<String, dynamic>>[],
          'parse': 0,
          'jx': 0,
          'last_update': '',
        }),
        documentsDir: temp,
        m3uIndex: _FakeM3uIndex(),
      );
      await fallback.load();
      return fallback;
    }

    test('本地 heiyan.json 被读进来，按名按站可取', () async {
      final fallback = await loadWithLocalHeiyan();
      expect(fallback.counts['heiyan'], 2);
      final rows = fallback.entriesForActress('测试演员', site: 'heiyan');
      expect(rows, hasLength(2));
      expect(rows.every((e) => e.site == 'heiyan'), isTrue);
      expect(fallback.entriesForActress('测试演员'), hasLength(2));
      // 兜底卡点播走本站蜘蛛。
      expect(
        rows.first.toDramaDetail().drama.source,
        'heiyan',
      );
    });

    test('片库站异步取不并 m3u，全部/whos 才并', () async {
      final fallback = await loadWithLocalHeiyan();
      final heiyanRows = await fallback.entriesForActressAsync(
        '测试演员',
        site: 'heiyan',
      );
      expect(heiyanRows, hasLength(2));
      expect(heiyanRows.every((e) => e.site == 'heiyan'), isTrue);
      final whosRows = await fallback.entriesForActressAsync(
        '测试演员',
        site: 'whos',
      );
      expect(whosRows, hasLength(1));
      expect(whosRows.single.site, 'whos');
    });
  });

  group('零作品的人也覆盖', () {
    late MemoryActressDatabase db;
    late _NameHitRepository repository;
    late LocalStore store;

    setUp(() async {
      _registerLibrarySites();
      addTearDown(_unregisterLibrarySites);
      db = MemoryActressDatabase();
      repository = _NameHitRepository();
      SharedPreferences.setMockInitialValues({});
      store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
    });

    Future<ActressPerson> seedEmptyPerson() async {
      final person = await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'EMPTY-1',
          name: '空作品演员',
          sex: 'female',
        ),
      );
      return (await db.personById(person!.localId))!;
    }

    test('enrichPerson：零作品也按名搜，搜到新增进库', () async {
      final person = await seedEmptyPerson();
      expect(await db.countWorks(person.localId), 0);
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
      expect(works.single.codeKey, 'HEY1');
      expect(works.single.site, 'heiyan');
    });

    test('enrichPerson：零作品且搜不到，保持为空、不算完成', () async {
      final person = await seedEmptyPerson();
      repository.searchByQuery = {};
      final completed = await ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
      ).enrichPerson(person);
      expect(completed, isFalse);
      expect(await db.countWorks(person.localId), 0);
      expect(
        (await db.personById(person.localId))!.enrichedAt,
        isNull,
      );
    });

    test('叠加服务：零作品的人也进队列，爬到作品新增', () async {
      final person = await seedEmptyPerson();
      final service = ActressStackingService(
        db: db,
        enrichment: ActressEnrichment(
          repository: repository,
          store: store,
          db: db,
        ),
      );
      addTearDown(service.dispose);
      final result = await service.run();
      expect(result.processed, 1);
      expect(result.worksAdded, 1);
      expect(await db.countWorks(person.localId), 1);
    });
  });
}

/// 名字路假仓：按名返回一条带番号的黑颜命中。
class _NameHitRepository extends FixtureRepository {
  Map<String, List<Drama>> searchByQuery = {
    '空作品演员': [
      const Drama(
        id: 'heiyan:hey-001',
        source: 'heiyan',
        title: 'HEY-001 空作品演员',
        cover: 'https://cover/hey001.jpg',
      ),
    ],
  };

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    return CatalogPage(searchByQuery[query] ?? const []);
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}
