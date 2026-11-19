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

    final file = File('${temp.path}/actress_json/mjv.json');
    expect(file.existsSync(), isTrue);
    final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(
      () => validateActressJsonDocument(doc, '现爬 mjv.json'),
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
    // 只跑完第一页（24 条）就停。
    expect(service.current.items, 24);
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
  });
}
