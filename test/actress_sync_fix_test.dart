// 演员库同步“卡”的四个大改动（2026-11-24，赶 v65）：
// ① 补流期间上报进度 ② 取消真中断 ③ _appendEntries 批量落盘
// ④ 作品旧路按页重试 + 阶段总预算。
// 每件改动至少一个单测，验收都以“慢站实测数据”为准：用假源模拟
// 慢单元（几秒一页、几百毫秒一条详情），量进度几秒一跳、取消几秒停、
// 写盘几次、重试几遍、预算到时停在哪——不只看代码。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_roster_sources.dart';
import 'package:moyi/actress/actress_site_crawl.dart';
import 'package:moyi/actress/actress_sync.dart';
import 'package:moyi/models.dart';

import 'fixtures.dart';

Future<ActressHttpResponse> _unusedFetch(
  String url, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 20),
}) async => throw UnimplementedError('fake source must not fetch');

/// 按页取作品的假源：作品清单按页给、可指定某页先失败几次、每页
/// 可拖慢。记每（人，页）实际取了几次——断言“失败只重试失败那页”
/// 就看它：第 1 页只取 1 次，第 2 页失败 2 次后成功一共 3 次。
class _PagedFilmsSource implements ActressRosterSource {
  _PagedFilmsSource({
    required this.sourceId,
    required this.rosterPages,
    required this.filmsPages,
    this.failTimes = const {},
    this.fetchDelay = Duration.zero,
  });

  final ActressRosterSourceId sourceId;
  final List<List<RosterPerson>> rosterPages;

  /// 人 → 页 → 作品：页序号 1 起；没给的页返回空页（到头）。
  final Map<String, List<List<RosterFilm>>> filmsPages;

  /// （人，页）→ 先失败几次再成功。
  final Map<(String, int), int> failTimes;
  final Duration fetchDelay;

  /// （人，页）→ 实际取了几次。
  final attempts = <(String, int), int>{};

  @override
  ActressRosterSourceId get id => sourceId;

  @override
  Future<ActressRosterPage> fetchRosterPage(
    int page, {
    required ActressHttpFetch fetch,
  }) async {
    final index = page - 1;
    if (index < 0 || index >= rosterPages.length) {
      return const ActressRosterPage(persons: [], hasMore: false);
    }
    return ActressRosterPage(
      persons: rosterPages[index],
      hasMore: index + 1 < rosterPages.length,
    );
  }

  @override
  Future<List<RosterFilm>> fetchFilmsPage(
    String sourceId,
    int page, {
    required ActressHttpFetch fetch,
  }) async {
    final key = (sourceId, page);
    attempts[key] = (attempts[key] ?? 0) + 1;
    if (fetchDelay > Duration.zero) {
      await Future<void>.delayed(fetchDelay);
    }
    final remaining = failTimes[key] ?? 0;
    if ((attempts[key] ?? 0) <= remaining) {
      throw StateError('fake films failure $sourceId page $page');
    }
    final pages = filmsPages[sourceId] ?? const [];
    final index = page - 1;
    if (index < 0 || index >= pages.length) return const [];
    return pages[index];
  }

  @override
  Future<List<RosterFilm>> fetchFilms(
    String sourceId, {
    required ActressHttpFetch fetch,
  }) async {
    final films = <RosterFilm>[];
    for (var page = 1; ; page++) {
      final pageFilms = await fetchFilmsPage(sourceId, page, fetch: fetch);
      if (pageFilms.isEmpty) break;
      films.addAll(pageFilms);
    }
    return films;
  }

  @override
  Future<ActressRosterPage> fetchRankingPage(
    int page, {
    required ActressHttpFetch fetch,
  }) async => const ActressRosterPage(persons: [], hasMore: false);
}

/// 慢名册源：每页拖 2.6 秒再回，每页 3 人。
class _SlowRosterSource implements ActressRosterSource {
  _SlowRosterSource({required this.sourceId, required this.pages});

  final ActressRosterSourceId sourceId;
  final int pages;

  @override
  ActressRosterSourceId get id => sourceId;

  @override
  Future<ActressRosterPage> fetchRosterPage(
    int page, {
    required ActressHttpFetch fetch,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 2600));
    if (page > pages) {
      return const ActressRosterPage(persons: [], hasMore: false);
    }
    return ActressRosterPage(
      persons: [
        for (var i = 0; i < 3; i++)
          RosterPerson(
            source: sourceId,
            sourceId: 'p${page}_$i',
            name: '演员${page}_$i',
            sex: 'female',
          ),
      ],
      hasMore: page < pages,
    );
  }

  @override
  Future<List<RosterFilm>> fetchFilmsPage(
    String sourceId,
    int page, {
    required ActressHttpFetch fetch,
  }) async => const [];

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

