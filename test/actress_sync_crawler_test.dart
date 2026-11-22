// 女优库同步改爬虫（2026-11-20）：爬虫腿、并发、计数、排序、不自动爬。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_roster_sources.dart';
import 'package:moyi/actress/actress_site_crawl.dart';
import 'package:moyi/actress/actress_sync.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Future<ActressHttpResponse> _unusedFetch(
  String url, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 20),
}) async => throw UnimplementedError('fake source must not fetch');

Future<LocalStore> _makeStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

/// 计数同步服务：只记 run() 被调了几次（不自动爬断言用）。
class _CountingSyncService extends ActressSyncService {
  _CountingSyncService({required super.db, required super.sources})
    : super(fetch: _unusedFetch);

  var runs = 0;

  @override
  Future<ActressSyncResult> run({bool refresh = false}) {
    runs++;
    return super.run(refresh: refresh);
  }
}

/// 假潮流目录（爬虫腿用）：mjv 每分类每页 2 条、2 页后空；
/// 详情带演员行，取流回直链（走 FixtureRepository.resolve）。
class _LegRepository extends FixtureRepository {
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    if (page > 2) return CatalogPage([]);
    // 每页 24 条：少于 24 条会被当成最后一页，只爬 1 页就停。
    return CatalogPage([
      for (var i = 0; i < 24; i++)
        Drama(
          id:
              '$category#${1000 + page * 100 + i}#TEST-$page${i.toString().padLeft(2, '0')}',
          source: source,
          title: '测试标题 TEST-$page${i.toString().padLeft(2, '0')}',
          cover: 'https://x/${page}_$i.jpg',
          onlineDate: '2026-01-02',
        ),
    ]);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    return DramaDetail(
      Drama(
        id: drama.id,
        source: drama.source,
        title: drama.title,
        description: '剧情简介\n演员：测试女优',
        cover: drama.cover,
      ),
      [Episode({'id': 'a|b|c|d', 'title': '正片'}, 1)],
    );
  }
}

/// 带并发计数的名册源：每页拖 10ms，记同时在途的取页数。
class _TrackingRosterSource implements ActressRosterSource {
  _TrackingRosterSource({required this.sourceId, required this.pages});

  @override
  final ActressRosterSourceId sourceId;
  final int pages;
  var inFlight = 0;
  var maxInFlight = 0;
  final fetched = <int>[];

  @override
  ActressRosterSourceId get id => sourceId;

  @override
  Future<ActressRosterPage> fetchRosterPage(
    int page, {
    required ActressHttpFetch fetch,
  }) async {
    fetched.add(page);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    inFlight--;
    if (page > pages) {
      return const ActressRosterPage(persons: [], hasMore: false);
    }
    return ActressRosterPage(
      persons: [
        RosterPerson(
          source: sourceId,
          sourceId: 'p$page',
          name: '演员$page',
          sex: 'female',
        ),
      ],
      hasMore: page < pages,
    );
  }

  @override
  Future<List<RosterFilm>> fetchFilms(
    String sourceId, {
    required ActressHttpFetch fetch,
  }) async => const [];

  @override
  Future<ActressRosterPage> fetchRankingPage(
    int page, {
    required ActressHttpFetch fetch,
  }) async => const ActressRosterPage(persons: [], hasMore: false);
}

