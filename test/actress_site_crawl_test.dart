// 女优库手机现爬（2026-11-19）：mjv 走潮流蜘蛛分类目录，有界、断点续跑。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_site_crawl.dart';
import 'package:moyi/models.dart';

import 'fixtures.dart';

/// 假潮流目录：每分类每页 24 条满页（番号页页不同），第 3 页起空；
/// 详情带演员行，取流回直链。满页 24 条是为贴合生产“短页即末页”
/// 启发（单页少于 24 条就停，不多跑空页省流量）。
class _CrawlRepository extends FixtureRepository {
  final calls = <({String category, int page})>[];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    calls.add((category: category, page: page));
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

void main() {
  late Directory temp;
  late MemoryActressDatabase db;

  setUp(() {
    temp = Directory.systemTemp.createTempSync();
    db = MemoryActressDatabase();
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  ActressSiteCrawlService makeService(_CrawlRepository repo) =>
      ActressSiteCrawlService(
        repository: repo,
        db: db,
        documentsDir: temp,
      );

  test('mjv 现爬有界：每分类只取前 N 页，写盘合格式，断点已存', () async {
    final repo = _CrawlRepository();
    final service = makeService(repo);
    addTearDown(service.dispose);
    final progresses = <ActressSiteCrawlProgress>[];
    service.progress.listen(progresses.add);

    await service.start(maxPagesPerCategory: 2, enrichPerCategory: 1);

    // 10 分类 × 2 页，每页 24 条。
    expect(repo.calls.length, 10 * 2);
    expect(repo.calls.map((c) => c.page).toSet(), {1, 2});
    // 终态读 service.current（同步更新）；broadcast 流最后一条
    // 完成事件投递是异步的，start() 返回时未必已送到监听器。
    expect(progresses.any((p) => p.running), isTrue);
    expect(service.current.done, isTrue);
    expect(service.current.items, 10 * 2 * 24);
    expect(service.current.enriched, 10);

    final file = File('${temp.path}/actress_json/mjv011.json');
    expect(file.existsSync(), isTrue);
    final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(
      () => validateActressJsonDocument(doc, '现爬 mjv011.json'),
      returnsNormally,
    );
    final rows = doc['list'] as List;
    expect(rows.length, 10 * 2 * 24);
    // 补流过的条目有女优名与直链。
    final enriched = rows
        .cast<Map<String, dynamic>>()
        .where((r) => (r['vod_play_url'] as String).isNotEmpty);
    expect(enriched.length, 10);
    expect(
      enriched.every(
        (r) =>
            (r['vod_play_url'] as String).startsWith('正片\$https://') &&
            (r['vod_actor'] as String) == '测试女优',
      ),
      isTrue,
    );

    final checkpoint = await db.checkpoint(
      ActressRosterSourceId.chaoliu,
      'site_crawl_mjv',
    );
    expect(checkpoint, isNotNull);
    expect(checkpoint!.finished, isTrue);
    expect(checkpoint.total, 10 * 2 * 24);
  });

  test('每分类只取前 1 页：页数上限生效', () async {
    final repo = _CrawlRepository();
    final service = makeService(repo);
    addTearDown(service.dispose);
    await service.start(maxPagesPerCategory: 1, enrichPerCategory: 0);
    expect(repo.calls.map((c) => c.page).toSet(), {1});
    expect(repo.calls.length, 10);
  });

  test('取消：跑完第一页就停，断点未完成', () async {
    final repo = _CrawlRepository();
    final service = makeService(repo);
    addTearDown(service.dispose);
    var cancelled = false;
    service.progress.listen((progress) {
      if (progress.running && !cancelled) {
        cancelled = true;
        service.cancel();
      }
    });
    await service.start(maxPagesPerCategory: 3, enrichPerCategory: 0);
    // 3 个分类工人并行：第一声进度就取消时，3 个工人手头的第 1 页
    // 都已发出、都会跑完（每页 24 条），所以条数是 24 的倍数、
    // 至少 48 条（单进程顺序爬只会是 24 条）；断点未完成。
    expect(service.current.items % 24, 0);
    expect(service.current.items, greaterThanOrEqualTo(48));
    expect(service.current.items, lessThanOrEqualTo(72));
    expect(service.current.done, isFalse);
    final checkpoint = await db.checkpoint(
      ActressRosterSourceId.chaoliu,
      'site_crawl_mjv',
    );
    expect(checkpoint, isNotNull);
    expect(checkpoint!.finished, isFalse);
  });

  test('whos 现爬报缺口：没有 whos 分类蜘蛛，不编假蜘蛛', () async {
    final repo = _CrawlRepository();
    final service = makeService(repo);
    addTearDown(service.dispose);
    final progresses = <ActressSiteCrawlProgress>[];
    service.progress.listen(progresses.add);
    await service.start(site: 'whos');
    expect(repo.calls, isEmpty);
    expect(service.current.error, contains('whos 暂无手机现爬'));
    expect(
      File('${temp.path}/actress_json/whos.json').existsSync(),
      isFalse,
    );
    // 单文件模型：whos 报缺口时什么文件都不写。
    expect(
      File('${temp.path}/actress_json/mjv011.json').existsSync(),
      isFalse,
    );
  });

  test('默认每分类 50 页、补流 50 条、不设总上限', () {
    expect(ActressSiteCrawlService.defaultMaxPagesPerCategory, 50);
    expect(ActressSiteCrawlService.defaultEnrichPerCategory, 50);
  });

  test('通用站现爬：分类取本站、蜘蛛走本站、条目记本站', () async {
    final repo = _GenericCrawlRepository();
    final service = makeService(repo);
    addTearDown(service.dispose);
    await service.start(site: 'test-site', maxPagesPerCategory: 1, enrichPerCategory: 1);

    expect(repo.categorySources, ['test-site']);
    expect(repo.catalogSources.toSet(), {'test-site'});
    expect(repo.calls.map((c) => c.category).toSet(), {'cat-a', 'cat-b'});
    expect(service.current.items, 2 * 24);
    expect(service.current.enriched, 2);

    // 单文件模型：任何站爬到的行都只进本地 mjv011.json 这一个文件，
    // 不分站另存 test-site.json、也不写旧的 mjv.json。
    final file = File('${temp.path}/actress_json/mjv011.json');
    expect(file.existsSync(), isTrue);
    expect(File('${temp.path}/actress_json/test-site.json').existsSync(), isFalse);
    expect(File('${temp.path}/actress_json/mjv.json').existsSync(), isFalse);
    final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final rows = doc['list'] as List;
    expect(rows.length, 2 * 24);
    final first = rows.first as Map<String, dynamic>;
    expect(first['vod_play_from'], 'test-site');
    expect(
      rows
          .cast<Map<String, dynamic>>()
          .every((r) => (r['vod_play_url'] as String).isEmpty),
      isFalse,
    );
    final checkpoint = await db.checkpoint(
      ActressRosterSourceId.chaoliu,
      'site_crawl_test-site',
    );
    expect(checkpoint, isNotNull);
    expect(checkpoint!.finished, isTrue);
  });

  test('默认 50 页跑满：2 分类 × 50 页 × 24 条，超 1000 不截断', () async {
    final repo = _GenericCrawlRepository()..maxPage = 50;
    final service = makeService(repo);
    addTearDown(service.dispose);
    await service.start(site: 'test-site', enrichPerCategory: 0);

    expect(repo.calls.map((c) => c.page).toSet(), {
      for (var p = 1; p <= 50; p++) p,
    });
    expect(repo.calls.length, 2 * 50);
    expect(service.current.items, 2 * 50 * 24);
    final file = File('${temp.path}/actress_json/mjv011.json');
    final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect((doc['list'] as List).length, 2 * 50 * 24);
  });

  test('多轮追加：本地文件持续增长、旧行不丢', () async {
    final repo = _GenericCrawlRepository()..maxPage = 1;
    final service = makeService(repo);
    addTearDown(service.dispose);
    final file = File('${temp.path}/actress_json/mjv011.json');

    await service.start(site: 'test-site', maxPagesPerCategory: 1, enrichPerCategory: 0);
    final firstDoc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final firstRows = firstDoc['list'] as List;
    expect(firstRows.length, 2 * 24);
    final firstBytes = file.lengthSync();
    final firstCode =
        (firstRows.first as Map<String, dynamic>)['vod_code'] as String;
    expect(firstCode, startsWith('AAA-'));

    // 第二轮：新番号（BBB-），旧行应保留、文件变大。
    repo.round = 2;
    await service.start(site: 'test-site', maxPagesPerCategory: 1, enrichPerCategory: 0);
    final secondDoc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final secondRows = secondDoc['list'] as List;
    expect(secondRows.length, 2 * 2 * 24);
    expect(file.lengthSync(), greaterThan(firstBytes));
    final codes = secondRows
        .cast<Map<String, dynamic>>()
        .map((r) => r['vod_code'] as String)
        .toSet();
    expect(codes, contains(firstCode));
    expect(codes.any((c) => c.startsWith('BBB-')), isTrue);
  });

  test('写盘后进库镜像：补流出的女优名进人表、作品行进 works 表', () async {
    final repo = _CrawlRepository();
    final service = makeService(repo);
    addTearDown(service.dispose);
    await service.start(maxPagesPerCategory: 1, enrichPerCategory: 1);

    // 10 分类各补流 1 条，详情都带“演员：测试女优”：目录行每分类
    // 24 条全进 json（10×24=240 行），其中每分类 1 条被补流出
    // 女优名与直链；作品表按（人，站，番号）去重，10 条补流行同
    // 番号只留 1 行，库里应有“测试女优”这个人且有 1 部作品。
    final file = File('${temp.path}/actress_json/mjv011.json');
    expect(file.existsSync(), isTrue);
    final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect((doc['list'] as List).length, 10 * 24);
    final persons = await db.listPersons(
      sex: ActressSexFilter.all,
      sort: ActressSort.nameAsc,
      query: '测试女优',
      offset: 0,
      limit: 10,
    );
    expect(persons.length, 1);
    expect(persons.single.displayName, '测试女优');
    expect(persons.single.sex, 'female');
    final works = await db.worksForPerson(
      persons.single.localId,
      offset: 0,
      limit: 50,
    );
    expect(works.length, 1);
    // 没女优名的目录行只留 json、不进库：库里作品数就是补流的 1 条。
    final overview = await db.overview();
    expect(overview.works, 1);
    expect(overview.personsWithWorks, 1);
  });

  test('单文件多站分流：通用站的行按 vod_play_from 认站进同一文件', () async {
    final repo = _GenericCrawlRepository()..maxPage = 1;
    final service = makeService(repo);
    addTearDown(service.dispose);
    await service.start(site: 'test-site', maxPagesPerCategory: 1, enrichPerCategory: 0);
    final doc = jsonDecode(
      File('${temp.path}/actress_json/mjv011.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final rows = doc['list'] as List;
    expect(rows.length, 2 * 24);
    expect(
      rows.cast<Map<String, dynamic>>().every(
        (r) => r['vod_play_from'] == 'test-site',
      ),
      isTrue,
    );
    // 加载器读这个单文件时按 vod_play_from 认站，不按文件名。
    final fallback = ActressJsonFallback(documentsDir: temp);
    await fallback.load();
    expect(fallback.counts['test-site'], 2 * 24);
  });
}

/// 通用站假仓：分类取本站现取（2 分类），目录按轮次出不同番号。
class _GenericCrawlRepository extends _CrawlRepository {
  final categorySources = <String>[];
  final catalogSources = <String>[];
  var round = 1;
  var maxPage = 1;

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    categorySources.add(source);
    return const [
      CatalogCategory('cat-a', '分类A'),
      CatalogCategory('cat-b', '分类B'),
    ];
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
    catalogSources.add(source);
    calls.add((category: category, page: page));
    if (page > maxPage) return CatalogPage([]);
    return CatalogPage([
      for (var i = 0; i < 24; i++)
        Drama(
          id:
              '$category#${1000 + page * 100 + i}#${round == 1 ? 'AAA' : 'BBB'}-$page${i.toString().padLeft(2, '0')}',
          source: source,
          title: '测试标题 ${round == 1 ? 'AAA' : 'BBB'}-$page${i.toString().padLeft(2, '0')}',
          cover: 'https://x/${page}_$i.jpg',
          onlineDate: '2026-01-02',
        ),
    ]);
  }
}