/// 慢潮流目录：每页 24 条满页，第 3 页起空；详情拖 [detailDelay]，
/// 目录拖 [catalogDelay]。详情带演员行，取流回直链。
class _SlowCrawlRepository extends FixtureRepository {
  _SlowCrawlRepository({
    this.catalogDelay = Duration.zero,
    this.detailDelay = Duration.zero,
  });

  final Duration catalogDelay;
  final Duration detailDelay;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    if (catalogDelay > Duration.zero) {
      await Future<void>.delayed(catalogDelay);
    }
    if (page > 2) return CatalogPage([]);
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
    if (detailDelay > Duration.zero) {
      await Future<void>.delayed(detailDelay);
    }
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

/// 批量落盘用的通用站假仓：2 分类 × 50 页 × 24 条，补流 0。
class _BatchCrawlRepository extends FixtureRepository {
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [
    CatalogCategory('cat-a', '分类A'),
    CatalogCategory('cat-b', '分类B'),
  ];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    if (page > 50) return CatalogPage([]);
    return CatalogPage([
      for (var i = 0; i < 24; i++)
        Drama(
          id:
              '$category#${1000 + page * 100 + i}#AAA-$page${i.toString().padLeft(2, '0')}',
          source: source,
          title: '测试标题 AAA-$page${i.toString().padLeft(2, '0')}',
          cover: 'https://x/${page}_$i.jpg',
          onlineDate: '2026-01-02',
        ),
    ]);
  }
}