void main() {
  group('同步改爬虫：潮流作品走爬虫腿', () {
    late Directory temp;
    late MemoryActressDatabase db;

    setUp(() {
      temp = Directory.systemTemp.createTempSync();
      db = MemoryActressDatabase();
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    test('潮流作品阶段调现爬：json 落单文件、进库镜像、检查点完成', () async {
      final repo = _LegRepository();
      final crawl = ActressSiteCrawlService(
        repository: repo,
        db: db,
        documentsDir: temp,
      );
      addTearDown(crawl.dispose);
      final chaoliu = FakeRosterSource(
        sourceId: ActressRosterSourceId.chaoliu,
        rosterPages: [
          [
            const RosterPerson(
              source: ActressRosterSourceId.chaoliu,
              sourceId: 'A',
              name: '演员甲',
              sex: 'female',
            ),
          ],
        ],
      );
      final sync = ActressSyncService(
        db: db,
        sources: [chaoliu],
        fetch: _unusedFetch,
        crawlService: crawl,
      );
      addTearDown(sync.dispose);
      final details = <String>[];
      sync.progress.listen((p) {
        if (p.detail.isNotEmpty) details.add(p.detail);
      });
      final result = await sync.run();
      expect(result.hasFailures, isFalse);

      // films 检查点由爬虫腿写完成。
      final films = await db.checkpoint(
        ActressRosterSourceId.chaoliu,
        'films',
      );
      expect(films, isNotNull);
      expect(films!.finished, isTrue);

      // 单文件 mjv011.json 里有行（10 分类 × 2 页 × 24 条；同番号在
      // 不同分类里各留一行，json 不按番号去重）。
      final file = File('${temp.path}/actress_json/mjv011.json');
      expect(file.existsSync(), isTrue);
      final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect((doc['list'] as List).length, 10 * 2 * 24);

      // 进库镜像：补流出的“测试女优”有人物且有作品行；作品表按
      // （人，站，番号）去重，10 个分类里同番号只留 1 行。
      final persons = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.nameAsc,
        query: '测试女优',
        offset: 0,
        limit: 10,
      );
      expect(persons.length, 1);
      expect(persons.single.sex, 'female');
      final works = await db.worksForPerson(
        persons.single.localId,
        offset: 0,
        limit: 100,
      );
      expect(works.length, 2 * 24);

      // 进度带爬虫真实文案（分类/页/条数），不是空 detail。
      expect(details.any((d) => d.contains('现爬')), isTrue);
    });

    test('MissAV 失败不拖垮其余源（三源并行）', () async {
      final missav = FakeRosterSource(
        sourceId: ActressRosterSourceId.missav,
        rosterPages: [
          [
            const RosterPerson(
              source: ActressRosterSourceId.missav,
              sourceId: '/p-a',
              name: '演员甲',
            ),
          ],
        ],
        failRosterPages: {1},
      );
      final whos = FakeRosterSource(
        sourceId: ActressRosterSourceId.whos,
        rosterPages: [
          [
            const RosterPerson(
              source: ActressRosterSourceId.whos,
              sourceId: 'w1',
              name: '演员丙',
            ),
          ],
        ],
      );
      final sync = ActressSyncService(
        db: db,
        sources: [missav, whos],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);
      final result = await sync.run();
      expect(result.failedSources, [ActressRosterSourceId.missav]);
      expect(
        await db.countPersons(sex: ActressSexFilter.all, query: ''),
        1,
      );
    });
  });

  group('多进程并发', () {
    test('名册 3 个取页工人并行（同时在途 >1）', () async {
      final db = MemoryActressDatabase();
      final source = _TrackingRosterSource(
        sourceId: ActressRosterSourceId.chaoliu,
        pages: 6,
      );
      final sync = ActressSyncService(
        db: db,
        sources: [source],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);
      await sync.run();
      // 6 页全取到，且取页确实并行过（不是一页一页顺序爬）。
      // 3 工人从共享计数器领页：最后一页（hasMore=false）的结果
      // 回来之前，已领到手的页（最多多 2 页）照常取完——多取的
      // 是空页，不入库，所以只断言 1..6 全在、且不超出 8。
      expect(source.fetched.toSet().containsAll({1, 2, 3, 4, 5, 6}), isTrue);
      expect(
        source.fetched.toSet().difference({1, 2, 3, 4, 5, 6, 7, 8}),
        isEmpty,
      );
      expect(source.maxInFlight, greaterThan(1));
      expect(await db.countPersons(sex: ActressSexFilter.all, query: ''), 6);
    });

    test('排行并行取、按页顺序提交，名次不错位', () async {
      final db = MemoryActressDatabase();
      final missav = FakeRosterSource(
        sourceId: ActressRosterSourceId.missav,
        rankingPages: [
          [
            const RosterPerson(
              source: ActressRosterSourceId.missav,
              sourceId: '/r1',
              name: '第一名',
            ),
            const RosterPerson(
              source: ActressRosterSourceId.missav,
              sourceId: '/r2',
              name: '第二名',
            ),
          ],
          [
            const RosterPerson(
              source: ActressRosterSourceId.missav,
              sourceId: '/r3',
              name: '第三名',
            ),
            const RosterPerson(
              source: ActressRosterSourceId.missav,
              sourceId: '/r4',
              name: '第四名',
            ),
          ],
        ],
      );
      final sync = ActressSyncService(
        db: db,
        sources: [missav],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);
      await sync.run();
      final persons = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.nameAsc,
        query: '',
        offset: 0,
        limit: 10,
      );
      final byRank = {for (final p in persons) p.missavRank: p.displayName};
      expect(byRank[1], '第一名');
      expect(byRank[2], '第二名');
      expect(byRank[3], '第三名');
      expect(byRank[4], '第四名');
    });

    test('作品全败也不掀翻整轮：run 正常返回，检查点未完成', () async {
      final db = MemoryActressDatabase();
      final failing = FakeRosterSource(
        sourceId: ActressRosterSourceId.chaoliu,
        rosterPages: [
          [
            const RosterPerson(
              source: ActressRosterSourceId.chaoliu,
              sourceId: 'A',
              name: '演员甲',
              sex: 'female',
            ),
            const RosterPerson(
              source: ActressRosterSourceId.chaoliu,
              sourceId: 'B',
              name: '演员乙',
              sex: 'female',
            ),
          ],
        ],
        failFilmsFor: {'A', 'B'},
      );
      final sync = ActressSyncService(
        db: db,
        sources: [failing],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);
      // 全败也不应抛错（旧版失败路径写库再抛错会掀翻工人、冻住横幅）。
      final result = await sync.run();
      expect(result.persons, 2);
      final films = await db.checkpoint(
        ActressRosterSourceId.chaoliu,
        'films',
      );
      expect(films, isNotNull);
      expect(films!.finished, isFalse);
    });
  });

  group('计数要入库才算', () {
    test('displayWorks 只算入库数，不算站方宣称数', () {
      // 波多野結衣式案例：宣称数再大，卡片也只显示入库数。
      const person = ActressPerson(
        displayName: '波多野結衣',
        worksCount: 42,
        rosterWorks: 1302,
      );
      expect(person.displayWorks, 42);
      const noWorks = ActressPerson(
        displayName: '只有名册',
        worksCount: 0,
        rosterWorks: 6956,
      );
      expect(noWorks.displayWorks, 0);
    });

    test('overview.personsWithWorks 只算有入库作品的人', () async {
      final db = MemoryActressDatabase();
      final a = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'a',
          name: '有作品',
          sex: 'female',
        ),
      ))!;
      await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'b',
          name: '只有名册',
          sex: 'female',
        ),
      );
      await db.upsertWorks(a.localId, const [
        RosterFilm(code: 'SSIS-100'),
      ]);
      final overview = await db.overview();
      expect(overview.persons, 2);
      expect(overview.works, 1);
      expect(overview.personsWithWorks, 1);
    });
  });

  group('排序最近更新', () {
    test('按入库最新作品日期倒序，无作品的人沉底', () async {
      final db = MemoryActressDatabase();
      Future<int> seed(String name, List<(String, String)> works) async {
        final person = (await db.upsertRosterPerson(
          RosterPerson(
            source: ActressRosterSourceId.chaoliu,
            sourceId: 'id-$name',
            name: name,
            sex: 'female',
          ),
        ))!;
        for (final (code, date) in works) {
          await db.upsertWorks(person.localId, [
            RosterFilm(code: code, date: date),
          ]);
        }
        return person.localId;
      }

      await seed('旧作多', [('AAA-001', '2026-01-15')]);
      await seed('最新', [('BBB-001', '2026-03-01')]);
      await seed('没作品', []);
      await seed('次新', [
        ('CCC-001', '2026-02-01'),
        ('CCC-002', '2025-12-01'),
      ]);
      final persons = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.recentDesc,
        query: '',
        offset: 0,
        limit: 10,
      );
      expect(
        persons.map((p) => p.displayName).toList(),
        ['最新', '次新', '旧作多', '没作品'],
      );
      // 另外两种排序不受影响。
      final byWorks = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.worksDesc,
        query: '',
        offset: 0,
        limit: 10,
      );
      expect(byWorks.first.displayName, '次新');
      final byName = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.nameAsc,
        query: '',
        offset: 0,
        limit: 10,
      );
      expect(byName.first.displayName, '旧作多');
    });
  });

  group('不自动爬取', () {
    testWidgets('库非空时打开列表页不自动跑同步', (tester) async {
      final db = MemoryActressDatabase();
      final store = await _makeStore();
      final sync = _CountingSyncService(db: db, sources: const []);
      addTearDown(sync.dispose);
      final temp = Directory.systemTemp.createTempSync();
      addTearDown(() => temp.deleteSync(recursive: true));
      final fallback = ActressJsonFallback(documentsDir: temp);
      // 2026-11-20 MYTV 绑定：空库打开也不自动生成（2026-11-22
      // 用户令最终口径），所以这条“不自动跑”在库非空时成立——
      // 先预置一人。
      await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'id-seed',
          name: '种子演员',
          sex: 'female',
        ),
      );
      // 2026-11-20：列表页 bootstrap 里 await 平台通道拿 MYTV
      // 绑定（真机上毫秒级）；FakeAsync 下平台通道等不到返回，
      // 按树里老办法包在 runAsync 里跑（见 AGENTS.md）。
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: ActressListPage(
              repository: FixtureRepository(),
              store: store,
              database: db,
              syncService: sync,
              fallback: fallback,
            ),
          ),
        );
        await tester.pumpAndSettle();
        // 没点刷新、没新 json：一次都没跑；设置弹窗（2026-11-21
        // 起顶栏不再排横幅，同步文案收进这个弹窗）里是未完成那条——
        // 本测没记检查点，allDone 为假，所以带“部分还没同步完”
        // 后缀；弹窗里同步区是多行拼成一个 Text（增长行 + 同步行），
        // 用 textContaining 找这一行。
        expect(sync.runs, 0);
        await tester.tap(
          find.byKey(const ValueKey('open-actress-settings')),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('已同步 1 人 · 0 部作品，部分还没同步完'),
          findsOneWidget,
        );
      });
    });

    testWidgets('库空时也不自动生成同步', (tester) async {
      final db = MemoryActressDatabase();
      final store = await _makeStore();
      final sync = _CountingSyncService(db: db, sources: const []);
      addTearDown(sync.dispose);
      final temp = Directory.systemTemp.createTempSync();
      addTearDown(() => temp.deleteSync(recursive: true));
      final fallback = ActressJsonFallback(documentsDir: temp);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: ActressListPage(
              repository: FixtureRepository(),
              store: store,
              database: db,
              syncService: sync,
              fallback: fallback,
            ),
          ),
        );
        await tester.pumpAndSettle();
        // 空库也不自动生成（2026-11-22 用户令最终口径）：不灌
        // 内置 json 种子、不走互联网同步，同步一次都不跑。
        expect(sync.runs, 0);
      });
    });

    testWidgets('排序菜单有最近更新，切换后按最新作品倒序', (tester) async {
      final db = MemoryActressDatabase();
      final store = await _makeStore();
      final sync = _CountingSyncService(db: db, sources: const []);
      addTearDown(sync.dispose);
      Future<void> seed(String name, List<(String, String)> works) async {
        final person = (await db.upsertRosterPerson(
          RosterPerson(
            source: ActressRosterSourceId.chaoliu,
            sourceId: 'id-$name',
            name: name,
            sex: 'female',
          ),
        ))!;
        for (final (code, date) in works) {
          await db.upsertWorks(person.localId, [
            RosterFilm(code: code, date: date),
          ]);
        }
      }

      await seed('旧作多', [('AAA-001', '2026-01-15')]);
      await seed('最新', [('BBB-001', '2026-03-01')]);
      await seed('没作品', []);
      await seed('次新', [('CCC-001', '2026-02-01')]);
      final temp = Directory.systemTemp.createTempSync();
      addTearDown(() => temp.deleteSync(recursive: true));
      final fallback = ActressJsonFallback(documentsDir: temp);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: ActressListPage(
              repository: FixtureRepository(),
              store: store,
              database: db,
              syncService: sync,
              fallback: fallback,
            ),
          ),
        );
        await tester.pumpAndSettle();
        // 默认按作品数：旧作多与最新各 1 部、没作品 0 部。
        expect(find.text('按作品数'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('actress-sort-menu')));
        await tester.pumpAndSettle();
        expect(find.text('最近更新'), findsOneWidget);
        await tester.tap(find.text('最近更新'));
        await tester.pumpAndSettle();
        expect(find.text('最近更新'), findsOneWidget);
        // 最近更新顺序：第一行左→右是最新（2026-03-01）、次新
        // （2026-02-01）、旧作多（2026-01-15）。没作品沉底由上面
        // 的单元测试断言（第 4 张卡片在屏外，GridView 不构建它）。
        final latest = tester.getTopLeft(find.text('最新'));
        final second = tester.getTopLeft(find.text('次新'));
        final older = tester.getTopLeft(find.text('旧作多'));
        expect(latest.dx, lessThan(second.dx));
        expect(second.dx, lessThan(older.dx));
      });
    });
  });
}