void main() {
  group('④ 作品旧路按页重试', () {
    test('一页失败只重试这一页，已取到的页不重取', () async {
      final db = MemoryActressDatabase();
      final source = _PagedFilmsSource(
        sourceId: ActressRosterSourceId.whos,
        rosterPages: [
          [
            const RosterPerson(
              source: ActressRosterSourceId.whos,
              sourceId: 'w1',
              name: '演员甲',
              sex: 'female',
            ),
          ],
        ],
        filmsPages: {
          'w1': [
            [const RosterFilm(code: 'AAA-001'), const RosterFilm(code: 'AAA-002')],
            [const RosterFilm(code: 'AAA-003')],
          ],
        },
        // 第 2 页先失败 2 次再成功：旧的整人重试会把第 1 页也重取
        // 3 遍（第 1 页一共取 4 次）；新写法第 1 页只取 1 次。
        failTimes: {('w1', 2): 2},
      );
      final sync = ActressSyncService(
        db: db,
        sources: [source],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);
      await sync.run();

      // 第 1 页只取 1 次，第 2 页取 3 次（2 次失败 + 1 次成功），
      // 第 3 页取 1 次（空页到头）。
      expect(source.attempts[('w1', 1)], 1);
      expect(source.attempts[('w1', 2)], 3);
      expect(source.attempts[('w1', 3)], 1);
      // 3 部作品全入库，检查点完成。
      final persons = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.nameAsc,
        query: '演员甲',
        offset: 0,
        limit: 10,
      );
      expect(persons.length, 1);
      final works = await db.worksForPerson(
        persons.single.localId,
        offset: 0,
        limit: 10,
      );
      expect(works.length, 3);
      final films = await db.checkpoint(
        ActressRosterSourceId.whos,
        'films',
      );
      expect(films, isNotNull);
      expect(films!.finished, isTrue);
    });

    test('whos 单页原语只取请求的页', () async {
      final fetchedUrls = <String>[];
      Future<ActressHttpResponse> fakeFetch(
        String url, {
        Map<String, String> headers = const {},
        Duration timeout = const Duration(seconds: 20),
      }) async {
        fetchedUrls.add(url);
        if (url.contains('page-2')) {
          return const ActressHttpResponse(
            statusCode: 200,
            body: '<html><body></body></html>',
          );
        }
        return const ActressHttpResponse(
          statusCode: 200,
          body:
              '<a href="/videos/SSIS-123"><h3>SSIS-123 测试标题</h3></a>'
              '<a href="/videos/SSIS-124"><h3>SSIS-124 测试标题2</h3></a>',
        );
      }

      final source = WhosRosterSource();
      // 第 1 页 2 部，第 2 页空页到头：fetchFilms 一共只取 2 次，
      // 不再像旧写法那样整人循环里多取。
      final films = await source.fetchFilms('some-slug', fetch: fakeFetch);
      expect(films.map((f) => f.code).toList(), ['SSIS-123', 'SSIS-124']);
      expect(fetchedUrls.length, 2);
      expect(fetchedUrls[0], contains('/actresses/some-slug'));
      expect(fetchedUrls[0], isNot(contains('page-')));
      expect(fetchedUrls[1], contains('/actresses/some-slug/page-2'));

      // 单页原语直接取第 2 页：只发一次第 2 页请求。
      fetchedUrls.clear();
      final page2 = await source.fetchFilmsPage(
        'some-slug',
        2,
        fetch: fakeFetch,
      );
      expect(page2, isEmpty);
      expect(fetchedUrls.length, 1);
      expect(fetchedUrls.single, contains('page-2'));
    });
  });

  group('④ 阶段总预算', () {
    test('作品阶段预算到时停下、断点未完成、人还在待取里', () async {
      final db = MemoryActressDatabase();
      final source = _PagedFilmsSource(
        sourceId: ActressRosterSourceId.whos,
        rosterPages: [
          [
            for (var i = 0; i < 5; i++)
              RosterPerson(
                source: ActressRosterSourceId.whos,
                sourceId: 'w$i',
                name: '演员$i',
                sex: 'female',
              ),
          ],
        ],
        filmsPages: {
          for (var i = 0; i < 5; i++)
            'w$i': [
              [RosterFilm(code: 'AAA-10$i')],
              [RosterFilm(code: 'AAA-20$i')],
              [RosterFilm(code: 'AAA-30$i')],
              [RosterFilm(code: 'AAA-40$i')],
              [RosterFilm(code: 'AAA-50$i')],
            ],
        },
        // 每页 2 秒、预算 300 毫秒：4 个工人各取完第 1 页（2 秒）
        // 后，第 2 页检查已过预算，停下；第 5 个人根本没领到。
        fetchDelay: const Duration(seconds: 2),
      );
      final sync = ActressSyncService(
        db: db,
        sources: [source],
        fetch: _unusedFetch,
        filmsPhaseBudget: const Duration(milliseconds: 300),
      );
      addTearDown(sync.dispose);
      final stopwatch = Stopwatch()..start();
      final result = await sync.run();
      stopwatch.stop();

      expect(result.budgetExpired, isTrue);
      expect(result.cancelled, isFalse);
      // 4 个工人各只取了第 1 页，第 2 页起一页都没取。
      expect(source.attempts.length, 4);
      expect(
        source.attempts.values.fold<int>(0, (sum, n) => sum + n),
        4,
      );
      // 5 个人一个都没取完，全在待取清单里，下次可续。
      final pending = await db.personsPendingFilms(
        ActressRosterSourceId.whos,
      );
      expect(pending.length, 5);
      final films = await db.checkpoint(
        ActressRosterSourceId.whos,
        'films',
      );
      expect(films, isNotNull);
      expect(films!.finished, isFalse);
      // 整轮 2 秒多就停下，不是拖几小时：预算外的时间只花在
      // 在途那一页上（2 秒一页，4 路并行）。
      expect(stopwatch.elapsedMilliseconds, lessThan(10000));
    });
  });

  group('② 取消真中断', () {
    test('作品阶段点取消后不等在途页取完就停', () async {
      final db = MemoryActressDatabase();
      final source = _PagedFilmsSource(
        sourceId: ActressRosterSourceId.whos,
        rosterPages: [
          [
            const RosterPerson(
              source: ActressRosterSourceId.whos,
              sourceId: 'w1',
              name: '演员甲',
              sex: 'female',
            ),
          ],
        ],
        filmsPages: {
          'w1': [
            [const RosterFilm(code: 'AAA-001')],
          ],
        },
        // 在途一页要 5 秒：旧写法点取消后要等满 5 秒（再加重试
        // 退避）才停；新写法应 1 秒内停下。
        fetchDelay: const Duration(seconds: 5),
      );
      final sync = ActressSyncService(
        db: db,
        sources: [source],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);
      final runFuture = sync.run();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final stopwatch = Stopwatch()..start();
      sync.cancel();
      await runFuture;
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, lessThan(3000));
      expect(sync.isRunning, isFalse);
      final films = await db.checkpoint(
        ActressRosterSourceId.whos,
        'films',
      );
      expect(films, isNotNull);
      expect(films!.finished, isFalse);
    });

    test('现爬点取消后不等在途目录取完就停', () async {
      final db = MemoryActressDatabase();
      final temp = Directory.systemTemp.createTempSync();
      addTearDown(() => temp.deleteSync(recursive: true));
      final repo = _SlowCrawlRepository(
        catalogDelay: const Duration(seconds: 5),
      );
      final crawl = ActressSiteCrawlService(
        repository: repo,
        db: db,
        documentsDir: temp,
      );
      addTearDown(crawl.dispose);
      final runFuture = crawl.start(maxPagesPerCategory: 2);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final stopwatch = Stopwatch()..start();
      crawl.cancel();
      await runFuture;
      stopwatch.stop();

      // 在途一页要 5 秒：点取消后 3 秒内必须停下（实测毫秒级，
      // 3 秒是给 CI 抖动留的余量）。
      expect(stopwatch.elapsedMilliseconds, lessThan(3000));
      expect(crawl.running, isFalse);
      expect(crawl.current.done, isFalse);
      expect(crawl.current.error, '已取消');
    });
  });

  group('① 补流期间上报进度', () {
    test('补流每起一条就报一次，补流数在走', () async {
      final db = MemoryActressDatabase();
      final temp = Directory.systemTemp.createTempSync();
      addTearDown(() => temp.deleteSync(recursive: true));
      final repo = _SlowCrawlRepository(
        detailDelay: const Duration(milliseconds: 150),
      );
      final crawl = ActressSiteCrawlService(
        repository: repo,
        db: db,
        documentsDir: temp,
      );
      addTearDown(crawl.dispose);
      final progresses = <ActressSiteCrawlProgress>[];
      crawl.progress.listen(progresses.add);

      await crawl.start(maxPagesPerCategory: 1, enrichPerCategory: 3);

      expect(crawl.current.done, isTrue);
      expect(crawl.current.enriched, 10 * 3);
      // 补流文案出现过，且补流尝试数不止一个值：旧写法补流期间
      // 零进度上报，面板长时间停在一个数上；新写法每起一条
      // 详情就报一次 enrichTried。
      expect(
        progresses.any((p) => p.label.contains('补流中')),
        isTrue,
      );
      final tried = progresses.map((p) => p.enrichTried).toSet();
      expect(tried.length, greaterThan(3));
      expect(tried.reduce((a, b) => a > b ? a : b), 10 * 3);
    });

    test('名册取页慢时有心跳，存库期间按人报数', () async {
      final db = MemoryActressDatabase();
      final source = _SlowRosterSource(
        sourceId: ActressRosterSourceId.chaoliu,
        pages: 2,
      );
      final sync = ActressSyncService(
        db: db,
        sources: [source],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);
      final details = <String>[];
      sync.progress.listen((p) {
        if (p.detail.isNotEmpty) details.add(p.detail);
      });
      await sync.run();

      expect(await db.countPersons(sex: ActressSexFilter.all, query: ''), 6);
      // 每页 2.6 秒无新进度：心跳每秒报一次“取数中，已等 N 秒”。
      expect(details.any((d) => d.contains('取数中')), isTrue);
      // 存库期间按人报“第 X 页 · 已存 Y 人”。
      expect(details.any((d) => d.contains('已存')), isTrue);
    });
  });

  group('③ _appendEntries 批量落盘', () {
    test('100 页只写几次盘，文件仍全、断点完成', () async {
      final db = MemoryActressDatabase();
      final temp = Directory.systemTemp.createTempSync();
      addTearDown(() => temp.deleteSync(recursive: true));
      final repo = _BatchCrawlRepository();
      final crawl = ActressSiteCrawlService(
        repository: repo,
        db: db,
        documentsDir: temp,
      );
      addTearDown(crawl.dispose);
      ActressSiteCrawlService.flushWriteCount = 0;

      await crawl.start(site: 'test-site', enrichPerCategory: 0);

      // 2 分类 × 50 页 × 24 条 = 2400 条：旧写法每页全量重写
      // 一次（100 次写盘）；新写法攒够 500 条才写一批 + 分类
      // 结束各写一次，个位数写盘。
      expect(ActressSiteCrawlService.flushWriteCount, lessThanOrEqualTo(10));
      expect(ActressSiteCrawlService.flushWriteCount, greaterThan(0));
      final file = File('${temp.path}/actress_json/mjv011.json');
      expect(file.existsSync(), isTrue);
      final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect((doc['list'] as List).length, 2 * 50 * 24);
      final checkpoint = await db.checkpoint(
        ActressRosterSourceId.chaoliu,
        'site_crawl_test-site',
      );
      expect(checkpoint, isNotNull);
      expect(checkpoint!.finished, isTrue);
      expect(checkpoint.total, 2 * 50 * 24);
    });

    test('全是重复行不重写盘', () async {
      final db = MemoryActressDatabase();
      final temp = Directory.systemTemp.createTempSync();
      addTearDown(() => temp.deleteSync(recursive: true));
      final repo = _BatchCrawlRepository();
      final crawl = ActressSiteCrawlService(
        repository: repo,
        db: db,
        documentsDir: temp,
      );
      addTearDown(crawl.dispose);

      await crawl.start(site: 'test-site', enrichPerCategory: 0);
      final file = File('${temp.path}/actress_json/mjv011.json');
      final firstBytes = file.lengthSync();

      // 第二轮重爬同一批：行全是重复的，内存合并表不变，
      // 一次盘都不用写，文件字节数也不变。
      ActressSiteCrawlService.flushWriteCount = 0;
      await crawl.start(site: 'test-site', enrichPerCategory: 0);
      expect(ActressSiteCrawlService.flushWriteCount, 0);
      expect(file.lengthSync(), firstBytes);
      final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect((doc['list'] as List).length, 2 * 50 * 24);
    });
  });
}
